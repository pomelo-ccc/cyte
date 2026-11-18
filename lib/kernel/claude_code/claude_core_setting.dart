import 'package:flutter/foundation.dart';

/// Settings → General → CodeBuddy CLI: what runs an agent session
/// (`cyte.core` in settings.json).
enum ClaudeCore {
  /// Tencent CodeBuddy CLI (`codebuddy` / `cbc`), run as a persistent local
  /// stream-json process using the active CodeBuddy account or local CLI setup.
  codebuddy,

  /// Cyte's built-in core, written in Dart (`package:bao_agent`): runs on
  /// custom API upstreams configured in Settings → Models.
  builtin;

  static const settingKey = 'cyte.core';

  /// Defaults to CodeBuddy CLI where `codebuddy` / `cbc` is installed on this
  /// machine, else the built-in core.
  static ClaudeCore get fallback => codebuddyInstalled() ? codebuddy : builtin;

  /// Whether CodeBuddy CLI (`codebuddy` / `cbc`) is on this machine; `main()`
  /// points it at `LocalCodeBuddy.installed`.
  static bool Function() codebuddyInstalled = () => false;

  static ClaudeCore parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now, read as each session starts; `main()` points
  /// it at settings.json.
  static ClaudeCore Function() current = () => fallback;

  /// Told as the setting may have changed; `main()` points it at
  /// settings.json.
  static Listenable changes = const _Never();

  /// Why [builtin] has nothing to run on: no upstream turned on.
  static const noModel =
      'No model to run on: Cyte\'s built-in core runs on the custom API '
      'providers of Settings → Models. Add one there, or switch the core to '
      'CodeBuddy CLI (codebuddy / cbc) in Settings → General.';
}

class _Never implements Listenable {
  const _Never();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
