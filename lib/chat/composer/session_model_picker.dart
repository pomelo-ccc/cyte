import 'dart:async';

import 'package:flutter/material.dart';

import '../../channel/channel_setup.dart' show ChannelSetup;
import '../../ide/ide_dialog.dart';
import '../../kernel/agent_kernel.dart' show KernelChoiceKind;
import '../../kernel/codebuddy/codebuddy_cli.dart';
import '../../kernel/kernel_types.dart';
import '../../l10n/l10n.dart';
import '../../models/model_provider.dart' show parseModelRef;
import '../../models/model_providers.dart';
import '../../models/model_runtime.dart' show codexService;
import '../../models/model_welcome.dart';
import '../../models/provider_health.dart';
import '../../settings/settings_dialog.dart'
    show SettingsOpener, SettingsSection;
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../chat_session.dart';
import '../resume_after_reset.dart';
import '../widgets/hover_builder.dart';
import 'composer_picker.dart';

/// The pill that picks [session]'s model, each model's settings (its
/// effort, its context) beside it: the composer's, and the one a plan is
/// started with. With no model to run on, one that sets a model up
/// ([showModelWelcome]); nothing where the kernel picks no model.
class SessionModelPicker extends StatelessWidget {
  const SessionModelPicker({
    super.key,
    required this.session,
    this.pickerKey,
    this.tooltip,
    this.tapRegionGroupId,
    this.focusNode,
  });

  final ChatSession session;

  /// The picker's own, to open it from a keybinding.
  final GlobalKey<ComposerPickerState>? pickerKey;

  /// See [ComposerPicker.tooltip], [ComposerPicker.tapRegionGroupId] and
  /// [ComposerPicker.focusNode].
  final String? tooltip;
  final Object? tapRegionGroupId;
  final FocusNode? focusNode;

  /// Remembers the last active intensity per toggleable model so toggling
  /// `思考模式` OFF → ON restores the user's previous intensity tier.
  static final Map<String, String> _lastActiveEfforts = {};

  /// The model with its settings, e.g. "GLM-5.3 · 极致" or "Opus · 1M · High".
  String _label(
    BuildContext context,
    KernelOption model,
    List<KernelOption> options,
  ) {
    final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
    if (CodeBuddyModels.of(model.id) case final cbc?) {
      final settings = session.modelSettings(model.id);
      String? contextLabel;
      String? effortLabel;
      for (final setting in settings) {
        if (setting.kind == KernelChoiceKind.context &&
            setting.options.length > 1) {
          contextLabel = setting.selected?.label;
        } else if (setting.kind == KernelChoiceKind.effort) {
          final sel = setting.selected;
          if (sel != null) {
            if (sel.id == 'none') {
              effortLabel = isZh ? '思考关闭' : 'Off';
            } else if (cbc.supportedEfforts.isNotEmpty) {
              effortLabel = sel.label;
            }
          }
        }
      }
      return [
        if (model.group case final group?
            when options.any(
              (other) =>
                  other.label == model.label && other.group?.id != group.id,
            ))
          group.label,
        model.label,
        ?contextLabel,
        ?effortLabel,
      ].join(' · ');
    }

    return [
      if (model.group case final group?
          when options.any(
            (other) =>
                other.label == model.label && other.group?.id != group.id,
          ))
        group.label,
      model.label,
      for (final setting in session.modelSettings(model.id))
        if (!setting.toggle && setting.options.length > 1)
          if (setting.selected case final selected?)
            selected.label,
    ].join(' · ');
  }

