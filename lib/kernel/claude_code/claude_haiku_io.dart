import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';

import '../../chat/chat_models.dart' show ImageAttachment;
import '../../models/launch_environment.dart';
import '../../network/network_proxy_io.dart';
import '../../network/tls.dart';
import '../../usage/usage_ledger.dart';
import '../codebuddy/codebuddy_accounts.dart';
import '../codebuddy/codebuddy_cli.dart';
import 'claude_core_setting.dart';
import 'claude_environment.dart';
import 'claude_haiku.dart';

/// Lightweight one-shot query via `codebuddy -p --no-session-persistence` (e.g.
/// for `总结新标题` auto-titling and auxiliary summaries) or Cyte's built-in core.
Future<String> askClaudeHaiku(
  String system,
  String prompt, {
  Future<void>? cancel,
  String? model,
  Map<String, String>? env,
  List<({String name, ImageAttachment image})> images = const [],
  ClaudeHaikuTools? tools,
  String? session,
}) async {
  void kept(String line) {
    if (env != null || !line.contains('"result"')) return;
    try {
      if (jsonDecode(line) case {'type': 'result'} && final Map result) {
        final call = claudeHaikuCall(
          result.cast<String, Object?>(),
          at: DateTime.now(),
          session: session,
        );
        if (call != null) UsageLedger.current.record(call);
      }
    } on FormatException {
      // Not a message.
    }
  }

  if (images.isNotEmpty) {
    final timer = ClaudeAnswerTimer();
    final clock = Stopwatch()..start();
    final (stderr, code) = await _run(
      system,
      '${claudeHaikuMessage(prompt, images)}\n',
      cancel: cancel,
      model: model,
      env: env,
      stream: true,
      message: true,
      tools: tools,
      onLine: (line) {
        timer.add(line, clock.elapsed);
        kept(line);
      },
    );
    return timer.answer(stderr, code).text;
  }
  final stdout = StringBuffer();
  final (stderr, code) = await _run(
    system,
    prompt,
    cancel: cancel,
    model: model,
    env: env,
    tools: tools,
    stream: false,
    onLine: (line) {
      stdout.writeln(line);
      kept(line);
    },
  );
  return claudeHaikuAnswer(stdout.toString(), stderr, code);
}

Future<ClaudeTimedAnswer> timeClaudeAnswer(
  String system,
  String prompt, {
  Future<void>? cancel,
  String? model,
  Map<String, String>? env,
}) async {
  final timer = ClaudeAnswerTimer();
  final clock = Stopwatch();
  final (stderr, code) = await _run(
    system,
    prompt,
    cancel: cancel,
    model: model,
    env: env,
    stream: true,
    onStart: clock.start,
    onLine: (line) => timer.add(line, clock.elapsed),
  );
  return timer.answer(stderr, code);
}

Future<(String, int)> _run(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String? model,
  required Map<String, String>? env,
  required bool stream,
  required void Function(String line) onLine,
  bool message = false,
  ClaudeHaikuTools? tools,
  void Function()? onStart,
}) async {
  if (env != null || ClaudeCore.current() == ClaudeCore.builtin) {
    return _runBuiltin(
      system,
      prompt,
      cancel: cancel,
      model: model,
      env: env,
      stream: stream,
      message: message,
      tools: tools,
      onLine: onLine,
      onStart: onStart,
    );
  }
  await CodeBuddyAccounts.instance.ensureInitialized();
  var activeAccount = CodeBuddyAccounts.instance.currentAccount;
  if (activeAccount != null) {
    activeAccount = await CodeBuddyAccounts.instance.ensureFreshAccount(
      activeAccount,
    );
  }
  final cli = await LocalCodeBuddy.locate();
  final proxy = await NetworkProxy.instance.environment();
  final certificates = await nodeCertificatesEnvironment(cli.environment);

  var effectivePrompt = prompt;
  if (message) {
    try {
      if (jsonDecode(prompt.trim()) case {
        'message': {'content': final List content},
      }) {
        final texts = [
          for (final item in content)
            if (item case {'type': 'text', 'text': final String t}) t,
        ];
        if (texts.isNotEmpty) effectivePrompt = texts.join('\n\n');
      }
    } on FormatException {
      // Keep prompt as-is.
    }
  }

  final cliModel =
      model != null && model.trim().isNotEmpty && model != 'haiku'
          ? CodeBuddyModels.cliModelIdOf(model)
          : CodeBuddyModels.fastAuxiliaryModel;

  final childEnv = <String, String>{
    ...cli.environment,
    ...proxy,
    ...certificates,
    ...?activeAccount?.processEnvironment(),
  };

  final Process process;
  try {
    process = await Process.start(
      cli.executable,
      [
        '-p',
        '-y',
        '--no-session-persistence',
        '--output-format',
        stream ? 'stream-json' : 'json',
        if (stream) ...['--verbose', '--include-partial-messages'],
        '--model',
        cliModel,
        if (system.trim().isNotEmpty) ...['--system-prompt', system],
        if (tools?.tools case final allowedTools?) ...[
          '--tools',
          allowedTools.join(','),
        ] else ...[
          '--tools',
          '',
        ],
        effectivePrompt,
      ],
      workingDirectory: switch (tools?.directory) {
        final directory? when Directory(directory).existsSync() => directory,
        _ => Directory.systemTemp.path,
      },
      environment: childEnv,
      includeParentEnvironment: Platform.isWindows,
      runInShell: cli.throughShell,
    );
  } on ProcessException catch (error) {
    throw ClaudeHaikuException('CodeBuddy CLI could not start: ${error.message}');
  }

  onStart?.call();
  unawaited(process.stdin.close().catchError((Object _) {}));
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      process.kill();
    }),
  );
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(onLine);
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final code = await process.exitCode.timeout(
    Duration(minutes: tools == null ? 2 : 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw const ClaudeHaikuException('CodeBuddy CLI took too long to answer.');
    },
  );
  if (cancelled) throw const ClaudeHaikuCancelled();
  await stdout;
  return (await stderr, code);
}

