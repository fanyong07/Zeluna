import 'dart:convert';

import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/sleep_timer_controller.dart';
import 'package:anime/src/sync/cloud_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('旧设置、单番覆盖、清除和 JSON 往返', () {
    final old = PlaybackSettings.fromJson({'autoNext': false});
    expect(old.effectiveSkipFor('a'), const SkipTiming());
    const custom = SkipTiming(introSeconds: 26);
    final value = old
        .copyWith(skipIntroSeconds: 85, skipOutroSeconds: 40)
        .withSubjectSkip('a', custom);
    final read = PlaybackSettings.fromJson(
      jsonDecode(jsonEncode(value.toJson())),
    );
    expect(read.effectiveSkipFor('a'), custom);
    expect(read.effectiveSkipFor('a').hashCode, custom.hashCode);
    expect(
      read.effectiveSkipFor('b'),
      const SkipTiming(introSeconds: 85, outroSeconds: 40),
    );
    for (final removed in [null, const SkipTiming()]) {
      expect(
        read.withSubjectSkip('a', removed).effectiveSkipFor('a'),
        read.effectiveSkipFor('b'),
      );
    }
    final mutation = CloudSyncMutation.playbackSettings(
      mutationId: 'wave-1-test-playback',
      settings: value,
    );
    final synced = PlaybackSettings.fromJson(
      CloudSyncMutation.fromJson(mutation.toJson()).payload,
    );
    expect(synced.subjectSkipTimings, read.subjectSkipTimings);
    expect(synced.skipIntroSeconds, 85);
    expect(synced.skipOutroSeconds, 40);
    expect(read.autoNext, isFalse);
    expect(old.subjectSkipTimings, isEmpty);
  });

  test('持久化边界夹逼秒数，并保留最近修改的 200 部作品', () {
    final raw = {
      for (var i = 0; i < 210; i++)
        '$i': {'introSeconds': 450, 'outroSeconds': -9},
    };
    final read = PlaybackSettings.fromJson({
      'skipIntroSeconds': -2,
      'skipOutroSeconds': 500,
      'subjectSkipTimings': {...raw, 'bad': 42},
    });
    expect(
      read.effectiveSkipFor('missing'),
      const SkipTiming(outroSeconds: 300),
    );
    expect(read.subjectSkipTimings.length, 200);
    expect(read.subjectSkipTimings.keys.first, '10');
    expect(read.subjectSkipTimings['10'], const SkipTiming(introSeconds: 300));
    final updated = read
        .withSubjectSkip('10', const SkipTiming(introSeconds: 7))
        .withSubjectSkip('new', const SkipTiming(outroSeconds: 4));
    expect(updated.subjectSkipTimings.length, 200);
    expect(updated.subjectSkipTimings['11'], isNull);
    expect(updated.subjectSkipTimings['10']?.introSeconds, 7);
  });

  testWidgets('倒计时按实际时长触发一次；替换、取消和本集结束互斥', (tester) async {
    var triggers = 0;
    final timer = SleepTimerController(onTriggered: () => triggers++);
    addTearDown(timer.dispose);
    timer.startCountdown(const Duration(minutes: 30));
    await tester.pump(const Duration(minutes: 5, seconds: 50));
    expect(timer.badgeLabel, '24:10');
    expect(timer.remaining, const Duration(minutes: 24, seconds: 10));
    timer.startCountdown(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(triggers, 1);
    expect(timer.mode, SleepTimerMode.off);
    expect(timer.remaining, isNull);
    timer.startCountdown(const Duration(minutes: 15));
    timer.setOff();
    await tester.pump(const Duration(hours: 1));
    expect(triggers, 1);
    timer.startCountdown(const Duration(seconds: 1));
    timer.setEndOfEpisode();
    expect(timer.badgeLabel, '播完本集');
    expect(timer.consumeEndOfEpisode(), isTrue);
    expect(timer.isActive, isFalse);
    expect(timer.consumeEndOfEpisode(), isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(triggers, 1);
  });
}
