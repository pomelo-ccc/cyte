import '../claude_code/claude_code_transport.dart';

Future<ClaudeCodeTransport> startCodeBuddy(ClaudeLaunch launch) =>
    throw UnsupportedError('CodeBuddy CLI is only available on desktop.');

bool isCodeBuddyLaunch(ClaudeLaunch launch) => false;
