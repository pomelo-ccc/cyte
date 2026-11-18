import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import 'codebuddy/codebuddy_cli.dart';
import '../remote/remote_claude.dart';

/// The kernels offered in Cyte: Tencent CodeBuddy (`codebuddy` / `cbc`) with
/// fallback to custom API providers configured in Settings → Models.
abstract final class KernelRegistry {
  static final KernelDescriptor codebuddy = KernelDescriptor(
    id: codebuddyBuiltinProviderId,
    label: 'CodeBuddy',
    icon: Icons.hub_rounded,
    description: 'Tencent CodeBuddy coding agent (codebuddy / cbc)',
    create: (context) => ClaudeCodeKernel(
      codebuddy,
      context,
      start: startClaude,
      readHistory: readClaudeHistory,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  static List<KernelDescriptor> _all = [codebuddy];

  static List<KernelDescriptor> get all => _all;

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}
