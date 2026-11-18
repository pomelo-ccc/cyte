import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'codebuddy_account_models.dart';

/// Pending CodeBuddy CLI OAuth login state (`POST /v2/plugin/auth/state?platform=CLI`).
class CodeBuddyPendingOAuth {
  const CodeBuddyPendingOAuth({
    required this.state,
    required this.authUrl,
    required this.endpoint,
    required this.region,
  });

  final String state;
  final String authUrl;
  final String endpoint;
  final CodeBuddyRegion region;
}

/// Official CodeBuddy CLI OAuth (`cli-external-link`), token refresh, and
/// account profile endpoints (`copilot.tencent.com` / `www.codebuddy.ai`).
abstract final class CodeBuddyOAuth {
  static const int _pendingTokenCode = 11217;

  /// Atomically writes [content] to [filePath] with `0600` permissions on Unix.
  static Future<void> writeAtomicSecure(String filePath, String content) async {
    final target = File(filePath);
    await target.parent.create(recursive: true);
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 30)}';
    final tmpPath = '$filePath.tmp.$suffix';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsString(content, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', tmpPath]);
    }
    await tmpFile.rename(filePath);
  }

  static String normalizeEndpoint(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return CodeBuddyRegion.cn.defaultEndpoint;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  static String _domainHeaderOf(String endpoint, [String? explicitDomain]) {
    if (explicitDomain != null && explicitDomain.trim().isNotEmpty) {
      return explicitDomain.trim();
    }
    return Uri.tryParse(endpoint)?.authority ?? 'copilot.tencent.com';
  }

  /// Step 1: Request an OAuth login state + browser authorization URL.
  static Future<CodeBuddyPendingOAuth> createAuthState({
    required CodeBuddyRegion region,
    String? customEndpoint,
  }) async {
    final endpoint = normalizeEndpoint(customEndpoint ?? region.defaultEndpoint);
    final uri = Uri.parse('$endpoint/v2/plugin/auth/state?platform=CLI');
    final resp = await _requestJson(
      method: 'POST',
      uri: uri,
      headers: {'X-Domain': _domainHeaderOf(endpoint)},
      body: const {},
    );
    final data = (resp['data'] as Map?)?.cast<String, Object?>();
    final state = data?['state'] as String? ?? '';
    final authUrl = data?['authUrl'] as String? ?? '';
    if (state.isEmpty || authUrl.isEmpty) {
      throw Exception(
        '获取 CodeBuddy 登录链接失败：${resp['msg'] ?? resp['message'] ?? '空响应'}',
      );
    }
    return CodeBuddyPendingOAuth(
      state: state,
      authUrl: authUrl,
      endpoint: endpoint,
      region: region,
    );
  }

  /// Step 2: Poll `/v2/plugin/auth/token?state=...` until user completes browser
  /// authorization, then fetch account profile via `/v2/plugin/account`.
  static Future<CodeBuddyAccount> pollForAuthorizedAccount(
    CodeBuddyPendingOAuth pending, {
    Future<void>? cancel,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    var cancelled = false;
    unawaited(cancel?.then((_) => cancelled = true));
    final deadline = DateTime.now().add(timeout);
    final domain = _domainHeaderOf(pending.endpoint);

    CodeBuddyAuthData? authData;
    while (DateTime.now().isBefore(deadline)) {
      if (cancelled) {
        throw const CodeBuddyOAuthCancelled();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (cancelled) {
        throw const CodeBuddyOAuthCancelled();
      }
      final uri = Uri.parse(
        '${pending.endpoint}/v2/plugin/auth/token?state=${Uri.encodeQueryComponent(pending.state)}',
      );
      Map<String, Object?> resp;
      try {
        resp = await _requestJson(
          method: 'GET',
          uri: uri,
          headers: {'X-Domain': domain},
        );
      } on Object {
        continue;
      }

      final code = (resp['code'] as num?)?.toInt();
      if (code == _pendingTokenCode) {
        continue;
      }
      final data = (resp['data'] as Map?)?.cast<String, Object?>();
      final accessToken = data?['accessToken'] as String? ??
          data?['access_token'] as String? ??
          '';
      if (accessToken.isNotEmpty) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final expiresIn = (data?['expiresIn'] as num?)?.toInt() ?? 86400;
        final refreshExpiresIn =
            (data?['refreshExpiresIn'] as num?)?.toInt() ?? 2592000;
        authData = CodeBuddyAuthData(
          kind: CodeBuddyAuthKind.oauth,
          accessToken: accessToken,
          refreshToken: data?['refreshToken'] as String? ??
              data?['refresh_token'] as String? ??
              '',
          expiresAt: (data?['expiresAt'] as num?)?.toInt() ??
              (nowMs + expiresIn * 1000),
          refreshExpiresAt: (data?['refreshExpiresAt'] as num?)?.toInt() ??
              (nowMs + refreshExpiresIn * 1000),
          domain: data?['domain'] as String? ?? domain,
        );
        break;
      }
      if (code != null && code != 0) {
        throw Exception('登录未完成（错误码 $code）：${resp['msg'] ?? ''}');
      }
    }

    if (authData == null) {
      throw Exception('等待浏览器授权超时（5 分钟），请重试。');
    }

    return fetchAccountWithAuth(
      auth: authData,
      region: pending.region,
      endpoint: pending.endpoint,
    );
  }

  /// Fetches `/v2/plugin/account` for [auth] and constructs a [CodeBuddyAccount].
  static Future<CodeBuddyAccount> fetchAccountWithAuth({
    required CodeBuddyAuthData auth,
    required CodeBuddyRegion region,
    required String endpoint,
    String? fallbackNickname,
  }) async {
    final normalized = normalizeEndpoint(endpoint);
    final domain = _domainHeaderOf(normalized, auth.domain);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    Map<String, Object?>? profile;
    try {
      final resp = await _requestJson(
        method: 'GET',
        uri: Uri.parse('$normalized/v2/plugin/account'),
        headers: {
          'Authorization': 'Bearer ${auth.accessToken}',
          'X-Domain': domain,
        },
      );
      if (resp['data'] is Map) {
        profile = (resp['data'] as Map).cast<String, Object?>();
      }
    } on Object {
      // Fallback to JWT claim inspection below if endpoint skips /v2/plugin/account.
    }

    final jwtClaims = _decodeJwtPayload(auth.accessToken);
    final uid = (profile?['uid'] as String?)?.trim() ??
        (profile?['id'] as String?)?.trim() ??
        (jwtClaims?['sub'] as String?)?.trim() ??
        'user_${auth.accessToken.hashCode.abs()}';
    final nickname = (profile?['nickname'] as String?)?.trim() ??
        (profile?['name'] as String?)?.trim() ??
        (jwtClaims?['preferred_username'] as String?)?.trim() ??
        (jwtClaims?['name'] as String?)?.trim() ??
        fallbackNickname?.trim() ??
        uid;
    final email = (profile?['email'] as String?)?.trim() ??
        (jwtClaims?['email'] as String?)?.trim();
    final enterpriseId = (profile?['enterpriseId'] as String?)?.trim() ??
        (profile?['enterprise_id'] as String?)?.trim();
    final enterpriseName = (profile?['enterpriseName'] as String?)?.trim() ??
        (profile?['enterprise_name'] as String?)?.trim() ??
        (profile?['departmentFullName'] as String?)?.trim();
    final department = (profile?['department'] as String?)?.trim() ??
        (profile?['departmentName'] as String?)?.trim();
    final avatarUrl = (profile?['avatar'] as String?)?.trim() ??
        (profile?['avatarUrl'] as String?)?.trim();
    final rawType = (profile?['type'] as String?)?.trim();

    final accountId = buildAccountId(
      region: region,
      uid: uid,
      enterpriseId: enterpriseId,
    );

    return CodeBuddyAccount(
      id: accountId,
      uid: uid,
      nickname: nickname.isEmpty ? uid : nickname,
      email: email?.isEmpty == true ? null : email,
      enterpriseId: enterpriseId?.isEmpty == true ? null : enterpriseId,
      enterpriseName: enterpriseName?.isEmpty == true ? null : enterpriseName,
      department: department?.isEmpty == true ? null : department,
      avatarUrl: avatarUrl?.isEmpty == true ? null : avatarUrl,
      region: region,
      endpoint: normalized,
      auth: auth.copyWith(domain: domain),
      quota: CodeBuddyQuotaData(
        edition: CodeBuddyEdition.fromWire(rawType),
        lastUpdated: nowSec,
      ),
      createdAt: nowSec,
      lastUsed: nowSec,
    );
  }

  /// Refreshes an OAuth [auth] token via `POST /v2/plugin/auth/token/refresh`.
  static Future<CodeBuddyAuthData> refreshAuthToken({
    required CodeBuddyAuthData auth,
    required String endpoint,
  }) async {
    if (auth.refreshToken.trim().isEmpty) {
      throw Exception('该账号缺少 Refresh Token，请重新登录授权。');
    }
    final normalized = normalizeEndpoint(endpoint);
    final domain = _domainHeaderOf(normalized, auth.domain);
    final resp = await _requestJson(
      method: 'POST',
      uri: Uri.parse('$normalized/v2/plugin/auth/token/refresh'),
      headers: {
        'X-Domain': domain,
        'X-Refresh-Token': auth.refreshToken,
        'X-Auth-Refresh-Source': 'plugin',
      },
      body: const {},
    );
    final data = (resp['data'] as Map?)?.cast<String, Object?>();
    final accessToken = data?['accessToken'] as String? ??
        data?['access_token'] as String? ??
        '';
    if (accessToken.isEmpty) {
      throw Exception(
        '刷新 CodeBuddy 令牌失败：${resp['msg'] ?? resp['message'] ?? '无效响应'}',
      );
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiresIn = (data?['expiresIn'] as num?)?.toInt() ?? 86400;
    final refreshExpiresIn =
        (data?['refreshExpiresIn'] as num?)?.toInt() ?? 2592000;
    return auth.copyWith(
      accessToken: accessToken,
      refreshToken: (data?['refreshToken'] as String?)?.isNotEmpty == true
          ? data!['refreshToken'] as String
          : auth.refreshToken,
      expiresAt:
          (data?['expiresAt'] as num?)?.toInt() ?? (nowMs + expiresIn * 1000),
      refreshExpiresAt: (data?['refreshExpiresAt'] as num?)?.toInt() ??
          (nowMs + refreshExpiresIn * 1000),
      domain: data?['domain'] as String? ?? domain,
    );
  }

  static String buildAccountId({
    required CodeBuddyRegion region,
    required String uid,
    String? enterpriseId,
  }) {
    final raw = [
      region.name,
      uid.trim(),
      if (enterpriseId != null && enterpriseId.trim().isNotEmpty)
        enterpriseId.trim(),
    ].join('_');
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  }

  static Map<String, Object?>? _decodeJwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final json = jsonDecode(decoded);
      return json is Map ? json.cast<String, Object?>() : null;
    } on Object {
      return null;
    }
  }

  static Future<Map<String, Object?>> _requestJson({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 15),
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
          'HTTP ${resp.statusCode}: 登录凭证已失效或无权限',
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
      return const {};
    } finally {
      client.close(force: true);
    }
  }
}

class CodeBuddyOAuthCancelled implements Exception {
  const CodeBuddyOAuthCancelled();

  @override
  String toString() => '已取消浏览器登录授权';
}

class CodeBuddyUnauthorizedException implements Exception {
  const CodeBuddyUnauthorizedException(this.message);

  final String message;

  @override
  String toString() => message;
}
