import 'dart:convert';
import 'dart:io';

import 'codebuddy_account_models.dart';
import 'codebuddy_oauth.dart';

/// Queries CodeBuddy account profile, edition/billing tier, free-upgrade quota,
/// and dynamic model catalog from the account's configured CodeBuddy endpoint.
abstract final class CodeBuddyQuotaService {
  static Future<({
    CodeBuddyAccount updatedAccount,
    CodeBuddyQuotaData quota,
  })> fetchQuota(CodeBuddyAccount account) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prev = account.quota;

    // Static API Key accounts do not use `/v2/plugin/account` or `/v2/billing`.
    if (account.auth.kind == CodeBuddyAuthKind.apiKey) {
      final quota = CodeBuddyQuotaData(
        edition: CodeBuddyEdition.apiKey,
        sessionCreditsUsed: prev?.sessionCreditsUsed ?? 0.0,
        turnCount: prev?.turnCount ?? 0,
        totalTokensUsed: prev?.totalTokensUsed ?? 0,
        lastUpdated: nowSec,
      );
      return (
        updatedAccount: account.copyWith(quota: quota, clearDisabled: true),
        quota: quota,
      );
    }

    var activeAuth = account.auth;
    if (activeAuth.needsRefresh && activeAuth.refreshToken.isNotEmpty) {
      activeAuth = await CodeBuddyOAuth.refreshAuthToken(
        auth: activeAuth,
        endpoint: account.endpoint,
      );
    }

    final endpoint = CodeBuddyOAuth.normalizeEndpoint(account.endpoint);
    final domain =
        activeAuth.domain?.trim().isNotEmpty == true
            ? activeAuth.domain!.trim()
            : (Uri.tryParse(endpoint)?.authority ?? 'copilot.tencent.com');

    final authHeaders = <String, String>{
      'Authorization': 'Bearer ${activeAuth.accessToken}',
      'X-Domain': domain,
      if (account.uid.isNotEmpty)
        'X-User-Id': Uri.encodeComponent(account.uid),
      if (account.enterpriseId != null && account.enterpriseId!.isNotEmpty)
        'X-Enterprise-Id': account.enterpriseId!,
    };

    // 1. Refresh `/v2/plugin/account` profile (auto-retrying once if 401 and refreshToken exists).
    Map<String, Object?>? profile;
    try {
      final accResp = await _httpJson(
        method: 'GET',
        uri: Uri.parse('$endpoint/v2/plugin/account'),
        headers: authHeaders,
      );
      if (accResp['data'] is Map) {
        profile = (accResp['data'] as Map).cast<String, Object?>();
      }
    } on CodeBuddyUnauthorizedException {
      if (activeAuth.refreshToken.isNotEmpty) {
        activeAuth = await CodeBuddyOAuth.refreshAuthToken(
          auth: activeAuth,
          endpoint: endpoint,
        );
        authHeaders['Authorization'] = 'Bearer ${activeAuth.accessToken}';
        final accResp = await _httpJson(
          method: 'GET',
          uri: Uri.parse('$endpoint/v2/plugin/account'),
          headers: authHeaders,
        );
        if (accResp['data'] is Map) {
          profile = (accResp['data'] as Map).cast<String, Object?>();
        }
      } else {
        rethrow;
      }
    }

    var edition = prev?.edition ?? CodeBuddyEdition.free;
    if (profile?['type'] case final String rawType when rawType.isNotEmpty) {
      edition = CodeBuddyEdition.fromWire(rawType);
    }
    if (account.enterpriseId != null &&
        account.enterpriseId!.isNotEmpty &&
        edition == CodeBuddyEdition.free) {
      edition = CodeBuddyEdition.ultimate;
    }

    // 2. Query `/v2/billing/meter/get-payment-type` (Pro vs Free).
    String? paymentType = prev?.paymentType;
    try {
      final payResp = await _httpJson(
        method: 'POST',
        uri: Uri.parse('$endpoint/v2/billing/meter/get-payment-type'),
        headers: authHeaders,
        body: const {},
      );
      if ((payResp['code'] as num?)?.toInt() == 0 && payResp['data'] is Map) {
        final data = (payResp['data'] as Map).cast<String, Object?>();
        paymentType = data['paymentType'] as String?;
        if (paymentType?.toLowerCase() == 'pro' &&
            edition == CodeBuddyEdition.free) {
          edition = CodeBuddyEdition.pro;
        }
      }
    } on Object {
      // Optional billing endpoint on enterprise/self-hosted deployments.
    }

