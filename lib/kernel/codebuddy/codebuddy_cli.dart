import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_environment.dart';
import '../claude_code/claude_path_setting.dart';
import 'codebuddy_account_models.dart';

/// Built-in provider id for CodeBuddy CLI (`codebuddy` / `cbc`) in Settings →
/// Models and the session model picker.
const codebuddyBuiltinProviderId = 'codebuddy-cli';

/// Settings → General → CodeBuddy CLI: custom executable path
/// (`codebuddy.path` in settings.json).
abstract final class CodeBuddyPathSetting {
  static const settingKey = 'codebuddy.path';

  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// The path set now: main.dart reads it from settings.json.
  static String? Function() current = () => null;
}

/// Canonical reasoning effort tiers supported by `codebuddy --effort`.
const codebuddyEffortOrder = [
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// A model offered by CodeBuddy CLI (`codebuddy` / `cbc`).
class CodeBuddyModel {
  const CodeBuddyModel({
    required this.id,
    required this.label,
    this.cliModelId,
    this.description = '',
    this.effortLevels = const [],
    this.defaultEffort,
    this.contextOptions = const [200000],
    this.defaultContext = 200000,
  });

  final String id;
  final String? cliModelId;
  final String label;
  final String description;
  final List<String> effortLevels;
  final String? defaultEffort;
  final List<int> contextOptions;
  final int defaultContext;

  String get effectiveCliModel => cliModelId ?? id;

  int resolveContextWindow(int? candidate) {
    if (contextOptions.isEmpty) return defaultContext;
    if (candidate == null || candidate <= 0) return defaultContext;
    if (contextOptions.contains(candidate)) return candidate;
    var best = contextOptions.first;
    var bestDiff = (candidate - best).abs();
    for (final option in contextOptions.skip(1)) {
      final diff = (candidate - option).abs();
      if (diff < bestDiff || (diff == bestDiff && option > best)) {
        best = option;
        bestDiff = diff;
      }
    }
    return best;
  }

  String contextOptionDescription(int tokens) {
    if (tokens == defaultContext) return '默认完整窗口';
    return switch (tokens) {
      200000 => '200K 自动压缩阈值',
      256000 => '256K 自动压缩阈值',
      512000 => '512K 扩展压缩阈值',
      1000000 => '1M 完整长上下文窗口',
      _ => tokens < defaultContext ? '提前自动压缩，降低长对话消耗' : '长上下文窗口',
    };
  }
}

/// Built-in and dynamically queried models of CodeBuddy CLI (`codebuddy`).
abstract final class CodeBuddyModels {
  /// Default CN (`internal` · `copilot.tencent.com` / `codebuddy.cn`) + shared
  /// models, with smart routing models first.
  static const List<CodeBuddyModel> cnDefaults = [
    CodeBuddyModel(
      id: 'default-model',
      label: 'Auto (智能路由)',
      description: '200K · 根据任务复杂度自动匹配最佳模型',
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'primary-model',
      label: 'Primary (主力编程)',
      description: '272K · 高能力编程与复杂工程推理',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [272000],
      defaultContext: 272000,
    ),
    CodeBuddyModel(
      id: 'balanced-model',
      label: 'Balanced (均衡推理)',
      description: '256K · 质量、速度与积分消耗均衡',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000],
      defaultContext: 256000,
    ),
    CodeBuddyModel(
      id: 'fast-model',
      label: 'Fast (极速轻量)',
      description: '200K · 低延迟检索、脚本与轻量改动',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'low',
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'deepseek-v4-pro',
      label: 'DeepSeek V4 Pro',
      description: '1M · 深度架构推理与大型代码库重构',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'deepseek-v4.1-flash',
      label: 'DeepSeek V4.1 Flash',
      description: '1M · 高速推理编码模型',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'hy4-preview',
      label: 'Hunyuan Hy4 Preview',
      description: '1M · 腾讯混元新一代旗舰编程预览版',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'hy3',
      label: 'Hunyuan Hy3',
      description: '192K · 腾讯混元主力推理模型',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [192000],
      defaultContext: 192000,
    ),
    CodeBuddyModel(
      id: 'glm-5.3',
      label: 'GLM-5.3',
      description: '1M · 智谱旗舰代码与工具调用模型',
      effortLevels: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'glm-5.3-flash',
      label: 'GLM-5.3 Flash',
      description: '1M · 智谱高速多模态编程模型',
      effortLevels: ['low', 'high', 'max'],
      defaultEffort: 'low',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'kimi-k3-2',
      label: 'Kimi K3',
      description: '1M · Moonshot 长上下文推理编程模型',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'kimi-k2.8-preview',
      label: 'Kimi K2.8 Preview',
      description: '1M · Moonshot 敏捷推理编码预览版',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'minimax-m3-pay',
      label: 'MiniMax M3',
      description: '512K · MiniMax 新一代 Agent 工程模型',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000],
      defaultContext: 512000,
    ),
  ];

  /// Default Global (`www.codebuddy.ai`) models.
  static const List<CodeBuddyModel> globalDefaults = [
    CodeBuddyModel(
      id: 'default-model',
      label: 'Auto (智能路由)',
      description: '200K · Automatic optimal model routing',
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'primary-model',
      label: 'Primary',
      description: '272K · Primary frontier coding & reasoning',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [272000],
      defaultContext: 272000,
    ),
    CodeBuddyModel(
      id: 'balanced-model',
      label: 'Balanced',
      description: '256K · Balanced coding & tool execution',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000],
      defaultContext: 256000,
    ),
    CodeBuddyModel(
      id: 'fast-model',
      label: 'Fast',
      description: '200K · High-speed coding & search',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'low',
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'gpt-6-astra',
      label: 'GPT-6 Astra',
      description: '1M · Flagship deep reasoning & coding',
      effortLevels: ['low', 'medium', 'high', 'xhigh', 'max'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'gpt-5.6-sol',
      label: 'GPT-5.6 Sol',
      description: '1M · High-capability engineering model',
      effortLevels: ['low', 'medium', 'high', 'xhigh'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'gpt-5.6-terra',
      label: 'GPT-5.6 Terra',
      description: '1M · Balanced frontier reasoning',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'gemini-3.5-flash',
      label: 'Gemini 3.5 Flash',
      description: '1M · Multimodal fast reasoning & coding',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'deepseek-v4.1-flash',
      label: 'DeepSeek V4.1 Flash',
      description: '1M · Fast reasoning & code synthesis',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'hy4-preview',
      label: 'Hunyuan Hy4 Preview',
      description: '1M · Tencent Hunyuan frontier preview',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'glm-5.3',
      label: 'GLM-5.3',
      description: '1M · Flagship agentic coding model',
      effortLevels: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'kimi-k3',
      label: 'Kimi K3',
      description: '1M · Long-context reasoning & coding',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
  ];

  static List<CodeBuddyModel> _current = cnDefaults;

  static List<CodeBuddyModel> get current => _current;

  /// Updates [current] to the default catalog for [region].
  static void syncForRegion(CodeBuddyRegion region) {
    _current = region == CodeBuddyRegion.global ? globalDefaults : cnDefaults;
  }

  /// Updates [current] to match [account]'s region + any custom `~/.codebuddy/models.json`.
  static void syncForAccount(CodeBuddyAccount account) {
    final base = account.region == CodeBuddyRegion.global
        ? globalDefaults
        : cnDefaults;
    final byId = <String, CodeBuddyModel>{
      for (final m in [...cnDefaults, ...globalDefaults]) m.id: m,
    };

    final merged = <CodeBuddyModel>[...base];
    final seen = <String>{for (final m in merged) m.id};

    // Merge server-advertised models from `/v2/config` if present.
    for (final serverId in account.quota?.availableModelIds ?? const <String>[]) {
      if (serverId.contains('image') || seen.contains(serverId)) continue;
      seen.add(serverId);
      merged.add(
        byId[serverId] ??
            CodeBuddyModel(
              id: serverId,
              label: _prettifyId(serverId),
              description: 'CodeBuddy 服务端可用模型',
              effortLevels: const ['low', 'medium', 'high'],
              defaultEffort: 'medium',
              contextOptions: const [200000],
              defaultContext: 200000,
            ),
      );
    }

    // Merge user `~/.codebuddy/models.json` custom models if present.
    for (final custom in _readUserCustomModels()) {
      final existingIdx = merged.indexWhere((m) => m.id == custom.id);
      if (existingIdx >= 0) {
        merged[existingIdx] = custom;
      } else {
        merged.add(custom);
      }
    }

    _current = merged;
  }

  /// Merges dynamic model descriptors reported by `codebuddy` `initialize` /
  /// `get_available_models`.
  static void updateFromCliModels(List<Map<String, Object?>> rawModels) {
    if (rawModels.isEmpty) return;
    final byKnown = <String, CodeBuddyModel>{
      for (final m in [...cnDefaults, ...globalDefaults, ..._current]) m.id: m,
    };
    final updated = <CodeBuddyModel>[];
    final seen = <String>{};
    for (final raw in rawModels) {
      final id = (raw['value'] ?? raw['modelId'] ?? raw['id']) as String? ?? '';
      if (id.isEmpty || id.contains('image') || !seen.add(id)) continue;
      if (byKnown[id] case final known?) {
        updated.add(known);
        continue;
      }
      final name =
          (raw['displayName'] ?? raw['name']) as String? ?? _prettifyId(id);
      final desc = raw['description'] as String? ?? 'CodeBuddy 可用模型';
      final maxInput = (raw['maxInputTokens'] as num?)?.toInt() ?? 200000;
      updated.add(
        CodeBuddyModel(
          id: id,
          label: name,
          description: desc,
          effortLevels: const ['low', 'medium', 'high'],
          defaultEffort: 'medium',
          contextOptions: maxInput >= 1000000
              ? const [256000, 512000, 1000000]
              : [maxInput],
          defaultContext: maxInput,
        ),
      );
    }
    if (updated.isNotEmpty) {
      _current = updated;
    }
  }

  static List<CodeBuddyModel> _readUserCustomModels() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return const [];
    final file = File(p.join(home, '.codebuddy', 'models.json'));
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['models'] is! List) return const [];
      final out = <CodeBuddyModel>[];
      for (final item in decoded['models'] as List) {
        if (item is! Map) continue;
        final id = (item['id'] as String?)?.trim() ?? '';
        if (id.isEmpty) continue;
        final name = (item['name'] as String?)?.trim();
        final maxIn = (item['maxInputTokens'] as num?)?.toInt() ?? 200000;
        final supportsReasoning = item['supportsReasoning'] as bool? ?? false;
        out.add(
          CodeBuddyModel(
            id: id,
            label: (name != null && name.isNotEmpty) ? name : id,
            description: '自定义模型 (~/.codebuddy/models.json)',
            effortLevels: supportsReasoning
                ? const ['low', 'medium', 'high']
                : const [],
            defaultEffort: supportsReasoning ? 'high' : null,
            contextOptions: maxIn >= 1000000
                ? const [256000, 512000, 1000000]
                : [maxIn],
            defaultContext: maxIn,
          ),
        );
      }
      return out;
    } on Object {
      return const [];
    }
  }

  static String _prettifyId(String id) => id
      .split('-')
      .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
      .join(' ');

  /// Strips `@codebuddy-cli/` prefix if present.
  static String stripPrefix(String? model) {
    if (model == null || model.isEmpty) return '';
    const prefix = '@$codebuddyBuiltinProviderId/';
    return model.startsWith(prefix) ? model.substring(prefix.length) : model;
  }

  static CodeBuddyModel? of(String? model) {
    final bare = stripPrefix(model);
    if (bare.isEmpty) return null;
    if (bare == 'default') return _current.first;
    for (final m in _current) {
      if (m.id == bare || m.effectiveCliModel == bare) return m;
    }
    for (final m in [...cnDefaults, ...globalDefaults]) {
      if (m.id == bare || m.effectiveCliModel == bare) return m;
    }
    return null;
  }

  static ({CodeBuddyModel model, String? effort})? parseVariant(String? model) {
    final found = of(model);
    if (found == null) return null;
    return (model: found, effort: null);
  }

  static bool isCodeBuddyModel(String? model) {
    if (model == null || model.isEmpty) return false;
    if (model.startsWith('@$codebuddyBuiltinProviderId/')) return true;
    return of(model) != null;
  }

  static String bareModelId(String? model) {
    final found = of(model);
    if (found != null) return found.id;
    final bare = stripPrefix(model);
    if (bare.isEmpty || bare == 'default') return _current.first.id;
    return bare;
  }

  static String cliModelIdOf(String? model) {
    final found = of(model);
    if (found != null) return found.effectiveCliModel;
    final bare = stripPrefix(model);
    if (bare.isEmpty || bare == 'default') {
      return _current.first.effectiveCliModel;
    }
    return bare;
  }

  static String labelOf(String modelId) =>
      of(modelId)?.label ?? bareModelId(modelId);

  /// Fast model id used for title summarization / lightweight helper calls.
  static String get fastAuxiliaryModel => 'fast-model';
}

