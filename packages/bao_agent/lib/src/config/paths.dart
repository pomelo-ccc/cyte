import 'dart:io';

import 'package:path/path.dart' as p;

/// Where CodeBuddy CLI (`codebuddy` / `cbc`) keeps sessions, plans, settings,
/// MCP configuration, and memory (`~/.codebuddy` unless overridden by
/// `CODEBUDDY_CONFIG_DIR` or `CYTE_SESSION_DATA_PATH`).
class AgentPaths {
  AgentPaths({
    required this.home,
    required this.configDir,
    String? tempDir,
    this._uid,
  }) : tempDir =
           tempDir ?? (Platform.isWindows ? Directory.systemTemp.path : '/tmp');

  /// From [environment]: `CODEBUDDY_CONFIG_DIR`, `CYTE_SESSION_DATA_PATH`,
  /// else `~/.codebuddy`.
  factory AgentPaths.from(
    Map<String, String> environment, {
    String? configDir,
    String? tempDir,
  }) {
    final home = homeOf(environment);
    final config =
        configDir ??
        [
          environment['CODEBUDDY_CONFIG_DIR'],
          environment['CYTE_SESSION_DATA_PATH'],
        ].whereType<String>().where((dir) => dir.isNotEmpty).firstOrNull ??
        p.join(home, '.codebuddy');
    return AgentPaths(home: home, configDir: config, tempDir: tempDir);
  }

  static String homeOf(Map<String, String> environment) {
    for (final name
        in Platform.isWindows
            ? const ['USERPROFILE', 'HOME']
            : const ['HOME', 'USERPROFILE']) {
      if (environment[name] case final dir? when dir.isNotEmpty) return dir;
    }
    return Platform.environment['HOME'] ?? Directory.current.path;
  }

  final String home;
  final String configDir;
  final String tempDir;
  final String? _uid;

  /// `~/.codebuddy/mcp.json`: the user's MCP servers.
  String get claudeJson => p.join(configDir, 'mcp.json');

  String get userSettings => p.join(configDir, 'settings.json');

  String get userMemory => p.join(configDir, 'CODEBUDDY.md');

  String get projectsDir => p.join(configDir, 'projects');

  String get pluginsDir => p.join(configDir, 'plugins');

  String get defaultPlansDir => p.join(configDir, 'plans');

  String fileHistoryDir(String sessionId) =>
      p.join(configDir, 'file-history', sessionId);

  String projectDir(String cwd) => p.join(projectsDir, projectDirName(cwd));

  static String projectDirName(String cwd) {
    final dashed = cwd.replaceAll(RegExp('[^a-zA-Z0-9]'), '-');
    if (dashed.length <= 200) return dashed;
    var hash = 0;
    for (final unit in cwd.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return '${dashed.substring(0, 200)}-${hash.toRadixString(36)}';
  }

  String sessionFile(String cwd, String sessionId) =>
      p.join(projectDir(cwd), '$sessionId.jsonl');

  String? findSession(String sessionId) {
    final projects = Directory(projectsDir);
    if (!projects.existsSync()) return null;
    for (final project in projects.listSync().whereType<Directory>()) {
      final file = File(p.join(project.path, '$sessionId.jsonl'));
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  String tasksDir(String cwd, String sessionId) => p.join(
    tempDir,
    Platform.isWindows ? 'cyte' : 'cyte-${uid()}',
    projectDirName(cwd),
    sessionId,
    'tasks',
  );

  String? _resolvedUid;

  String uid() {
    if (_uid != null) return _uid;
    if (_resolvedUid != null) return _resolvedUid!;
    try {
      final result = Process.runSync('id', ['-u']);
      _resolvedUid = '${result.stdout}'.trim();
    } on Object {
      _resolvedUid = '';
    }
    if (_resolvedUid!.isEmpty) _resolvedUid = '0';
    return _resolvedUid!;
  }

  static String get managedDir {
    if (Platform.isMacOS) return '/Library/Application Support/Cyte';
    if (Platform.isWindows) return r'C:\Program Files\Cyte';
    return '/etc/cyte';
  }

  String expandHome(String path) {
    if (path == '~') return home;
    if (path.startsWith('~/') || path.startsWith(r'~\')) {
      return p.join(home, path.substring(2));
    }
    return path;
  }
}
