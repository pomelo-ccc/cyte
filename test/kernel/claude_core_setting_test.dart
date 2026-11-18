@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/dart_core_transport_io.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the core: as picked; unset, CodeBuddy CLI where codebuddy is '
      'installed, else built-in', () {
    ClaudeCore.codebuddyInstalled = () => false;
    expect(ClaudeCore.parse(null), ClaudeCore.builtin);
    expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    expect(ClaudeCore.parse('codebuddy'), ClaudeCore.codebuddy);
    expect(ClaudeCore.parse('nonsense'), ClaudeCore.builtin);
    expect(ClaudeCore.parse(true), ClaudeCore.builtin);

    ClaudeCore.codebuddyInstalled = () => true;
    addTearDown(() => ClaudeCore.codebuddyInstalled = () => false);
    expect(ClaudeCore.parse(null), ClaudeCore.codebuddy);
    expect(ClaudeCore.parse('nonsense'), ClaudeCore.codebuddy);
    expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    expect(ClaudeCore.parse('codebuddy'), ClaudeCore.codebuddy);
  });

  group('what runs a session here', () {
    late Directory root;
    late String cwd;

    setUp(() {
      root = Directory.systemTemp.createTempSync('cyte-core-');
      cwd = p.join(root.resolveSymbolicLinksSync(), 'project');
      Directory(cwd).createSync();
      final fake = File(p.join(root.path, 'codebuddy'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', fake.path]);
      CodeBuddyPathSetting.current = () => fake.path;
      NetworkProxy.instance.follow(
        ValueNotifier(0),
        (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
      );
    });

    tearDown(() {
      CodeBuddyPathSetting.current = () => null;
      ClaudeCore.current = () => ClaudeCore.fallback;
      ClaudeEnvironment.use(null);
      root.deleteSync(recursive: true);
    });

    void environment({String? key}) => ClaudeEnvironment.use({
      'HOME': root.path,
      'PATH': '/usr/bin:/bin',
      ClaudeEnvironment.dataPathVariable: p.join(root.path, 'config'),
      'ANTHROPIC_API_KEY': ?key,
    });

    Future<ClaudeCodeTransport> start({Map<String, String>? env}) async {
      final transport = await startClaude(ClaudeLaunch(cwd: cwd, env: env));
      addTearDown(() async {
        transport.close();
        await transport.exited.timeout(const Duration(seconds: 20));
      });
      return transport;
    }

    test('the built-in core, on a custom provider\'s model', () async {
      environment();
      ClaudeCore.current = () => ClaudeCore.builtin;
      expect(
        await start(env: {'ANTHROPIC_AUTH_TOKEN': 'token'}),
        isA<DartCoreTransport>(),
      );
    });

    test('the built-in core on none: tells user to add a provider or use CodeBuddy CLI', () async {
      environment(key: 'sk-user');
      ClaudeCore.current = () => ClaudeCore.builtin;
      await expectLater(
        startClaude(ClaudeLaunch(cwd: cwd)),
        throwsA(
          isA<ClaudeUnavailable>().having(
            (error) => error.message,
            'message',
            allOf(contains('Settings → Models'), contains('CodeBuddy CLI')),
          ),
        ),
      );
    });

    test('CodeBuddy CLI picked: starts CodeBuddyTransport', () async {
      environment();
      ClaudeCore.current = () => ClaudeCore.codebuddy;
      expect(await start(), isA<CodeBuddyTransport>());
    });
  });
}
