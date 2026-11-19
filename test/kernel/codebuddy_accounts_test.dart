import 'dart:io';

import 'package:baocode/kernel/claude_code/turn_stats.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_quota.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late CodeBuddyAccounts store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cyte_cbc_accounts_test_');
    store = CodeBuddyAccounts(dataDir: tempDir.path);
    await store.ensureInitialized();
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'CodeBuddyRegion maps wire names, billingOrigin, and CODEBUDDY_INTERNET_ENVIRONMENT accurately',
    () {
      expect(CodeBuddyRegion.cn.internetEnvironment, 'internal');
      expect(CodeBuddyRegion.global.internetEnvironment, isNull);
      expect(CodeBuddyRegion.ioa.internetEnvironment, 'ioa');
      expect(CodeBuddyRegion.cloudhosted.internetEnvironment, 'cloudhosted');
      expect(CodeBuddyRegion.selfhosted.internetEnvironment, 'selfhosted');

      expect(CodeBuddyRegion.cn.billingOrigin, 'https://www.codebuddy.cn');
      expect(CodeBuddyRegion.ioa.billingOrigin, 'https://www.codebuddy.cn');
      expect(CodeBuddyRegion.global.billingOrigin, 'https://www.codebuddy.ai');

      expect(
        CodeBuddyRegion.fromDomain('https://www.codebuddy.ai'),
        CodeBuddyRegion.global,
      );
      expect(
        CodeBuddyRegion.fromDomain('https://copilot.tencent.com'),
        CodeBuddyRegion.cn,
      );
      expect(
        CodeBuddyRegion.fromDomain('https://tencent.sso.copilot.tencent.com'),
        CodeBuddyRegion.ioa,
      );
    },
  );

  test(
    'parses WorkBuddy get-user-resource-summary string capacities and formats remaining credits',
    () {
      final quota = CodeBuddyQuotaService.parseResourceSummaryResponse(
        {
          'code': 0,
          'msg': 'OK',
          'data': {
            'IsPaidUser': true,
            'SubscriptionPackageCode': 'TCACA_code_002_abc',
            'Packages': [
              {
                'PackageCode': 'TCACA_code_007_nzdH5h4Nl0',
                'CycleTotalCapacity': '8121',
                'CycleRemainCapacity': '5297.64000115',
                'CycleUsedCapacity': '2823.35999885',
                'Status': 0,
              },
              {
                'PackageCode': 'TCACA_code_008_free',
                'CycleTotalCapacity': '600',
                'CycleRemainCapacity': '600',
                'CycleUsedCapacity': '0',
                'Status': 0,
              },
            ],
          },
        },
        nowSec: 1700000000,
      );

      expect(quota.edition, CodeBuddyEdition.pro);
      expect(quota.subscriptionPackageName, '专业版 Pro');
      expect(quota.totalCredits, closeTo(8721.0, 1e-4));
      expect(quota.remainingCredits, closeTo(5897.64000115, 1e-4));
      expect(quota.packages.length, 2);
      expect(quota.pillCreditsLabel, '剩余 5,897.6 积分');
      expect(quota.summaryLabel, '剩余 5,897.6 / 8,721 积分');

      final unlimited = CodeBuddyQuotaService.parseEnterpriseUsageResponse(
        {
          'code': 0,
          'data': {'limitNum': -1, 'credit': 128.5},
        },
        nowSec: 1700000000,
      );
      expect(unlimited.unlimited, isTrue);
      expect(unlimited.pillCreditsLabel, '不限积分');
    },
  );

  test(
    'adds API Key accounts, switches active account, and exports/imports JSON',
    () async {
      final cnAcc = await store.addApiKeyAccount(
        apiKey: 'cbk-cn-secret-123456',
        region: CodeBuddyRegion.cn,
        nickname: '腾讯国内账号',
      );
      expect(store.accounts.length, 1);
      expect(store.currentAccount?.id, cnAcc.id);
      expect(
        cnAcc.processEnvironment(),
        allOf(
          containsPair('CODEBUDDY_API_KEY', 'cbk-cn-secret-123456'),
          containsPair('CODEBUDDY_INTERNET_ENVIRONMENT', 'internal'),
          containsPair('ACC_USER_NICKNAME', '腾讯国内账号'),
        ),
      );

      final globalAcc = await store.addApiKeyAccount(
        apiKey: 'cbk-ai-secret-999888',
        region: CodeBuddyRegion.global,
        nickname: 'Global AI Account',
        baseUrl: 'https://www.codebuddy.ai/v1',
      );
      expect(store.accounts.length, 2);
      expect(store.currentAccount?.id, globalAcc.id);
      expect(
        globalAcc.processEnvironment(),
        allOf(
          containsPair('CODEBUDDY_API_KEY', 'cbk-ai-secret-999888'),
          containsPair('CODEBUDDY_BASE_URL', 'https://www.codebuddy.ai/v1'),
          isNot(contains('CODEBUDDY_INTERNET_ENVIRONMENT')),
        ),
      );

      await store.switchAccount(cnAcc.id);
      expect(store.currentAccount?.id, cnAcc.id);
      await store.setCustomLabel(cnAcc.id, '主力研发号');
      expect(store.currentAccount?.displayName, '主力研发号');

      final exported = store.exportAccountsJson();
      final otherDir = await Directory.systemTemp.createTemp('cyte_cbc_import_');
      addTearDown(() async {
        if (otherDir.existsSync()) await otherDir.delete(recursive: true);
      });
      final other = CodeBuddyAccounts(dataDir: otherDir.path);
      final count = await other.importAccountsJson(exported);
      expect(count, 2);
      expect(other.accounts.length, 2);
    },
  );

  test(
    'recordTurnUsage decrements remainingCredits immediately, persists TurnStats credits, and auto-switches on quota exhaustion',
    () async {
      var cn1 = await store.addApiKeyAccount(
        apiKey: 'cbk-cn-111111',
        region: CodeBuddyRegion.cn,
        nickname: 'CN-1',
      );
      cn1 = await store.upsertAccount(
        cn1.copyWith(
          quota: const CodeBuddyQuotaData(
            edition: CodeBuddyEdition.pro,
            totalCredits: 1000.0,
            remainingCredits: 500.0,
            usedCredits: 500.0,
            lastUpdated: 1700000000,
          ),
        ),
      );
      final global1 = await store.addApiKeyAccount(
        apiKey: 'cbk-gl-222222',
        region: CodeBuddyRegion.global,
        nickname: 'GL-1',
      );
      final cn2 = await store.addApiKeyAccount(
        apiKey: 'cbk-cn-333333',
        region: CodeBuddyRegion.cn,
        nickname: 'CN-2',
      );
      expect(global1.region, CodeBuddyRegion.global);

      await store.switchAccount(cn1.id);
      await store.setAutoSwitch(
        const CodeBuddyAutoSwitchConfig(enabled: true, preferSameRegion: true),
      );

      await store.recordTurnUsage(credits: 1.25, tokens: 4200);
      expect(store.currentAccount?.id, cn1.id);
      expect(
        store.currentAccount?.quota?.sessionCreditsUsed,
        closeTo(1.25, 1e-6),
      );
      expect(
        store.currentAccount?.quota?.remainingCredits,
        closeTo(498.75, 1e-6),
      );
      expect(store.currentAccount?.quota?.totalTokensUsed, 4200);
      expect(store.currentAccount?.quota?.turnCount, 1);

      // Verify TurnStats round-trips per-turn credits cleanly
      final encoded = TurnStats.encode(
        'turn-1',
        (
          worked: const Duration(milliseconds: 2400),
          usage: store.currentAccount?.quota == null
              ? null
              : TurnStats.decode([
                  '{"turn":"t0","workedMs":2400,"inputTokens":3000,"outputTokens":400,"credits":1.25}',
                ])['t0']?.usage,
        ),
      );
      final decoded = TurnStats.decode([encoded]);
      expect(decoded['turn-1']?.usage?.credits, closeTo(1.25, 1e-6));

      // Exhaust CN-1 -> should prefer CN-2 (same region) over GL-1!
      await store.recordTurnUsage(
        credits: 0.5,
        tokens: 800,
        quotaExhausted: true,
      );
      expect(store.currentAccount?.id, cn2.id);
    },
  );
}
