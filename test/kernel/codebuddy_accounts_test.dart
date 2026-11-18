import 'dart:io';

import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
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

  test('CodeBuddyRegion maps wire names andCODEBUDDY_INTERNET_ENVIRONMENT accurately', () {
    expect(CodeBuddyRegion.cn.internetEnvironment, 'internal');
    expect(CodeBuddyRegion.global.internetEnvironment, isNull);
    expect(CodeBuddyRegion.ioa.internetEnvironment, 'ioa');
    expect(CodeBuddyRegion.cloudhosted.internetEnvironment, 'cloudhosted');
    expect(CodeBuddyRegion.selfhosted.internetEnvironment, 'selfhosted');

    expect(CodeBuddyRegion.fromDomain('https://www.codebuddy.ai'), CodeBuddyRegion.global);
    expect(CodeBuddyRegion.fromDomain('https://copilot.tencent.com'), CodeBuddyRegion.cn);
    expect(CodeBuddyRegion.fromDomain('https://tencent.sso.copilot.tencent.com'), CodeBuddyRegion.ioa);
  });

  test('adds API Key accounts, switches active account, and exports/imports JSON', () async {
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

    // Switch back to CN account and customize label
    await store.switchAccount(cnAcc.id);
    expect(store.currentAccount?.id, cnAcc.id);
    await store.setCustomLabel(cnAcc.id, '主力研发号');
    expect(store.currentAccount?.displayName, '主力研发号');

    // Export & import into a fresh store
    final exported = store.exportAccountsJson();
    final otherDir = await Directory.systemTemp.createTemp('cyte_cbc_import_');
    addTearDown(() async {
      if (otherDir.existsSync()) await otherDir.delete(recursive: true);
    });
    final other = CodeBuddyAccounts(dataDir: otherDir.path);
    final count = await other.importAccountsJson(exported);
    expect(count, 2);
    expect(other.accounts.length, 2);
  });

  test('recordTurnUsage tracks credits/tokens and auto-switches on quota exhaustion', () async {
    final cn1 = await store.addApiKeyAccount(
      apiKey: 'cbk-cn-111111',
      region: CodeBuddyRegion.cn,
      nickname: 'CN-1',
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
    expect(store.currentAccount?.quota?.sessionCreditsUsed, closeTo(1.25, 1e-6));
    expect(store.currentAccount?.quota?.totalTokensUsed, 4200);
    expect(store.currentAccount?.quota?.turnCount, 1);

    // Exhaust CN-1 -> should prefer CN-2 (same region) over GL-1!
    await store.recordTurnUsage(credits: 0.5, tokens: 800, quotaExhausted: true);
    expect(store.currentAccount?.id, cn2.id);
  });
}
