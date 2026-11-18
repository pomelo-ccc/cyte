import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

void main() {
  test(
    'resuming a session without an explicit session model restores the latest '
    'assistant model from transcript history instead of global fallback',
    () async {
      final prevCore = ClaudeCore.current;
      ClaudeCore.current = () => ClaudeCore.codebuddy;
      addTearDown(() => ClaudeCore.current = prevCore);

      final session = SessionRecord(
        id: 'sess-hunyuan-1',
        title: 'Test Hunyuan Session',
        updatedAt: DateTime(2026, 11, 18),
        cwd: '/tmp/proj',
      );

      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/tmp/proj',
          resume: session,
          settings: const {
            'model': '@codebuddy-cli/glm-5.3',
            'effort@@codebuddy-cli/hy4-preview': 'high',
            'context@@codebuddy-cli/hy4-preview': '512000',
          },
        ),
        start: (_) async => FakeCli(),
        providers: ModelProviders.memory(providers: const []),
        readHistory: (_) async => const [
          {
            'type': 'assistant',
            'uuid': 'cbc-asst-1-0',
            'message': {
              'role': 'assistant',
              'model': 'deepseek-v4-pro',
              'content': [
                {'type': 'text', 'text': 'earlier turn'},
              ],
            },
          },
          {
            'type': 'assistant',
            'uuid': 'cbc-asst-1-1',
            'message': {
              'role': 'assistant',
              'model': 'hy4-preview',
              'content': [
                {'type': 'text', 'text': 'latest turn'},
              ],
            },
          },
        ],
      );
      addTearDown(kernel.dispose);

      await pumpEventQueue();
      expect(kernel.loadingHistory, isFalse);
      expect(kernel.model.selected, '@codebuddy-cli/hy4-preview');
      expect(kernel.effort.selected, 'high');
      expect(kernel.contextSize.selected, '512000');
      expect(kernel.contextWindow, 512000);
    },
  );
}