    // 3. Query `/v2/billing/meter/get-free-user-upgrade` for credit/quota fields if exposed.
    double? totalCredits = prev?.totalCredits;
    double? usedCredits = prev?.usedCredits;
    String? resetTime = prev?.resetTime;
    String? upgradeUrl = prev?.upgradeUrl ?? account.region.planUrl;
    try {
      final freeResp = await _httpJson(
        method: 'POST',
        uri: Uri.parse('$endpoint/v2/billing/meter/get-free-user-upgrade'),
        headers: authHeaders,
        body: const {},
      );
      if ((freeResp['code'] as num?)?.toInt() == 0 && freeResp['data'] is Map) {
        final data = (freeResp['data'] as Map).cast<String, Object?>();
        totalCredits =
            _numField(data, const ['totalCredits', 'total', 'quota', 'limit']) ??
            totalCredits;
        usedCredits =
            _numField(data, const ['usedCredits', 'used', 'consumed']) ??
            usedCredits;
        if (data['resetTime'] is String) {
          resetTime = data['resetTime'] as String;
        }
        if (data['upgradeUrl'] is String &&
            (data['upgradeUrl'] as String).isNotEmpty) {
          upgradeUrl = data['upgradeUrl'] as String;
        }
      }
    } on Object {
      // Optional.
    }

    // 4. Query `/v2/config` for server-enabled models on this account.
    var modelIds = prev?.availableModelIds ?? const <String>[];
    try {
      final cfgResp = await _httpJson(
        method: 'GET',
        uri: Uri.parse('$endpoint/v2/config'),
        headers: authHeaders,
      );
      final cfgData = cfgResp['data'] is Map
          ? (cfgResp['data'] as Map).cast<String, Object?>()
          : cfgResp;
      if (cfgData['models'] case final List models) {
        final parsed = <String>[
          for (final m in models)
            if (m is Map && m['id'] is String && (m['id'] as String).isNotEmpty)
              m['id'] as String,
        ];
        if (parsed.isNotEmpty) modelIds = parsed;
      }
    } on Object {
      // Keep existing modelIds.
    }

    final quota = CodeBuddyQuotaData(
      edition: edition,
      paymentType: paymentType,
      totalCredits: totalCredits,
      usedCredits: usedCredits,
      sessionCreditsUsed: prev?.sessionCreditsUsed ?? 0.0,
      turnCount: prev?.turnCount ?? 0,
      totalTokensUsed: prev?.totalTokensUsed ?? 0,
      quotaExhausted: false,
      resetTime: resetTime,
      upgradeUrl: upgradeUrl,
      availableModelIds: modelIds,
      lastUpdated: nowSec,
    );

    final updatedAccount = account.copyWith(
      nickname: (profile?['nickname'] as String?)?.trim().isNotEmpty == true
          ? (profile!['nickname'] as String).trim()
          : null,
      email: (profile?['email'] as String?)?.trim().isNotEmpty == true
          ? (profile!['email'] as String).trim()
          : null,
      enterpriseName:
          (profile?['enterpriseName'] as String?)?.trim().isNotEmpty == true
              ? (profile!['enterpriseName'] as String).trim()
              : null,
      auth: activeAuth,
      quota: quota,
      clearDisabled: true,
    );

    return (updatedAccount: updatedAccount, quota: quota);
  }

  static double? _numField(Map<String, Object?> map, List<String> keys) {
    for (final k in keys) {
      if (map[k] case final num n) return n.toDouble();
    }
    return null;
  }

  static Future<Map<String, Object?>> _httpJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'CodeBuddy-CLI/2.185.0');
      for (final MapEntry(:key, :value) in headers.entries) {
        req.headers.set(key, value);
      }
      if (body != null) {
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        req.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw CodeBuddyUnauthorizedException(
          'HTTP ${resp.statusCode}: 凭证已过期或无权限',
        );
      }
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } finally {
      client.close(force: true);
    }
  }
}