  /// Builds WorkBuddy-exact model settings (`思考模式` switch + `思考强度` + `上下文`)
  /// for CodeBuddy models, preserving standard settings for all other providers.
  List<ModelSettingChoice> _settingsFor(
    BuildContext context,
    KernelOption option,
  ) {
    final rawSettings = session.modelSettings(option.id);
    if (CodeBuddyModels.of(option.id) case final cbc?) {
      final isZh = Localizations.maybeLocaleOf(context)?.languageCode == 'zh';
      final result = <ModelSettingChoice>[];

      for (final setting in rawSettings) {
        if (setting.kind == KernelChoiceKind.effort) {
          final selectedOpt = setting.selected;
          final selectedId = selectedOpt?.id;
          if (selectedId != null && selectedId != 'none') {
            _lastActiveEfforts[option.id] = selectedId;
          }

          if (cbc.canToggleThinking) {
            final isThinking = selectedId != 'none';
            final toggleOpt = KernelOption(
              'thinking',
              isZh ? '思考模式' : 'Thinking mode',
              Icons.psychology_alt_rounded,
              '',
            );
            result.add(
              ModelSettingChoice(
                kind: null,
                options: [toggleOpt],
                selected: isThinking ? toggleOpt : null,
                toggle: true,
                onSelected: (_) {
                  if (isThinking) {
                    final offOpt = setting.options
                        .where((o) => o.id == 'none')
                        .firstOrNull;
                    if (offOpt != null) {
                      unawaited(
                        _switch(
                          context,
                          option,
                          () => setting.onSelected(offOpt),
                        ),
                      );
                    }
                  } else {
                    final restoreId =
                        _lastActiveEfforts[option.id] ??
                        cbc.defaultEffort ??
                        cbc.supportedEfforts.firstOrNull ??
                        'enabled';
                    final onOpt =
                        setting.options
                            .where((o) => o.id == restoreId)
                            .firstOrNull ??
                        setting.options
                            .where((o) => o.id != 'none')
                            .firstOrNull;
                    if (onOpt != null) {
                      unawaited(
                        _switch(
                          context,
                          option,
                          () => setting.onSelected(onOpt),
                        ),
                      );
                    }
                  }
                },
              ),
            );

            // WorkBuddy rule: `u = effortItems.length > 0 && (!canToggleThinking || isThinking)`
            if (isThinking && cbc.supportedEfforts.isNotEmpty) {
              final intensityOptions = [
                for (final o in setting.options)
                  if (cbc.supportedEfforts.contains(o.id)) o,
              ];
              if (intensityOptions.isNotEmpty) {
                result.add(
                  ModelSettingChoice(
                    kind: KernelChoiceKind.effort,
                    options: intensityOptions,
                    selected: intensityOptions
                        .where((o) => o.id == selectedId)
                        .firstOrNull,
                    onSelected: (choice) => unawaited(
                      _switch(
                        context,
                        option,
                        () => setting.onSelected(choice),
                      ),
                    ),
                  ),
                );
              }
            }
          } else if (cbc.supportedEfforts.isNotEmpty) {
            final intensityOptions = [
              for (final o in setting.options)
                if (cbc.supportedEfforts.contains(o.id)) o,
            ];
            if (intensityOptions.isNotEmpty) {
              result.add(
                ModelSettingChoice(
                  kind: KernelChoiceKind.effort,
                  options: intensityOptions,
                  selected:
                      intensityOptions
                          .where((o) => o.id == selectedId)
                          .firstOrNull ??
                      intensityOptions.first,
                  onSelected: (choice) => unawaited(
                    _switch(context, option, () => setting.onSelected(choice)),
                  ),
                ),
              );
            }
          }
        } else {
          result.add(
            ModelSettingChoice(
              kind: setting.kind,
              options: setting.options,
              selected: setting.selected,
              toggle: setting.toggle,
              onSelected: (choice) => unawaited(
                _switch(context, option, () => setting.onSelected(choice)),
              ),
            ),
          );
        }
      }

      if (_resumeAfterLimit(context, option.id) case final resume?) {
        result.add(resume);
      }
      return result;
    }

    return [
      for (final setting in rawSettings)
        ModelSettingChoice(
          kind: setting.kind,
          options: setting.options,
          selected: setting.selected,
          toggle: setting.toggle,
          onSelected: (choice) => unawaited(
            _switch(context, option, () => setting.onSelected(choice)),
          ),
        ),
      ?_resumeAfterLimit(context, option.id),
      ?_autoResetCredits(context, option.id),
    ];
  }

