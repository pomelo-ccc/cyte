/// Data models for CodeBuddy multi-account management, edition/billing tiers,
/// regional deployments (CN / Global / iOA / Enterprise), and credit tracking.
library;

import 'dart:math' as math;

/// Formats an account credit balance (e.g. `5,897.6`, `8,721`, `0`).
String formatBalanceCredits(double value) {
  if (!value.isFinite || value <= 0) return '0';
  final roundedTenths = (value * 10).round() / 10.0;
  final isWhole = (roundedTenths - roundedTenths.roundToDouble()).abs() < 1e-6;
  final fixed = isWhole
      ? roundedTenths.round().toString()
      : roundedTenths.toStringAsFixed(1);
  final dot = fixed.indexOf('.');
  final intPart = dot >= 0 ? fixed.substring(0, dot) : fixed;
  final decPart = dot >= 0 ? fixed.substring(dot) : '';
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) {
      buf.write(',');
    }
    buf.write(intPart[i]);
  }
  return '$buf$decPart';
}

/// Formats per-turn or cumulative consumed credits (e.g. `0.42`, `3.03`, `0.005`).
String formatConsumedCredits(double value) {
  if (!value.isFinite || value <= 0) return '0.00';
  if (value >= 100) return formatBalanceCredits(value);
  if (value >= 0.01) return value.toStringAsFixed(2);
  if (value >= 0.001) return value.toStringAsFixed(3);
  return value.toStringAsFixed(4);
}

enum CodeBuddyRegion {
  cn,
  global,
  ioa,
  cloudhosted,
  selfhosted;

  String get label => switch (this) {
    CodeBuddyRegion.cn => '中国版 CN',
    CodeBuddyRegion.global => '国际版 AI',
    CodeBuddyRegion.ioa => '腾讯 iOA',
    CodeBuddyRegion.cloudhosted => '企业专享版',
    CodeBuddyRegion.selfhosted => '私有化部署',
  };

  String get shortBadge => switch (this) {
    CodeBuddyRegion.cn => 'CN',
    CodeBuddyRegion.global => 'AI',
    CodeBuddyRegion.ioa => 'iOA',
    CodeBuddyRegion.cloudhosted => '专享',
    CodeBuddyRegion.selfhosted => '私有',
  };

  String get defaultEndpoint => switch (this) {
    CodeBuddyRegion.cn => 'https://copilot.tencent.com',
    CodeBuddyRegion.global => 'https://www.codebuddy.ai',
    CodeBuddyRegion.ioa => 'https://tencent.sso.copilot.tencent.com',
    CodeBuddyRegion.cloudhosted => 'https://copilot.tencent.com',
    CodeBuddyRegion.selfhosted => 'https://copilot.tencent.com',
  };

  /// Billing portal origin used by WorkBuddy for `/billing/meter/get-user-resource-summary`.
  String get billingOrigin => switch (this) {
    CodeBuddyRegion.global => 'https://www.codebuddy.ai',
    CodeBuddyRegion.cn || CodeBuddyRegion.ioa => 'https://www.codebuddy.cn',
    CodeBuddyRegion.cloudhosted || CodeBuddyRegion.selfhosted =>
      'https://www.codebuddy.cn',
  };

  /// Value for `CODEBUDDY_INTERNET_ENVIRONMENT` documented in `iam.md`.
  String? get internetEnvironment => switch (this) {
    CodeBuddyRegion.cn => 'internal',
    CodeBuddyRegion.global => null,
    CodeBuddyRegion.ioa => 'ioa',
    CodeBuddyRegion.cloudhosted => 'cloudhosted',
    CodeBuddyRegion.selfhosted => 'selfhosted',
  };

  String get planUrl => switch (this) {
    CodeBuddyRegion.cn || CodeBuddyRegion.ioa =>
      'https://www.codebuddy.cn/profile/plans-usage',
    CodeBuddyRegion.global => 'https://www.codebuddy.ai/profile/plans-usage',
    _ => 'https://copilot.tencent.com',
  };