// ---------------------------------------------------------------------------
// Local CodeBuddy CLI (`codebuddy` / `cbc`) discovery, status & installation
// ---------------------------------------------------------------------------

class CodeBuddyCli {
  const CodeBuddyCli({
    required this.executable,
    required this.environment,
    this.throughShell = false,
  });

  final String executable;
  final Map<String, String> environment;
  final bool throughShell;
}

abstract final class LocalCodeBuddy {
  static bool? _installed;

  static String get installCommand =>
      'npm install -g @tencent-ai/codebuddy-code';

  static bool installed() =>
      _installed ??= _locateSync(Map.of(Platform.environment)) != null;

  static Future<void> lookForInstall() async {
    try {
      final env = await ClaudeEnvironment.of();
      _installed = _locateSync(env) != null;
    } on Object catch (error) {
      debugPrint('CodeBuddy CLI lookup failed: $error');
    }
  }

  static Future<LocalClaudeStatus?> status() async {
    try {
      final cli = await locate();
      final result = await Process.run(
        cli.executable,
        const ['--version'],
        environment: cli.environment,
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) {
        _installed = false;
        return LocalClaudeFailed('${result.stderr}'.trim());
      }
      final ver = const LineSplitter()
              .convert('${result.stdout}'.trim())
              .where((l) => l.trim().isNotEmpty)
              .firstOrNull ??
          'unknown';
      _installed = true;
      return LocalClaudeFound(cli.executable, ver);
    } on ClaudeUnavailable catch (error) {
      _installed = false;
      return error.detail == null || error.message.contains('未检测到')
          ? const LocalClaudeMissing()
          : LocalClaudeFailed(error.detail!);
    } on Object catch (error) {
      return LocalClaudeFailed('$error');
    }
  }

