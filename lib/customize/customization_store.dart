import 'dart:convert';

import 'package:bao_remote/files.dart'
    show IdeFileExistsException, IdeFileNotFoundException;
import 'package:path/path.dart' as p;

import 'customization_disk.dart';
import 'customizations.dart';

/// CodeBuddy CLI (`codebuddy` / `cbc`) customizations on a [CustomizationDisk]:
/// - User global customizations under `~/.codebuddy` (`skills/`, `agents/`,
///   `commands/`, `rules/`, `CODEBUDDY.md`, `AGENTS.md`, `mcp.json`,
///   `settings.json`, `plugins/`).
/// - Workspace project customizations under `<project>/.codebuddy` (and
///   `<project>/CODEBUDDY.md`, `<project>/CODEBUDDY.local.md`,
///   `<project>/.mcp.json`).
class CustomizationStore {
  CustomizationStore({this.configDir, this.homeDir, CustomizationDisk? disk})
    : _disk = disk ?? CustomizationDisk.local;

  /// CodeBuddy's global config folder (`~/.codebuddy` by default).
  final String? configDir;

  /// The user's home directory.
  final String? homeDir;

  final CustomizationDisk? _disk;

  CustomizationDisk get _files =>
      _disk ?? (throw UnsupportedError('No files on the web'));

  p.Context get _paths => _files.paths;

  /// Whether there are files to read and write here (not on the web).
  bool get supported => _disk != null;

  /// Whether the files are this machine's (not a remote host's): shown in
  /// its file manager, opened in its IDE.
  bool get isLocal => _disk?.isLocal ?? true;

  /// How paths are spelled where the files are.
  p.Context get paths => _disk == null ? p.context : _paths;

  Future<String> config() async => configDir ?? await _files.configDir();

