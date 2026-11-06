import 'dart:convert';
import 'dart:io';

import 'package:anime/src/updates/app_update_models.dart';
import 'package:anime/src/updates/app_update_platform.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Native-only installer acceptance, exclusively in an ephemeral .qa package.
/// The host builds tiny signed QA APK fixtures, serves them on loopback, and
/// enables unknown-source permission only after observing the denied state.
/// No production update source, application data or installed package is touched.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'verified QA APK opens real Android system installer',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      const platform = AndroidAppUpdatePlatform();
      final environment = await platform.environment();
      expect(environment.packageName, 'app.anime.anime.qa');
      const candidateBuild = int.fromEnvironment(
        'ZELUNA_QA_UPDATE_BUILD',
        defaultValue: 88,
      );
      const candidateVersion = String.fromEnvironment(
        'ZELUNA_QA_UPDATE_VERSION',
        defaultValue: '1.3.2',
      );
      expect(
        environment.versionCode,
        lessThan(candidateBuild),
        reason:
            'Build the isolated host below the explicitly configured fixture build.',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Zeluna QA 更新验证'))),
        ),
      );
      final directory = await platform.downloadDirectory();
      expect(directory.path.endsWith('/cache/app_updates'), isTrue);
      expect(directory.availableBytes, greaterThan(1024 * 1024));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<(String, UpdateRelease)> fixture(String name) async {
        final response = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:18765/$name'),
        )).close();
        expect(response.statusCode, 200);
        final bytes = await response.fold<List<int>>(
          [],
          (value, part) => value..addAll(part),
        );
        expect(bytes.length, lessThan(1024 * 1024));
        final hash = sha256.convert(bytes).toString();
        final file = File('${directory.path}/app-$candidateBuild-$hash.apk');
        await file.writeAsBytes(bytes, flush: true);
        return (
          file.path,
          UpdateRelease(
            version: candidateVersion,
            buildNumber: candidateBuild,
            apkUri: Uri.parse('https://example.com/$name'),
            sha256: hash,
            bytes: bytes.length,
            notes: 'QA only',
          ),
        );
      }

      final valid = await fixture('candidate.apk');
      final wrongSigner = await fixture('wrong-signer.apk');
      final wrongPackage = await fixture('wrong-package.apk');
      final old = await fixture('old-version.apk');
      Future<void> expectCode(Future<void> future, String code) async =>
          expectLater(
            future,
            throwsA(
              isA<PlatformException>().having((e) => e.code, 'code', code),
            ),
          );
      await platform.verify(valid.$1, valid.$2);
      await expectCode(
        platform.verify(wrongSigner.$1, wrongSigner.$2),
        'update_signature_mismatch',
      );
      await expectCode(
        platform.verify(wrongPackage.$1, wrongPackage.$2),
        'update_package_mismatch',
      );
      await expectCode(
        platform.verify(old.$1, old.$2),
        'update_version_mismatch',
      );
      await expectCode(
        platform.verify('/sdcard/candidate.apk', valid.$2),
        'update_invalid_path',
      );
      final mutated = UpdateRelease(
        version: candidateVersion,
        buildNumber: candidateBuild,
        apkUri: valid.$2.apkUri,
        sha256: '0' * 64,
        bytes: valid.$2.bytes,
        notes: '',
      );
      await expectCode(
        platform.verify(valid.$1, mutated),
        'update_hash_mismatch',
      );
      final snapshot = await platform.environment();
      expect(
        snapshot.canRequestInstallPackages,
        isFalse,
        reason: 'Host starts QA appops denied',
      );
      expect(await platform.install(valid.$1, valid.$2), isFalse);
      expect(await platform.openInstallPermission(), isTrue);
      debugPrint('APP_UPDATE_QA_PERMISSION_WAIT');
      final end = DateTime.now().add(const Duration(seconds: 75));
      var allowed = false;
      while (DateTime.now().isBefore(end)) {
        allowed = (await platform.environment()).canRequestInstallPackages;
        if (allowed) break;
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(allowed, isTrue);
      expect(await platform.install(valid.$1, valid.$2), isTrue);
      final report = {
        'passed': true,
        'package': environment.packageName,
        'valid_native_verification': true,
        'wrong_signer_rejected': true,
        'wrong_package_rejected': true,
        'wrong_version_rejected': true,
        'wrong_hash_rejected': true,
        'outside_cache_rejected': true,
        'permission_required_then_granted': true,
        'system_installer_launched': true,
        'installation_confirmed': false,
      };
      binding.reportData = report;
      debugPrint('APP_UPDATE_QA ${jsonEncode(report)}');
      // Leave the real system installer onscreen for host UI capture. The host
      // cancels it; no fixture is silently installed by this test.
      await tester.pump(const Duration(seconds: 8));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
