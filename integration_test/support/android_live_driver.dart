import 'package:integration_test/integration_test_driver.dart';

// Attach to an explicitly installed/running app with --use-existing-app.
// Never use flutter test for Android here: its teardown uninstalls the app.
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 4),
  writeResponseOnFailure: true,
);
