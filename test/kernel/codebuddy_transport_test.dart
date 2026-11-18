@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('CodeBuddyModels resolves CN/Global models, efforts, and context windows', () {
    CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn);
    expect(
      CodeBuddyModels.current.map((m) => m.id),
      containsAll(['default-model', 'primary-model', 'hy4-preview', 'glm-5.3', 'deepseek-v4-pro']),
    );
    expect(CodeBuddyModels.isCodeBuddyModel('@codebuddy-cli/hy4-preview'), isTrue);
    expect(CodeBuddyModels.isCodeBuddyModel('hy4-preview'), isTrue);
    expect(CodeBuddyModels.isCodeBuddyModel('@custom/gpt-4o'), isFalse);

    final hy = CodeBuddyModels.of('@codebuddy-cli/hy4-preview')!;
    expect(hy.resolveContextWindow(512000), 512000);
    expect(hy.resolveContextWindow(128000), 256000);

    CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
    addTearDown(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));
    expect(
      CodeBuddyModels.current.map((m) => m.id),
      containsAll(['gpt-6-astra', 'gpt-5.6-sol', 'gemini-3.5-flash']),
    );
  });

  test('CodeBuddyTransport.buildArguments omits unsupported Claude flags and clamps autocompact', () {
    final args = CodeBuddyTransport.buildArguments(
      launch: const ClaudeLaunch(
        cwd: '/tmp/work',
        permissionMode: 'bypassPermissions',
        sdkServers: ['baocode'],
      ),
      model: 'hy4-preview',
      permissionMode: 'bypassPermissions',
      effort: 'high',
      maxContextTokens: 64000,
      resumeSessionId: 'sess-123',
      settingsFilePath: null,
      inlineSettings: const {},
    );

    expect(args, containsAllInOrder(['-p', '--input-format', 'stream-json', '--output-format', 'stream-json']));
    expect(args, contains('-y'));
    expect(args, containsAllInOrder(['--model', 'hy4-preview']));
    expect(args, containsAllInOrder(['--effort', 'high']));
    // 64000 clamped to CodeBuddy CLI's [100000..1000000] range
    expect(args, containsAllInOrder(['--autocompact', '100000']));
    expect(args, containsAllInOrder(['--resume', 'sess-123']));

    // Never pass flags rejected by @tencent-ai/codebuddy-code!
    expect(args, isNot(contains('--permission-prompt-tool')));
    expect(args, isNot(contains('--thinking-display')));
  });

  test('CodeBuddyTransport bridges control requests and usage_update over stream-json', () async {
    final root = await Directory.systemTemp.createTemp('cyte_cbc_transport_');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final cwd = p.join(root.path, 'proj')..also((d) => Directory(d).createSync());
    final seenLog = File(p.join(root.path, 'seen.jsonl'));

    // Fake `codebuddy` script speaking stream-json over stdio
    final fakeCbc = File(p.join(root.path, 'codebuddy'));
    await fakeCbc.writeAsString('''#!/usr/bin/env python3
import json, sys

seen_path = ${jsonEncode(seenLog.path)}
with open(seen_path, "a", encoding="utf-8") as log:
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        log.write(line + "\\n")
        log.flush()
        msg = json.loads(line)
        if msg.get("type") == "control_request":
            req_id = msg["request_id"]
            sub = msg["request"]["subtype"]
            if sub == "initialize":
                sys.stdout.write(json.dumps({
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": req_id,
                        "response": {
                            "commands": [{"name": "review", "description": "Review code"}],
                            "models": []
                        }
                    }
                }) + "\\n")
                sys.stdout.flush()
            elif sub == "set_config":
                sys.stdout.write(json.dumps({
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": req_id,
                        "response": {"ok": True}
                    }
                }) + "\\n")
                sys.stdout.flush()
        elif msg.get("type") == "user":
            sys.stdout.write(json.dumps({
                "type": "system",
                "subtype": "usage_update",
                "_meta": {
                    "codebuddy.ai/turnUsage": {
                        "total": {
                            "credits": 0.42,
                            "usage": {"inputTokens": 3200, "outputTokens": 480}
                        }
                    }
                }
            }) + "\\n")
            sys.stdout.write(json.dumps({
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "result": "Done",
                "duration_ms": 120,
                "usage": {"input_tokens": 3200, "output_tokens": 480}
            }) + "\\n")
            sys.stdout.flush()
''');
    await Process.run('chmod', ['+x', fakeCbc.path]);

    CodeBuddyPathSetting.current = () => fakeCbc.path;
    addTearDown(() => CodeBuddyPathSetting.current = () => null);
    ClaudeEnvironment.use({
      'HOME': root.path,
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin:/opt/homebrew/bin',
      ClaudeEnvironment.dataPathVariable: p.join(root.path, '.codebuddy'),
    });
    addTearDown(() => ClaudeEnvironment.use(null));
    NetworkProxy.instance.follow(
      ValueNotifier(0),
      (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
    );

    final transport = await startCodeBuddy(
      ClaudeLaunch(
        cwd: cwd,
        model: '@codebuddy-cli/hy4-preview',
        effort: 'high',
      ),
    );
    addTearDown(() async {
      transport.close();
      await transport.exited.timeout(const Duration(seconds: 5));
    });

    Future<Map<String, Object?>> nextControlResponse(String reqId) => transport
        .messages
        .firstWhere(
          (m) =>
              m['type'] == 'control_response' &&
              (m['response'] as Map?)?['request_id'] == reqId,
        )
        .timeout(const Duration(seconds: 5));

    // 1. initialize -> enriches models with CodeBuddyModels
    final initFuture = nextControlResponse('req-init');
    transport.write({
      'type': 'control_request',
      'request_id': 'req-init',
      'request': {'subtype': 'initialize'},
    });
    final initResp = await initFuture;
    final models = ((initResp['response'] as Map)['response'] as Map)['models'] as List;
    expect(models, isNotEmpty);

    // 2. apply_flag_settings -> bridged to set_config (thoughtLevel + contextWindow)
    final cfgFuture = nextControlResponse('req-cfg');
    transport.write({
      'type': 'control_request',
      'request_id': 'req-cfg',
      'request': {
        'subtype': 'apply_flag_settings',
        'settings': {'effortLevel': 'high', 'contextWindow': 512000},
      },
    });
    await cfgFuture;
    final seenLines = await seenLog.readAsLines();
    expect(
      seenLines.any((l) => l.contains('"subtype": "set_config"') || l.contains('"subtype":"set_config"')),
      isTrue,
    );

    // 3. user message -> usage_update updates get_context_usage
    final resultFuture = transport.messages
        .firstWhere((m) => m['type'] == 'result')
        .timeout(const Duration(seconds: 5));
    transport.write({
      'type': 'user',
      'uuid': 'u-1',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hello'}
        ],
      },
    });
    await resultFuture;
    final ctxFuture = nextControlResponse('req-ctx');
    transport.write({
      'type': 'control_request',
      'request_id': 'req-ctx',
      'request': {'subtype': 'get_context_usage'},
    });
    final ctxResp = await ctxFuture;
    final ctxPayload = (ctxResp['response'] as Map)['response'] as Map;
    expect(ctxPayload['totalTokens'], 3680);
    expect(ctxPayload['maxTokens'], 512000);
  });
}

extension _Also<T> on T {
  void also(void Function(T) fn) => fn(this);
}
