import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show IdeFileExistsException;
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String config;
  late String project;
  late CustomizationStore store;

  void write(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('customize');
    config = p.join(temp.path, 'home', '.codebuddy');
    project = p.join(temp.path, 'app');
    store = CustomizationStore(
      configDir: config,
      homeDir: p.join(temp.path, 'home'),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('reads front matter, block scalars and quotes included', () {
    const text =
        '---\n'
        'name: "pdf"\n'
        'description: >-\n'
        '  Reads PDFs\n'
        '  and fills forms.\n'
        'tools: Read\n'
        '---\n'
        '\n'
        '# PDF\n';
    expect(parseFrontMatter(text), {
      'name': 'pdf',
      'description': 'Reads PDFs and fills forms.',
      'tools': 'Read',
    });
    expect(describeMarkdown('# Title\n\nFirst line.\n'), 'First line.');
    expect(bodyOf(text), '\n# PDF\n');
  });

  test('finds a /command\'s file: a skill\'s, a command\'s, a plugin\'s', () async {
    final skill = p.join(config, 'skills', 'pdf-tools', 'SKILL.md');
    write(skill, '---\nname: pdf\ndescription: Reads PDFs\n---\n');
    final command = p.join(project, '.codebuddy', 'commands', 'ship.md');
    write(command, 'Ship it.\n');
    final root = p.join(config, 'plugins', 'cache', 'cf');
    final pluginSkill = p.join(root, 'skills', 'wrangler', 'SKILL.md');
    write(pluginSkill, '---\nname: wrangler\n---\n');
    write(
      p.join(config, 'plugins', 'installed_plugins.json'),
      jsonEncode({
        'version': 2,
        'plugins': {
          'cloudflare@market': [
            {'installPath': root},
          ],
        },
      }),
    );
    expect(await store.commandFile('pdf', project: project), skill);
    expect(await store.commandFile('pdf-tools', project: project), skill);
    expect(await store.commandFile('ship', project: project), command);
    expect(await store.commandFile('ship'), isNull);
    expect(await store.commandFile('cloudflare:wrangler'), pluginSkill);
    expect(await store.commandFile('cloudflare:nope'), isNull);
    expect(await store.commandFile('compact', project: project), isNull);
  });

  test('lists the user\'s and the project\'s skills, agents, commands and rules', () async {
    write(
      p.join(config, 'skills', 'pdf', 'SKILL.md'),
      '---\nname: pdf\ndescription: Reads PDFs\n---\n',
    );
    write(p.join(config, 'skills', 'empty', 'notes.txt'), 'no SKILL.md');
    write(
      p.join(config, 'skills', 'synced', 'bucket-1', 'docx', 'SKILL.md'),
      '---\nname: docx\ndescription: Word files\n---\n',
    );
    write(
      p.join(project, '.codebuddy', 'skills', 'deploy', 'SKILL.md'),
      '# Deploy\n\nShips it.\n',
    );
    write(
      p.join(config, 'agents', 'reviewer.md'),
      '---\nname: code-reviewer\ndescription: Reviews diffs\n---\n',
    );
    write(
      p.join(project, '.codebuddy', 'commands', 'git', 'ship.md'),
      '---\ndescription: Commit and push\n---\n',
    );
    write(p.join(config, 'CODEBUDDY.md'), '# Me\n\nBe brief.\n');
    write(p.join(project, 'CODEBUDDY.md'), 'Use Dart.\n');
    write(p.join(project, '.codebuddy', 'rules', 'tests.md'), 'Test it.\n');

    final skills = await store.list(CustomizationKind.skills, project: project);
    expect(
      [for (final s in skills) (s.scope, s.name, s.description)],
      [
        (CustomizationScope.user, 'pdf', 'Reads PDFs'),
        (CustomizationScope.synced, 'docx', 'Word files'),
        (CustomizationScope.project, 'deploy', 'Ships it.'),
      ],
    );

    final agents = await store.list(CustomizationKind.subagents);
    expect(agents.single.name, 'code-reviewer');

    final commands = await store.list(
      CustomizationKind.commands,
      project: project,
    );
    expect(commands.single.name, '/git:ship');
    expect(commands.single.description, 'Commit and push');

    final rules = await store.list(CustomizationKind.rules, project: project);
    expect(
      [for (final r in rules) (r.scope, r.name)],
      [
        (CustomizationScope.user, 'CODEBUDDY.md'),
        (CustomizationScope.project, p.join('.codebuddy', 'rules', 'tests.md')),
        (CustomizationScope.project, 'CODEBUDDY.md'),
      ],
    );
  });

  test('lists MCP servers, hooks and plugins from CodeBuddy JSON files', () async {
    write(
      p.join(config, 'mcp.json'),
      jsonEncode({
        'mcpServers': {
          'github': {'type': 'http', 'url': 'https://example.com/mcp'},
        },
      }),
    );
    write(
      p.join(project, '.mcp.json'),
      jsonEncode({
        'mcpServers': {
          'docs': {'command': 'docs-mcp'},
        },
      }),
    );
    write(
      p.join(config, 'settings.json'),
      jsonEncode({
        'hooks': {
          'PostToolUse': [
            {
              'matcher': 'Edit',
              'hooks': [
                {'type': 'command', 'command': 'dart format .'},
              ],
            },
          ],
        },
        'enabledPlugins': {'review@market': true},
      }),
    );
    final installRoot = p.join(config, 'plugins', 'cache', 'review');
    write(
      p.join(config, 'plugins', 'installed_plugins.json'),
      jsonEncode({
        'version': 2,
        'plugins': {
          'review@market': [
            {'scope': 'user', 'installPath': installRoot, 'version': '1.2.0'},
          ],
        },
      }),
    );
    write(
      p.join(installRoot, '.codebuddy-plugin', 'plugin.json'),
      jsonEncode({'name': 'review', 'description': 'Reviews code'}),
    );

    final servers = await store.list(CustomizationKind.mcps, project: project);
    expect(
      [for (final s in servers) (s.scope, s.name, s.description, s.editable)],
      [
        (
          CustomizationScope.user,
          'github',
          'http · https://example.com/mcp',
          true,
        ),
        (CustomizationScope.project, 'docs', 'docs-mcp', true),
      ],
    );

    final hooks = await store.list(CustomizationKind.hooks);
    expect(hooks.single.name, 'PostToolUse · Edit');

    final plugins = await store.list(CustomizationKind.plugins);
    expect(plugins.single.name, 'review');
    expect(plugins.single.enabled, isTrue);
  });

  test('makes new ones from templates, edits and deletes them', () async {
    final skill = await store.create(
      CustomizationKind.skills,
      CustomizationScope.user,
      'release-notes',
    );
    expect(skill, p.join(config, 'skills', 'release-notes', 'SKILL.md'));
    await expectLater(
      store.create(
        CustomizationKind.skills,
        CustomizationScope.user,
        'release-notes',
      ),
      throwsA(isA<IdeFileExistsException>()),
    );

    final rule = await store.create(
      CustomizationKind.rules,
      CustomizationScope.project,
      'style',
      project: project,
    );
    expect(rule, p.join(project, '.codebuddy', 'rules', 'style.md'));

    await store.delete((await store.list(CustomizationKind.skills)).single);
    expect(await store.list(CustomizationKind.skills), isEmpty);
  });
}