  static Future<CodeBuddyCli> locate() async {
    final baseEnv = await ClaudeEnvironment.of();
    final env = _enrichedPathEnvironment(baseEnv);
    final found = _locateSync(env);
    if (found != null) {
      _installed = true;
      final isCmd = Platform.isWindows &&
          (found.toLowerCase().endsWith('.cmd') ||
              found.toLowerCase().endsWith('.bat'));
      return CodeBuddyCli(
        executable: found,
        environment: env,
        throughShell: isCmd,
      );
    }
    _installed = false;
    throw ClaudeUnavailable(
      '未检测到 CodeBuddy CLI (codebuddy / cbc)',
      detail:
          '请先在终端安装腾讯云 CodeBuddy Code CLI：\n$installCommand\n\n'
          '或在「设置 → 通用 → CodeBuddy CLI」中指定可执行文件路径。',
    );
  }

  /// Installs `@tencent-ai/codebuddy-code` globally via `npm`.
  static Future<void> install() async {
    final env = _enrichedPathEnvironment(await ClaudeEnvironment.of());
    final npm = _findBinaryInEnv('npm', env);
    if (npm == null) {
      throw ClaudeUnavailable(
        '未找到 npm，无法自动安装 CodeBuddy CLI',
        detail: '请先安装 Node.js (v18+)，然后运行：\n$installCommand',
      );
    }
    final res = await Process.run(
      npm,
      const ['install', '-g', '@tencent-ai/codebuddy-code'],
      environment: env,
      includeParentEnvironment: Platform.isWindows,
      runInShell: Platform.isWindows,
    );
    if (res.exitCode != 0) {
      throw ClaudeUnavailable(
        '安装 @tencent-ai/codebuddy-code 失败',
        detail: '${res.stderr}\n${res.stdout}'.trim(),
      );
    }
    _installed = true;
  }

