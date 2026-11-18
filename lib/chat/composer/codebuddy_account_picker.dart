import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../ide/ide_spinning.dart';
import '../../kernel/codebuddy/codebuddy_account_models.dart';
import '../../kernel/codebuddy/codebuddy_accounts.dart';
import '../../kernel/codebuddy/codebuddy_cli.dart';
import '../../kernel/codebuddy/codebuddy_usage_widgets.dart';
import '../../settings/settings_dialog.dart'
    show SettingsOpener, SettingsSection;
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../widgets/hover_builder.dart';

/// Compact composer-toolbar trigger showing the active CodeBuddy account status
/// and opening the 1-click CodeBuddy Account Switcher & Credits Popover.
class CodeBuddyAccountPicker extends StatefulWidget {
  const CodeBuddyAccountPicker({super.key, required this.modelId});

  final String? modelId;

  @override
  State<CodeBuddyAccountPicker> createState() => _CodeBuddyAccountPickerState();
}

class _CodeBuddyAccountPickerState extends State<CodeBuddyAccountPicker> {
  final CodeBuddyAccounts _store = CodeBuddyAccounts.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_store.ensureInitialized());
  }

  void _openPopover(BuildContext pillContext) {
    final box = pillContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final openSettings = SettingsOpener.maybeOf(pillContext);

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_store.currentAccount case final active?) {
      if (nowSec - (active.quota?.lastUpdated ?? 0) > 60) {
        unawaited(_store.refreshQuota(active.id));
      }
    }

    unawaited(
      showGeneralDialog<void>(
        context: pillContext,
        barrierDismissible: true,
        barrierLabel: 'Dismiss',
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder: (dialogCtx, _, _) => _CodeBuddyUsagePopover(
          anchor: anchor,
          store: _store,
          onManageAccounts: openSettings == null
              ? null
              : () {
                  Navigator.of(dialogCtx).pop();
                  openSettings(SettingsSection.codebuddyAccounts);
                },
        ),
        transitionBuilder: (context, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!CodeBuddyModels.isCodeBuddyModel(widget.modelId)) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final active = _store.currentAccount;
        final busy = _store.switchingId != null;
        final dark = themeColors.dark;
        final hoverBg = (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.08 : 0.05,
        );
        final tooltip = active == null
            ? 'CodeBuddy 账号（当前复用 CLI 默认登录态 · 点击添加或切换多账号）'
            : [
                '${active.displayName} (${active.region.shortBadge} · ${active.edition.label})',
                active.quota?.summaryLabel,
                '点击查看详情或切换账号',
              ].whereType<String>().join(' · ');

        return Builder(
          builder: (pillCtx) => IdeHover(
            position: IdeHoverPosition.above,
            message: tooltip,
            child: HoverBuilder(
              cursor: SystemMouseCursors.click,
              builder: (context, hovered) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) {},
                onTap: () => _openPopover(pillCtx),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hovered ? hoverBg : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: busy
                      ? IdeSpinning(
                          Icon(
                            Codicons.loading,
                            size: 13.5,
                            color: AppColors.textMuted,
                          ),
                        )
                      : active == null
                      ? Icon(
                          Codicons.account,
                          size: 14,
                          color: hovered ? AppColors.text : AppColors.textMuted,
                        )
                      : Opacity(
                          opacity: hovered ? 1.0 : 0.9,
                          child: CodeBuddyQuotaRing(
                            fraction: active.quota?.remainingFraction ?? 1.0,
                            size: 14.5,
                            strokeWidth: 1.95,
                          ),
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CodeBuddyUsagePopover extends StatelessWidget {
  const _CodeBuddyUsagePopover({
    required this.anchor,
    required this.store,
    required this.onManageAccounts,
  });

  final Rect anchor;
  final CodeBuddyAccounts store;
  final VoidCallback? onManageAccounts;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    const width = 330.0;
    final left = (anchor.right - width)
        .clamp(12.0, math.max(12.0, screen.width - width - 12.0))
        .toDouble();
    final bottom = (screen.height - anchor.top + 8.0)
        .clamp(12.0, math.max(12.0, screen.height - 80.0))
        .toDouble();
    final dark = themeColors.dark;
    final bg = dark ? const Color(0xFF1E222A) : Colors.white;
    final border = dark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.10);
    final titleColor = dark ? const Color(0xFFF3F4F6) : const Color(0xFF111827);
    final subColor = dark ? const Color(0xFF9CA3AF) : const Color(0xFF4B5563);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          left: left,
          bottom: bottom,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                final active = store.currentAccount;
                final accounts = store.accounts;
                final refreshing =
                    store.isRefreshingAll ||
                    (active != null && store.isRefreshing(active.id));

                return Container(
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: dark ? 0.42 : 0.14,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'CodeBuddy 账号与配额',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                ),
                              ),
                            ),
                            if (active != null)
                              _IconAction(
                                icon: Codicons.refresh,
                                spinning: refreshing,
                                tooltip: '刷新账号与套餐状态',
                                onTap: refreshing
                                    ? null
                                    : () => unawaited(
                                        store.refreshQuota(active.id),
                                      ),
                              ),
                            if (onManageAccounts != null)
                              _IconAction(
                                icon: Codicons.settingsGear,
                                tooltip: '管理 CodeBuddy 账号',
                                onTap: onManageAccounts,
                              ),
                          ],
                        ),
                      ),
                      Divider(height: 1, thickness: 1, color: border),
                      if (active == null)
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '当前复用本机 CodeBuddy CLI 默认登录态',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: titleColor,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '你可以直接在设置中添加多个中国版 (CN) / 国际版 (AI) OAuth 或 API Key 账号，实现一键切号与配额监控。',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: subColor,
                                  height: 1.4,
                                ),
                              ),
                              if (onManageAccounts != null) ...[
                                const SizedBox(height: 10),
                                GestureDetector(
                                  onTap: onManageAccounts,
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF0EA5E9,
                                        ).withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Codicons.add,
                                            size: 13,
                                            color: Color(0xFF0EA5E9),
                                          ),
                                          SizedBox(width: 5),
                                          Text(
                                            '添加 CodeBuddy 账号',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF0EA5E9),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        )
                      else ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      active.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: titleColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  CodeBuddyRegionBadge(region: active.region),
                                  const SizedBox(width: 4),
                                  CodeBuddyEditionBadge(
                                    edition: active.edition,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      active.quota?.summaryLabel ??
                                          '${active.edition.label} · 就绪',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: subColor,
                                      ),
                                    ),
                                  ),
                                  CodeBuddyQuotaRing(
                                    fraction:
                                        active.quota?.remainingFraction ?? 1.0,
                                    size: 17,
                                    strokeWidth: 2.0,
                                  ),
                                ],
                              ),
                              if ((active.quota?.turnCount ?? 0) > 0) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '已执行 ${active.quota!.turnCount} 轮 · 累计 Credits ${active.quota!.sessionCreditsUsed.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: subColor.withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (accounts.length > 1) ...[
                          Divider(height: 1, thickness: 1, color: border),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                            child: Text(
                              '快速切换账号 (${accounts.length})',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: subColor,
                              ),
                            ),
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 190),
                            child: ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                              itemCount: accounts.length,
                              itemBuilder: (context, idx) {
                                final acc = accounts[idx];
                                final isCurrent =
                                    acc.id == store.currentAccountId;
                                return _AccountSwitchTile(
                                  account: acc,
                                  selected: isCurrent,
                                  titleColor: titleColor,
                                  subColor: subColor,
                                  onTap: isCurrent
                                      ? null
                                      : () {
                                          unawaited(
                                            store.switchAccount(acc.id),
                                          );
                                          Navigator.of(context).pop();
                                        },
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountSwitchTile extends StatelessWidget {
  const _AccountSwitchTile({
    required this.account,
    required this.selected,
    required this.titleColor,
    required this.subColor,
    this.onTap,
  });

  final CodeBuddyAccount account;
  final bool selected;
  final Color titleColor;
  final Color subColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = themeColors.dark;
    return HoverBuilder(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF0EA5E9).withValues(alpha: dark ? 0.16 : 0.10)
                : hovered
                ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Codicons.check : Codicons.account,
                size: 13.5,
                color: selected ? const Color(0xFF0EA5E9) : subColor,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  account.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: titleColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              CodeBuddyRegionBadge(region: account.region),
              const SizedBox(width: 4),
              CodeBuddyEditionBadge(edition: account.edition),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    this.spinning = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool spinning;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: tooltip,
      child: HoverBuilder(
        cursor: onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered
                  ? AppColors.text.withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: spinning
                ? IdeSpinning(
                    Icon(icon, size: 13.5, color: AppColors.textMuted),
                  )
                : Icon(
                    icon,
                    size: 13.5,
                    color: hovered ? AppColors.text : AppColors.textMuted,
                  ),
          ),
        ),
      ),
    );
  }
}
