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
import '../../workspace/editor_launcher.dart' show openExternal;
import '../widgets/hover_builder.dart';

/// Compact composer-toolbar pill showing the active CodeBuddy account's
/// real-time remaining credits (`剩余 5,897.6 积分`) and opening the 1-click
/// CodeBuddy Account Switcher & Credits Popover.
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
    unawaited(
      _store.ensureInitialized().then((_) {
        final active = _store.currentAccount;
        if (active == null || active.disabled) return;
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final missingBalance =
            active.auth.kind != CodeBuddyAuthKind.apiKey &&
            active.quota?.remainingCredits == null &&
            active.quota?.unlimited != true;
        if (missingBalance || nowSec - (active.quota?.lastUpdated ?? 0) > 60) {
          unawaited(_store.refreshQuota(active.id));
        }
      }),
    );
  }

  void _openPopover(BuildContext pillContext) {
    final box = pillContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final openSettings = SettingsOpener.maybeOf(pillContext);

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_store.currentAccount case final active?) {
      final missingBalance =
          active.auth.kind != CodeBuddyAuthKind.apiKey &&
          active.quota?.remainingCredits == null &&
          active.quota?.unlimited != true;
      if (missingBalance || nowSec - (active.quota?.lastUpdated ?? 0) > 45) {
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
        final busy =
            _store.switchingId != null ||
            (active != null &&
                _store.isRefreshing(active.id) &&
                active.quota?.remainingCredits == null);
        final dark = themeColors.dark;
        final hoverBg = (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.08 : 0.05,
        );
        final subtleBg = (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.035 : 0.025,
        );
        final pillText = active == null
            ? 'CodeBuddy 账号'
            : (active.quota?.pillCreditsLabel ?? active.edition.label);
        final tooltip = active == null
            ? 'CodeBuddy 账号（当前复用 CLI 默认登录态 · 点击添加账号查看剩余积分）'
            : [
                '${active.displayName} (${active.region.shortBadge} · ${active.quota?.subscriptionPackageName ?? active.edition.label})',
                active.quota?.summaryLabel,
                '点击查看积分明细或切换账号',
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
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 7.5),
                  decoration: BoxDecoration(
                    color: hovered ? hoverBg : subtleBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (dark ? Colors.white : Colors.black).withValues(
                        alpha: hovered ? 0.12 : 0.06,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy)
                        IdeSpinning(
                          Icon(
                            Codicons.loading,
                            size: 12.5,
                            color: AppColors.textMuted,
                          ),
                        )
                      else if (active == null)
                        Icon(
                          Codicons.account,
                          size: 13,
                          color: hovered ? AppColors.text : AppColors.textMuted,
                        )
                      else
                        CodeBuddyQuotaRing(
                          fraction: active.quota?.remainingFraction ?? 1.0,
                          size: 13.5,
                          strokeWidth: 1.9,
                        ),
                      const SizedBox(width: 5.5),
                      Text(
                        pillText,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: active?.quota?.quotaExhausted == true
                              ? const Color(0xFFDC3E3E)
                              : (hovered ? AppColors.text : AppColors.textMuted),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
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
    const width = 346.0;
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
                final quota = active?.quota;
                final remain = quota?.effectiveRemainingCredits;
                final total = quota?.totalCredits;
                final pct = quota?.percentage ?? 100;
                final barColor = CodeBuddyQuotaRing.colorForPercentage(pct);

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
                                'CodeBuddy 账号与积分',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                ),
                              ),
                            ),
                            if (active != null) ...[
                              _IconAction(
                                icon: Codicons.linkExternal,
                                tooltip: '打开网页端套餐与积分明细',
                                onTap: () => unawaited(
                                  openExternal(
                                    quota?.upgradeUrl ?? active.region.planUrl,
                                  ),
                                ),
                              ),
                              _IconAction(
                                icon: Codicons.refresh,
                                spinning: refreshing,
                                tooltip: '刷新剩余积分与套餐状态',
                                onTap: refreshing
                                    ? null
                                    : () => unawaited(
                                        store.refreshQuota(active.id),
                                      ),
                              ),
                            ],
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
                                '在设置中一键授权登录中国版 (CN) 或国际版 (AI) 账号后，即可实时查看当前账号剩余积分、资源包明细与一键切号。',
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
                              const SizedBox(height: 10),
                              // Remaining Credits Box
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: (dark ? Colors.white : Colors.black)
                                      .withValues(alpha: dark ? 0.04 : 0.025),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: border.withValues(alpha: 0.6),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '当前剩余积分',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: subColor,
                                          ),
                                        ),
                                        const Spacer(),
                                        if (quota?.subscriptionPackageName
                                            case final subName?
                                            when subName.isNotEmpty)
                                          Text(
                                            subName,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                              color: barColor,
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        Text(
                                          quota?.unlimited == true
                                              ? '不限积分'
                                              : remain != null
                                              ? formatBalanceCredits(remain)
                                              : '—',
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                            color: titleColor,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                        if (total != null && total > 0) ...[
                                          const SizedBox(width: 4),
                                          Text(
                                            '/ ${formatBalanceCredits(total)} 积分',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: subColor,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ],
                                        const Spacer(),
                                        if (total != null && total > 0)
                                          Text(
                                            '$pct%',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: barColor,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (total != null && total > 0) ...[
                                      const SizedBox(height: 7),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value:
                                              quota?.remainingFraction ?? 1.0,
                                          minHeight: 4.5,
                                          backgroundColor:
                                              (dark
                                                      ? Colors.white
                                                      : Colors.black)
                                                  .withValues(alpha: 0.09),
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                barColor,
                                              ),
                                        ),
                                      ),
                                    ],
                                    if (quota != null &&
                                        quota.packages.length > 1) ...[
                                      const SizedBox(height: 8),
                                      for (final pkg in quota.packages)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2.5,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  pkg.displayTitle,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: subColor,
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                '${formatBalanceCredits(pkg.remain)} / ${formatBalanceCredits(pkg.total)}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: titleColor.withValues(
                                                    alpha: 0.85,
                                                  ),
                                                  fontFeatures: const [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ],
                                ),
                              ),
                              if ((quota?.turnCount ?? 0) > 0 ||
                                  (quota?.sessionCreditsUsed ?? 0) > 0) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(
                                      Codicons.sparkle,
                                      size: 11.5,
                                      color: subColor,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        '本机已对话 ${quota!.turnCount} 轮 · 累计消耗 ${formatConsumedCredits(quota.sessionCreditsUsed)} 积分',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: subColor,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
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
    final rem = account.quota?.effectiveRemainingCredits;
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
              if (rem != null) ...[
                const SizedBox(width: 6),
                Text(
                  '${formatBalanceCredits(rem)} 积分',
                  style: TextStyle(
                    fontSize: 11,
                    color: subColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
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