  static CodeBuddyRegion fromWire(String? raw) => switch (raw?.trim()) {
    'cn' || 'internal' => CodeBuddyRegion.cn,
    'global' || 'external' => CodeBuddyRegion.global,
    'ioa' => CodeBuddyRegion.ioa,
    'cloudhosted' => CodeBuddyRegion.cloudhosted,
    'selfhosted' => CodeBuddyRegion.selfhosted,
    _ => CodeBuddyRegion.cn,
  };

  static CodeBuddyRegion fromDomain(String? domainOrUrl) {
    final s = (domainOrUrl ?? '').toLowerCase();
    if (s.contains('.sso.')) return CodeBuddyRegion.ioa;
    if (s.contains('codebuddy.ai') || s.contains('workbuddy.ai')) {
      return CodeBuddyRegion.global;
    }
    if (s.contains('copilot.qq.com')) return CodeBuddyRegion.cloudhosted;
    return CodeBuddyRegion.cn;
  }
}

enum CodeBuddyEdition {
  free,
  pro,
  ultimate,
  exclusive,
  apiKey;

  String get label => switch (this) {
    CodeBuddyEdition.free => '体验版',
    CodeBuddyEdition.pro => 'PRO',
    CodeBuddyEdition.ultimate => '旗舰版',
    CodeBuddyEdition.exclusive => '专享版',
    CodeBuddyEdition.apiKey => 'API KEY',
  };

  static CodeBuddyEdition fromWire(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'pro' => CodeBuddyEdition.pro,
        'ultimate' || 'enterprise' => CodeBuddyEdition.ultimate,
        'exclusive' => CodeBuddyEdition.exclusive,
        'apikey' || 'api_key' => CodeBuddyEdition.apiKey,
        _ => CodeBuddyEdition.free,
      };
}

enum CodeBuddyAuthKind {
  oauth,
  apiKey,
  authToken;

  static CodeBuddyAuthKind fromWire(String? raw) => switch (raw?.trim()) {
    'apiKey' || 'api_key' => CodeBuddyAuthKind.apiKey,
    'authToken' || 'auth_token' => CodeBuddyAuthKind.authToken,
    _ => CodeBuddyAuthKind.oauth,
  };
}

class CodeBuddyAuthData {
  const CodeBuddyAuthData({
    required this.kind,
    this.accessToken = '',
    this.refreshToken = '',
    this.expiresAt = 0,
    this.refreshExpiresAt = 0,
    this.domain,
    this.apiKey = '',
    this.baseUrl,
  });

  final CodeBuddyAuthKind kind;
  final String accessToken;
  final String refreshToken;
  final int expiresAt;
  final int refreshExpiresAt;
  final String? domain;
  final String apiKey;
  final String? baseUrl;

