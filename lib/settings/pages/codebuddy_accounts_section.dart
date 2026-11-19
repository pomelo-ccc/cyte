import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/widgets/hover_builder.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../ide/ide_hover.dart';
import '../../ide/ide_input.dart';
import '../../ide/ide_spinning.dart';
import '../../kernel/codebuddy/codebuddy_account_models.dart';
import '../../kernel/codebuddy/codebuddy_accounts.dart';
import '../../kernel/codebuddy/codebuddy_oauth.dart';
import '../../kernel/codebuddy/codebuddy_usage_widgets.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_controls.dart';
import 'settings_widgets.dart';

/// Standalone Settings → CodeBuddy 账号 page (`SettingsSection.codebuddyAccounts`).
class CodeBuddyAccountsPage extends StatelessWidget {
  const CodeBuddyAccountsPage({super.key, this.store});

  final CodeBuddyAccounts? store;

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return SettingsPage(
      title: isZh ? 'CodeBuddy 账号' : 'CodeBuddy Accounts',
      description: isZh
          ? '管理多个腾讯云 CodeBuddy 中国版 (CN) / 国际版 (AI) / 企业专享及 API Key 账号，支持浏览器一键 OAuth 登录、Credits 用量追踪与限额自动切号。'
          : 'Manage Tencent CodeBuddy CN, Global, Enterprise, and API Key accounts with 1-click OAuth sign-in, credit tracking, and smart auto-switching.',
      children: [CodeBuddyAccountsSection(store: store)],
    );
  }
}

class CodeBuddyAccountsSection extends StatefulWidget {
  const CodeBuddyAccountsSection({super.key, this.store});

  final CodeBuddyAccounts? store;

  @override
  State<CodeBuddyAccountsSection> createState() =>
      _CodeBuddyAccountsSectionState();
}

class _CodeBuddyAccountsSectionState extends State<CodeBuddyAccountsSection> {
  final TextEditingController _searchController = TextEditingController();
  CodeBuddyRegion? _regionFilter;
  String? _bannerMessage;
  bool _bannerError = false;

  CodeBuddyAccounts get _store => widget.store ?? CodeBuddyAccounts.instance;

