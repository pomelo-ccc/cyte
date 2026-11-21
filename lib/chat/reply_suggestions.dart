/// What the agent suggests the user send next, written by itself at the
/// end of its reply, each in a [tag]: no request of its own. Shown over the
/// composer, apart from what it said (see [AssistantTextItem.text]), while
/// the user has them on (`chat.promptSuggestions`, [PromptSuggestions]).
abstract final class ReplySuggestions {
  static const tag = 'reply_suggestion';

  /// The most shown.
  static const max = 3;

  /// The longest shown, in characters: a line to send, not a message.
  static const maxLength = 80;

  /// What the agent is told, with the user's message, when they turn them
  /// on (or with the first message, on).
  static const on =
      '<system-reminder>Reply suggestions are on: the user turned them on '
      'in Cyte. When you finish your turn and hand back to them, end your '
      'last message with two or three things they might send you next, each '
      'in its own <$tag>…</$tag> on a line of its own (plain <$tag>…</$tag> '
      'tags only, never <parameter>), after all else: in '
      'their voice and their language, short (about 20 Chinese characters, '
      'or 10 words, at most), each a different way on (go ahead, change '
      'course, ask). They pick one to edit and send. The app shows them apart '
      'from your message: do not speak of them. None while you are still '
      'working.</system-reminder>';

  /// With each message after, a word.
  static const stillOn =
      '<system-reminder>Reply suggestions still on: end your turn with two '
      'or three short <$tag>…</$tag> lines (never <parameter>).</system-reminder>';

  /// Once, when they turn them off.
  static const off =
      '<system-reminder>Reply suggestions are off: the user turned them off '
      'in Cyte. Write no more <$tag>.</system-reminder>';

  /// What to tell the agent with a message, suggestions [wanted] or not:
  /// [told], what it was last told this run (none yet); [suggested],
  /// whether its last reply has suggestions (told before this run).
  static List<String> notes({
    required bool wanted,
    required bool? told,
    required bool suggested,
  }) => switch ((wanted, told)) {
    (true, true) => const [stillOn],
    (true, _) => const [on],
    (false, true) => const [off],
    (false, null) when suggested => const [off],
    _ => const [],
  };

  /// [text] without the suggestions at its end, and without one still
  /// being written there (streaming): what the agent said. Only at the
  /// end: one spoken of in the middle of the text, or in code, stays.
  static String strip(String text) => switch (_tailAt(text)) {
    final at? => text.substring(0, at),
    null => text,
  };

  /// The suggestions at the end of [text], each whole; at most [max], none
  /// too long.
  static List<String> of(String text) {
    final at = _tailAt(text);
    if (at == null) return const [];
    return [
      for (final match in _whole.allMatches(text, at))
        if (match[1]!.trim() case final said
            when said.isNotEmpty && said.length <= maxLength)
          said,
    ].take(max).toList();
  }

  /// [text] with [suggestions] at its end, as the agent writes them.
  static String write(String text, List<String> suggestions) =>
      [text, for (final said in suggestions) '<$tag>$said</$tag>'].join('\n');

  static const _openCandidates = [
    '<$tag>',
    '<parameter name="$tag">',
    "<parameter name='$tag'>",
    '<antml:parameter name="$tag">',
    "<antml:parameter name='$tag'>",
  ];

  static bool _isOpenPrefix(String s) =>
      s.isNotEmpty && _openCandidates.any((c) => c.startsWith(s));

  /// Matches `<reply_suggestion>` as well as tool-style hallucinations such as
  /// `<parameter name="reply_suggestion">` / `<antml:parameter name='reply_suggestion'>`.
  static const _openExpr =
      '<(?:(?:[a-z0-9_]+:)?parameter\\s+name=["\']$tag["\']|$tag)>';

  static final _whole = RegExp('$_openExpr([^<\\n]*)</[^>\\n]+>');

  static const _wholeExpr = '$_openExpr[^<\\n]*</[^>\\n]+>';
  static const _trailWrapperExpr =
      '(?:\\s*</(?:[a-z0-9_]+:)?(?:invoke|function_calls)>)*';

  /// Whole ones; then perhaps one under way, its end tag not yet whole;
  /// or the start of its opening tag.
  static final _tail = RegExp(
    '(?:\\s*$_wholeExpr)*\\s*'
    '(?:$_openExpr[^<\\n]*(?:<(?:/[^>\\n]*)?)?|(<[^<\\n>]*))?'
    '$_trailWrapperExpr\\s*\$',
  );

  /// Where the suggestions at the end of [text] start (the space before
  /// them too); null when there are none.
  static int? _tailAt(String text) {
    final lt = text.lastIndexOf('<');
    if (lt < 0) return null;
    // Cheap first: no tag of them, nor the start of one at the end.
    if (!text.contains(tag) && !_isOpenPrefix(text.substring(lt))) {
      return null;
    }
    final match = _tail.firstMatch(text);
    if (match == null || match.start == match.end) return null;
    // A tag's start at the end that is not theirs: none.
    if (match[1] case final start? when !_isOpenPrefix(start)) return null;
    final at = match.start;
    // Inline code (`<reply_suggestion>...`) is spoken of, not a suggestion.
    final firstLt = text.indexOf('<', at);
    if (firstLt > 0 && text.codeUnitAt(firstLt - 1) == 0x60) return null;
    // Only space before: nothing said.
    if (text.substring(at).trim().isEmpty) return null;
    return at;
  }
}
