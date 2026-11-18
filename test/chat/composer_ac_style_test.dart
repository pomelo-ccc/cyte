import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/codebuddy_account_picker.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/chat/composer/pickers_row.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ChatComposer applies A (warm unified card + ghost buttons + focus ring) '
    'and C (left Agent + Model only, icon-only permission shield, right quota ring)',
    (tester) async {
      await tester.runAsync(() async {
        await WorkbenchThemeService.instance.setColorTheme('Antigravity Light');
      });

      final session = ChatSession(historyCount: 0);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 680,
                  child: ChatComposer(session: session),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // 1. Placeholder uses unified ` · ` separators without `、` mix.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ChatComposer)),
      )!;
      expect(
        l10n.composerPlaceholder,
        '描述任务或提问 · 拖入或粘贴文件 · 输入 / 调用命令',
      );
      expect(l10n.composerPlaceholder.contains('、'), isFalse);

      // 2. Left PickersRow contains ONLY ghost buttons, with the mode picker
      //    rendered as iconOnly and the model picker keeping its ghost label.
      final leftPickers = tester
          .widgetList<ComposerPicker>(
            find.descendant(
              of: find.byType(PickersRow),
              matching: find.byType(ComposerPicker),
            ),
          )
          .toList();
      expect(leftPickers, isNotEmpty);
      for (final picker in leftPickers) {
        expect(picker.emphasized, isFalse);
      }
      expect(leftPickers.any((p) => p.iconOnly), isTrue);
      expect(
        find.descendant(
          of: find.byType(PickersRow),
          matching: find.byType(CodeBuddyAccountPicker),
        ),
        findsNothing,
      );

      // 3. Mode picker + permission picker are compact iconOnly buttons.
      final allPickers = tester.widgetList<ComposerPicker>(
        find.byType(ComposerPicker),
      );
      final iconPickers = allPickers.where((p) => p.iconOnly).toList();
      expect(iconPickers.length, 2);
      for (final p in iconPickers) {
        expect(p.tooltip, isNotEmpty);
      }

      // 4. Unified white card with warm border & 3px translucent focus halo when focused.
      final animatedContainers = tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(ChatComposer),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final cardContainer = animatedContainers.firstWhere(
        (c) => c.decoration is ShapeDecoration,
      );
      final shapeDeco = cardContainer.decoration! as ShapeDecoration;
      expect(shapeDeco.color, Colors.white);
      expect(
        shapeDeco.shadows!.any((s) => s.spreadRadius == 3 && s.blurRadius == 0),
        isTrue,
      );
    },
  );
}