  /// Whether [accessToken] is missing or within 5 minutes of expiring.
  bool get needsRefresh {
    if (kind != CodeBuddyAuthKind.oauth) return false;
    if (accessToken.isEmpty) return refreshToken.isNotEmpty;
    if (expiresAt <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch + 300000 >= expiresAt;
  }

  CodeBuddyAuthData copyWith({
    CodeBuddyAuthKind? kind,
    String? accessToken,
    String? refreshToken,
    int? expiresAt,
    int? refreshExpiresAt,
    String? domain,
    String? apiKey,
    String? baseUrl,
  }) => CodeBuddyAuthData(
    kind: kind ?? this.kind,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    refreshExpiresAt: refreshExpiresAt ?? this.refreshExpiresAt,
    domain: domain ?? this.domain,
    apiKey: apiKey ?? this.apiKey,
    baseUrl: baseUrl ?? this.baseUrl,
  );

  factory CodeBuddyAuthData.fromJson(Map<String, Object?> json) =>
      CodeBuddyAuthData(
        kind: CodeBuddyAuthKind.fromWire(json['kind'] as String?),
        accessToken:
            json['access_token'] as String? ??
            json['accessToken'] as String? ??
            '',
        refreshToken:
            json['refresh_token'] as String? ??
            json['refreshToken'] as String? ??
            '',
        expiresAt:
            (json['expires_at'] as num?)?.toInt() ??
            (json['expiresAt'] as num?)?.toInt() ??
            0,
        refreshExpiresAt:
            (json['refresh_expires_at'] as num?)?.toInt() ??
            (json['refreshExpiresAt'] as num?)?.toInt() ??
            0,
        domain: json['domain'] as String?,
        apiKey: json['api_key'] as String? ?? json['apiKey'] as String? ?? '',
        baseUrl: json['base_url'] as String? ?? json['baseUrl'] as String?,
      );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (accessToken.isNotEmpty) 'access_token': accessToken,
    if (refreshToken.isNotEmpty) 'refresh_token': refreshToken,
    if (expiresAt > 0) 'expires_at': expiresAt,
    if (refreshExpiresAt > 0) 'refresh_expires_at': refreshExpiresAt,
    if (domain != null && domain!.isNotEmpty) 'domain': domain,
    if (apiKey.isNotEmpty) 'api_key': apiKey,
    if (baseUrl != null && baseUrl!.isNotEmpty) 'base_url': baseUrl,
  };
}

/// One resource/credit package returned by WorkBuddy's
/// `/billing/meter/get-user-resource-summary` API.
class CodeBuddyCreditPackage {
  const CodeBuddyCreditPackage({
    required this.packageCode,
    this.packageName,
    required this.total,
    required this.remain,
    required this.used,
    this.expireTime,
  });

  final String packageCode;
  final String? packageName;
  final double total;
  final double remain;
  final double used;
  final String? expireTime;

  String get displayTitle {
    final name = packageName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return labelForPackageCode(packageCode) ?? '积分资源包';
  }

  static String? labelForPackageCode(String? code) {
    if (code == null || code.isEmpty) return null;
    if (code.contains('_043_')) return 'Buddy One';
    if (code.contains('_027_')) return '旗舰版';
    if (code.contains('_026_')) return '高级版';
    if (code.contains('_023_')) return '青春版';
    if (code.contains('_039_') || code.contains('_040_')) return '专业试用版';
    if (code.contains('_002_') ||
        code.contains('_003_') ||
        code.contains('_005_')) {
      return '专业版 Pro';
    }
    if (code.contains('_007_') || code.contains('_006_')) return '加油包 / 增购积分';
    if (code.contains('_001_') ||
        code.contains('_008_') ||
        code.contains('_035_')) {
      return '体验版积分包';
    }
    return null;
  }

  factory CodeBuddyCreditPackage.fromJson(Map<String, Object?> json) =>
      CodeBuddyCreditPackage(
        packageCode: json['package_code'] as String? ?? '',
        packageName: json['package_name'] as String?,
        total: (json['total'] as num?)?.toDouble() ?? 0.0,
        remain: (json['remain'] as num?)?.toDouble() ?? 0.0,
        used: (json['used'] as num?)?.toDouble() ?? 0.0,
        expireTime: json['expire_time'] as String?,
      );

  Map<String, Object?> toJson() => {
    'package_code': packageCode,
    if (packageName != null && packageName!.isNotEmpty)
      'package_name': packageName,
    'total': total,
    'remain': remain,
    'used': used,
    if (expireTime != null && expireTime!.isNotEmpty) 'expire_time': expireTime,
  };
}

class CodeBuddyQuotaData {
  const CodeBuddyQuotaData({
    this.edition = CodeBuddyEdition.free,
    this.paymentType,
    this.subscriptionPackageCode,
    this.subscriptionPackageName,
    this.totalCredits,
    this.remainingCredits,
    this.usedCredits,
    this.unlimited = false,
    this.packages = const [],
    this.sessionCreditsUsed = 0.0,
    this.turnCount = 0,
    this.totalTokensUsed = 0,
    this.quotaExhausted = false,
    this.resetTime,
    this.upgradeUrl,
    this.availableModelIds = const [],
    required this.lastUpdated,
    this.fetchError,
  });