  Widget? _pingBadge(KernelOption model) {
    final ping = ProviderHealthMonitor.instance.pingForModel(model.id);
    final (Color dotColor, String text) = switch (ping.status) {
      ProviderPingStatus.healthy => (const Color(0xFF22A35A), ping.shortLabel),
      ProviderPingStatus.slow => (const Color(0xFFD98B1C), ping.shortLabel),
      ProviderPingStatus.offline => (const Color(0xFFDC3E3E), '离线'),
      _ => (Colors.transparent, ''),
    };
    if (text.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5.5,
          height: 5.5,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: dotColor.withValues(alpha: 0.35),
                blurRadius: 3,
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.textFaint,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// Runs [pick], which switches to [option]: once confirmed, if that
  /// restarts the agent on another upstream mid-conversation.
  Future<void> _switch(
    BuildContext context,
    KernelOption option,
    VoidCallback pick,
  ) async {
    if (!session.switchRestarts(option.id)) return pick();
    final l10n = context.l10n;
    final choice = await showIdeDialog(
      context,
      message: l10n.modelsSwitchTitle(option.group?.label ?? option.label),
      detail: l10n.modelsSwitchDetail,
      buttons: [l10n.modelsSwitchConfirm],
      type: IdeDialogType.question,
    );
    if (choice == 0 && context.mounted) pick();
  }

  /// Beside a model of the account's plan, last: whether an agent stopped
  /// at its usage limit goes on by itself once it resets. Not where it
  /// cannot be set.
  ModelSettingChoice? _resumeAfterLimit(BuildContext context, String model) {
    final write = ResumeAfterResetSetting.write;
    if (write == null || !session.continuesAfterLimit(model)) return null;
    final on = KernelOption(
      'on',
      context.l10n.resumeAfterLimitToggle,
      Icons.schedule_send_rounded,
      '',
    );
    final enabled = ResumeAfterResetSetting.current();
    return ModelSettingChoice(
      kind: null,
      options: [on],
      selected: enabled ? on : null,
      toggle: true,
      onSelected: (_) => write(!enabled),
    );
  }

  /// Beside a model of ChatGPT accounts, last: whether an account out of
  /// quota uses up a reset credit of its own by itself.
  ModelSettingChoice? _autoResetCredits(BuildContext context, String model) {
    final providers = ModelProviders.current;
    final provider = providers.provider(parseModelRef(model)?.provider);
    if (provider == null || !provider.protocol.usesAccounts) return null;
    final on = KernelOption(
      'on',
      context.l10n.autoResetCreditsToggle,
      Icons.restart_alt_rounded,
      '',
    );
    final enabled = provider.autoResetCredits;
    return ModelSettingChoice(
      kind: null,
      options: [on],
      selected: enabled ? on : null,
      toggle: true,
      onSelected: (_) => unawaited(() async {
        final now = providers.provider(provider.id) ?? provider;
        await providers.save(now.copyWith(autoResetCredits: !enabled));
        // Turned on: one out of quota already uses its credit now.
        if (!enabled) {
          await codexService.refreshUsage(
            providers.provider(provider.id) ?? now,
          );
        }
      }()),
    );
  }

  @override
  Widget build(BuildContext context) {
    ProviderHealthMonitor.instance.ensureStarted();
    return ListenableBuilder(
      // Its switches turned, as settings.json says.
      listenable: Listenable.merge([
        ?ResumeAfterResetSetting.changes,
        ModelProviders.current,
        ProviderHealthMonitor.instance,
        CodeBuddyModels.changes,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final model = session.models;
    final l10n = context.l10n;
    if (model == null) {
      if (!session.health.noModel) return const SizedBox.shrink();
      return _SetUpPill(
        label: l10n.modelSetUp,
        onTap: () => unawaited(showModelWelcome(context)),
      );
    }
    final allCodeBuddy =
        model.options.isNotEmpty &&
        model.options.every((o) => CodeBuddyModels.isCodeBuddyModel(o.id));
    return ComposerPicker(
      key: pickerKey,
      options: model.options,
      selected: model.selected,
      label: _label(context, model.selected, model.options),
      trailingBadge: _pingBadge(model.selected),
      // For CodeBuddy models, show each model's credit multiplier (`0.29x`)
      // right-aligned on the same row just like WorkBuddy.
      describes: allCodeBuddy,
      descriptionAside: allCodeBuddy,
      settingsOf: (option) => _settingsFor(context, option),
      tooltip: tooltip,
      menuWidth: 268,
      searchPlaceholder: l10n.modelsSearch,
      footers: [
        if (SettingsOpener.maybeOf(context) case final open?)
          (
            label: ChannelSetup.channelBuild
                ? l10n.channelAccountTitle
                : l10n.modelsManage,
            icon: Icons.tune_rounded,
            onTap: () => open(SettingsSection.models),
          ),
      ],
      tapRegionGroupId: tapRegionGroupId,
      focusNode: focusNode,
      onSelected: (option) =>
          unawaited(_switch(context, option, () => model.onSelected(option))),
    );
  }
}

/// In the model's place while there is none: as its pill, in the accent,
/// a click away from setting one up.
class _SetUpPill extends StatelessWidget {
  const _SetUpPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: hovered ? .2 : .12),
            border: Border.all(color: accent.withValues(alpha: .4)),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Codicons.sparkle, size: 13, color: accent),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: accent, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