  /// Those of [kind], the user's and [project]'s (none of a project's when
  /// null), by scope then name.
  Future<List<Customization>> list(
    CustomizationKind kind, {
    String? project,
  }) async {
    if (!supported) return const [];
    final config = await this.config();
    final dotCodeBuddy = project == null
        ? null
        : _paths.join(project, '.codebuddy');
    final items = switch (kind) {
      CustomizationKind.skills => [
        ...await _skills(
          CustomizationScope.user,
          _paths.join(config, 'skills'),
        ),
        ...await _pluginSkills(config),
        if (dotCodeBuddy != null)
          ...await _skills(
            CustomizationScope.project,
            _paths.join(dotCodeBuddy, 'skills'),
          ),
      ],
      CustomizationKind.subagents => [
        ...await _markdown(
          kind,
          CustomizationScope.user,
          _paths.join(config, 'agents'),
        ),
        if (dotCodeBuddy != null)
          ...await _markdown(
            kind,
            CustomizationScope.project,
            _paths.join(dotCodeBuddy, 'agents'),
          ),
      ],
      CustomizationKind.commands => [
        ...await _markdown(
          kind,
          CustomizationScope.user,
          _paths.join(config, 'commands'),
        ),
        if (dotCodeBuddy != null)
          ...await _markdown(
            kind,
            CustomizationScope.project,
            _paths.join(dotCodeBuddy, 'commands'),
          ),
      ],
      CustomizationKind.rules => await _rules(config, project),
      CustomizationKind.memory => await _memories(config, project),
      CustomizationKind.mcps => await _servers(config, project),
      CustomizationKind.hooks => await _hooks(config, project),
      CustomizationKind.plugins => await _plugins(config, project),
    };
    return [...items]..sort((a, b) {
      final scope = a.scope.index.compareTo(b.scope.index);
      return scope != 0
          ? scope
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// The file of the `/command` [name]: a skill's SKILL.md or a command's
  /// markdown, the user's, [project]'s or a plugin's (`plugin:name`); null
  /// for none (one built in).
  Future<String?> commandFile(String name, {String? project}) async {
    if (!supported) return null;
    final colon = name.indexOf(':');
    if (colon > 0) {
      final fromPlugin = await _pluginCommandFile(
        name.substring(0, colon),
        name.substring(colon + 1),
      );
      if (fromPlugin != null) return fromPlugin;
      for (final command in await list(
        CustomizationKind.commands,
        project: project,
      )) {
        if (command.name == '/$name') return command.path;
      }
      return null;
    }
    for (final skill in await list(
      CustomizationKind.skills,
      project: project,
    )) {
      if (skill.name == name ||
          _paths.basename(_paths.dirname(skill.path)) == name) {
        return skill.path;
      }
    }
    for (final command in await list(
      CustomizationKind.commands,
      project: project,
    )) {
      if (command.name == '/$name') return command.path;
    }
    return null;
  }

  Future<String?> _pluginCommandFile(String plugin, String name) async {
    final config = await this.config();
    final installed = await _json(
      _paths.join(config, 'plugins', 'installed_plugins.json'),
    );
    if (installed?['plugins'] case final Map<String, Object?> plugins) {
      for (final MapEntry(key: id, value: entry) in plugins.entries) {
        final at = id.indexOf('@');
        if ((at < 0 ? id : id.substring(0, at)) != plugin) continue;
        final install = switch (entry) {
          final List<Object?> installs =>
            installs.whereType<Map<String, Object?>>().firstOrNull,
          final Map<String, Object?> install => install,
          _ => null,
        };
        if (install?['installPath'] case final String root) {
          for (final path in [
            _paths.join(root, 'skills', name, 'SKILL.md'),
            _paths.join(root, 'commands', '$name.md'),
          ]) {
            if (await _files.read(path) != null) return path;
          }
        }
      }
    }
    final directRoot = _paths.join(config, 'plugins', plugin);
    for (final path in [
      _paths.join(directRoot, 'skills', name, 'SKILL.md'),
      _paths.join(directRoot, 'commands', '$name.md'),
    ]) {
      if (await _files.read(path) != null) return path;
    }
    return null;
  }

  Future<String> read(String path) async =>
      await _files.read(path) ?? (throw IdeFileNotFoundException(path));

  Future<bool> exists(String path) async =>
      await _files.isDirectory(path) == false;

  Future<void> write(String path, String text) => _files.write(path, text);

  /// Makes a new one of [kind] named [name] from its template: the user's,
  /// or [project]'s. Returns its file; throws an [IdeFileExistsException]
  /// when one by that name is there already.
  Future<String> create(
    CustomizationKind kind,
    CustomizationScope scope,
    String name, {
    String? project,
  }) async {
    if (!kind.creatable || !isCustomizationName(name)) {
      throw ArgumentError.value(name, 'name');
    }
    final base = scope == CustomizationScope.user
        ? await config()
        : _paths.join(project!, '.codebuddy');
    final path = switch (kind) {
      CustomizationKind.skills => _paths.join(base, 'skills', name, 'SKILL.md'),
      CustomizationKind.subagents => _paths.join(base, 'agents', '$name.md'),
      CustomizationKind.commands => _paths.join(base, 'commands', '$name.md'),
      _ => _paths.join(base, 'rules', '$name.md'),
    };
    final taken = kind == CustomizationKind.skills
        ? await _files.isDirectory(_paths.dirname(path)) != null
        : await _files.isDirectory(path) != null;
    if (taken) throw IdeFileExistsException(path);
    await write(path, template(kind, name));
    return path;
  }

  /// The file [kind] is kept in for [scope], to be edited whole:
  /// `mcp.json` / `.mcp.json` for MCPs, `settings.json` for hooks.
  Future<String?> configFile(
    CustomizationKind kind,
    CustomizationScope scope, {
    String? project,
  }) async {
    if (!kind.configuredIn(scope) || !supported) return null;
    final config = await this.config();
    if (kind == CustomizationKind.mcps) {
      return switch (scope) {
        CustomizationScope.user => _paths.join(config, 'mcp.json'),
        CustomizationScope.project when project != null => _paths.join(
          project,
          '.mcp.json',
        ),
        _ => null,
      };
    }
    for (final (own, path) in _settingsFiles(config, project)) {
      if (own == scope) return path;
    }
    return null;
  }

  /// Removes [item]'s file, or its folder (a skill's).
  Future<void> delete(Customization item) async {
    final path = item.removePath;
    if (path == null) return;
    await _files.delete(path);
  }

  // --- Reading ---------------------------------------------------------------

  Future<Map<String, Object?>?> _json(String path) async {
    final text = await _files.read(path);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  static const _pretty = JsonEncoder.withIndent('  ');

  Future<List<String>> _subfolders(String dir) async => [
    for (final child in await _files.children(dir))
      if (child.directory && !_paths.basename(child.path).startsWith('.'))
        child.path,
  ];

  /// Each folder of [root] with a SKILL.md (including synced skill buckets).
  Future<List<Customization>> _skills(
    CustomizationScope scope,
    String root,
  ) async {
    final skills = <Customization>[];
    for (final folder in await _subfolders(root)) {
      if (scope == CustomizationScope.user &&
          _paths.basename(folder) == 'synced') {
        for (final bucket in await _subfolders(folder)) {
          skills.addAll(await _skills(CustomizationScope.synced, bucket));
        }
        continue;
      }
      skills.addAll([?await _skill(scope, folder)]);
    }
    return skills;
  }

  Future<List<Customization>> _pluginSkills(String config) async {
    final skills = <Customization>[];
    final seenRoots = <String>{};
    final installed = await _json(
      _paths.join(config, 'plugins', 'installed_plugins.json'),
    );
    if (installed?['plugins'] case final Map<String, Object?> plugins) {
      for (final entry in plugins.values) {
        final install = switch (entry) {
          final List<Object?> installs =>
            installs.whereType<Map<String, Object?>>().firstOrNull,
          final Map<String, Object?> install => install,
          _ => null,
        };
        if (install?['installPath'] case final String root
            when seenRoots.add(root)) {
          for (final folder in await _subfolders(_paths.join(root, 'skills'))) {
            skills.addAll([?await _skill(CustomizationScope.plugin, folder)]);
          }
        }
      }
    }
    for (final pluginDir in await _subfolders(_paths.join(config, 'plugins'))) {
      if (!seenRoots.add(pluginDir)) continue;
      for (final folder in await _subfolders(
        _paths.join(pluginDir, 'skills'),
      )) {
        skills.addAll([?await _skill(CustomizationScope.plugin, folder)]);
      }
    }
    return skills;
  }

  Future<Customization?> _skill(CustomizationScope scope, String folder) async {
    final path = _paths.join(folder, 'SKILL.md');
    final text = await _files.read(path);
    if (text == null) {
      if (await _files.isDirectory(folder) != null) return null;
      return Customization(
        kind: CustomizationKind.skills,
        scope: scope,
        name: _paths.basename(folder),
        path: path,
        editable: false,
        detail: '',
        removePath: folder,
        unreachable: true,
      );
    }
    final readOnly =
        scope == CustomizationScope.synced ||
        scope == CustomizationScope.plugin;
    return Customization(
      kind: CustomizationKind.skills,
      scope: scope,
      name: switch (parseFrontMatter(text)['name']) {
        final name? when name.isNotEmpty => name,
        _ => _paths.basename(folder),
      },
      description: describeMarkdown(text),
      path: path,
      editable: !readOnly,
      removePath: readOnly ? null : folder,
    );
  }

  static const _deepest = 8;

  Future<List<Customization>> _markdown(
    CustomizationKind kind,
    CustomizationScope scope,
    String root, {
    bool editable = true,
  }) async {
    final found = <Customization>[];
    Future<void> walk(String dir, int depth) async {
      for (final child in await _files.children(dir)) {
        if (child.directory) {
          if (depth < _deepest) await walk(child.path, depth + 1);
        } else if (child.path.endsWith('.md')) {
          if (await _files.read(child.path) case final text?) {
            found.add(
              Customization(
                kind: kind,
                scope: scope,
                name: _markdownName(kind, root, child.path, text),
                description: describeMarkdown(text),
                path: child.path,
                editable: editable,
                removePath: editable ? child.path : null,
              ),
            );
          }
        }
      }
    }

    await walk(root, 0);
    return found;
  }

  String _markdownName(
    CustomizationKind kind,
    String root,
    String path,
    String text,
  ) {
    if (kind == CustomizationKind.commands) {
      final rel = _paths.withoutExtension(_paths.relative(path, from: root));
      final parts = _paths.split(rel);
      return '/${parts.join(':')}';
    }
    return switch (parseFrontMatter(text)['name']) {
      final name? when name.isNotEmpty => name,
      _ => _paths.basenameWithoutExtension(path),
    };
  }

  /// Rules CodeBuddy reads: `CODEBUDDY.md`, `AGENTS.md`, `rules/*.md` globally
  /// (`~/.codebuddy`) and in the workspace (`.codebuddy/rules`, `CODEBUDDY.md`,
  /// `CODEBUDDY.local.md`).
  Future<List<Customization>> _rules(String config, String? project) async {
    Future<Customization?> ruleFile(
      CustomizationScope scope,
      String path,
      String base,
    ) async {
      final text = await _files.read(path);
      if (text == null) return null;
      return Customization(
        kind: CustomizationKind.rules,
        scope: scope,
        name: _paths.relative(path, from: base),
        description: describeMarkdown(text),
        path: path,
        removePath: path,
      );
    }

    Future<List<Customization>> folder(
      CustomizationScope scope,
      String root,
      String base, {
      bool editable = true,
    }) async => [
      for (final rule in await _markdown(
        CustomizationKind.rules,
        scope,
        root,
        editable: editable,
      ))
        Customization(
          kind: rule.kind,
          scope: rule.scope,
          name: _paths.relative(rule.path, from: base),
          description: rule.description,
          path: rule.path,
          editable: editable,
          removePath: rule.removePath,
        ),
    ];

    return [
      ?await ruleFile(
        CustomizationScope.user,
        _paths.join(config, 'CODEBUDDY.md'),
        config,
      ),
      ?await ruleFile(
        CustomizationScope.user,
        _paths.join(config, 'AGENTS.md'),
        config,
      ),
      ...await folder(
        CustomizationScope.user,
        _paths.join(config, 'rules'),
        config,
      ),
      if (project != null) ...[
        ?await ruleFile(
          CustomizationScope.project,
          _paths.join(project, 'CODEBUDDY.md'),
          project,
        ),
        ?await ruleFile(
          CustomizationScope.project,
          _paths.join(project, '.codebuddy', 'CODEBUDDY.md'),
          project,
        ),
        ?await ruleFile(
          CustomizationScope.project,
          _paths.join(project, 'AGENTS.md'),
          project,
        ),
        ?await ruleFile(
          CustomizationScope.local,
          _paths.join(project, 'CODEBUDDY.local.md'),
          project,
        ),
        ...await folder(
          CustomizationScope.project,
          _paths.join(project, '.codebuddy', 'rules'),
          project,
        ),
      ],
    ];
  }

  /// Project memory files stored under `<config>/projects/<project>/memory/`.
  Future<List<Customization>> _memories(String config, String? project) async {
    if (project == null) return const [];
    final folder = _paths.join(
      config,
      'projects',
      claudeProjectDirName(project),
      'memory',
    );
    return [
      for (final child in await _files.children(folder))
        if (!child.directory && child.path.endsWith('.md'))
          if (await _files.read(child.path) case final text?)
            Customization(
              kind: CustomizationKind.memory,
              scope: CustomizationScope.project,
              name: _paths.basename(child.path),
              description: describeMarkdown(text),
              path: child.path,
              removePath: child.path,
            ),
    ];
  }

  /// MCP servers configured in `~/.codebuddy/mcp.json`, inside plugins, or in
  /// `<project>/.codebuddy/mcp.json` and `<project>/.mcp.json`.
  Future<List<Customization>> _servers(String config, String? project) async {
    final disabledShared = <String>{};
    if (project != null) {
      for (final path in [
        _paths.join(project, '.codebuddy', 'settings.json'),
        _paths.join(project, '.codebuddy', 'settings.local.json'),
      ]) {
        if ((await _json(path))?['disabledMcpjsonServers']
            case final List<Object?> list) {
          disabledShared.addAll(list.whereType<String>());
        }
      }
    }

    List<Customization> servers(
      CustomizationScope scope,
      Object? entries,
      String path, {
      required bool editable,
    }) => [
      if (entries is Map<String, Object?>)
        for (final MapEntry(key: name, value: server) in entries.entries)
          Customization(
            kind: CustomizationKind.mcps,
            scope: scope,
            name: name,
            description: _describeServer(server),
            path: path,
            editable: editable,
            detail: _pretty.convert({name: server}),
            server: server is Map<String, Object?> ? server : null,
            enabled:
                (server is Map<String, Object?> &&
                        server['disabled'] == true) ||
                    (scope == CustomizationScope.project &&
                        disabledShared.contains(name))
                ? false
                : null,
          ),
    ];

    final userMcp = _paths.join(config, 'mcp.json');
    final projectFiles = [
      if (project != null) _paths.join(project, '.codebuddy', 'mcp.json'),
      if (project != null) _paths.join(project, '.mcp.json'),
    ];
    final projectMcps = <Customization>[];
    for (final file in projectFiles) {
      final json = await _json(file);
      if (json != null) {
        projectMcps.addAll(
          servers(
            CustomizationScope.project,
            json['mcpServers'],
            file,
            editable: true,
          ),
        );
      }
    }

    return [
      ...servers(
        CustomizationScope.user,
        (await _json(userMcp))?['mcpServers'],
        userMcp,
        editable: true,
      ),
      ...projectMcps,
    ];
  }

  static String _describeServer(Object? server) {
    if (server is! Map<String, Object?>) return '';
    if (server['url'] case final String url) {
      return switch (server['type']) {
        final String type => '$type · $url',
        _ => url,
      };
    }
    return [
      if (server['command'] case final String command) command,
      if (server['args'] case final List<Object?> args)
        for (final arg in args) '$arg',
    ].join(' ');
  }

  List<(CustomizationScope, String)> _settingsFiles(
    String config,
    String? project,
  ) => [
    (CustomizationScope.user, _paths.join(config, 'settings.json')),
    if (project != null) ...[
      (
        CustomizationScope.project,
        _paths.join(project, '.codebuddy', 'settings.json'),
      ),
      (
        CustomizationScope.local,
        _paths.join(project, '.codebuddy', 'settings.local.json'),
      ),
    ],
  ];

  Future<List<Customization>> _hooks(String config, String? project) async => [
    for (final (scope, path) in _settingsFiles(config, project))
      if ((await _json(path))?['hooks'] case final Map<String, Object?> events)
        for (final MapEntry(key: event, value: groups) in events.entries)
          if (groups is List<Object?>)
            for (final group in groups.whereType<Map<String, Object?>>())
              for (final hook
                  in (group['hooks'] as List<Object?>? ?? const [])
                      .whereType<Map<String, Object?>>())
                Customization(
                  kind: CustomizationKind.hooks,
                  scope: scope,
                  name: switch (group['matcher']) {
                    final String matcher when matcher.isNotEmpty =>
                      '$event · $matcher',
                    _ => event,
                  },
                  description: switch (hook['command'] ?? hook['prompt']) {
                    final String command => command,
                    _ => '${hook['type'] ?? ''}',
                  },
                  path: path,
                ),
  ];

  /// Installed CodeBuddy plugins (`plugins/installed_plugins.json` or direct
  /// `plugins/<name>/plugin.json`).
  Future<List<Customization>> _plugins(String config, String? project) async {
    final enabled = <String, bool>{};
    for (final (_, path) in _settingsFiles(config, project)) {
      if ((await _json(path))?['enabledPlugins']
          case final Map<String, Object?> map) {
        for (final MapEntry(:key, :value) in map.entries) {
          if (value is bool) enabled[key] = value;
        }
      }
    }

    final result = <Customization>[];
    final installed = await _json(
      _paths.join(config, 'plugins', 'installed_plugins.json'),
    );
    if (installed?['plugins'] case final Map<String, Object?> plugins) {
      for (final MapEntry(key: id, value: entry) in plugins.entries) {
        final install = switch (entry) {
          final List<Object?> installs =>
            installs.whereType<Map<String, Object?>>().firstOrNull,
          final Map<String, Object?> install => install,
          _ => null,
        };
        if (install != null) {
          result.add(await _plugin(id, install, enabled[id] ?? false));
        }
      }
    }
    return result;
  }

  Future<Customization> _plugin(
    String id,
    Map<String, Object?> install,
    bool enabled,
  ) async {
    final root = install['installPath'] as String?;
    String? manifestPath;
    Map<String, Object?>? manifest;
    if (root != null) {
      for (final candidate in [
        _paths.join(root, '.codebuddy-plugin', 'plugin.json'),
        _paths.join(root, '.claude-plugin', 'plugin.json'),
        _paths.join(root, 'plugin.json'),
      ]) {
        final parsed = await _json(candidate);
        if (parsed != null) {
          manifestPath = candidate;
          manifest = parsed;
          break;
        }
      }
      manifestPath ??= _paths.join(root, '.codebuddy-plugin', 'plugin.json');
    }
    final at = id.indexOf('@');
    return Customization(
      kind: CustomizationKind.plugins,
      scope: CustomizationScope.plugin,
      name: at < 0 ? id : id.substring(0, at),
      description: switch (manifest?['description']) {
        final String description => description,
        _ => [
          if (at >= 0) id.substring(at + 1),
          if (install['version'] case final String version) version,
        ].join(' · '),
      },
      path: manifestPath ?? root ?? id,
      editable: false,
      detail: _pretty.convert({
        id: {...install, 'enabled': enabled},
      }),
      enabled: enabled,
    );
  }
}

/// Dashed directory name for [cwd] under `~/.codebuddy/projects/`.
String claudeProjectDirName(String cwd) {
  final dashed = cwd.replaceAll(RegExp('[^a-zA-Z0-9]'), '-');
  if (dashed.length <= 200) return dashed;
  var hash = 0;
  for (final unit in cwd.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return '${dashed.substring(0, 200)}-${hash.toRadixString(36)}';
}