  final CodeBuddyEdition edition;
  final String? paymentType;
  final String? subscriptionPackageCode;
  final String? subscriptionPackageName;
  final double? totalCredits;
  final double? remainingCredits;
  final double? usedCredits;
  final bool unlimited;
  final List<CodeBuddyCreditPackage> packages;
  final double sessionCreditsUsed;
  final int turnCount;
  final int totalTokensUsed;
  final bool quotaExhausted;
  final String? resetTime;
  final String? upgradeUrl;
  final List<String> availableModelIds;
  final int lastUpdated;
  final String? fetchError;

  /// Effective remaining credits for this account when finite and known.
  double? get effectiveRemainingCredits {
    if (unlimited) return null;
    if (quotaExhausted) return 0.0;
    if (remainingCredits case final rem?) {
      return math.max(0.0, rem);
    }
    if (totalCredits case final total? when total > 0) {
      final used = usedCredits ?? sessionCreditsUsed;
      return (total - used).clamp(0.0, total);
    }
    return null;
  }

  double get remainingFraction {
    if (quotaExhausted) return 0.0;
    if (unlimited) return 1.0;
    final total = totalCredits;
    if (total != null && total > 0) {
      final left = effectiveRemainingCredits ?? 0.0;
      return (left / total).clamp(0.0, 1.0);
    }
    return 1.0;
  }

  int get percentage => (remainingFraction * 100).round().clamp(0, 100);

  /// Short inline label for the composer toolbar pill (e.g. `剩余 5,897.6 积分`).
  String get pillCreditsLabel {
    if (quotaExhausted) return '积分已用尽';
    if (unlimited) return '不限积分';
    if (effectiveRemainingCredits case final left?) {
      return '剩余 ${formatBalanceCredits(left)} 积分';
    }
    if (sessionCreditsUsed > 0) {
      return '已用 ${formatConsumedCredits(sessionCreditsUsed)} 积分';
    }
    return subscriptionPackageName?.trim().isNotEmpty == true
        ? subscriptionPackageName!.trim()
        : edition.label;
  }

  String get summaryLabel {
    if (quotaExhausted) return '积分配额已用尽';
    if (unlimited) return '企业不限积分 · 正常可用';
    final left = effectiveRemainingCredits;
    final total = totalCredits;
    if (left != null && total != null && total > 0) {
      return '剩余 ${formatBalanceCredits(left)} / ${formatBalanceCredits(total)} 积分';
    }
    if (left != null) {
      return '剩余 ${formatBalanceCredits(left)} 积分';
    }
    if (sessionCreditsUsed > 0) {
      return '累计消耗 ${formatConsumedCredits(sessionCreditsUsed)} 积分';
    }
    final plan = subscriptionPackageName?.trim();
    return '${(plan != null && plan.isNotEmpty) ? plan : edition.label} · 正常可用';
  }

