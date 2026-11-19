@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:bao_remote/local.dart' show ClaudeSessions;
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
            # CodeBuddy CLI echoes user message with isReplay: True and its own UUIDv7!
            sys.stdout.write(json.dumps({
                "type": "user",
                "isReplay": True,
                "uuid": "01a1f180-9999-7000-8000-aaaaaaaaaaaa",
                "session_id": "sess-live-001",
                "message": msg.get("message")
            }) + "\\n")
            # Even if a second duplicate replay frame arrives, transport must drop it!
            sys.stdout.write(json.dumps({
                "type": "user",
                "isReplay": True,
                "uuid": "01a1f180-9999-7000-8000-bbbbbbbbbbbb",
                "session_id": "sess-live-001",
                "message": msg.get("message")
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

      // 3. user message -> reconciles echoed UUIDv7 back to `u-1` (no duplicate!),
      // flushes session thoughtLevel, and attaches `credits: 0.42` onto result!
      final receivedUserUuids = <String>[];
      final userSub = transport.messages.listen((m) {
        if (m['type'] == 'user') {
          receivedUserUuids.add('${m['uuid']}');
        }
      });
      addTearDown(userSub.cancel);
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
      expect(receivedUserUuids, ['u-1']);
      expect((resultMsg['credits'] as num?)?.toDouble(), closeTo(0.42, 1e-6));

      final seenLines = await seenLog.readAsLines();
      expect(
        seenLines.any((l) => l.contains('"hasPrompt":true')),
        isTrue,
      );
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

  test(
    'CodeBuddyTransport suppresses --resume startup renderHistory burst and stray isReplay frames',
    () async {
      final root = await Directory.systemTemp.createTemp('cyte_cbc_resume_');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final cwd = p.join(root.path, 'proj')
        ..also((d) => Directory(d).createSync());
      final fakeCbc = File(p.join(root.path, 'codebuddy'));
      await fakeCbc.writeAsString('''#!/usr/bin/env python3
import json, sys

# Simulate codebuddy --resume dumping a 4-turn renderHistory() burst on stdout
sys.stdout.write(json.dumps({
    "type": "system",
    "subtype": "init",
    "uuid": "sess-hist-001",
    "session_id": "sess-hist-001",
    "tools": [],
    "mcp_servers": [],
    "model": "unknown"
}) + "\\n")
for idx, text in enumerate(["试试", "workbuddy是怎么建立号池的", "与workbiuddy相比", "那就是看不出优势呗"]):
    sys.stdout.write(json.dumps({
        "type": "user",
        "uuid": f"01a1f197-000{idx}-7000-8000-00000000000{idx}",
        "session_id": "sess-hist-001",
        "message": {"role": "user", "content": [{"type": "text", "text": text}]}
    }) + "\\n")
    sys.stdout.write(json.dumps({
        "type": "assistant",
        "uuid": f"01a1f198-000{idx}-7000-8000-00000000000{idx}",
        "session_id": "sess-hist-001",
        "message": {
            "id": f"msg-hist-{idx}",
            "role": "assistant",
            "model": "deepseek-v3-2-volc",
            "content": [{"type": "text", "text": f"答复 {idx}"}]
        }
    }) + "\\n")
sys.stdout.write(json.dumps({
    "type": "result",
    "subtype": "success",
    "session_id": "sess-hist-001",
    "is_error": False,
    "result": "History done"
}) + "\\n")
sys.stdout.flush()

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    msg = json.loads(line)
    if msg.get("type") == "control_request":
        req_id = msg["request_id"]
        sub = msg["request"]["subtype"]
        sys.stdout.write(json.dumps({
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": req_id,
                "response": {"rawModels": [], "models": []}
            }
        }) + "\\n")
        sys.stdout.flush()
    elif msg.get("type") == "user":
        sys.stdout.write(json.dumps({
            "type": "user",
            "isReplay": True,
            "uuid": "01a1f199-live-7000-8000-111111111111",
            "session_id": "sess-hist-001",
            "message": msg.get("message")
        }) + "\\n")
        sys.stdout.write(json.dumps({
            "type": "result",
            "subtype": "success",
            "session_id": "sess-hist-001",
            "is_error": False,
            "result": "Live done"
        }) + "\\n")
        # Late stray isReplay AFTER turn result (_currentTurnClientUuid == null)
        sys.stdout.write(json.dumps({
            "type": "user",
            "isReplay": True,
            "uuid": "01a1f199-late-7000-8000-222222222222",
            "session_id": "sess-hist-001",
            "message": msg.get("message")
        }) + "\\n")
        sys.stdout.flush()
''');
      await Process.run('chmod', ['+x', fakeCbc.path]);

      CodeBuddyPathSetting.current = () => fakeCbc.path;
      addTearDown(() => CodeBuddyPathSetting.current = () => null);
      ClaudeEnvironment.use({
        'HOME': root.path,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        ClaudeEnvironment.dataPathVariable: p.join(root.path, '.codebuddy'),
      });
      addTearDown(() => ClaudeEnvironment.use(null));
      NetworkProxy.instance.follow(
        ValueNotifier(0),
        (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
      );

      final received = <Map<String, Object?>>[];
      final transport = await startCodeBuddy(
        ClaudeLaunch(
          cwd: cwd,
          resume: 'sess-hist-001',
          model: '@codebuddy-cli/glm-5.3',
        ),
      );
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited.timeout(const Duration(seconds: 5));
      });

      final initDone = transport.messages
          .firstWhere(
            (m) =>
                m['type'] == 'control_response' &&
                (m['response'] as Map?)?['request_id'] == 'init-resume',
          )
          .timeout(const Duration(seconds: 5));
      transport.write({
        'type': 'control_request',
        'request_id': 'init-resume',
        'request': {'subtype': 'initialize'},
      });
      await initDone;

      // Zero historical user/assistant/result messages leaked during --resume!
      expect(received.where((m) => m['type'] == 'user'), isEmpty);
      expect(received.where((m) => m['type'] == 'assistant'), isEmpty);
      expect(received.where((m) => m['type'] == 'result'), isEmpty);

      // Now send live turn `u-5` -> only `u-5` and its single `result` appear!
      final liveResult = transport.messages
          .firstWhere((m) => m['type'] == 'result')
          .timeout(const Duration(seconds: 5));
      transport.write({
        'type': 'user',
        'uuid': 'u-5',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '第五条消息'},
          ],
        },
      });
      await liveResult;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final userUuids = [
        for (final m in received)
          if (m['type'] == 'user') '${m['uuid']}',
      ];
      expect(userUuids, ['u-5']);
      expect(received.where((m) => m['type'] == 'result').length, 1);
    },
  );

  test(
    'ClaudeSessions scans, pages, replays with credits, and forks CodeBuddy .jsonl sessions',
    () async {
      final root = await Directory.systemTemp.createTemp('cyte_cbc_sessions_');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final projectDir = p.join(root.path, 'my-project')
        ..also((d) => Directory(d).createSync());
      final configDir = p.join(root.path, '.codebuddy');
      final sessionsDir = p.join(configDir, 'projects', 'proj-slug')
        ..also((d) => Directory(d).createSync(recursive: true));
      final jsonlFile = File(p.join(sessionsDir, '01a1f197-test.jsonl'));
      await jsonlFile.writeAsString('${[
        jsonEncode({
          'id': 'u-msg-1',
          'timestamp': 1795054632000,
          'type': 'message',
          'role': 'user',
          'content': [
            {
              'type': 'input_text',
              'text':
                  '<system-reminder>Reply suggestions are on.</system-reminder>\n\n试试',
            },
          ],
        }),
        jsonEncode({
          'timestamp': 1795054632010,
          'type': 'file-history-snapshot',
          'messageId': 'u-msg-1',
          'cwd': projectDir,
        }),
        jsonEncode({
          'id': 'r-msg-1',
          'parentId': 'u-msg-1',
          'timestamp': 1795054634000,
          'type': 'reasoning',
          'providerData': {
            'messageId': 'gen-1',
            'model': 'deepseek-v3-2-volc',
          },
          'content': [
            {'type': 'reasoning_text', 'text': '正在思考...'},
          ],
        }),
        jsonEncode({
          'id': 'fc-1',
          'parentId': 'r-msg-1',
          'timestamp': 1795054634500,
          'type': 'function_call',
          'callId': 'call_1',
          'name': 'Bash',
          'arguments': jsonEncode({'command': 'echo ok'}),
          'providerData': {
            'messageId': 'gen-1',
            'model': 'deepseek-v3-2-volc',
            'rawUsage': {'credit': 1.25},
            'usage': {'inputTokens': 2000, 'outputTokens': 100},
          },
        }),
        jsonEncode({
          'id': 'fcr-1',
          'parentId': 'fc-1',
          'timestamp': 1795054635000,
          'type': 'function_call_result',
          'callId': 'call_1',
          'name': 'Bash',
          'status': 'completed',
          'output': {'type': 'text', 'text': 'ok\n'},
        }),
        jsonEncode({
          'id': 'a-msg-1',
          'parentId': 'fcr-1',
          'timestamp': 1795054636000,
          'type': 'message',
          'role': 'assistant',
          'providerData': {
            'messageId': 'gen-2',
            'model': 'deepseek-v3-2-volc',
            'rawUsage': {'credit': 0.50},
            'usage': {
              'inputTokens': 2200,
              'outputTokens': 150,
              'inputTokensDetails': [
                {'cached_tokens': 2000},
              ],
            },
          },
          'content': [
            {'type': 'output_text', 'text': '收到，一切正常。'},
          ],
        }),
        jsonEncode({
          'type': 'custom-title',
          'customTitle': '试运行',
          'sessionId': '01a1f197-test',
        }),
      ].join('\n')}\n');

      final store = ClaudeSessions(
        configDir: configDir,
        cacheFile: p.join(root.path, 'cache.json'),
      );
      final projects = await store.projects();
      expect(projects, hasLength(1));
      expect(projects.first.path, projectDir);
      expect(projects.first.sessions, hasLength(1));
      expect(projects.first.sessions.first.id, '01a1f197-test');
      expect(projects.first.sessions.first.title, '试运行');

      final page = await ClaudeSessions.readPage(jsonlFile.path, turns: 10);
      var seq = 0;
      final transcript = Transcript();
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..replaying = true;
      for (final entry in page.entries) {
        translator.translate(entry);
      }
      translator.endReplay();

      final items = [for (final (_, item) in transcript.liveItems) item];
      final userItems = items.whereType<UserMessageItem>().toList();
      expect(userItems, hasLength(1));
      expect(userItems.single.text, '试试');
      expect(userItems.single.usage?.credits, closeTo(1.75, 1e-6));
      expect(
        items.whereType<AssistantTextItem>().single.text,
        '收到，一切正常。',
      );

      final forkedPath = await store.fork(
        '01a1f197-test',
        '01a1f197-forked',
        title: '分支会话',
      );
      expect(File(forkedPath).existsSync(), isTrue);
      final afterFork = await store.projects();
      expect(afterFork.first.sessions.map((s) => s.id), contains('01a1f197-forked'));
    },
  );
}

extension _Also<T> on T {
  void also(void Function(T) fn) => fn(this);
}
