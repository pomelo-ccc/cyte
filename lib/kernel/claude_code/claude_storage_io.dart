import 'package:bao_remote/local.dart';
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../agent_kernel.dart';

/// CodeBuddy's session catalog on this machine (`~/.codebuddy/projects/`).
class ClaudeStorage implements SessionCatalog, MovesSessions {
  const ClaudeStorage({this.configDir, this.tempDir, this.cacheFile});

  final String? configDir;
  final String? tempDir;
  final String? cacheFile;

  ClaudeSessions get _sessions => ClaudeSessions(
    configDir: configDir,
    tempDir: tempDir,
    cacheFile:
        cacheFile ??
        p.join(DataDirectory.current.cacheDir, 'codebuddy-sessions.json'),
  );

  @override
  Future<void> delete(String id) => _sessions.delete(id);

  @override
  Future<int> moveSessions(String from, String to) => _sessions.move(from, to);

  @override
  Future<List<ProjectRecord>> projects() async => [
    for (final project in await _sessions.projects()) projectRecord(project),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final all = await projects();
    return all.where((p) => p.path == cwd).firstOrNull?.sessions ?? const [];
  }

  Future<List<Map<String, Object?>>> goal(String id) => _sessions.goal(id);

  Future<String> fork(
    String id,
    String into, {
    String? before,
    String? title,
  }) => _sessions.fork(id, into, before: before, title: title);

  static Future<List<Map<String, Object?>>> read(SessionRecord session) {
    final path = session.path;
    if (path == null) return Future.value(const []);
    return ClaudeSessions.read(path);
  }

  static Future<ClaudeHistoryPage> readPage(
    SessionRecord session, {
    required int turns,
    String? before,
  }) {
    final path = session.path;
    if (path == null) return Future.value(const ClaudeHistoryPage([]));
    return ClaudeSessions.readPage(path, turns: turns, before: before);
  }

  static ProjectRecord projectRecord(
    ClaudeProjectSummary project, {
    String Function(String path)? location,
  }) => ProjectRecord(
    path: location?.call(project.path) ?? project.path,
    sessions: [
      for (final session in project.sessions)
        SessionRecord(
          id: session.id,
          title: session.title,
          updatedAt: session.updatedAt,
          cwd: location?.call(session.cwd) ?? session.cwd,
          path: session.path,
        ),
    ],
  );
}