  CodeBuddyQuotaData copyWith({
    CodeBuddyEdition? edition,
    String? paymentType,
    String? subscriptionPackageCode,
    String? subscriptionPackageName,
    double? totalCredits,
    double? remainingCredits,
    double? usedCredits,
    bool? unlimited,
    List<CodeBuddyCreditPackage>? packages,
    double? sessionCreditsUsed,
    int? turnCount,
    int? totalTokensUsed,
    bool? quotaExhausted,
    String? resetTime,
    String? upgradeUrl,
    List<String>? availableModelIds,
    int? lastUpdated,
    String? fetchError,
    bool clearError = false,
  }) => CodeBuddyQuotaData(
    edition: edition ?? this.edition,
    paymentType: paymentType ?? this.paymentType,
    subscriptionPackageCode:
        subscriptionPackageCode ?? this.subscriptionPackageCode,
    subscriptionPackageName:
        subscriptionPackageName ?? this.subscriptionPackageName,
    totalCredits: totalCredits ?? this.totalCredits,
    remainingCredits: remainingCredits ?? this.remainingCredits,
    usedCredits: usedCredits ?? this.usedCredits,
    unlimited: unlimited ?? this.unlimited,
    packages: packages ?? this.packages,
    sessionCreditsUsed: sessionCreditsUsed ?? this.sessionCreditsUsed,
    turnCount: turnCount ?? this.turnCount,
    totalTokensUsed: totalTokensUsed ?? this.totalTokensUsed,
    quotaExhausted: quotaExhausted ?? this.quotaExhausted,
    resetTime: resetTime ?? this.resetTime,
    upgradeUrl: upgradeUrl ?? this.upgradeUrl,
    availableModelIds: availableModelIds ?? this.availableModelIds,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    fetchError: clearError ? null : (fetchError ?? this.fetchError),
  );

  factory CodeBuddyQuotaData.fromJson(Map<String, Object?> json) =>
      CodeBuddyQuotaData(
        edition: CodeBuddyEdition.fromWire(json['edition'] as String?),
        paymentType: json['payment_type'] as String?,
        subscriptionPackageCode: json['subscription_package_code'] as String?,
        subscriptionPackageName: json['subscription_package_name'] as String?,
        totalCredits: (json['total_credits'] as num?)?.toDouble(),
        remainingCredits: (json['remaining_credits'] as num?)?.toDouble(),
        usedCredits: (json['used_credits'] as num?)?.toDouble(),
        unlimited: json['unlimited'] as bool? ?? false,
        packages: [
          if (json['packages'] case final List list)
            for (final item in list)
              if (item is Map)
                CodeBuddyCreditPackage.fromJson(item.cast<String, Object?>()),
        ],
        sessionCreditsUsed:
            (json['session_credits_used'] as num?)?.toDouble() ?? 0.0,
        turnCount: (json['turn_count'] as num?)?.toInt() ?? 0,
        totalTokensUsed: (json['total_tokens_used'] as num?)?.toInt() ?? 0,
        quotaExhausted: json['quota_exhausted'] as bool? ?? false,
        resetTime: json['reset_time'] as String?,
        upgradeUrl: json['upgrade_url'] as String?,
        availableModelIds: [
          if (json['available_model_ids'] case final List list)
            for (final item in list)
              if (item is String && item.isNotEmpty) item,
        ],
        lastUpdated: (json['last_updated'] as num?)?.toInt() ?? 0,
        fetchError: json['fetch_error'] as String?,
      );

  Map<String, Object?> toJson() => {
    'edition': edition.name,
    if (paymentType != null) 'payment_type': paymentType,
    if (subscriptionPackageCode != null)
      'subscription_package_code': subscriptionPackageCode,
    if (subscriptionPackageName != null)
      'subscription_package_name': subscriptionPackageName,
    if (totalCredits != null) 'total_credits': totalCredits,
    if (remainingCredits != null) 'remaining_credits': remainingCredits,
    if (usedCredits != null) 'used_credits': usedCredits,
    if (unlimited) 'unlimited': true,
    if (packages.isNotEmpty)
      'packages': [for (final p in packages) p.toJson()],
    'session_credits_used': sessionCreditsUsed,
    'turn_count': turnCount,
    'total_tokens_used': totalTokensUsed,
    'quota_exhausted': quotaExhausted,
    if (resetTime != null) 'reset_time': resetTime,
    if (upgradeUrl != null) 'upgrade_url': upgradeUrl,
    if (availableModelIds.isNotEmpty) 'available_model_ids': availableModelIds,
    'last_updated': lastUpdated,
    if (fetchError != null) 'fetch_error': fetchError,
  };
}

