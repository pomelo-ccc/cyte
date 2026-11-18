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
    return info.defaultEffort;
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
  String? _effort;
  int _maxContextTokens;
  int _lastContextTokens = 0;
  double _turnCreditsReported = 0.0;
  int _turnTokensReported = 0;
  bool _turnInFlight = false;
  bool _needsAccountRespawn = false;
  bool _closed = false;
  bool _recycling = false;
  String? _pendingCustomTitle;

  final List<String> _stderr = [];
  static const int _maxStderrLines = 30;
  final Set<String> _initializeRequestIds = {};

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

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
      if (effort != null && effort.isNotEmpty) ...['--effort', effort],
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
      if (activeAccount != null &&
          (activeAccount.region == CodeBuddyRegion.cloudhosted ||
              activeAccount.region == CodeBuddyRegion.selfhosted))
        'endpoint': activeAccount.endpoint,
    };
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
          ...accountEnv,
          ...ClaudeEnvironment.stateDirectory(cli.environment),
        },
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      );
      _process = proc;
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
      }
    } finally {
      _recycling = false;
    }
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
      _sessionId = sid;
      if (_pendingCustomTitle case final title?) {
        _pendingCustomTitle = null;
        _appendCustomTitleToTranscript(sid, title);
      }
    }

    final type = decoded['type'] as String?;
    if (type == 'control_response') {
      decoded = _normalizeControlResponse(decoded);
    } else if (type == 'assistant') {
      _observeAssistantUsage(decoded);
    } else if (type == 'system' && decoded['subtype'] == 'usage_update') {
      _observeTurnUsageUpdate(decoded);
    } else if (type == 'result') {
      _onTurnResult(decoded);
    }

    if (!_closed && !_messages.isClosed) {
      _messages.add(decoded);
    }
  }

  Map<String, Object?> _normalizeControlResponse(
    Map<String, Object?> message,
  ) {
    final resp = (message['response'] as Map?)?.cast<String, Object?>();
    if (resp == null) return message;
    final reqId = resp['request_id'] as String?;
    if (reqId == null || !_initializeRequestIds.remove(reqId)) {
      return message;
    }
    if (resp['subtype'] != 'success') return message;

    final payload =
        (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
    if (payload['models'] case final List rawModels) {
      final maps = [
        for (final m in rawModels)
          if (m is Map) m.cast<String, Object?>(),
      ];
      CodeBuddyModels.updateFromCliModels(maps);
    }

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
      ...message,
      'response': {
        ...resp,
        'response': normalizedPayload,
      },
    };
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
    if (total['credits'] case final num c when c.toDouble() > 0) {
      _turnCreditsReported = c.toDouble();
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
      final cc = ((u['cacheCreationInputTokens'] ??
                  u['cache_creation_input_tokens']) as num?)
              ?.toInt() ??
          0;
      _turnTokensReported = inp + out + cr + cc;
      if (_turnTokensReported > 0) {
        _lastContextTokens = _turnTokensReported;
      }
    }
  }

  void _onTurnResult(Map<String, Object?> decoded) {
    _turnInFlight = false;
    final isError = decoded['is_error'] == true;
    final resultText = '${decoded['result'] ?? ''}'.toLowerCase();
    final quotaExhausted = isError &&
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
      final cc = ((u['cache_creation_input_tokens'] ??
                  u['cacheCreationInputTokens']) as num?)
              ?.toInt() ??
          0;
      resultTokens = inp + out + cr + cc;
      if (resultTokens > 0 && _turnTokensReported <= 0) {
        _lastContextTokens = resultTokens;
      }
    }
    final tokens = _turnTokensReported > 0 ? _turnTokensReported : resultTokens;

    unawaited(
      CodeBuddyAccounts.instance.recordTurnUsage(
        credits: _turnCreditsReported,
        tokens: tokens,
        quotaExhausted: quotaExhausted,
      ),
    );
    _turnCreditsReported = 0.0;
    _turnTokensReported = 0;

    if (_needsAccountRespawn && !_closed) {
      unawaited(_recycleProcess());
    }
  }

  void _onStderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > _maxStderrLines) {
      _stderr.removeAt(0);
    }
  }

  void _onProcessExit(Process proc, int code) {
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

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    final type = message['type'] as String?;
    if (type == 'control_request') {
      _handleControlRequest(message);
      return;
    }
    if (type == 'user') {
      _turnInFlight = true;
      _turnCreditsReported = 0.0;
      _turnTokensReported = 0;
      if (_needsAccountRespawn) {
        unawaited(
          _recycleProcess().then((_) => _writeRaw(message)),
        );
        return;
      }
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
        _initializeRequestIds.add(requestId);
        _writeRaw({
          'type': 'control_request',
          'request_id': requestId,
          'request': {
            'subtype': 'initialize',
            if (request['sdkMcpServers'] != null)
              'sdkMcpServers': request['sdkMcpServers'],
            if (request['capabilities'] != null)
              'capabilities': request['capabilities'],
          },
        });
      case 'set_permission_mode':
        if (request['mode'] case final String mode) {
          _permissionMode = mode;
        }
        _writeRaw(message);
      case 'set_model':
        if (request['model'] case final String rawModel) {
          _model = CodeBuddyModels.cliModelIdOf(rawModel);
          final info = CodeBuddyModels.of(rawModel);
          if (info != null) {
            _maxContextTokens = info.resolveContextWindow(_maxContextTokens);
            if (info.effortLevels.isEmpty) {
              _effort = null;
            } else if (_effort == null ||
                !info.effortLevels.contains(_effort)) {
              _effort = info.defaultEffort;
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
          if (settings['effortLevel'] case final String effort) {
            _effort = effort;
            configUpdates['thoughtLevel'] = effort;
          }
          if (settings['contextWindow'] case final num tokens
              when tokens.toInt() > 0) {
            _maxContextTokens = tokens.toInt();
            configUpdates['contextWindow'] = _maxContextTokens;
          }
          if (configUpdates.isNotEmpty) {
            _writeRaw({
              'type': 'control_request',
              'request_id': requestId,
              'request': {
                'subtype': 'set_config',
                if (_sessionId != null) 'session_id': _sessionId,
                'config': configUpdates,
              },
            });
            return;
          }
        }
        respondSuccess();
      case 'interrupt':
      case 'rewind':
      case 'rewind_files':
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
