import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'codebuddy_account_models.dart';
import 'codebuddy_cli.dart';
import 'codebuddy_oauth.dart';
import 'codebuddy_quota.dart';

/// Manages CodeBuddy accounts (CN / Global / iOA / Enterprise / API Key),
/// OAuth sign-ins, automatic token refresh, live quota & credit tracking, and
/// 1-click / smart auto-switching inside Cyte.
///
/// Storage root: `~/.cyte/codebuddy_accounts/`.
class CodeBuddyAccounts extends ChangeNotifier {
  CodeBuddyAccounts({String? dataDir}) : _overrideDir = dataDir;

  static final CodeBuddyAccounts instance = CodeBuddyAccounts();

  /// Hook notified whenever the active CodeBuddy account switches so idle or
  /// next-turn `CodeBuddyTransport` processes respawn cleanly with the new
  /// account credentials and regional endpoint.
  static FutureOr<void> Function(CodeBuddyAccount? switched)?
  onActiveAccountSwitched;

  final String? _overrideDir;
  bool _initialized = false;
  Future<void>? _initFuture;
  Timer? _refreshTimer;
  Timer? _postTurnRefreshTimer;

  final List<CodeBuddyAccount> _accounts = [];
  String? _currentAccountId;
  CodeBuddyAutoSwitchConfig _autoSwitch = const CodeBuddyAutoSwitchConfig();

  final Set<String> _refreshingIds = {};
  bool _refreshingAll = false;
  String? _switchingId;
  String? _lastRefreshError;
  int _backgroundTick = 0;

  List<CodeBuddyAccount> get accounts => List.unmodifiable(_accounts);
  String? get currentAccountId => _currentAccountId;
  CodeBuddyAutoSwitchConfig get autoSwitch => _autoSwitch;
  bool get isRefreshingAll => _refreshingAll;
  String? get switchingId => _switchingId;
  String? get lastRefreshError => _lastRefreshError;
  bool isRefreshing(String id) => _refreshingIds.contains(id);

  CodeBuddyAccount? get currentAccount {
    final id = _currentAccountId;
    if (id != null) {
      for (final a in _accounts) {
        if (a.id == id) return a;
      }
    }
    return _accounts.firstOrNull;
  }

  String get dataDirectoryPath {
    if (_overrideDir case final dir? when dir.isNotEmpty) return dir;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return p.join(home, '.cyte', 'codebuddy_accounts');
  }