class CodeBuddyAccount {
  const CodeBuddyAccount({
    required this.id,
    required this.uid,
    required this.nickname,
    this.email,
    this.enterpriseId,
    this.enterpriseName,
    this.department,
    this.avatarUrl,
    this.customLabel,
    required this.region,
    required this.endpoint,
    required this.auth,
    this.quota,
    this.disabled = false,
    this.disabledReason,
    required this.createdAt,
    required this.lastUsed,
  });

  final String id;
  final String uid;
  final String nickname;
  final String? email;
  final String? enterpriseId;
  final String? enterpriseName;
  final String? department;
  final String? avatarUrl;
  final String? customLabel;
  final CodeBuddyRegion region;
  final String endpoint;
  final CodeBuddyAuthData auth;
  final CodeBuddyQuotaData? quota;
  final bool disabled;
  final String? disabledReason;
  final int createdAt;
  final int lastUsed;

  CodeBuddyEdition get edition {
    if (auth.kind == CodeBuddyAuthKind.apiKey) return CodeBuddyEdition.apiKey;
    return quota?.edition ??
        (enterpriseId != null && enterpriseId!.isNotEmpty
            ? CodeBuddyEdition.ultimate
            : CodeBuddyEdition.free);
  }

  String get displayName {
    final label = customLabel?.trim() ?? '';
    if (label.isNotEmpty) return label;
    if (nickname.trim().isNotEmpty) return nickname.trim();
    if (email != null && email!.trim().isNotEmpty) return email!.trim();
    return uid;
  }

  String get subtitle {
    final parts = <String>[
      region.label,
      if (enterpriseName != null && enterpriseName!.trim().isNotEmpty)
        enterpriseName!.trim()
      else if (enterpriseId != null && enterpriseId!.trim().isNotEmpty)
        '企业 ${enterpriseId!.trim()}',
      if (email != null &&
          email!.trim().isNotEmpty &&
          email!.trim() != displayName)
        email!.trim()
      else if (uid.isNotEmpty && uid != displayName)
        uid.length > 16
            ? '${uid.substring(0, 8)}…${uid.substring(uid.length - 4)}'
            : uid,
    ];
    return parts.join(' · ');
  }

  /// Environment variables passed directly to spawned `codebuddy` processes
  /// following `iam.md` priority (`CODEBUDDY_AUTH_TOKEN > CODEBUDDY_API_KEY`).
  Map<String, String> processEnvironment() {
    final env = <String, String>{};
    switch (auth.kind) {
      case CodeBuddyAuthKind.oauth:
      case CodeBuddyAuthKind.authToken:
        if (auth.accessToken.isNotEmpty) {
          env['CODEBUDDY_AUTH_TOKEN'] = auth.accessToken;
        }
        if (region.internetEnvironment case final ie?) {
          env['CODEBUDDY_INTERNET_ENVIRONMENT'] = ie;
        } else {
          env['CODEBUDDY_INTERNET_ENVIRONMENT'] = '';
        }
      case CodeBuddyAuthKind.apiKey:
        if (auth.apiKey.isNotEmpty) {
          env['CODEBUDDY_API_KEY'] = auth.apiKey;
        }
        if (auth.baseUrl case final url? when url.trim().isNotEmpty) {
          env['CODEBUDDY_BASE_URL'] = url.trim();
        } else if (region.internetEnvironment case final ie?) {
          env['CODEBUDDY_INTERNET_ENVIRONMENT'] = ie;
        }
    }
    if (uid.isNotEmpty) env['ACC_USER_ID'] = uid;
    if (nickname.isNotEmpty) env['ACC_USER_NICKNAME'] = nickname;
    return env;
  }

