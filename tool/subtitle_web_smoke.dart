import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_overlay.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:anime/src/player/subtitles/supplemental_subtitle_controller.dart';
import 'package:anime/src/player/web_stream_player.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../test/fixtures/subtitle_video_fixture.dart';

// Local-only QA entry point; uses generated video and an in-memory store.
// flutter build web --debug --no-pub -t tool/subtitle_web_smoke.dart
void main() => runApp(const MaterialApp(home: SubtitleWebSmoke()));

class SubtitleWebSmoke extends StatefulWidget {
  const SubtitleWebSmoke({super.key});
  @override
  State<SubtitleWebSmoke> createState() => _SubtitleWebSmokeState();
}

class _SubtitleWebSmokeState extends State<SubtitleWebSmoke> {
  final captions = SupplementalSubtitleController(SubtitleStore());
  final playback = WebStreamPlayerController();
  Duration position = Duration.zero;
  bool ready = false;
  bool failed = false;
  String status = 'RUNNING';
  @override
  void initState() {
    super.initState();
    captions.bind(
      subject: 'test:1',
      episode: 'test:1:1',
      line: 'web',
      originalLanguage: 'en',
    );
    unawaited(runChecks());
  }

  Future<void> until(bool Function() condition, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!condition() && !failed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (failed || !condition()) throw StateError(reason);
  }

  void check(bool condition, String reason) {
    if (!condition) throw StateError(reason);
  }

  Future<void> runChecks() async {
    try {
      await captions.selectDocument(
        parseSubtitle(
          Uint8List.fromList(
            utf8.encode(
              '1\n00:00:00,000 --> 00:00:05,000\nOriginal first\n\n'
              '2\n00:00:05,000 --> 00:00:12,000\nOriginal second',
            ),
          ),
          'fixture.en.srt',
          'en',
        ),
        expectedGeneration: captions.generation,
      );
      await until(
        () => ready && position > Duration.zero,
        'first video time event',
      );
      final video = web.document.querySelector('video') as web.HTMLVideoElement;
      final chinese = video.addTextTrack('subtitles', '简中', 'zh');
      chinese.addCue(web.VTTCue(0, 12, '片源原有中文字幕'));
      chinese.mode = 'showing';
      await until(
        () => captions.textAt(position) == 'Original first',
        'first cue',
      );
      playback.seek(const Duration(seconds: 7));
      await until(() => captions.textAt(position) == 'Original second', 'seek');
      playback.pause();
      await until(() => video.paused, 'pause');
      final pausedAt = video.currentTime;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      check((video.currentTime - pausedAt).abs() < .05, 'paused timeline');
      check(video.playbackRate == 1.5, 'playback rate');
      await captions.setBilingual(true);
      check(captions.textAt(position).isEmpty, 'bilingual suppression');
      check(
        chinese.mode == 'showing' && chinese.cues?.length == 1,
        'original track preserved',
      );
      await captions.setBilingual(false);
      await captions.adjustDelay(3000);
      check(
        captions.textAt(position) == 'Original first',
        'delay follows media position',
      );
      check(chinese.mode == 'showing', 'original track still preserved');
      web.document.title = 'SUBTITLE_WEB_QA_PASS';
      setState(
        () => status =
            'PASS · decode / Chinese track / seek / pause / rate / bilingual / delay',
      );
    } catch (error) {
      web.document.title = 'SUBTITLE_WEB_QA_FAIL';
      if (mounted) setState(() => status = 'FAIL: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff18313a),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(status, style: const TextStyle(color: Colors.white)),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                WebStreamPlayer(
                  url: subtitleVideoDataUri,
                  controller: playback,
                  playing: true,
                  volume: 0,
                  position: position,
                  rate: 1.5,
                  onReady: () => ready = true,
                  onError: () => failed = true,
                  onPosition: (value) {
                    if (mounted) setState(() => position = value);
                  },
                ),
                SupplementalSubtitleOverlay(
                  controller: captions,
                  position: position,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    captions.dispose();
    super.dispose();
  }
}
