import 'dart:io';

import 'package:anime/src/accounts/local_account_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local accounts hash passwords and support login and password changes',
    () async {
      final root = await Directory.systemTemp.createTemp('anime-accounts-');
      Hive.init(root.path);
      final box = await Hive.openBox<dynamic>(LocalAccountRepository.boxName);
      final repository = LocalAccountRepository(box);
      addTearDown(() async {
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final account = await repository.beginRegistration(
        email: '  USER@Example.com ',
        nickname: '星野',
        password: 'correct-password',
        importGuestData: true,
      );

      expect(account.email, 'user@example.com');
      expect(repository.currentAccount(), isNull);
      expect(repository.pendingRegistration()?.account.id, account.id);
      await repository.completeRegistration(account.id);
      expect(repository.pendingRegistration()?.account.id, account.id);
      await repository.setActiveAccount(account.id);
      await repository.finalizeRegistration(account.id);
      expect(repository.currentAccount()?.id, account.id);
      expect(repository.listAccounts(), hasLength(1));
      final stored = box.get('account.${account.id}') as Map;
      expect(stored['passwordAlgorithm'], 'pbkdf2-hmac-sha256');
      expect(stored['passwordHash'], isNot('correct-password'));
      expect(stored['passwordSalt'], isNotEmpty);
      expect(stored.toString(), isNot(contains('correct-password')));

      await repository.signOut();
      expect(repository.currentAccount(), isNull);
      await expectLater(
        repository.login(email: account.email, password: 'wrong-password'),
        throwsA(
          isA<AccountException>().having(
            (error) => error.message,
            'message',
            '邮箱或密码不正确',
          ),
        ),
      );

      final loggedIn = await repository.login(
        email: account.email,
        password: 'correct-password',
      );
      expect(loggedIn.id, account.id);
      expect(repository.currentAccount(), isNull);
      await repository.setActiveAccount(loggedIn.id);
      expect(repository.currentAccount()?.id, account.id);

      await repository.changePassword(
        accountId: account.id,
        currentPassword: 'correct-password',
        newPassword: 'new-correct-password',
      );
      await repository.signOut();
      await expectLater(
        repository.login(email: account.email, password: 'correct-password'),
        throwsA(isA<AccountException>()),
      );
      expect(
        (await repository.login(
          email: account.email,
          password: 'new-correct-password',
        )).id,
        account.id,
      );

      await repository.deleteAccount(
        accountId: account.id,
        password: 'new-correct-password',
      );
      expect(repository.currentAccount(), isNull);
      expect(repository.listAccounts(), isEmpty);
    },
  );

  test(
    'local accounts validate identity fields and reject duplicate email',
    () async {
      final root = await Directory.systemTemp.createTemp('anime-accounts-');
      Hive.init(root.path);
      final box = await Hive.openBox<dynamic>(LocalAccountRepository.boxName);
      final repository = LocalAccountRepository(box);
      addTearDown(() async {
        await Hive.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      await expectLater(
        repository.beginRegistration(
          email: 'not-an-email',
          nickname: '星野',
          password: 'correct-password',
          importGuestData: false,
        ),
        throwsA(isA<AccountException>()),
      );
      final account = await repository.beginRegistration(
        email: 'user@example.com',
        nickname: '星野',
        password: 'correct-password',
        importGuestData: false,
      );
      await repository.completeRegistration(account.id);
      await expectLater(
        repository.beginRegistration(
          email: 'USER@example.com',
          nickname: '另一位用户',
          password: 'another-password',
          importGuestData: false,
        ),
        throwsA(
          isA<AccountException>().having(
            (error) => error.message,
            'message',
            '这个邮箱已经注册过了',
          ),
        ),
      );
    },
  );
}