Future<(String, int)> _runBuiltin(
  String system,
  String prompt, {
  required Future<void>? cancel,
  required String? model,
  required Map<String, String>? env,
  required bool stream,
  required bool message,
  required ClaudeHaikuTools? tools,
  required void Function(String line) onLine,
  void Function()? onStart,
}) async {
  final base = await ClaudeEnvironment.of();
  final proxy = await NetworkProxy.instance.environment();
  final environment = <String, String>{...base, ...proxy};
  if (env != null) {
    for (final name in ClaudeModelVariables.inherited) {
      environment.remove(name);
    }
  }
  environment.addAll(ClaudeEnvironment.stateDirectory(base));
  final options = EngineOptions(
    cwd: switch (tools?.directory) {
      final directory? when Directory(directory).existsSync() => directory,
      _ => Directory.systemTemp.resolveSymbolicLinksSync(),
    },
    model: model ?? 'haiku',
    permissionMode: 'dontAsk',
    persist: false,
    flagSettings: {
      'env': ?env,
      if (env != null && model != null)
        'availableModels': allowedModels(env, [model]),
      ...?tools?.settings,
    },
    environment: environment,
    systemPrompt: system,
    tools: tools?.tools ?? const [],
    maxTurns: tools?.maxTurns,
    strictMcpConfig: true,
    slashCommands: false,
  );
  final AgentIsolate agent;
  try {
    agent = await AgentIsolate.spawn(options, debugName: 'bao-agent-haiku');
  } on Object catch (error) {
    throw ClaudeHaikuException('The built-in core could not start: $error');
  }
  onStart?.call();
  final ended = Completer<int>();
  final subscription = agent.messages.listen(
    (line) {
      final isResult = line['type'] == 'result';
      if (stream || message || isResult) onLine(jsonEncode(line));
      if (isResult && !ended.isCompleted) {
        ended.complete(line['is_error'] == true ? 1 : 0);
      }
    },
    onDone: () {
      if (!ended.isCompleted) ended.complete(1);
    },
  );
  var cancelled = false;
  unawaited(
    cancel?.then((_) {
      cancelled = true;
      if (!ended.isCompleted) ended.complete(130);
    }),
  );
  agent.write(
    message
        ? (jsonDecode(prompt.trim()) as Map).cast<String, Object?>()
        : {
            'type': 'user',
            'message': {'role': 'user', 'content': prompt},
          },
  );
  try {
    final code = await ended.future.timeout(
      Duration(minutes: tools == null ? 2 : 5),
      onTimeout: () => throw const ClaudeHaikuException(
        'Built-in core took too long to answer.',
      ),
    );
    if (cancelled) throw const ClaudeHaikuCancelled();
    return (agent.errors.join('\n'), code);
  } finally {
    unawaited(subscription.cancel());
    agent.close();
  }
}
