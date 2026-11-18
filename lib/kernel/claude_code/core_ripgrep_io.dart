import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show FileIndex;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// Ripgrep lookup helper for Cyte's built-in core.
abstract final class CoreRipgrep {
  /// Ensures `rg` is left as configured on [environment]'s `PATH`.
  static Future<void> addTo(Map<String, String> environment) async {
    if (FileIndex(environment).which('rg', scripts: false) != null) return;
  }

  /// Writes `rg` shims in [dir] pointing at [executable] (used in unit tests).
  @visibleForTesting
  static Future<String> writeShims(
    String dir,
    String executable, {
    bool? windows,
  }) async {
    windows ??= Platform.isWindows;
    await Directory(dir).create(recursive: true);
    final quoted = "'${executable.replaceAll("'", r"'\''")}'";
    final shims = {
      'rg': '#!/bin/sh\nARGV0=rg exec $quoted "\$@"\n',
      if (windows)
        'rg.cmd':
            '@echo off\r\nsetlocal\r\nset "ARGV0=rg"\r\n"$executable" %*\r\n',
    };
    for (final MapEntry(key: name, value: text) in shims.entries) {
      final file = File(p.join(dir, name));
      if (file.existsSync() && file.readAsStringSync() == text) continue;
      await file.writeAsString(text, flush: true);
      if (!windows) await Process.run('chmod', ['755', file.path]);
    }
    return dir;
  }
}
