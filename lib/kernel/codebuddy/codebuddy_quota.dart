import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'codebuddy_account_models.dart';
import 'codebuddy_oauth.dart';

/// Queries CodeBuddy account profile, subscription tier, and real-time credit
/// resource summary using WorkBuddy's exact billing endpoints:
/// - Individual / Pro / Flagship: `POST <billingOrigin>/billing/meter/get-user-resource-summary`
///   (`https://www.codebuddy.cn` for CN/iOA, `https://www.codebuddy.ai` for Global)
/// - Enterprise / Self-hosted: `POST <endpoint>/v2/billing/meter/get-enterprise-user-usage`
abstract final class CodeBuddyQuotaService {
  @visibleForTesting
  static String resolveBillingOrigin(CodeBuddyAccount account) {
    final ep = account.endpoint.toLowerCase();
    if (account.region == CodeBuddyRegion.global ||
        ep.contains('codebuddy.ai') ||
        ep.contains('workbuddy.ai')) {
      return 'https://www.codebuddy.ai';
    }
    if (account.region == CodeBuddyRegion.cn ||
        account.region == CodeBuddyRegion.ioa ||
        ep.contains('copilot.tencent.com') ||
        ep.contains('codebuddy.cn') ||
        ep.contains('workbuddy.cn')) {
      return 'https://www.codebuddy.cn';
    }
    return CodeBuddyOAuth.normalizeEndpoint(account.endpoint);
  }

  static Future<({
    CodeBuddyAccount updatedAccount,
    CodeBuddyQuotaData quota,
  })> fetchQuota(CodeBuddyAccount account) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prev = account.quota;

