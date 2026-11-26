import 'package:anime/src/rules/drpy_runtime_models.dart';
import 'package:anime/src/rules/drpy_runtime_stub.dart';
import 'package:anime/src/rules/rule_playback_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'DRPY unsupported-platform API accepts cancellation and scope reset',
    () async {
      final storage = DrpyLocalStorage()..replace('fixture', {'seen': 1});
      final runtime = DrpyRuntime(storage: storage);
      runtime.resetExecutionScope();
      expect(storage.debugSnapshot, isEmpty);
      final token = RulePlaybackCancellationToken()..cancel();
      final result = await runtime.resolve(
        const DrpyRuntimeRequest(
          ruleId: 'fixture',
          keyword: 'Fixture',
          episodeNumber: 1,
          episodeTitle: '',
        ),
        cancellationToken: token,
      );
      expect(result.candidates, isEmpty);
      expect(result.error, contains('only available'));
    },
  );
}
