import 'package:anime/src/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('effective watch uses the earlier of 25 percent and ten minutes', () {
    expect(
      recommendationEffectiveWatchThreshold(const Duration(minutes: 24)),
      const Duration(minutes: 6),
    );
    expect(
      recommendationEffectiveWatchThreshold(const Duration(minutes: 60)),
      const Duration(minutes: 10),
    );
  });

  test('completion follows 90 percent or two minutes remaining', () {
    expect(
      recommendationPlaybackReachedCompletion(
        position: const Duration(minutes: 26),
        duration: const Duration(minutes: 30),
      ),
      isFalse,
    );
    expect(
      recommendationPlaybackReachedCompletion(
        position: const Duration(minutes: 27),
        duration: const Duration(minutes: 30),
      ),
      isTrue,
    );
    expect(
      recommendationPlaybackReachedCompletion(
        position: const Duration(minutes: 58),
        duration: const Duration(minutes: 60),
      ),
      isTrue,
    );
  });
}