  CodeBuddyAccount copyWith({
    String? uid,
    String? nickname,
    String? email,
    String? enterpriseId,
    String? enterpriseName,
    String? department,
    String? avatarUrl,
    String? customLabel,
    bool clearCustomLabel = false,
    CodeBuddyRegion? region,
    String? endpoint,
    CodeBuddyAuthData? auth,
    CodeBuddyQuotaData? quota,
    bool? disabled,
    String? disabledReason,
    bool clearDisabled = false,
    int? lastUsed,
  }) => CodeBuddyAccount(
    id: id,
    uid: uid ?? this.uid,
    nickname: nickname ?? this.nickname,
    email: email ?? this.email,
    enterpriseId: enterpriseId ?? this.enterpriseId,
    enterpriseName: enterpriseName ?? this.enterpriseName,
    department: department ?? this.department,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    customLabel: clearCustomLabel ? null : (customLabel ?? this.customLabel),
    region: region ?? this.region,
    endpoint: endpoint ?? this.endpoint,
    auth: auth ?? this.auth,
    quota: quota ?? this.quota,
    disabled: clearDisabled ? false : (disabled ?? this.disabled),
    disabledReason: clearDisabled
        ? null
        : (disabledReason ?? this.disabledReason),
    createdAt: createdAt,
    lastUsed: lastUsed ?? this.lastUsed,
  );

  factory CodeBuddyAccount.fromJson(Map<String, Object?> json) {
    final region = CodeBuddyRegion.fromWire(json['region'] as String?);
    return CodeBuddyAccount(
      id: json['id'] as String? ?? '',
      uid: json['uid'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      email: json['email'] as String?,
      enterpriseId: json['enterprise_id'] as String?,
      enterpriseName: json['enterprise_name'] as String?,
      department: json['department'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      customLabel: json['custom_label'] as String?,
      region: region,
      endpoint: (json['endpoint'] as String?)?.trim().isNotEmpty == true
          ? (json['endpoint'] as String).trim()
          : region.defaultEndpoint,
      auth: CodeBuddyAuthData.fromJson(
        (json['auth'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
      quota: json['quota'] is Map
          ? CodeBuddyQuotaData.fromJson(
              (json['quota'] as Map).cast<String, Object?>(),
            )
          : null,
      disabled: json['disabled'] as bool? ?? false,
      disabledReason: json['disabled_reason'] as String?,
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      lastUsed: (json['last_used'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'uid': uid,
    'nickname': nickname,
    if (email != null && email!.isNotEmpty) 'email': email,
    if (enterpriseId != null && enterpriseId!.isNotEmpty)
      'enterprise_id': enterpriseId,
    if (enterpriseName != null && enterpriseName!.isNotEmpty)
      'enterprise_name': enterpriseName,
    if (department != null && department!.isNotEmpty) 'department': department,
    if (avatarUrl != null && avatarUrl!.isNotEmpty) 'avatar_url': avatarUrl,
    if (customLabel != null && customLabel!.isNotEmpty)
      'custom_label': customLabel,
    'region': region.name,
    'endpoint': endpoint,
    'auth': auth.toJson(),
    if (quota != null) 'quota': quota!.toJson(),
    'disabled': disabled,
    if (disabledReason != null) 'disabled_reason': disabledReason,
    'created_at': createdAt,
    'last_used': lastUsed,
  };
}

class CodeBuddyAutoSwitchConfig {
  const CodeBuddyAutoSwitchConfig({
    this.enabled = true,
    this.preferSameRegion = true,
  });

  final bool enabled;
  final bool preferSameRegion;

  CodeBuddyAutoSwitchConfig copyWith({
    bool? enabled,
    bool? preferSameRegion,
  }) => CodeBuddyAutoSwitchConfig(
    enabled: enabled ?? this.enabled,
    preferSameRegion: preferSameRegion ?? this.preferSameRegion,
  );

  factory CodeBuddyAutoSwitchConfig.fromJson(Map<String, Object?> json) =>
      CodeBuddyAutoSwitchConfig(
        enabled: json['enabled'] as bool? ?? true,
        preferSameRegion: json['prefer_same_region'] as bool? ?? true,
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'prefer_same_region': preferSameRegion,
  };
}
