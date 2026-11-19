import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths, Shell;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../bash_exe/bao_bash.dart';
import '../../models/launch_environment.dart';
import '../../network/network_proxy_io.dart';
import '../../network/tls.dart';
import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_environment.dart';
import '../claude_code/claude_settings_file.dart';
import 'codebuddy_account_models.dart';
import 'codebuddy_accounts.dart';
import 'codebuddy_cli.dart';

/// Starts a session on the CodeBuddy CLI (`codebuddy` / `cbc`).
Future<ClaudeCodeTransport> startCodeBuddy(ClaudeLaunch launch) =>
    CodeBuddyTransport.start(launch);

/// Whether [launch] targets a CodeBuddy CLI model.
bool isCodeBuddyLaunch(ClaudeLaunch launch) =>
    CodeBuddyModels.isCodeBuddyModel(launch.model);

/// Persistent `stream-json` child-process transport for Tencent CodeBuddy Code
/// CLI (`codebuddy -p --input-format stream-json --output-format stream-json`).
class CodeBuddyTransport implements ClaudeCodeTransport {
  CodeBuddyTransport._({
    required this.cli,
    required this.launch,
  }) : _sessionId = (launch.resume != null && launch.resume!.isNotEmpty)
           ? launch.resume
           : null,
       _model = CodeBuddyModels.cliModelIdOf(launch.model),
       _permissionMode = launch.permissionMode ?? 'default',
       _effort = _resolveInitialEffort(launch.model, launch.effort),
       _maxContextTokens = _resolveInitialContextTokens(
         launch.model,
         launch.autocompact,
       ),
       _paths = AgentPaths.from(cli.environment) {
    _live.add(this);
  }

  static int _resolveInitialContextTokens(
    String? rawModel,
    int? launchAutocompact,
  ) {
    final info = CodeBuddyModels.of(rawModel);
    if (info != null) {
      return info.resolveContextWindow(launchAutocompact);
    }
    if (launchAutocompact != null && launchAutocompact > 0) {
      return launchAutocompact;
    }
    return 200000;
  }

  static String? _resolveInitialEffort(String? rawModel, String? launchEffort) {
    final info = CodeBuddyModels.of(rawModel);
    if (info == null) return launchEffort;
    if (info.effortLevels.isEmpty) return null;
    if (launchEffort != null && info.effortLevels.contains(launchEffort)) {
      return launchEffort;
    }
    return info.initialEffort;
  }