    // Static API Key accounts do not expose OAuth billing endpoints; preserve
    // any locally tracked or imported credit balances.
    if (account.auth.kind == CodeBuddyAuthKind.apiKey) {
      final quota = (prev ?? CodeBuddyQuotaData(lastUpdated: nowSec)).copyWith(
        edition: CodeBuddyEdition.apiKey,
        lastUpdated: nowSec,
        clearError: true,
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
    final domain = activeAuth.domain?.trim().isNotEmpty == true
        ? activeAuth.domain!.trim()
        : (Uri.tryParse(endpoint)?.authority ?? 'copilot.tencent.com');

    Map<String, String> buildHeaders() => <String, String>{
      'Authorization': 'Bearer ${activeAuth.accessToken}',
      'X-Domain': domain,
      'Accept-Language': 'zh',
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
        headers: buildHeaders(),
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
        final accResp = await _httpJson(
          method: 'GET',
          uri: Uri.parse('$endpoint/v2/plugin/account'),
          headers: buildHeaders(),
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
    final isEnterprise =
        (account.enterpriseId != null &&
            account.enterpriseId!.trim().isNotEmpty) ||
        account.region == CodeBuddyRegion.cloudhosted ||
        account.region == CodeBuddyRegion.selfhosted;
    if (isEnterprise && edition == CodeBuddyEdition.free) {
      edition = CodeBuddyEdition.ultimate;
    }

    var quota = CodeBuddyQuotaData(
      edition: edition,
      paymentType: prev?.paymentType,
      subscriptionPackageCode: prev?.subscriptionPackageCode,
      subscriptionPackageName: prev?.subscriptionPackageName,
      totalCredits: prev?.totalCredits,
      remainingCredits: prev?.remainingCredits,
      usedCredits: prev?.usedCredits,
      unlimited: prev?.unlimited ?? false,
      packages: prev?.packages ?? const [],
      sessionCreditsUsed: prev?.sessionCreditsUsed ?? 0.0,
      turnCount: prev?.turnCount ?? 0,
      totalTokensUsed: prev?.totalTokensUsed ?? 0,
      quotaExhausted: false,
      resetTime: prev?.resetTime,
      upgradeUrl: prev?.upgradeUrl ?? account.region.planUrl,
      availableModelIds: prev?.availableModelIds ?? const [],
      lastUpdated: nowSec,
    );

    // 2. Enterprise credit usage (`/v2/billing/meter/get-enterprise-user-usage`)
    var fetchedSummary = false;
    if (isEnterprise) {
      try {
        final entResp = await _httpJson(
          method: 'POST',
          uri: Uri.parse('$endpoint/v2/billing/meter/get-enterprise-user-usage'),
          headers: buildHeaders(),
          body: const {},
        );
        if ((entResp['code'] as num?)?.toInt() == 0 && entResp['data'] is Map) {
          quota = parseEnterpriseUsageResponse(
            entResp,
            previous: quota,
            nowSec: nowSec,
          );
          fetchedSummary = true;
        }
      } on Object {
        // Fall through to standard resource summary below.
      }
    }

    // 3. Individual / Pro / Flagship resource summary (`POST <billingOrigin>/billing/meter/get-user-resource-summary`)
    if (!fetchedSummary) {
      final billingOrigin = resolveBillingOrigin(account);
      try {
        final sumResp = await _httpJson(
          method: 'POST',
          uri: Uri.parse('$billingOrigin/billing/meter/get-user-resource-summary'),
          headers: buildHeaders(),
          body: const {},
        );
        if ((sumResp['code'] as num?)?.toInt() == 0 && sumResp['data'] is Map) {
          quota = parseResourceSummaryResponse(
            sumResp,
            previous: quota,
            nowSec: nowSec,
          );
        }
      } on Object catch (e) {
        quota = quota.copyWith(fetchError: '$e');
      }
    }

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

  /// Parses WorkBuddy's `/billing/meter/get-user-resource-summary` payload,
  /// where capacity fields (`CycleTotalCapacity`, `CycleRemainCapacity`,
  /// `CycleUsedCapacity`) are returned as numeric strings (e.g. `"5297.64000115"`).
  @visibleForTesting
  static CodeBuddyQuotaData parseResourceSummaryResponse(
    Map<String, Object?> resp, {
    CodeBuddyQuotaData? previous,
    required int nowSec,
  }) {
    final data = (resp['data'] as Map?)?.cast<String, Object?>() ?? const {};
    final rawPackages = data['Packages'] ?? data['packages'];
    final packages = <CodeBuddyCreditPackage>[];
    var totalSum = 0.0;
    var remainSum = 0.0;
    var hasAnyPackage = false;

    if (rawPackages is List) {
      for (final raw in rawPackages) {
        if (raw is! Map) continue;
        final m = raw.cast<String, Object?>();
        // Skip expired/refunded packages if Status is explicitly non-zero and
        // CycleRemainCapacity <= 0 (Status 0 or null = active in WorkBuddy).
        final status = _parseInt(m['Status'] ?? m['status']);
        final total =
            _parseDouble(
              m['CycleTotalCapacity'] ??
                  m['TotalCapacity'] ??
                  m['cycleTotalCapacity'] ??
                  m['total'],
            ) ??
            0.0;
        final remain =
            _parseDouble(
              m['CycleRemainCapacity'] ??
                  m['RemainCapacity'] ??
                  m['cycleRemainCapacity'] ??
                  m['remain'],
            ) ??
            0.0;
        final used =
            _parseDouble(
              m['CycleUsedCapacity'] ??
                  m['UsedCapacity'] ??
                  m['cycleUsedCapacity'] ??
                  m['used'],
            ) ??
            math.max(0.0, total - remain);

        if (status != null && status != 0 && remain <= 0) {
          continue;
        }
        final code =
            (m['PackageCode'] ?? m['packageCode']) as String? ?? '';
        final name =
            (m['PackageName'] ?? m['packageName']) as String?;
        final expire =
            (m['CycleEndTime'] ??
                    m['ExpireTime'] ??
                    m['EndTime'] ??
                    m['expireTime'])
                as String?;

        if (total > 0 || remain > 0) {
          hasAnyPackage = true;
          totalSum += total;
          remainSum += math.max(0.0, remain);
          packages.add(
            CodeBuddyCreditPackage(
              packageCode: code,
              packageName: name,
              total: total,
              remain: math.max(0.0, remain),
              used: math.max(0.0, used),
              expireTime: expire,
            ),
          );
        }
      }
    }

    final subCode =
        (data['SubscriptionPackageCode'] ?? data['subscriptionPackageCode'])
            as String?;
    final rawSubName =
        (data['SubscriptionPackageName'] ?? data['subscriptionPackageName'])
            as String?;
    final isPaid =
        (data['IsPaidUser'] ?? data['isPaidUser']) == true ||
        (subCode != null &&
            (subCode.contains('_002_') ||
                subCode.contains('_003_') ||
                subCode.contains('_005_') ||
                subCode.contains('_023_') ||
                subCode.contains('_026_') ||
                subCode.contains('_027_') ||
                subCode.contains('_043_')));

    var edition = previous?.edition ?? CodeBuddyEdition.free;
    if (subCode != null &&
        (subCode.contains('_027_') || subCode.contains('_043_'))) {
      edition = CodeBuddyEdition.ultimate;
    } else if (isPaid && edition == CodeBuddyEdition.free) {
      edition = CodeBuddyEdition.pro;
    }

    final subName = (rawSubName != null && rawSubName.trim().isNotEmpty)
        ? rawSubName.trim()
        : CodeBuddyCreditPackage.labelForPackageCode(subCode) ??
              (isPaid ? '专业版 Pro' : null);

    final totalCredits = hasAnyPackage ? totalSum : previous?.totalCredits;
    final remainingCredits = hasAnyPackage
        ? remainSum
        : previous?.remainingCredits;
    final usedCredits = hasAnyPackage
        ? math.max(0.0, totalSum - remainSum)
        : previous?.usedCredits;
    final exhausted = hasAnyPackage && totalSum > 0 && remainSum <= 0.0001;

    return (previous ?? CodeBuddyQuotaData(lastUpdated: nowSec)).copyWith(
      edition: edition,
      paymentType: isPaid ? 'pro' : (previous?.paymentType ?? 'free'),
      subscriptionPackageCode: subCode,
      subscriptionPackageName: subName,
      totalCredits: totalCredits,
      remainingCredits: remainingCredits,
      usedCredits: usedCredits,
      unlimited: false,
      packages: packages,
      quotaExhausted: exhausted,
      resetTime: packages.firstOrNull?.expireTime ?? previous?.resetTime,
      lastUpdated: nowSec,
      clearError: true,
    );
  }

  @visibleForTesting
  static CodeBuddyQuotaData parseEnterpriseUsageResponse(
    Map<String, Object?> resp, {
    CodeBuddyQuotaData? previous,
    required int nowSec,
  }) {
    final data = (resp['data'] as Map?)?.cast<String, Object?>() ?? const {};
    final limit = _parseDouble(
      data['limitNum'] ?? data['limit_num'] ?? data['total'] ?? data['quota'],
    );
    final used =
        _parseDouble(
          data['credit'] ?? data['used_num'] ?? data['usedCredits'] ?? data['used'],
        ) ??
        0.0;
    final unlimited = limit != null && limit < 0;
    final totalCredits =
        (limit != null && limit >= 0) ? limit : previous?.totalCredits;
    final remainingCredits = (totalCredits != null)
        ? math.max(0.0, totalCredits - used)
        : null;

    return (previous ?? CodeBuddyQuotaData(lastUpdated: nowSec)).copyWith(
      edition: CodeBuddyEdition.ultimate,
      subscriptionPackageName: previous?.subscriptionPackageName ?? '企业专享版',
      totalCredits: totalCredits,
      remainingCredits: remainingCredits,
      usedCredits: used,
      unlimited: unlimited,
      quotaExhausted:
          !unlimited && totalCredits != null && totalCredits > 0 && remainingCredits! <= 0,
      lastUpdated: nowSec,
      clearError: true,
    );
  }

  static double? _parseDouble(Object? raw) => switch (raw) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s.trim()),
    _ => null,
  };

  static int? _parseInt(Object? raw) => switch (raw) {
    final int i => i,
    final num n => n.toInt(),
    final String s => int.tryParse(s.trim()),
    _ => null,
  };

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
      req.headers.set(HttpHeaders.userAgentHeader, 'WorkBuddy/1.0.0');
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