  Future<void> ensureInitialized() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      final dir = Directory(dataDirectoryPath);
      await dir.create(recursive: true);
      await _loadFromDisk(dir);
      _syncActiveRegionModels();
      _startBackgroundRefreshTimer();
      if (_accounts.isNotEmpty) {
        unawaited(refreshAllQuotas(silent: true));
      }
    } finally {
      _initialized = true;
    }
    notifyListeners();
  }

  Future<void> _loadFromDisk(Directory dir) async {
    _accounts.clear();
    final accountsDir = Directory(p.join(dir.path, 'accounts'));
    final byId = <String, CodeBuddyAccount>{};

    if (accountsDir.existsSync()) {
      for (final entity in accountsDir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = _stripBom(await entity.readAsString());
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final acc = CodeBuddyAccount.fromJson(
              decoded.cast<String, Object?>(),
            );
            if (acc.id.isNotEmpty) {
              byId[acc.id] = acc;
            }
          }
        } on Object {
          // Skip unreadable file.
        }
      }
    }

    final indexFile = File(p.join(dir.path, 'accounts.json'));
    final orderedIds = <String>[];
    if (indexFile.existsSync()) {
      try {
        final decoded = jsonDecode(_stripBom(await indexFile.readAsString()));
        if (decoded is Map) {
          _currentAccountId = decoded['current_account_id'] as String?;
          if (decoded['accounts'] case final List list) {
            for (final item in list) {
              if (item is Map && item['id'] is String) {
                orderedIds.add(item['id'] as String);
              }
            }
          }
        }
      } on Object {
        // Self-heal below.
      }
    }

    for (final id in orderedIds) {
      if (byId.remove(id) case final acc?) {
        _accounts.add(acc);
      }
    }
    final remaining = byId.values.toList()
      ..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    _accounts.addAll(remaining);

    if (_currentAccountId == null ||
        !_accounts.any((a) => a.id == _currentAccountId)) {
      _currentAccountId = _accounts.firstOrNull?.id;
    }

    final autoFile = File(p.join(dir.path, 'auto_switch.json'));
    if (autoFile.existsSync()) {
      try {
        final decoded = jsonDecode(_stripBom(await autoFile.readAsString()));
        if (decoded is Map) {
          _autoSwitch = CodeBuddyAutoSwitchConfig.fromJson(
            decoded.cast<String, Object?>(),
          );
        }
      } on Object {
        // Keep defaults.
      }
    }

    if (remaining.isNotEmpty || !indexFile.existsSync()) {
      await _saveIndex();
    }
  }

  void _syncActiveRegionModels() {
    final active = currentAccount;
    if (active != null) {
      CodeBuddyModels.syncForAccount(active);
    }
  }

  void _startBackgroundRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _backgroundTick++;
      if (_backgroundTick % 3 == 0) {
        unawaited(refreshAllQuotas(silent: true));
      } else if (currentAccount case final active?) {
        unawaited(refreshQuota(active.id));
      }
    });
  }

  Future<void> _saveAccount(CodeBuddyAccount account) async {
    final filePath = p.join(
      dataDirectoryPath,
      'accounts',
      '${account.id}.json',
    );
    const encoder = JsonEncoder.withIndent('  ');
    await CodeBuddyOAuth.writeAtomicSecure(
      filePath,
      encoder.convert(account.toJson()),
    );
  }

  Future<void> _saveIndex() async {
    final indexPath = p.join(dataDirectoryPath, 'accounts.json');
    const encoder = JsonEncoder.withIndent('  ');
    await CodeBuddyOAuth.writeAtomicSecure(
      indexPath,
      encoder.convert({
        'current_account_id': _currentAccountId,
        'accounts': [
          for (final a in _accounts)
            {
              'id': a.id,
              'uid': a.uid,
              'nickname': a.nickname,
              'region': a.region.name,
            },
        ],
      }),
    );
  }

  /// Inserts or updates [account] and optionally makes it active.
  Future<CodeBuddyAccount> upsertAccount(
    CodeBuddyAccount account, {
    bool makeActive = true,
  }) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == account.id);
    final merged = idx >= 0
        ? account.copyWith(
            customLabel: account.customLabel ?? _accounts[idx].customLabel,
            quota: account.quota ?? _accounts[idx].quota,
          )
        : account;
    if (idx >= 0) {
      _accounts[idx] = merged;
    } else {
      _accounts.insert(0, merged);
    }
    await _saveAccount(merged);
    if (makeActive || _currentAccountId == null) {
      _currentAccountId = merged.id;
      _syncActiveRegionModels();
      await _saveIndex();
      notifyListeners();
      await onActiveAccountSwitched?.call(merged);
    } else {
      await _saveIndex();
      notifyListeners();
    }
    unawaited(refreshQuota(merged.id));
    return merged;
  }

  /// Adds an API Key account (`CODEBUDDY_API_KEY` + region / custom baseUrl).
  Future<CodeBuddyAccount> addApiKeyAccount({
    required String apiKey,
    required CodeBuddyRegion region,
    String? nickname,
    String? baseUrl,
    String? endpoint,
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      throw Exception('API Key 不能为空');
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tail = trimmedKey.length > 6
        ? trimmedKey.substring(trimmedKey.length - 6)
        : trimmedKey;
    final uid = 'apikey_${trimmedKey.hashCode.abs()}_$tail';
    final account = CodeBuddyAccount(
      id: CodeBuddyOAuth.buildAccountId(region: region, uid: uid),
      uid: uid,
      nickname: (nickname != null && nickname.trim().isNotEmpty)
          ? nickname.trim()
          : 'API Key (…$tail)',
      region: region,
      endpoint: CodeBuddyOAuth.normalizeEndpoint(
        endpoint ?? region.defaultEndpoint,
      ),
      auth: CodeBuddyAuthData(
        kind: CodeBuddyAuthKind.apiKey,
        apiKey: trimmedKey,
        baseUrl: baseUrl?.trim().isEmpty == true ? null : baseUrl?.trim(),
      ),
      quota: CodeBuddyQuotaData(
        edition: CodeBuddyEdition.apiKey,
        lastUpdated: nowSec,
      ),
      createdAt: nowSec,
      lastUsed: nowSec,
    );
    return upsertAccount(account, makeActive: true);
  }

  /// Adds an account directly from a Bearer Access Token (+ optional Refresh Token).
  Future<CodeBuddyAccount> addTokenAccount({
    required String accessToken,
    String? refreshToken,
    required CodeBuddyRegion region,
    String? endpoint,
    String? nickname,
  }) async {
    final trimmedAccess = accessToken.trim();
    final trimmedRefresh = refreshToken?.trim() ?? '';
    if (trimmedAccess.isEmpty && trimmedRefresh.isEmpty) {
      throw Exception('Access Token 或 Refresh Token 至少填写一项');
    }
    final normalizedEndpoint = CodeBuddyOAuth.normalizeEndpoint(
      endpoint ?? region.defaultEndpoint,
    );
    var auth = CodeBuddyAuthData(
      kind: trimmedRefresh.isNotEmpty
          ? CodeBuddyAuthKind.oauth
          : CodeBuddyAuthKind.authToken,
      accessToken: trimmedAccess,
      refreshToken: trimmedRefresh,
    );
    if (auth.accessToken.isEmpty && auth.refreshToken.isNotEmpty) {
      auth = await CodeBuddyOAuth.refreshAuthToken(
        auth: auth,
        endpoint: normalizedEndpoint,
      );
    }
    final account = await CodeBuddyOAuth.fetchAccountWithAuth(
      auth: auth,
      region: region,
      endpoint: normalizedEndpoint,
      fallbackNickname: nickname,
    );
    return upsertAccount(account, makeActive: true);
  }

  /// Ensures [account] has a fresh non-expired `accessToken` before spawning `codebuddy`.
  Future<CodeBuddyAccount> ensureFreshAccount(CodeBuddyAccount account) async {
    if (!account.auth.needsRefresh || account.auth.refreshToken.isEmpty) {
      return account;
    }
    try {
      final refreshedAuth = await CodeBuddyOAuth.refreshAuthToken(
        auth: account.auth,
        endpoint: account.endpoint,
      );
      final updated = account.copyWith(auth: refreshedAuth, clearDisabled: true);
      final idx = _accounts.indexWhere((a) => a.id == account.id);
      if (idx >= 0) {
        _accounts[idx] = updated;
        await _saveAccount(updated);
        notifyListeners();
      }
      return updated;
    } on Object {
      return account;
    }
  }

  /// Switches the active CodeBuddy account to [accountId].
  Future<void> switchAccount(String accountId) async {
    await ensureInitialized();
    final targetIdx = _accounts.indexWhere((a) => a.id == accountId);
    if (targetIdx < 0) return;

    _switchingId = accountId;
    notifyListeners();
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var target = _accounts[targetIdx].copyWith(lastUsed: nowSec);
      target = await ensureFreshAccount(target);
      _accounts[targetIdx] = target;
      _currentAccountId = accountId;
      _syncActiveRegionModels();
      await _saveAccount(target);
      await _saveIndex();
      notifyListeners();
      await onActiveAccountSwitched?.call(target);
    } finally {
      _switchingId = null;
      notifyListeners();
    }
  }

  /// Clears active managed account selection? Deleting the active account
  /// switches to the next available account (or falls back to CLI default).
  Future<void> deleteAccount(String accountId) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    _accounts.removeAt(idx);
    final file = File(p.join(dataDirectoryPath, 'accounts', '$accountId.json'));
    if (file.existsSync()) {
      await file.delete();
    }
    final wasActive = _currentAccountId == accountId;
    if (wasActive) {
      _currentAccountId = _accounts.firstOrNull?.id;
      _syncActiveRegionModels();
    }
    await _saveIndex();
    notifyListeners();
    if (wasActive) {
      await onActiveAccountSwitched?.call(currentAccount);
    }
  }

  Future<void> setCustomLabel(String accountId, String label) async {
    await ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    final trimmed = label.trim();
    final updated = trimmed.isEmpty
        ? _accounts[idx].copyWith(clearCustomLabel: true)
        : _accounts[idx].copyWith(customLabel: trimmed);
    _accounts[idx] = updated;
    await _saveAccount(updated);
    notifyListeners();
  }

  Future<void> setAutoSwitch(CodeBuddyAutoSwitchConfig config) async {
    await ensureInitialized();
    _autoSwitch = config;
    const encoder = JsonEncoder.withIndent('  ');
    await CodeBuddyOAuth.writeAtomicSecure(
      p.join(dataDirectoryPath, 'auto_switch.json'),
      encoder.convert(config.toJson()),
    );
    notifyListeners();
  }

  /// Records live credit & token usage reported by `codebuddy` stream-json
  /// (`codebuddy.ai/turnUsage`), updates remaining credits immediately,
  /// schedules a background server balance sync, and triggers smart auto-switch
  /// if quota is exhausted (`429` / `insufficient_quota` / `6005` / `14018`).
  Future<void> recordTurnUsage({
    double credits = 0.0,
    int tokens = 0,
    bool quotaExhausted = false,
  }) async {
    final active = currentAccount;
    if (active == null) return;
    final idx = _accounts.indexWhere((a) => a.id == active.id);
    if (idx < 0) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prev = active.quota ?? CodeBuddyQuotaData(lastUpdated: nowSec);
    final delta = credits > 0 ? credits : 0.0;
    final nextRemain = prev.remainingCredits != null && delta > 0
        ? (prev.remainingCredits! - delta).clamp(0.0, double.infinity)
        : prev.remainingCredits;
    final nextQuota = prev.copyWith(
      sessionCreditsUsed: prev.sessionCreditsUsed + delta,
      remainingCredits: nextRemain,
      usedCredits: prev.usedCredits != null && delta > 0
          ? prev.usedCredits! + delta
          : prev.usedCredits,
      turnCount: prev.turnCount + 1,
      totalTokensUsed: prev.totalTokensUsed + (tokens > 0 ? tokens : 0),
      quotaExhausted: quotaExhausted ? true : prev.quotaExhausted,
      lastUpdated: nowSec,
    );
    final updated = active.copyWith(quota: nextQuota, lastUsed: nowSec);
    _accounts[idx] = updated;
    await _saveAccount(updated);
    notifyListeners();

    if (quotaExhausted && _autoSwitch.enabled) {
      await _tryAutoSwitchFrom(updated);
      return;
    }

    // Sync authoritative server credit balance after turn settles.
    if (updated.auth.kind != CodeBuddyAuthKind.apiKey &&
        updated.auth.accessToken.isNotEmpty) {
      _postTurnRefreshTimer?.cancel();
      final targetId = updated.id;
      _postTurnRefreshTimer = Timer(const Duration(milliseconds: 2200), () {
        unawaited(refreshQuota(targetId));
      });
    }
  }

  /// Auto-imports the CLI's own logged-in account when Cyte has no managed
  /// accounts yet, so users who ran `codebuddy login` in terminal immediately
  /// see their remaining credits without signing in twice.
  Future<void> syncFromCliInitializeAccount(
    Map<String, Object?> rawAccount,
  ) async {
    await ensureInitialized();
    if (_accounts.isNotEmpty) return;
    final uid =
        (rawAccount['uid'] ?? rawAccount['userId'] ?? rawAccount['id'])
            as String? ??
        '';
    final token =
        (rawAccount['accessToken'] ??
                rawAccount['access_token'] ??
                rawAccount['token'])
            as String? ??
        '';
    if (uid.isEmpty || token.isEmpty) return;
    final domain =
        (rawAccount['domain'] ?? rawAccount['endpoint']) as String? ?? '';
    final region = CodeBuddyRegion.fromDomain(domain);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final account = CodeBuddyAccount(
      id: CodeBuddyOAuth.buildAccountId(region: region, uid: uid),
      uid: uid,
      nickname:
          (rawAccount['nickname'] ?? rawAccount['userName']) as String? ?? uid,
      email: rawAccount['email'] as String?,
      enterpriseId: rawAccount['enterpriseId'] as String?,
      enterpriseName: rawAccount['enterpriseName'] as String?,
      region: region,
      endpoint: CodeBuddyOAuth.normalizeEndpoint(
        domain.startsWith('http') ? domain : region.defaultEndpoint,
      ),
      auth: CodeBuddyAuthData(
        kind: CodeBuddyAuthKind.authToken,
        accessToken: token,
        refreshToken:
            (rawAccount['refreshToken'] ?? rawAccount['refresh_token'])
                as String? ??
            '',
        domain: domain.isNotEmpty ? domain : null,
      ),
      createdAt: nowSec,
      lastUsed: nowSec,
    );
    _accounts.add(account);
    _currentAccountId = account.id;
    await _saveAccount(account);
    await _saveIndex();
    notifyListeners();
    unawaited(refreshQuota(account.id));
  }

  Future<void> _tryAutoSwitchFrom(CodeBuddyAccount exhausted) async {
    final candidates = _accounts.where(
      (a) =>
          a.id != exhausted.id &&
          !a.disabled &&
          (a.quota?.quotaExhausted != true),
    );
    if (candidates.isEmpty) return;
    CodeBuddyAccount? pick;
    if (_autoSwitch.preferSameRegion) {
      for (final c in candidates) {
        if (c.region == exhausted.region) {
          pick = c;
          break;
        }
      }
    }
    pick ??= candidates.first;
    await switchAccount(pick.id);
  }

  Future<void> refreshQuota(String accountId) async {
    await ensureInitialized();
    if (_refreshingIds.contains(accountId)) return;
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;

    _refreshingIds.add(accountId);
    _lastRefreshError = null;
    notifyListeners();
    try {
      final (:updatedAccount, :quota) = await CodeBuddyQuotaService.fetchQuota(
        _accounts[idx],
      );
      final newIdx = _accounts.indexWhere((a) => a.id == accountId);
      if (newIdx >= 0) {
        final latest = _accounts[newIdx];
        final latestQuota = latest.quota;
        final mergedQuota = quota.copyWith(
          totalCredits: quota.totalCredits ?? latestQuota?.totalCredits,
          remainingCredits:
              quota.remainingCredits ?? latestQuota?.remainingCredits,
          usedCredits: quota.usedCredits ?? latestQuota?.usedCredits,
          sessionCreditsUsed:
              latestQuota != null &&
                  latestQuota.sessionCreditsUsed > quota.sessionCreditsUsed
              ? latestQuota.sessionCreditsUsed
              : quota.sessionCreditsUsed,
          turnCount:
              latestQuota != null && latestQuota.turnCount > quota.turnCount
              ? latestQuota.turnCount
              : quota.turnCount,
          totalTokensUsed:
              latestQuota != null &&
                  latestQuota.totalTokensUsed > quota.totalTokensUsed
              ? latestQuota.totalTokensUsed
              : quota.totalTokensUsed,
        );
        final mergedAccount = updatedAccount.copyWith(
          customLabel: latest.customLabel,
          quota: mergedQuota,
        );
        _accounts[newIdx] = mergedAccount;
        await _saveAccount(mergedAccount);
        if (_currentAccountId == accountId &&
            mergedQuota.availableModelIds.isNotEmpty) {
          CodeBuddyModels.syncForAccount(mergedAccount);
        }
      }
    } on CodeBuddyUnauthorizedException catch (e) {
      final newIdx = _accounts.indexWhere((a) => a.id == accountId);
      if (newIdx >= 0) {
        final marked = _accounts[newIdx].copyWith(
          disabled: true,
          disabledReason: e.message,
        );
        _accounts[newIdx] = marked;
        await _saveAccount(marked);
      }
      _lastRefreshError = e.message;
    } on Object catch (e) {
      _lastRefreshError = '$e';
    } finally {
      _refreshingIds.remove(accountId);
      notifyListeners();
    }
  }

  Future<void> refreshAllQuotas({bool silent = false}) async {
    await ensureInitialized();
    if (_refreshingAll || _accounts.isEmpty) return;
    _refreshingAll = true;
    if (!silent) _lastRefreshError = null;
    notifyListeners();
    try {
      for (final acc in [..._accounts]) {
        await refreshQuota(acc.id);
      }
    } finally {
      _refreshingAll = false;
      notifyListeners();
    }
  }

  String exportAccountsJson() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'version': 1,
      'current_account_id': _currentAccountId,
      'accounts': [for (final a in _accounts) a.toJson()],
    });
  }

  Future<int> importAccountsJson(String rawJson) async {
    await ensureInitialized();
    final decoded = jsonDecode(_stripBom(rawJson));
    final items = <Map<String, Object?>>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) items.add(item.cast<String, Object?>());
      }
    } else if (decoded is Map) {
      if (decoded['accounts'] case final List list) {
        for (final item in list) {
          if (item is Map) items.add(item.cast<String, Object?>());
        }
      } else if (decoded['id'] is String || decoded['auth'] is Map) {
        items.add(decoded.cast<String, Object?>());
      }
    }
    var count = 0;
    for (final map in items) {
      final acc = CodeBuddyAccount.fromJson(map);
      if (acc.id.isEmpty) continue;
      await upsertAccount(acc, makeActive: count == 0 && _accounts.isEmpty);
      count++;
    }
    return count;
  }

  static String _stripBom(String s) =>
      s.startsWith('\uFEFF') ? s.substring(1) : s;
}