  @visibleForTesting
  static CodeBuddyProcessRegistry registry = CodeBuddyProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('codebuddy')),
  );

  static final Set<CodeBuddyTransport> _live = {};

  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await Future.wait([
      for (final transport in [..._live]) transport._stop(timeout),
    ]);
    await registry.flush();
  }

  static Future<void> reapLeftovers() => registry.reaped;

  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async {
    await registry.reaped;
    if (!Directory(launch.cwd).existsSync()) {
      throw ClaudeFolderGone(launch.cwd);
    }
    await CodeBuddyAccounts.instance.ensureInitialized();
    CodeBuddyAccounts.onActiveAccountSwitched ??= (_) async {
      for (final transport in [..._live]) {
        transport._needsAccountRespawn = true;
        if (!transport._turnInFlight) {
          await transport._recycleProcess();
        }
      }
    };
    final cli = await LocalCodeBuddy.locate();
    final transport = CodeBuddyTransport._(cli: cli, launch: launch);
    await transport._spawnProcess();
    return transport;
  }

  final CodeBuddyCli cli;
  final ClaudeLaunch launch;
  final AgentPaths _paths;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  String? _settingsFilePath;

  String? _sessionId;
  String _model;
  String _permissionMode;
  String? _pendingPermissionMode;
  String? _effort;
  String? _pendingThoughtLevel;
  final Set<String> _sessionApprovedTools = {};
  int _maxContextTokens;
  int _lastContextTokens = 0;
  double _turnCreditsReported = 0.0;
  int _turnTokensReported = 0;
  bool _turnInFlight = false;
  bool _hasSentTurnOnProcess = false;
  bool _suppressingResumeReplay = false;
  bool _needsAccountRespawn = false;
  bool _closed = false;
  bool _recycling = false;
  String? _pendingCustomTitle;
  Map<String, Object?>? _lastInitializeRequest;

  final List<String> _stderr = [];
  static const int _maxStderrLines = 30;
  final Set<String> _initializeRequestIds = {};
  final Set<String> _internalControlIds = {};
  final List<String> _pendingClientUserUuids = [];
  final Map<String, String> _clientToCliUserUuid = {};
  final Map<
    String,
    ({
      String origReqId,
      Map<String, Object?> origMessage,
      Timer fallbackTimer,
    })
  > _pendingModelFetches = {};
  int _internalSeq = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  static const _cliEffortTiers = {
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  };

  /// Maps Cyte's effort value (`none`, `enabled`, `low`..`max`) to WorkBuddy's
  /// `thoughtLevel` (`disabled`, `enabled`, `low`..`max`).
  static String _toThoughtLevel(String effort) => switch (effort) {
    'none' || 'disabled' => 'disabled',
    'enabled' => 'enabled',
    'minimal' => 'low',
    _ => effort,
  };

  /// Builds CLI arguments compatible with `@tencent-ai/codebuddy-code` (`cbc`).
  @visibleForTesting
  static List<String> buildArguments({
    required ClaudeLaunch launch,
    required String model,
    required String permissionMode,
    required String? effort,
    required int maxContextTokens,
    required String? resumeSessionId,
    required String? settingsFilePath,
    required Map<String, Object?> inlineSettings,
  }) {
    final clampedAutocompact = maxContextTokens.clamp(100000, 1000000);
    final bash = BaoBash.cliEnvironment(Platform.environment);
    final told = BaoBash.givesBaoBash(bash) && !launch.ownPrompt
        ? [
            Shell.baoBashNote,
            if (launch.instructions case final own? when own.isNotEmpty) own,
          ].join('\n\n')
        : launch.instructions;

    final cliEffort =
        (effort != null && _cliEffortTiers.contains(effort)) ? effort : null;

    return [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--replay-user-messages',
      if (permissionMode == 'bypassPermissions') '-y',
      '--permission-mode',
      permissionMode,
      if (model.isNotEmpty && model != 'default') ...['--model', model],
      if (cliEffort != null) ...['--effort', cliEffort],
      '--autocompact',
      '$clampedAutocompact',
      if (resumeSessionId != null && resumeSessionId.isNotEmpty) ...[
        '--resume',
        resumeSessionId,
      ],
      for (final directory in launch.directories) ...['--add-dir', directory],
      if (settingsFilePath != null) ...[
        '--settings',
        settingsFilePath,
      ] else if (inlineSettings.isNotEmpty) ...[
        '--settings',
        jsonEncode(inlineSettings),
      ],
      if (!launch.persist) '--no-session-persistence',
      if (launch.tools case final tools?) ...[
        '--tools',
        tools.join(','),
        if (!launch.userServers) '--strict-mcp-config',
      ],
      if (launch.sdkServers.isNotEmpty) ...[
        '--mcp-config',
        jsonEncode({
          'mcpServers': {
            for (final name in launch.sdkServers)
              name: {'type': 'sdk', 'name': name},
          },
        }),
        '--allowedTools',
        launch.sdkServers.map((name) => 'mcp__$name').join(','),
      ],
      if (launch.ownPrompt) ...[
        '--system-prompt',
        told ?? '',
      ] else ...[
        '--append-system-prompt',
        switch (told) {
          final text? when text.isNotEmpty =>
            '${ClaudeLaunch.appendedSystemPrompt}\n\n$text',
          _ => ClaudeLaunch.appendedSystemPrompt,
        },
      ],
    ];
  }

  Future<void> _spawnProcess() async {
    var activeAccount = CodeBuddyAccounts.instance.currentAccount;
    if (activeAccount != null) {
      activeAccount = await CodeBuddyAccounts.instance.ensureFreshAccount(
        activeAccount,
      );
    }

    final accountEnv = activeAccount?.processEnvironment() ?? const {};
    final settingsMap = <String, Object?>{
      ...launch.settings,
      if (_effort == 'none' || _effort == 'disabled')
        'alwaysThinkingEnabled': false,
      if (activeAccount != null &&
          (activeAccount.region == CodeBuddyRegion.cloudhosted ||
              activeAccount.region == CodeBuddyRegion.selfhosted))
        'endpoint': activeAccount.endpoint,
    };
    if (_effort != null && (_sessionId == null || _sessionId!.isEmpty)) {
      _pendingThoughtLevel = _toThoughtLevel(_effort!);
    }
    final hasSecrets =
        launch.hasSecrets ||
        accountEnv.containsKey('CODEBUDDY_AUTH_TOKEN') ||
        accountEnv.containsKey('CODEBUDDY_API_KEY');

    String? settingsFile;
    if (hasSecrets) {
      final filePayload = <String, Object?>{
        ...settingsMap,
        'env': <String, Object?>{
          if (settingsMap['env'] case final Map existing)
            ...existing.cast<String, Object?>(),
          ...accountEnv,
        },
      };
      settingsFile = await ClaudeSettingsFile.write(filePayload);
      _settingsFilePath = settingsFile;
    }

    final proxy = await NetworkProxy.instance.environment();
    final certificates = await nodeCertificatesEnvironment(cli.environment);
    final bash = BaoBash.cliEnvironment({
      ...Platform.environment,
      ...cli.environment,
    });

    final args = buildArguments(
      launch: launch,
      model: _model,
      permissionMode: _permissionMode,
      effort: _effort,
      maxContextTokens: _maxContextTokens,
      resumeSessionId: _sessionId,
      settingsFilePath: settingsFile,
      inlineSettings: settingsMap,
    );

    try {
      final proc = await Process.start(
        cli.executable,
        args,
        workingDirectory: launch.cwd,
        environment: {
          ...cli.environment,
          ...proxy,
          ...certificates,
          ...bash,
          if (launch.env != null)
            for (final name in ClaudeModelVariables.inherited) name: '',
          // Enables session-level `thoughtLevel` & `contextWindow` in `set_config`,
          // matching WorkBuddy's ConversationEngine subprocess environment.
          'CBC_SESSION_CONFIG_SYNC': '1',
          ...accountEnv,
          ...ClaudeEnvironment.stateDirectory(cli.environment),
        },
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      );
      _process = proc;
      _hasSentTurnOnProcess = false;
      _suppressingResumeReplay = false;
      _needsAccountRespawn = false;
      unawaited(registry.add(proc.pid));

      _stdoutSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _onStdoutLine,
            onError: (Object e) => _onStderrLine('$e'),
          );
      _stderrSub = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _onStderrLine,
            onError: (Object e) => _onStderrLine('$e'),
          );
      unawaited(proc.exitCode.then((code) => _onProcessExit(proc, code)));
    } on ProcessException catch (error) {
      if (settingsFile != null) {
        await ClaudeSettingsFile.delete(settingsFile);
        _settingsFilePath = null;
      }
      throw ClaudeUnavailable(
        'CodeBuddy CLI 启动失败',
        detail: '${cli.executable}\n${error.message}',
      );
    }
  }

  Future<void> _recycleProcess() async {
    if (_closed || _recycling) return;
    _recycling = true;
    try {
      for (final entry in _pendingModelFetches.values) {
        entry.fallbackTimer.cancel();
      }
      _pendingModelFetches.clear();
      _internalControlIds.clear();
      final old = _process;
      _process = null;
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
      _stdoutSub = null;
      _stderrSub = null;
      if (_settingsFilePath case final path?) {
        _settingsFilePath = null;
        unawaited(ClaudeSettingsFile.delete(path));
      }
      if (old != null) {
        unawaited(registry.remove(old.pid));
        unawaited(old.stdin.close().catchError((Object _) {}));
        old.kill();
        await old.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            old.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      }
      if (!_closed) {
        await _spawnProcess();
        if (_lastInitializeRequest case final prevInit?) {
          final reinitId = '_cyte_reinit_${++_internalSeq}';
          _internalControlIds.add(reinitId);
          _writeRaw({
            'type': 'control_request',
            'request_id': reinitId,
            'request': {
              'subtype': 'initialize',
              'hasPrompt': true,
              if (prevInit['sdkMcpServers'] != null)
                'sdkMcpServers': prevInit['sdkMcpServers'],
              if (prevInit['capabilities'] != null)
                'capabilities': prevInit['capabilities'],
            },
          });
        }
      }
    } finally {
      _recycling = false;
    }
  }

  void _flushPendingSessionThoughtLevel(String sid) {
    final pending = _pendingThoughtLevel;
    if (pending == null || pending.isEmpty) return;
    final info = CodeBuddyModels.of(_model);
    if (pending == 'disabled' && (info?.onlyReasoning ?? false)) {
      _pendingThoughtLevel = null;
      return;
    }
    _pendingThoughtLevel = null;
    final internalId = '_cyte_thought_${++_internalSeq}';
    _internalControlIds.add(internalId);
    _writeRaw({
      'type': 'control_request',
      'request_id': internalId,
      'request': {
        'subtype': 'set_config',
        'session_id': sid,
        'config': {'thoughtLevel': pending},
      },
    });
  }

  void _flushPendingSessionPermissionMode(String sid) {
    final pending = _pendingPermissionMode;
    if (pending == null || pending.isEmpty) return;
    _pendingPermissionMode = null;
    final internalId = '_cyte_perm_mode_${++_internalSeq}';
    _internalControlIds.add(internalId);
    _writeRaw({
      'type': 'control_request',
      'request_id': internalId,
      'request': {
        'subtype': 'set_permission_mode',
        'session_id': sid,
        'mode': pending,
      },
    });
  }

  void _onStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Map<String, Object?> decoded;
    try {
      final raw = jsonDecode(trimmed);
      if (raw is! Map) {
        _onStderrLine(line);
        return;
      }
      decoded = raw.cast<String, Object?>();
    } on FormatException {
      _onStderrLine(line);
      return;
    }

    if (decoded['session_id'] case final String sid when sid.isNotEmpty) {
      final wasEmpty = _sessionId == null || _sessionId!.isEmpty;
      _sessionId = sid;
      if (wasEmpty || _pendingThoughtLevel != null) {
        _flushPendingSessionThoughtLevel(sid);
      }
      if (wasEmpty || _pendingPermissionMode != null) {
        _flushPendingSessionPermissionMode(sid);
      }
      if (_pendingCustomTitle case final title?) {
        _pendingCustomTitle = null;
        _appendCustomTitleToTranscript(sid, title);
      }
    }

    final type = decoded['type'] as String?;
    if (type == 'control_response') {
      final handled = _handleControlResponse(decoded);
      if (handled == null) return;
      decoded = handled;
      if (!_closed && !_messages.isClosed) {
        _messages.add(decoded);
      }
      return;
    }
    if (type == 'control_request') {
      final normalized = _normalizeIncomingControlRequest(decoded);
      if (normalized != null && !_closed && !_messages.isClosed) {
        _messages.add(normalized);
      }
      return;
    }

    // Defense-in-depth: suppress any startup `renderHistory()` burst emitted by
    // `codebuddy --resume` before a live user turn is sent on this process.
    if (_suppressingResumeReplay) {
      if (type == 'result') {
        _suppressingResumeReplay = false;
      }
      return;
    }
    if (type == 'system' &&
        decoded['subtype'] == 'init' &&
        decoded['model'] == 'unknown' &&
        (decoded['tools'] as List?)?.isEmpty == true) {
      _suppressingResumeReplay = true;
      return;
    }
    if (!_hasSentTurnOnProcess &&
        _sessionId != null &&
        _sessionId!.isNotEmpty &&
        (type == 'user' ||
            type == 'assistant' ||
            type == 'stream_event' ||
            type == 'file-history-snapshot' ||
            type == 'ai-title' ||
            type == 'topic' ||
            type == 'result' ||
            (type == 'system' && decoded['subtype'] == 'usage_update'))) {
      return;
    }

    if (type == 'user') {
      final reconciled = _reconcileUserEcho(decoded);
      if (reconciled == null) return;
      decoded = reconciled;
    } else if (type == 'assistant') {
      _observeAssistantUsage(decoded);
    } else if (type == 'system' && decoded['subtype'] == 'usage_update') {
      _observeTurnUsageUpdate(decoded);
    } else if (type == 'result') {
      decoded = _onTurnResult(decoded);
    }

    if (!_closed && !_messages.isClosed) {
      _messages.add(decoded);
    }
  }

  Map<String, Object?>? _handleControlResponse(Map<String, Object?> message) {
    final resp = (message['response'] as Map?)?.cast<String, Object?>();
    if (resp == null) return message;
    final reqId = resp['request_id'] as String?;
    if (reqId == null) return message;

    // 1. Swallow responses to internal fire-and-forget control requests.
    if (_internalControlIds.remove(reqId)) {
      return null;
    }

    // 2. Complete deferred `initialize` once `get_available_models` returns `rawModels`.
    if (_pendingModelFetches.remove(reqId) case final pending?) {
      pending.fallbackTimer.cancel();
      if (resp['subtype'] == 'success') {
        final modelsPayload =
            (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
        final rawList = modelsPayload['rawModels'] ?? modelsPayload['models'];
        if (rawList is List) {
          final maps = [
            for (final m in rawList)
              if (m is Map) m.cast<String, Object?>(),
          ];
          CodeBuddyModels.updateFromCliModels(maps);
        }
      }
      return _buildNormalizedInitResponse(pending.origMessage);
    }

    // 3. Intercept `initialize`: parse stub models & CLI account, then query
    // `get_available_models` so `rawModels` (`reasoning.supportedEfforts`,
    // `onlyReasoning`, `credits`) are populated before kernel finishes init!
    if (_initializeRequestIds.remove(reqId)) {
      if (resp['subtype'] != 'success') return message;
      final payload =
          (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
      if (payload['account'] case final Map rawAcc) {
        unawaited(
          CodeBuddyAccounts.instance.syncFromCliInitializeAccount(
            rawAcc.cast<String, Object?>(),
          ),
        );
      }
      if (payload['models'] case final List rawModels) {
        final maps = [
          for (final m in rawModels)
            if (m is Map) m.cast<String, Object?>(),
        ];
        CodeBuddyModels.updateFromCliModels(maps);
      }

      final fetchId = '_cyte_models_${++_internalSeq}';
      final timer = Timer(const Duration(milliseconds: 350), () {
        if (_pendingModelFetches.remove(fetchId) case final timedOut?) {
          if (!_closed && !_messages.isClosed) {
            _messages.add(_buildNormalizedInitResponse(timedOut.origMessage));
          }
        }
      });
      _pendingModelFetches[fetchId] = (
        origReqId: reqId,
        origMessage: message,
        fallbackTimer: timer,
      );
      _writeRaw({
        'type': 'control_request',
        'request_id': fetchId,
        'request': const {'subtype': 'get_available_models'},
      });
      return null;
    }

    return message;
  }

  Map<String, Object?> _buildNormalizedInitResponse(
    Map<String, Object?> origMessage,
  ) {
    final resp =
        (origMessage['response'] as Map?)?.cast<String, Object?>() ?? const {};
    final payload =
        (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
    final activeAccount = CodeBuddyAccounts.instance.currentAccount;
    final normalizedPayload = <String, Object?>{
      ...payload,
      'account': {
        'subscriptionType': activeAccount != null
            ? 'CodeBuddy (${activeAccount.region.shortBadge} · ${activeAccount.edition.label})'
            : 'CodeBuddy CLI',
      },
      'models': [
        for (final m in CodeBuddyModels.current)
          {
            'value': m.id,
            'displayName': m.label,
            'description': m.description,
            'supportsEffort': m.effortLevels.isNotEmpty,
            'supportedEffortLevels': m.effortLevels,
            'supportsAutoMode': true,
          },
      ],
    };
    return {
      ...origMessage,
      'response': {
        ...resp,
        'response': normalizedPayload,
      },
    };
  }

  /// Reconciles echoed user messages (`--replay-user-messages`) emitted by
  /// `codebuddy` (`isReplay: true`, carrying a newly generated UUIDv7) back to
  /// the client's original `turn.id` UUID, preventing duplicate user bubbles in
  /// `ChatSession` while keeping tool_result and subagent messages untouched.
  Map<String, Object?>? _reconcileUserEcho(Map<String, Object?> decoded) {
    if (decoded['parent_tool_use_id'] != null ||
        decoded['isMeta'] == true ||
        decoded['isSynthetic'] == true ||
        decoded['isCompactSummary'] == true ||
        decoded['isVisibleInTranscriptOnly'] == true) {
      return decoded;
    }

    final body = decoded['message'];
    var hasVisiblePrompt = false;
    if (body is Map) {
      final content = body['content'];
      if (content is List) {
        final hasToolResult = content.any(
          (b) => b is Map && b['type'] == 'tool_result',
        );
        if (hasToolResult) return decoded;
        final visibleTexts = <String>[];
        var hasImage = false;
        for (final b in content) {
          if (b is! Map) continue;
          final bType = b['type'];
          if (bType == 'image') {
            hasImage = true;
          } else if (bType == 'text' && b['text'] is String) {
            final t = (b['text'] as String).trimLeft();
            if (t.isEmpty ||
                t.startsWith('<system-reminder>') ||
                t.startsWith('<local-command-caveat>')) {
              continue;
            }
            visibleTexts.add(t);
          }
        }
        final textJoined = visibleTexts.join('\n');
        if (textJoined.startsWith('<task-notification>') ||
            textJoined.startsWith('[Request interrupted')) {
          return decoded;
        }
        hasVisiblePrompt = visibleTexts.isNotEmpty || hasImage;
      } else if (content is String) {
        final trimmed = content.trimLeft();
        if (trimmed.startsWith('<task-notification>') ||
            trimmed.startsWith('[Request interrupted')) {
          return decoded;
        }
        hasVisiblePrompt =
            trimmed.isNotEmpty &&
            !trimmed.startsWith('<system-reminder>') &&
            !trimmed.startsWith('<local-command-caveat>');
      }
    }

    if (!hasVisiblePrompt) {
      return decoded;
    }

    final cliUuid = decoded['uuid'] as String?;
    if (cliUuid != null && _pendingClientUserUuids.remove(cliUuid)) {
      if (!_closed && !_messages.isClosed) {
        _messages.add({
          'type': 'command_lifecycle',
          'command_uuid': cliUuid,
          'state': 'started',
        });
      }
      return decoded;
    }

    if (_pendingClientUserUuids.isNotEmpty) {
      final clientUuid = _pendingClientUserUuids.removeAt(0);
      if (cliUuid != null && cliUuid.isNotEmpty) {
        _clientToCliUserUuid[clientUuid] = cliUuid;
      }
      if (!_closed && !_messages.isClosed) {
        _messages.add({
          'type': 'command_lifecycle',
          'command_uuid': clientUuid,
          'state': 'started',
        });
      }
      return {...decoded, 'uuid': clientUuid};
    }

    if (decoded['isReplay'] == true) {
      return null;
    }

    return decoded;
  }

  void _observeAssistantUsage(Map<String, Object?> decoded) {
    final msg = decoded['message'];
    if (msg is! Map) return;
    final usage = msg['usage'];
    if (usage is! Map) return;
    final input = (usage['input_tokens'] as num?)?.toInt() ?? 0;
    final cacheRead = (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
    final cacheCreate =
        (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0;
    final output = (usage['output_tokens'] as num?)?.toInt() ?? 0;
    final total = input + cacheRead + cacheCreate + output;
    if (total > 0) {
      _lastContextTokens = total;
    }
  }

  void _observeTurnUsageUpdate(Map<String, Object?> decoded) {
    final meta = decoded['_meta'];
    if (meta is! Map) return;
    final snapshot = meta['codebuddy.ai/turnUsage'];
    if (snapshot is! Map) return;
    final total = snapshot['total'];
    if (total is! Map) return;
    final rawCredits = total['credits'];
    final parsedCredits = switch (rawCredits) {
      final num c => c.toDouble(),
      final String s => double.tryParse(s.trim()),
      _ => null,
    };
    if (parsedCredits != null && parsedCredits > 0) {
      _turnCreditsReported = parsedCredits;
    }
    if (total['usage'] case final Map u) {
      final inp =
          ((u['inputTokens'] ?? u['input_tokens']) as num?)?.toInt() ?? 0;
      final out =
          ((u['outputTokens'] ?? u['output_tokens']) as num?)?.toInt() ?? 0;
      final cr =
          ((u['cacheReadInputTokens'] ?? u['cache_read_input_tokens']) as num?)
              ?.toInt() ??
          0;
      final cc =
          ((u['cacheCreationInputTokens'] ?? u['cache_creation_input_tokens'])
                  as num?)
              ?.toInt() ??
          0;
      _turnTokensReported = inp + out + cr + cc;
      if (_turnTokensReported > 0) {
        _lastContextTokens = _turnTokensReported;
      }
    }
  }

  Map<String, Object?> _onTurnResult(Map<String, Object?> decoded) {
    _turnInFlight = false;
    final isError = decoded['is_error'] == true;
    final resultText = '${decoded['result'] ?? ''}'.toLowerCase();
    final quotaExhausted =
        isError &&
        (resultText.contains('insufficient_quota') ||
            resultText.contains('quota exceeded') ||
            resultText.contains('quota exhausted') ||
            resultText.contains('credit balance is too low') ||
            resultText.contains('余额不足') ||
            resultText.contains('已欠费') ||
            resultText.contains('6005') ||
            resultText.contains('14018'));

    var resultTokens = 0;
    if (decoded['usage'] case final Map u) {
      final inp =
          ((u['input_tokens'] ?? u['inputTokens']) as num?)?.toInt() ?? 0;
      final out =
          ((u['output_tokens'] ?? u['outputTokens']) as num?)?.toInt() ?? 0;
      final cr =
          ((u['cache_read_input_tokens'] ?? u['cacheReadInputTokens']) as num?)
              ?.toInt() ??
          0;
      final cc =
          ((u['cache_creation_input_tokens'] ?? u['cacheCreationInputTokens'])
                  as num?)
              ?.toInt() ??
          0;
      resultTokens = inp + out + cr + cc;
      if (resultTokens > 0 && _turnTokensReported <= 0) {
        _lastContextTokens = resultTokens;
      }
    }
    final tokens = _turnTokensReported > 0 ? _turnTokensReported : resultTokens;
    final turnCredits = _turnCreditsReported;

    unawaited(
      CodeBuddyAccounts.instance.recordTurnUsage(
        credits: turnCredits,
        tokens: tokens,
        quotaExhausted: quotaExhausted,
      ),
    );
    _turnCreditsReported = 0.0;
    _turnTokensReported = 0;

    if (_needsAccountRespawn && !_closed) {
      unawaited(_recycleProcess());
    }

    if (turnCredits > 0) {
      return {...decoded, 'credits': turnCredits};
    }
    return decoded;
  }

  void _onStderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > _maxStderrLines) {
      _stderr.removeAt(0);
    }
  }

  void _onProcessExit(Process proc, int code) {
    for (final entry in _pendingModelFetches.values) {
      entry.fallbackTimer.cancel();
    }
    _pendingModelFetches.clear();
    if (_settingsFilePath case final path?) {
      _settingsFilePath = null;
      unawaited(ClaudeSettingsFile.delete(path));
    }
    unawaited(registry.remove(proc.pid));
    if (_recycling || _process != proc) return;
    _live.remove(this);
    if (!_messages.isClosed) {
      _messages
        ..add(
          ClaudeExit.message(
            code,
            _stderr.join('\n'),
            executable: cli.executable,
          ),
        )
        ..close();
    }
    if (!_exited.isCompleted) {
      _exited.complete();
    }
  }

  /// Normalizes incoming CLI `control_request`s (`can_use_tool` &
  /// `elicitation_create`) to match `ClaudeCodeKernel`'s interaction protocol,
  /// and auto-approves tools the user marked "Always allow" for this session.
  Map<String, Object?>? _normalizeIncomingControlRequest(
    Map<String, Object?> decoded,
  ) {
    final reqId = decoded['request_id'] as String?;
    final req = (decoded['request'] as Map?)?.cast<String, Object?>();
    if (reqId == null || req == null) return decoded;
    final subtype = req['subtype'] as String?;

    if (subtype == 'elicitation_create') {
      return {
        ...decoded,
        'request': {
          ...req,
          'subtype': 'elicitation',
        },
      };
    }

    if (subtype == 'can_use_tool') {
      final toolName = req['tool_name'] as String?;
      final input = (req['input'] as Map?)?.cast<String, Object?>() ?? const {};
      if (toolName != null &&
          toolName != 'AskUserQuestion' &&
          toolName != 'ExitPlanMode' &&
          _sessionApprovedTools.contains(toolName)) {
        _writeRaw({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': reqId,
            'response': {
              'allowed': true,
              'behavior': 'allow',
              'updatedInput': input,
            },
          },
        });
        return null;
      }

      if (toolName != null &&
          toolName != 'AskUserQuestion' &&
          toolName != 'ExitPlanMode' &&
          (req['permission_suggestions'] as List? ?? const []).isEmpty) {
        return {
          ...decoded,
          'request': {
            ...req,
            'permission_suggestions': [
              {
                'type': 'addRules',
                'behavior': 'allow',
                'destination': 'session',
                'rules': [
                  {'toolName': toolName},
                ],
              },
            ],
          },
        };
      }
    }

    return decoded;
  }

  /// Translates `ClaudeCodeKernel`'s `can_use_tool` response (`behavior:
  /// 'allow' | 'deny'`, `message`) into `@tencent-ai/codebuddy-code`'s
  /// `SdkPermissionClient` schema (`allowed: true | false`, `reason`), and
  /// records session-level "Always allow" rules (`updatedPermissions`).
  Map<String, Object?> _translateOutgoingControlResponse(
    Map<String, Object?> message,
  ) {
    final resp = (message['response'] as Map?)?.cast<String, Object?>();
    if (resp == null || resp['subtype'] != 'success') return message;
    final inner = (resp['response'] as Map?)?.cast<String, Object?>();
    if (inner == null) return message;
    final behavior = inner['behavior'] as String?;
    if (behavior == null) return message;

    if (behavior == 'allow') {
      if (inner['updatedPermissions'] case final List perms) {
        for (final entry in perms) {
          if (entry is! Map) continue;
          if (entry['type'] == 'setMode' &&
              entry['mode'] == 'bypassPermissions') {
            _permissionMode = 'bypassPermissions';
          }
          if (entry['rules'] case final List rules) {
            for (final r in rules) {
              if (r is Map && r['toolName'] is String) {
                final name = (r['toolName'] as String).trim();
                if (name.isNotEmpty) _sessionApprovedTools.add(name);
              }
            }
          }
        }
      }
      return {
        ...message,
        'response': {
          ...resp,
          'response': {
            ...inner,
            'allowed': true,
          },
        },
      };
    }

    if (behavior == 'deny') {
      final reason =
          (inner['reason'] as String?) ??
          (inner['message'] as String?) ??
          'Permission denied by user';
      return {
        ...message,
        'response': {
          ...resp,
          'response': {
            ...inner,
            'allowed': false,
            'reason': reason,
          },
        },
      };
    }

    return message;
  }

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    final type = message['type'] as String?;
    if (type == 'control_request') {
      _handleControlRequest(message);
      return;
    }
    if (type == 'control_response') {
      _writeRaw(_translateOutgoingControlResponse(message));
      return;
    }
    if (type == 'user') {
      if (message['uuid'] case final String clientUuid
          when clientUuid.isNotEmpty) {
        _pendingClientUserUuids.add(clientUuid);
      }
      _turnInFlight = true;
      _turnCreditsReported = 0.0;
      _turnTokensReported = 0;
      if (_needsAccountRespawn) {
        unawaited(
          _recycleProcess().then((_) {
            _hasSentTurnOnProcess = true;
            _writeRaw(message);
          }),
        );
        return;
      }
      _hasSentTurnOnProcess = true;
    }
    _writeRaw(message);
  }

  void _handleControlRequest(Map<String, Object?> message) {
    final requestId = message['request_id'] as String?;
    final request = (message['request'] as Map?)?.cast<String, Object?>();
    if (requestId == null || request == null) return;
    final subtype = request['subtype'] as String? ?? '';

    void respondSuccess([Map<String, Object?> payload = const {}]) {
      if (_closed || _messages.isClosed) return;
      _messages.add({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': payload,
        },
      });
    }

    switch (subtype) {
      case 'initialize':
        _lastInitializeRequest = request;
        _initializeRequestIds.add(requestId);
        _writeRaw({
          'type': 'control_request',
          'request_id': requestId,
          'request': {
            'subtype': 'initialize',
            'hasPrompt': true,
            if (request['sdkMcpServers'] != null)
              'sdkMcpServers': request['sdkMcpServers'],
            if (request['capabilities'] != null)
              'capabilities': request['capabilities'],
          },
        });
      case 'set_permission_mode':
        if (request['mode'] case final String mode when mode.isNotEmpty) {
          _permissionMode = mode;
          if (_sessionId case final sid? when sid.isNotEmpty) {
            _pendingPermissionMode = null;
            _writeRaw({
              'type': 'control_request',
              'request_id': requestId,
              'request': {
                'subtype': 'set_permission_mode',
                'session_id': sid,
                'mode': mode,
              },
            });
          } else {
            _pendingPermissionMode = mode;
            respondSuccess({'mode': mode});
          }
          return;
        }
        respondSuccess();
      case 'set_model':
        if (request['model'] case final String rawModel) {
          _model = CodeBuddyModels.cliModelIdOf(rawModel);
          final info = CodeBuddyModels.of(rawModel);
          if (info != null) {
            _maxContextTokens = info.resolveContextWindow(_maxContextTokens);
            if (info.effortLevels.isEmpty) {
              _effort = null;
              _pendingThoughtLevel = null;
            } else if (_effort == null ||
                !info.effortLevels.contains(_effort)) {
              _effort = info.initialEffort;
            }
          }
          _writeRaw({
            'type': 'control_request',
            'request_id': requestId,
            'request': {
              'subtype': 'set_model',
              if (_sessionId != null) 'session_id': _sessionId,
              'model': _model,
            },
          });
          return;
        }
        respondSuccess();
      case 'apply_flag_settings':
        if (request['settings'] case final Map settings) {
          final configUpdates = <String, Object?>{};
          final info = CodeBuddyModels.of(_model);
          final hasSession = _sessionId != null && _sessionId!.isNotEmpty;

          if (settings['effortLevel'] case final String rawEffort
              when rawEffort.isNotEmpty) {
            _effort = rawEffort;
            final thoughtLevel = _toThoughtLevel(rawEffort);
            final disallowedDisable =
                thoughtLevel == 'disabled' && (info?.onlyReasoning ?? false);
            if (!disallowedDisable) {
              if (thoughtLevel == 'disabled') {
                configUpdates['alwaysThinkingEnabled'] = false;
              } else {
                configUpdates['alwaysThinkingEnabled'] = true;
                if (_cliEffortTiers.contains(thoughtLevel)) {
                  configUpdates['reasoningEffort'] = thoughtLevel;
                }
              }
              if (hasSession) {
                configUpdates['thoughtLevel'] = thoughtLevel;
                _pendingThoughtLevel = null;
              } else {
                _pendingThoughtLevel = thoughtLevel;
              }
            }
          }

          if (settings['contextWindow'] case final num tokens
              when tokens.toInt() > 0) {
            _maxContextTokens = tokens.toInt();
            // With CBC_SESSION_CONFIG_SYNC=1, `set_config.contextWindow` is only
            // valid for models advertising >= 2 supported context lengths.
            if (info == null || info.contextOptions.length >= 2) {
              configUpdates['contextWindow'] = _maxContextTokens;
            }
          }

          if (configUpdates.isNotEmpty) {
            _writeRaw({
              'type': 'control_request',
              'request_id': requestId,
              'request': {
                'subtype': 'set_config',
                if (hasSession) 'session_id': _sessionId,
                'config': configUpdates,
              },
            });
            return;
          }
        }
        respondSuccess();
      case 'rewind':
      case 'rewind_conversation':
        final mappedTarget = switch (request['target_message_uuid']) {
          final String id => _clientToCliUserUuid[id] ?? id,
          _ => null,
        };
        _writeRaw({
          ...message,
          'request': {
            ...request,
            'target_message_uuid': ?mappedTarget,
          },
        });
      case 'rewind_files':
        final mappedUserMsg = switch (request['user_message_id']) {
          final String id => _clientToCliUserUuid[id] ?? id,
          _ => null,
        };
        _writeRaw({
          ...message,
          'request': {
            ...request,
            'user_message_id': ?mappedUserMsg,
          },
        });
      case 'interrupt':
      case 'mcp_message':
      case 'reconnect_mcp':
      case 'steer':
        _writeRaw(message);
      case 'get_settings':
        respondSuccess({
          'applied': {
            'model': CodeBuddyModels.bareModelId(_model),
            if (_effort != null) 'effort': _effort,
            'contextWindow': _maxContextTokens,
          },
        });
      case 'get_context_usage':
        respondSuccess({
          'maxTokens': _maxContextTokens,
          'rawMaxTokens': _maxContextTokens,
          'totalTokens': _lastContextTokens,
          'categories': [
            {
              'name': 'Messages & Tools',
              'tokens': _lastContextTokens,
              'color': 'blue',
            },
          ],
        });
      case 'rename_session':
        if (request['title'] case final String title
            when title.trim().isNotEmpty) {
          final trimmed = title.trim();
          if (_sessionId case final sid? when sid.isNotEmpty) {
            _appendCustomTitleToTranscript(sid, trimmed);
          } else {
            _pendingCustomTitle = trimmed;
          }
        }
        respondSuccess();
      case 'cancel_async_message':
        if (request['message_uuid'] case final String u) {
          _pendingClientUserUuids.remove(u);
        }
        respondSuccess(const {'cancelled': true});
      case 'get_usage':
        respondSuccess(const {'rate_limits_available': false});
      default:
        respondSuccess();
    }
  }

  void _appendCustomTitleToTranscript(String sessionId, String title) {
    if (!launch.persist) return;
    try {
      final path =
          _paths.findSession(sessionId) ??
          _paths.sessionFile(launch.cwd, sessionId);
      final file = File(path);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        '${jsonEncode({'type': 'custom-title', 'customTitle': title, 'sessionId': sessionId})}\n',
        mode: FileMode.append,
      );
    } on Object {
      // Best-effort custom title append.
    }
  }

  void _writeRaw(Map<String, Object?> message) {
    final proc = _process;
    if (proc == null || _closed) return;
    try {
      proc.stdin.writeln(jsonEncode(message));
    } on Object {
      // Closed under us; exit event follows.
    }
  }

  Future<void> _stop(Duration timeout) async {
    close();
    try {
      await exited.timeout(timeout);
    } on TimeoutException {
      _process?.kill(ProcessSignal.sigkill);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _live.remove(this);
    for (final entry in _pendingModelFetches.values) {
      entry.fallbackTimer.cancel();
    }
    _pendingModelFetches.clear();
    final proc = _process;
    if (proc == null) {
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    unawaited(proc.stdin.close().catchError((Object _) {}));
    if (Platform.isWindows) {
      unawaited(_endTree(proc));
    } else {
      proc.kill();
    }
  }

  Future<void> _endTree(Process proc) async {
    final ended = await proc.exitCode
        .timeout(const Duration(seconds: 1))
        .then((_) => true, onError: (Object _) => false);
    if (ended) return;
    try {
      await Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
    } on ProcessException {
      proc.kill();
    }
  }
}

class CodeBuddyProcessRegistry extends ChildProcessRegistry {
  CodeBuddyProcessRegistry({
    required super.file,
    super.ownPid,
    super.lookup,
    super.signal,
  }) : super(recognizes: _isCodeBuddy);

  static bool _isCodeBuddy(String command) =>
      (command.contains('codebuddy') || command.contains('cbc')) &&
      command.contains('stream-json');
}