  @override
  void initState() {
    super.initState();
    unawaited(
      _store.ensureInitialized().then((_) {
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final stale = _store.accounts.any(
          (a) =>
              !a.disabled &&
              ((a.auth.kind != CodeBuddyAuthKind.apiKey &&
                      a.quota?.remainingCredits == null &&
                      a.quota?.unlimited != true) ||
                  nowSec - (a.quota?.lastUpdated ?? 0) > 60),
        );
        if (stale) {
          unawaited(_store.refreshAllQuotas(silent: true));
        }
      }),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _bannerMessage = msg;
      _bannerError = error;
    });
  }

  List<CodeBuddyAccount> _filtered(List<CodeBuddyAccount> all) {
    final q = _searchController.text.trim().toLowerCase();
    return [
      for (final a in all)
        if ((_regionFilter == null || a.region == _regionFilter) &&
            (q.isEmpty ||
                a.displayName.toLowerCase().contains(q) ||
                a.uid.toLowerCase().contains(q) ||
                (a.email?.toLowerCase().contains(q) ?? false) ||
                (a.enterpriseName?.toLowerCase().contains(q) ?? false)))
          a,
    ];
  }

  Future<void> _switchAccount(CodeBuddyAccount account) async {
    try {
      await _store.switchAccount(account.id);
      _showStatus(
        '已切换至账号 ${account.displayName}（${account.region.label} · 新轮次与新会话自动生效）',
      );
    } on Object catch (e) {
      _showStatus('切换账号失败：$e', error: true);
    }
  }

  Future<void> _exportBackup() async {
    if (_store.accounts.isEmpty) {
      _showStatus('当前暂无可导出的账号', error: true);
      return;
    }
    final jsonText = _store.exportAccountsJson();
    final savePath = await WindowControls.pickSaveFile(
      name: 'codebuddy-accounts.json',
    );
    if (savePath != null && savePath.isNotEmpty) {
      await CodeBuddyOAuth.writeAtomicSecure(savePath, jsonText);
      _showStatus('已将 ${_store.accounts.length} 个账号导出保存至 $savePath');
      return;
    }
    await Clipboard.setData(ClipboardData(text: jsonText));
    _showStatus('已将 ${_store.accounts.length} 个账号的备份 JSON 复制到剪贴板');
  }

  Future<void> _deleteAccount(CodeBuddyAccount account) async {
    final choice = await showIdeDialog(
      context,
      message: '移除账号 ${account.displayName}？',
      detail: '这将从 Cyte 本地账号库中移除该账号记录，不会注销云端账户本身。',
      buttons: const ['移除账号'],
    );
    if (choice == 0) {
      await _store.deleteAccount(account.id);
      _showStatus('已移除账号 ${account.displayName}');
    }
  }

  Future<void> _editLabel(CodeBuddyAccount account) async {
    final updated = await showGeneralDialog<String?>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: const Color(0x70000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) =>
          _EditAccountLabelDialog(initialLabel: account.customLabel ?? ''),
    );
    if (updated != null) {
      await _store.setCustomLabel(account.id, updated);
    }
  }

  Future<void> _openAddDialog() async {
    final msg = await showGeneralDialog<String?>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Dismiss',
      barrierColor: const Color(0x78000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => _AddCodeBuddyAccountDialog(store: _store),
    );
    if (msg != null && msg.isNotEmpty) {
      _showStatus(msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final all = _store.accounts;
        final filtered = _filtered(all);
        final auto = _store.autoSwitch;

        final cnCount = all.where((a) => a.region == CodeBuddyRegion.cn).length;
        final globalCount = all
            .where((a) => a.region == CodeBuddyRegion.global)
            .length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 240,
                            child: IdeInputBox(
                              controller: _searchController,
                              placeholder: '搜索昵称、UID、企业或备注...',
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IdeButton(
                                label: '添加账号',
                                icon: Codicons.add,
                                onPressed: () => unawaited(_openAddDialog()),
                              ),
                              const SizedBox(width: 6),
                              IdeButton(
                                label: '刷新全部状态',
                                icon: Codicons.refresh,
                                spinning: _store.isRefreshingAll,
                                secondary: true,
                                onPressed: _store.isRefreshingAll
                                    ? null
                                    : () => unawaited(
                                        _store.refreshAllQuotas(),
                                      ),
                              ),
                              const SizedBox(width: 6),
                              IdeButton(
                                label: '导出备份',
                                icon: Codicons.exportIcon,
                                secondary: true,
                                onPressed: () => unawaited(_exportBackup()),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (all.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _RegionFilterChip(
                              label: '全部 (${all.length})',
                              selected: _regionFilter == null,
                              onTap: () => setState(() => _regionFilter = null),
                            ),
                            if (cnCount > 0)
                              _RegionFilterChip(
                                label: '中国版 CN ($cnCount)',
                                selected: _regionFilter == CodeBuddyRegion.cn,
                                onTap: () => setState(
                                  () => _regionFilter = CodeBuddyRegion.cn,
                                ),
                              ),
                            if (globalCount > 0)
                              _RegionFilterChip(
                                label: '国际版 AI ($globalCount)',
                                selected:
                                    _regionFilter == CodeBuddyRegion.global,
                                onTap: () => setState(
                                  () => _regionFilter = CodeBuddyRegion.global,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (_bannerMessage != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: (_bannerError
                                    ? const Color(0xFFDC3E3E)
                                    : const Color(0xFF0EA5E9))
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _bannerError
                                    ? Codicons.warning
                                    : Codicons.check,
                                size: 14,
                                color: _bannerError
                                    ? const Color(0xFFDC3E3E)
                                    : const Color(0xFF0EA5E9),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _bannerMessage!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.text,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _bannerMessage = null),
                                child: Icon(
                                  Codicons.close,
                                  size: 13,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (filtered.isEmpty)
              SettingsCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 28,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Codicons.account,
                          size: 28,
                          color: AppColors.textMuted,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          all.isEmpty
                              ? '暂未添加托管账号（当前自动使用本机 CodeBuddy CLI 登录态）'
                              : '没有匹配的 CodeBuddy 账号',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '支持添加多个中国版 (copilot.tencent.com) 与国际版 (codebuddy.ai) 账号，随时一键无缝切换。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                        if (all.isEmpty) ...[
                          const SizedBox(height: 14),
                          IdeButton(
                            label: '浏览器一键授权登录',
                            icon: Codicons.add,
                            onPressed: () => unawaited(_openAddDialog()),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              )
            else
              for (final acc in filtered) ...[
                _CodeBuddyAccountCard(
                  account: acc,
                  isActive: acc.id == _store.currentAccountId,
                  isRefreshing: _store.isRefreshing(acc.id),
                  isSwitching: _store.switchingId == acc.id,
                  onSwitch: () => unawaited(_switchAccount(acc)),
                  onRefresh: () => unawaited(_store.refreshQuota(acc.id)),
                  onEditLabel: () => unawaited(_editLabel(acc)),
                  onDelete: () => unawaited(_deleteAccount(acc)),
                ),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 6),
            SettingsGroup(
              title: '智能切号策略',
              children: [
                SettingsCard(
                  children: [
                    SettingsSwitchRow(
                      label: '配额耗尽自动切号',
                      description: '当检测到当前账号 Credits 不足或触发 429 限流时，自动切换至下一个可用账号。',
                      value: auto.enabled,
                      onChanged: (v) => unawaited(
                        _store.setAutoSwitch(auto.copyWith(enabled: v)),
                      ),
                    ),
                    SettingsSwitchRow(
                      label: '优先保持相同区域 (CN / 国际版)',
                      description: '自动切号时优先挑选同一区域版本的健康账号，避免模型列表变化。',
                      value: auto.preferSameRegion,
                      onChanged: (v) => unawaited(
                        _store.setAutoSwitch(
                          auto.copyWith(preferSameRegion: v),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _CodeBuddyAccountCard extends StatelessWidget {
  const _CodeBuddyAccountCard({
    required this.account,
    required this.isActive,
    required this.isRefreshing,
    required this.isSwitching,
    required this.onSwitch,
    required this.onRefresh,
    required this.onEditLabel,
    required this.onDelete,
  });

  final CodeBuddyAccount account;
  final bool isActive;
  final bool isRefreshing;
  final bool isSwitching;
  final VoidCallback onSwitch;
  final VoidCallback onRefresh;
  final VoidCallback onEditLabel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final dark = themeColors.dark;
    final activeBorder = const Color(0xFF0EA5E9).withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? activeBorder : AppColors.border,
          width: isActive ? 1.3 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CodeBuddyQuotaRing(
                fraction: account.quota?.remainingFraction ?? 1.0,
                size: 20,
                strokeWidth: 2.2,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            account.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        CodeBuddyRegionBadge(region: account.region),
                        const SizedBox(width: 4),
                        CodeBuddyEditionBadge(edition: account.edition),
                        if (isActive) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF10B981,
                              ).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '当前使用',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF10B981),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isActive)
                    IdeButton(
                      label: '切换使用',
                      spinning: isSwitching,
                      onPressed: isSwitching ? null : onSwitch,
                    ),
                  const SizedBox(width: 4),
                  _SmallCardIcon(
                    icon: Codicons.edit,
                    tooltip: '修改备注名称',
                    onTap: onEditLabel,
                  ),
                  _SmallCardIcon(
                    icon: Codicons.refresh,
                    tooltip: '刷新账号与套餐配额',
                    spinning: isRefreshing,
                    onTap: isRefreshing ? null : onRefresh,
                  ),
                  _SmallCardIcon(
                    icon: Codicons.linkExternal,
                    tooltip: '打开套餐与用量中心',
                    onTap: () => unawaited(
                      openExternal(
                        account.quota?.upgradeUrl ?? account.region.planUrl,
                      ),
                    ),
                  ),
                  _SmallCardIcon(
                    icon: Codicons.trash,
                    tooltip: '移除账号',
                    onTap: onDelete,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(
                alpha: dark ? 0.04 : 0.025,
              ),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        account.disabled
                            ? '状态异常：${account.disabledReason ?? '请重新登录授权'}'
                            : (account.quota?.summaryLabel ?? '状态正常'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: account.disabled
                              ? const Color(0xFFDC3E3E)
                              : AppColors.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Text(
                      '已对话 ${account.quota?.turnCount ?? 0} 轮 · 累计消耗 ${formatConsumedCredits(account.quota?.sessionCreditsUsed ?? 0)} 积分',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (!account.disabled &&
                    (account.quota?.totalCredits ?? 0) > 0) ...[
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: account.quota?.remainingFraction ?? 1.0,
                      minHeight: 4.5,
                      backgroundColor: (dark ? Colors.white : Colors.black)
                          .withValues(alpha: 0.09),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        CodeBuddyQuotaRing.colorForPercentage(
                          account.quota?.percentage ?? 100,
                        ),
                      ),
                    ),
                  ),
                ],
                if (!account.disabled &&
                    (account.quota?.packages.length ?? 0) > 1) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      for (final pkg in account.quota!.packages)
                        Text(
                          '${pkg.displayTitle}：${formatBalanceCredits(pkg.remain)} / ${formatBalanceCredits(pkg.total)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionFilterChip extends StatelessWidget {
  const _RegionFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF0EA5E9).withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? const Color(0xFF0EA5E9) : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? const Color(0xFF0EA5E9) : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallCardIcon extends StatelessWidget {
  const _SmallCardIcon({
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
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered
                  ? AppColors.text.withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: spinning
                ? IdeSpinning(
                    Icon(icon, size: 14, color: AppColors.textMuted),
                  )
                : Icon(
                    icon,
                    size: 14,
                    color: hovered ? AppColors.text : AppColors.textMuted,
                  ),
          ),
        ),
      ),
    );
  }
}

class _EditAccountLabelDialog extends StatefulWidget {
  const _EditAccountLabelDialog({required this.initialLabel});

  final String initialLabel;

  @override
  State<_EditAccountLabelDialog> createState() =>
      _EditAccountLabelDialogState();
}

class _EditAccountLabelDialogState extends State<_EditAccountLabelDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialLabel,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '账号备注名称',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(height: 10),
              IdeInputBox(
                controller: _controller,
                placeholder: '例如：个人中国版 Pro / 团队旗舰版（留空恢复默认昵称）',
                autofocus: true,
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IdeButton(
                    label: '取消',
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: '保存',
                    onPressed: () =>
                        Navigator.of(context).pop(_controller.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddCodeBuddyAccountDialog extends StatefulWidget {
  const _AddCodeBuddyAccountDialog({required this.store});

  final CodeBuddyAccounts store;

  @override
  State<_AddCodeBuddyAccountDialog> createState() =>
      _AddCodeBuddyAccountDialogState();
}

class _AddCodeBuddyAccountDialogState
    extends State<_AddCodeBuddyAccountDialog> {
  int _tab = 0; // 0: OAuth, 1: API Key, 2: Token / JSON Import
  CodeBuddyRegion _region = CodeBuddyRegion.cn;

  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _importController = TextEditingController();
  final TextEditingController _refreshTokenController = TextEditingController();

  bool _busy = false;
  String? _error;
  CodeBuddyPendingOAuth? _pendingOAuth;
  Completer<void>? _cancelOAuth;

  @override
  void dispose() {
    _cancelOAuth?.complete();
    _endpointController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _nicknameController.dispose();
    _importController.dispose();
    _refreshTokenController.dispose();
    super.dispose();
  }

  Future<void> _startBrowserOAuth() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final cancel = Completer<void>();
    _cancelOAuth = cancel;
    try {
      final customEp = _endpointController.text.trim();
      final pending = await CodeBuddyOAuth.createAuthState(
        region: _region,
        customEndpoint: customEp.isEmpty ? null : customEp,
      );
      if (!mounted) return;
      setState(() => _pendingOAuth = pending);
      await openExternal(pending.authUrl);

      final account = await CodeBuddyOAuth.pollForAuthorizedAccount(
        pending,
        cancel: cancel.future,
      );
      final saved = await widget.store.upsertAccount(account, makeActive: true);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop('已成功登录并启用账号 ${saved.displayName} (${saved.region.label})');
    } on CodeBuddyOAuthCancelled {
      if (mounted) {
        setState(() {
          _busy = false;
          _pendingOAuth = null;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _submitApiKey() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.store.addApiKeyAccount(
        apiKey: _apiKeyController.text,
        region: _region,
        nickname: _nicknameController.text,
        baseUrl: _baseUrlController.text,
        endpoint: _endpointController.text.trim().isEmpty
            ? null
            : _endpointController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop('已添加并切换至 API Key 账号 ${saved.displayName}');
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _submitImportOrToken() async {
    final raw = _importController.text.trim();
    final rt = _refreshTokenController.text.trim();
    if (raw.isEmpty && rt.isEmpty) {
      setState(() => _error = '请粘贴备份 JSON 或 Bearer Access / Refresh Token');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (raw.startsWith('{') || raw.startsWith('[')) {
        final count = await widget.store.importAccountsJson(raw);
        if (!mounted) return;
        Navigator.of(context).pop('已成功导入 $count 个 CodeBuddy 账号');
        return;
      }
      final saved = await widget.store.addTokenAccount(
        accessToken: raw,
        refreshToken: rt,
        region: _region,
        endpoint: _endpointController.text.trim().isEmpty
            ? null
            : _endpointController.text.trim(),
        nickname: _nicknameController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop('已导入并启用账号 ${saved.displayName}');
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsCustomEndpoint =
        _region == CodeBuddyRegion.cloudhosted ||
        _region == CodeBuddyRegion.selfhosted;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '添加 CodeBuddy 账号',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      _cancelOAuth?.complete();
                      Navigator.of(context).pop();
                    },
                    child: Icon(
                      Codicons.close,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _TabPill(
                    label: '浏览器 OAuth 授权',
                    selected: _tab == 0,
                    onTap: _busy ? null : () => setState(() => _tab = 0),
                  ),
                  const SizedBox(width: 6),
                  _TabPill(
                    label: 'API Key 接入',
                    selected: _tab == 1,
                    onTap: _busy ? null : () => setState(() => _tab = 1),
                  ),
                  const SizedBox(width: 6),
                  _TabPill(
                    label: 'Token / 备份导入',
                    selected: _tab == 2,
                    onTap: _busy ? null : () => setState(() => _tab = 2),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '选择服务区域版本',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in const [
                    CodeBuddyRegion.cn,
                    CodeBuddyRegion.global,
                    CodeBuddyRegion.ioa,
                    CodeBuddyRegion.cloudhosted,
                  ])
                    _RegionFilterChip(
                      label: r.label,
                      selected: _region == r,
                      onTap: () {
                        if (!_busy) setState(() => _region = r);
                      },
                    ),
                ],
              ),
              if (needsCustomEndpoint) ...[
                const SizedBox(height: 10),
                IdeInputBox(
                  controller: _endpointController,
                  placeholder: '企业服务端地址（如 https://your-org.copilot.qq.com）',
                ),
              ],
              const SizedBox(height: 14),
              if (_tab == 0) ...[
                Text(
                  _region == CodeBuddyRegion.cn
                      ? '将打开腾讯云 CodeBuddy 中国版 (copilot.tencent.com) 浏览器登录页，支持微信、QQ、腾讯云及企业 SSO 扫码授权。'
                      : '将打开 CodeBuddy 国际版 (${_region.defaultEndpoint}) 浏览器登录页，支持 Google / GitHub 账号一键授权。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    height: 1.45,
                  ),
                ),
                if (_pendingOAuth != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const IdeSpinning(
                          Icon(
                            Codicons.loading,
                            size: 14,
                            color: Color(0xFF0EA5E9),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '正在等待浏览器完成授权…',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.text,
                            ),
                          ),
                        ),
                        IdeButton(
                          label: '复制登录链接',
                          secondary: true,
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: _pendingOAuth!.authUrl),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ] else if (_tab == 1) ...[
                IdeInputBox(
                  controller: _apiKeyController,
                  placeholder: '粘贴 CODEBUDDY_API_KEY',
                ),
                const SizedBox(height: 8),
                IdeInputBox(
                  controller: _nicknameController,
                  placeholder: '账号备注名称（可选，如：个人中国版 Key）',
                ),
                const SizedBox(height: 8),
                IdeInputBox(
                  controller: _baseUrlController,
                  placeholder: '自定义 Base URL（可选，留空使用官方端点）',
                ),
              ] else ...[
                IdeInputBox(
                  controller: _importController,
                  placeholder: '粘贴 Access Token 或导出的 codebuddy-accounts.json',
                ),
                const SizedBox(height: 8),
                IdeInputBox(
                  controller: _refreshTokenController,
                  placeholder: 'Refresh Token（可选，填写后支持自动续期）',
                ),
                const SizedBox(height: 8),
                IdeInputBox(
                  controller: _nicknameController,
                  placeholder: '备注昵称（可选）',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFDC3E3E),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IdeButton(
                    label: _busy ? '取消等待' : '关闭',
                    secondary: true,
                    onPressed: () {
                      if (_busy && _tab == 0) {
                        _cancelOAuth?.complete();
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: switch (_tab) {
                      0 => _busy ? '等待授权中…' : '打开浏览器授权登录',
                      1 => '保存并启用 API Key',
                      _ => '导入并启用',
                    },
                    spinning: _busy,
                    onPressed: _busy
                        ? null
                        : switch (_tab) {
                            0 => () => unawaited(_startBrowserOAuth()),
                            1 => () => unawaited(_submitApiKey()),
                            _ => () => unawaited(_submitImportOrToken()),
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF0EA5E9).withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? const Color(0xFF0EA5E9) : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? const Color(0xFF0EA5E9) : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
