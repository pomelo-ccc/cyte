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
  test(
    'CodeBuddyModels matches WorkBuddy thinking effort labels and capability rules',
    () {
      CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn);
      expect(
        CodeBuddyModels.current.map((m) => m.id),
        containsAll([
          'default-model',
          'hy4std',
          'hy4flash-free',
          'hy4flash',
          'glm-5.3',
          'space-bunny',
          'glm-5.2',
        ]),
      );
      expect(codebuddyEffortLabel('low'), '低');
      expect(codebuddyEffortLabel('medium'), '中');
      expect(codebuddyEffortLabel('high'), '高');
      expect(codebuddyEffortLabel('xhigh'), '超高');
      expect(codebuddyEffortLabel('max'), '极致');
      expect(codebuddyEffortLabel('none'), '关闭');

      // GLM-5.2 has onlyReasoning: true and no supportedEfforts -> non-configurable!
      final glm52 = CodeBuddyModels.of('glm-5.2')!;
      expect(glm52.isReasoningConfigurable, isFalse);
      expect(glm52.effortLevels, isEmpty);

      // GLM-5.3 has onlyReasoning: true and supportedEfforts: ['low', 'high', 'max'], default 'max'
      final glm53 = CodeBuddyModels.of('glm-5.3')!;
      expect(glm53.isReasoningConfigurable, isTrue);
      expect(glm53.canToggleThinking, isFalse);
      expect(glm53.effortLevels, ['low', 'high', 'max']);
      expect(glm53.initialEffort, 'max');

      // Space-Bunny supports all 5 WorkBuddy intensities
      final bunny = CodeBuddyModels.of('space-bunny')!;
      expect(bunny.effortLevels, ['low', 'medium', 'high', 'xhigh', 'max']);

      // Toggleable model (`onlyReasoning: false`) includes `'none'` to disable thinking
      final toggleable = CodeBuddyModel.fromRawJson({
        'id': 'custom-toggle',
        'name': 'Toggle Model',
        'credits': 'x0.25 credits',
        'maxInputTokens': 200000,
        'supportsReasoning': true,
        'onlyReasoning': false,
        'reasoning': {
          'canDisableThinking': true,
          'defaultEffort': 'high',
          'supportedEfforts': ['low', 'high', 'max'],
        },
      });
      expect(toggleable.canToggleThinking, isTrue);
      expect(toggleable.creditsRate, '0.25x');
      expect(toggleable.effortLevels, ['none', 'low', 'high', 'max']);

      CodeBuddyModels.syncForRegion(CodeBuddyRegion.global);
      addTearDown(() => CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn));
      expect(
        CodeBuddyModels.current.map((m) => m.id),
        containsAll(['gpt-6-astra', 'gpt-5.6-sol', 'gemini-3.5-flash']),
      );
    },
  );

  test(
    'CodeBuddyTransport.buildArguments omits unsupported Claude flags and clamps autocompact',
    () {
      final args = CodeBuddyTransport.buildArguments(
        launch: const ClaudeLaunch(
          cwd: '/tmp/work',
          permissionMode: 'bypassPermissions',
          sdkServers: ['baocode'],
        ),
        model: 'glm-5.3',
        permissionMode: 'bypassPermissions',
        effort: 'max',
        maxContextTokens: 64000,
        resumeSessionId: 'sess-123',
        settingsFilePath: null,
        inlineSettings: const {},
      );

      expect(
        args,
        containsAllInOrder([
          '-p',
          '--input-format',
          'stream-json',
          '--output-format',
          'stream-json',
        ]),
      );
      expect(args, contains('-y'));
      expect(args, containsAllInOrder(['--model', 'glm-5.3']));
      expect(args, containsAllInOrder(['--effort', 'max']));
      expect(args, containsAllInOrder(['--autocompact', '100000']));
      expect(args, containsAllInOrder(['--resume', 'sess-123']));

      // When thinking is disabled ('none'), do not pass invalid `--effort none`
      final disabledArgs = CodeBuddyTransport.buildArguments(
        launch: const ClaudeLaunch(cwd: '/tmp/work'),
        model: 'gemini-3.5-flash',
        permissionMode: 'default',
        effort: 'none',
        maxContextTokens: 200000,
        resumeSessionId: null,
        settingsFilePath: null,
        inlineSettings: const {},
      );
      expect(disabledArgs, isNot(contains('--effort')));

      // Never pass flags rejected by @tencent-ai/codebuddy-code!
      expect(args, isNot(contains('--permission-prompt-tool')));
      expect(args, isNot(contains('--thinking-display')));
    },
  );

  test(
    'CodeBuddyTransport syncs get_available_models.rawModels, CBC_SESSION_CONFIG_SYNC, thoughtLevel, and per-turn credits',
    () async {
      final root = await Directory.systemTemp.createTemp('cyte_cbc_transport_');
      addTearDown(() async {
        CodeBuddyModels.syncForRegion(CodeBuddyRegion.cn);
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final cwd = p.join(root.path, 'proj')
        ..also((d) => Directory(d).createSync());
      final seenLog = File(p.join(root.path, 'seen.jsonl'));
      final envLog = File(p.join(root.path, 'env.json'));

      // Fake `codebuddy` script speaking stream-json over stdio
      final fakeCbc = File(p.join(root.path, 'codebuddy'));
      await fakeCbc.writeAsString('''#!/usr/bin/env python3
import json, os, sys

with open(${jsonEncode(envLog.path)}, "w", encoding="utf-8") as ef:
    json.dump({"CBC_SESSION_CONFIG_SYNC": os.environ.get("CBC_SESSION_CONFIG_SYNC")}, ef)

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
            elif sub == "get_available_models":
                sys.stdout.write(json.dumps({
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": req_id,
                        "response": {
                            "rawModels": [
                                {
                                    "id": "glm-5.3",
                                    "name": "GLM-5.3",
                                    "credits": "x0.69 credits",
                                    "maxInputTokens": 1000000,
                                    "supportsReasoning": True,
                                    "onlyReasoning": True,
                                    "reasoning": {
                                        "canDisableThinking": False,
                                        "defaultEffort": "max",
                                        "supportedEfforts": ["low", "high", "max"]
                                    },
                                    "contextWindow": {
                                        "defaultLength": 1000000,
                                        "supportedLengths": [256000, 512000, 1000000]
                                    }
                                }
                            ]
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
                "subtype": "init",
                "session_id": "sess-live-001"
            }) + "\\n")
            sys.stdout.write(json.dumps({
                "type": "system",
                "subtype": "usage_update",
                "session_id": "sess-live-001",
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
                "session_id": "sess-live-001",
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
          model: '@codebuddy-cli/glm-5.3',
          effort: 'max',
        ),
      );
      addTearDown(() async {
        transport.close();
        await transport.exited.timeout(const Duration(seconds: 5));
      });

      Future<Map<String, Object?>> nextControlResponse(String reqId) =>
          transport.messages
              .firstWhere(
                (m) =>
                    m['type'] == 'control_response' &&
                    (m['response'] as Map?)?['request_id'] == reqId,
              )
              .timeout(const Duration(seconds: 5));

      // 1. initialize -> queries get_available_models and populates rawModels
      final initFuture = nextControlResponse('req-init');
      transport.write({
        'type': 'control_request',
        'request_id': 'req-init',
        'request': {'subtype': 'initialize'},
      });
      final initResp = await initFuture;
      final models =
          ((initResp['response'] as Map)['response'] as Map)['models'] as List;
      expect(models, isNotEmpty);
      final envMap = jsonDecode(await envLog.readAsString()) as Map;
      expect(envMap['CBC_SESSION_CONFIG_SYNC'], '1');

      // 2. apply_flag_settings before session_id -> sets reasoningEffort + queues thoughtLevel
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

      // 3. user message -> flushes session thoughtLevel + attaches `credits: 0.42` onto result!
      final resultFuture = transport.messages
          .firstWhere((m) => m['type'] == 'result')
          .timeout(const Duration(seconds: 5));
      transport.write({
        'type': 'user',
        'uuid': 'u-1',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
        },
      });
      final resultMsg = await resultFuture;
      expect((resultMsg['credits'] as num?)?.toDouble(), closeTo(0.42, 1e-6));

      final seenLines = await seenLog.readAsLines();
      expect(
        seenLines.any((l) => l.contains('"thoughtLevel"') && l.contains('"high"')),
        isTrue,
      );

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
    },
  );
}

extension _Also<T> on T {
  void also(void Function(T) fn) => fn(this);
}