  static Map<String, String> _enrichedPathEnvironment(
    Map<String, String> base,
  ) {
    final home =
        base['HOME'] ??
        base['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final sep = Platform.isWindows ? ';' : ':';
    final existing = (base['PATH'] ?? Platform.environment['PATH'] ?? '')
        .split(sep)
        .where((s) => s.isNotEmpty)
        .toList();
    final extras = <String>[
      if (home.isNotEmpty && !Platform.isWindows) ...[
        p.join(home, '.local', 'bin'),
        p.join(home, '.hermes', 'node', 'bin'),
        p.join(home, '.codebuddy', 'bin'),
        p.join(home, '.bun', 'bin'),
        p.join(home, '.volta', 'bin'),
        '/opt/homebrew/bin',
        '/usr/local/bin',
        ..._globNodeBins(p.join(home, '.local', 'share', 'fnm', 'node-versions'), 'installation/bin'),
        ..._globNodeBins(p.join(home, '.nvm', 'versions', 'node'), 'bin'),
      ],
      if (home.isNotEmpty && Platform.isWindows) ...[
        if (base['APPDATA'] case final appData? when appData.isNotEmpty)
          p.join(appData, 'npm'),
        p.join(home, '.local', 'bin'),
        p.join(home, '.bun', 'bin'),
      ],
    ];
    final seen = <String>{};
    final merged = <String>[
      for (final dir in [...extras, ...existing])
        if (seen.add(dir)) dir,
    ];
    return {...base, 'PATH': merged.join(sep)};
  }

  static List<String> _globNodeBins(String parentDir, String sub) {
    final d = Directory(parentDir);
    if (!d.existsSync()) return const [];
    try {
      final dirs = d
          .listSync()
          .whereType<Directory>()
          .map((e) => p.join(e.path, sub))
          .where((binPath) => Directory(binPath).existsSync())
          .toList()
        ..sort((a, b) => b.compareTo(a));
      return dirs;
    } on Object {
      return const [];
    }
  }

  static String? _locateSync(Map<String, String> env) {
    final home =
        env['HOME'] ??
        env['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';

    if (CodeBuddyPathSetting.current() case final custom?
        when custom.isNotEmpty) {
      final expanded =
          (custom == '~' || custom.startsWith('~/') || custom.startsWith(r'~\'))
              ? '$home${custom.substring(1)}'
              : custom;
      if (File(expanded).existsSync()) return expanded;
    }

    final enriched = _enrichedPathEnvironment(env);
    for (final name in const ['codebuddy', 'cbc', 'codebuddy-code']) {
      if (_findBinaryInEnv(name, enriched) case final hit?) {
        return hit;
      }
    }
    return null;
  }

  static String? _findBinaryInEnv(String name, Map<String, String> env) {
    final sep = Platform.isWindows ? ';' : ':';
    final pathVar = env['PATH'] ?? '';
    final exts = Platform.isWindows
        ? const ['.cmd', '.exe', '.bat', '']
        : const [''];
    for (final dir in pathVar.split(sep)) {
      if (dir.trim().isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir.trim(), '$name$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}
