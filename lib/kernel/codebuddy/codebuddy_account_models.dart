/// Data models for CodeBuddy multi-account management, edition/billing tiers,
/// regional deployments (CN / Global / iOA / Enterprise), and credit tracking.
library;

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

  /// Value for `CODEBUDDY_INTERNET_ENVIRONMENT` documented in `iam.md`.
  String? get internetEnvironment => switch (this) {
    CodeBuddyRegion.cn => 'internal',
    CodeBuddyRegion.global => null,
    CodeBuddyRegion.ioa => 'ioa',
    CodeBuddyRegion.cloudhosted => 'cloudhosted',
    CodeBuddyRegion.selfhosted => 'selfhosted',
  };

  String get planUrl => switch (this) {
    CodeBuddyRegion.cn => 'https://www.codebuddy.cn/profile/plan',
    CodeBuddyRegion.global => 'https://www.codebuddy.ai/profile/plan',
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
    CodeBuddyEdition.free => 'FREE',
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
        accessToken: json['access_token'] as String? ??
            json['accessToken'] as String? ??
            '',
        refreshToken: json['refresh_token'] as String? ??
            json['refreshToken'] as String? ??
            '',
        expiresAt: (json['expires_at'] as num?)?.toInt() ??
            (json['expiresAt'] as num?)?.toInt() ??
            0,
        refreshExpiresAt: (json['refresh_expires_at'] as num?)?.toInt() ??
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

class CodeBuddyQuotaData {
  const CodeBuddyQuotaData({
    this.edition = CodeBuddyEdition.free,
    this.paymentType,
    this.totalCredits,
    this.usedCredits,
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
  final double? totalCredits;
  final double? usedCredits;
  final double sessionCreditsUsed;
  final int turnCount;
  final int totalTokensUsed;
  final bool quotaExhausted;
  final String? resetTime;
  final String? upgradeUrl;
  final List<String> availableModelIds;
  final int lastUpdated;
  final String? fetchError;

  double get remainingFraction {
    if (quotaExhausted) return 0.0;
    final total = totalCredits;
    if (total != null && total > 0) {
      final used = usedCredits ?? sessionCreditsUsed;
      return ((total - used) / total).clamp(0.0, 1.0);
    }
    return 1.0;
  }

  int get percentage => (remainingFraction * 100).round().clamp(0, 100);

  String get summaryLabel {
    if (quotaExhausted) return '配额已用尽';
    final total = totalCredits;
    if (total != null && total > 0) {
      final left = (total - (usedCredits ?? sessionCreditsUsed)).clamp(
        0.0,
        total,
      );
      return '${left.toStringAsFixed(left == left.roundToDouble() ? 0 : 1)} / '
          '${total.toStringAsFixed(total == total.roundToDouble() ? 0 : 1)} Credits';
    }
    if (sessionCreditsUsed > 0) {
      return '累计已用 ${sessionCreditsUsed.toStringAsFixed(2)} Credits';
    }
    return '${edition.label} · 正常可用';
  }

  CodeBuddyQuotaData copyWith({
    CodeBuddyEdition? edition,
    String? paymentType,
    double? totalCredits,
    double? usedCredits,
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
    totalCredits: totalCredits ?? this.totalCredits,
    usedCredits: usedCredits ?? this.usedCredits,
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
        totalCredits: (json['total_credits'] as num?)?.toDouble(),
        usedCredits: (json['used_credits'] as num?)?.toDouble(),
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
    if (totalCredits != null) 'total_credits': totalCredits,
    if (usedCredits != null) 'used_credits': usedCredits,
    'session_credits_used': sessionCreditsUsed,
    'turn_count': turnCount,
    'total_tokens_used': totalTokensUsed,
    'quota_exhausted': quotaExhausted,
    if (resetTime != null) 'reset_time': resetTime,
    if (upgradeUrl != null) 'upgrade_url': upgradeUrl,
    if (availableModelIds.isNotEmpty)
      'available_model_ids': availableModelIds,
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
        uid.length > 16 ? '${uid.substring(0, 8)}…${uid.substring(uid.length - 4)}' : uid,
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
