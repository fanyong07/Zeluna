import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:anime/src/domain/anime_models.dart';
import 'package:anime/src/player/subtitles/subtitle_document.dart';
import 'package:anime/src/player/subtitles/subtitle_matching.dart';
import 'package:anime/src/player/subtitles/subtitle_store.dart';
import 'package:anime/src/player/subtitles/supplemental_subtitle_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
SubtitleDocument sample([String text = '日本語']) => parseSubtitle(
  bytes(
    '1\n00:00:01,000 --> 00:00:03,000\n$text\n\n2\n00:00:05,000 --> 00:00:06,000\nsecond',
  ),
  'show.01.srt',
  'ja',
);
AnimeEpisode episode(int n, {int? season, int? localNumber}) => AnimeEpisode(
  id: n,
  subjectId: 100,
  number: n,
  title: '',
  airdate: null,
  duration: '',
  description: '',
  seasonNumber: season,
  seasonEpisodeNumber: localNumber,
);

void main() {
  group('text parsing and media timeline', () {
    test('SRT retains languages and seek uses media time', () {
      final doc = sample('日本語\n简体中文');
      expect(doc.textAt(const Duration(milliseconds: 999)), '');
      expect(doc.textAt(const Duration(seconds: 1)), '日本語\n简体中文');
      expect(doc.textAt(const Duration(seconds: 3)), '');
      expect(doc.textAt(const Duration(seconds: 5)), 'second');
      expect(doc.textAt(const Duration(seconds: 2)), '日本語\n简体中文');
      expect(doc.textAt(const Duration(seconds: 1), delayMs: 500), '');
      expect(
        doc.textAt(const Duration(milliseconds: 1500), delayMs: 500),
        '日本語\n简体中文',
      );
      expect(
        doc.textAt(const Duration(milliseconds: 500), delayMs: -500),
        '日本語\n简体中文',
      );
    });
    test('overlapping, unsorted cues keep their own end time', () {
      final doc = parseSubtitle(
        bytes(
          '1\n00:00:02,000 --> 00:00:03,000\nshort\n\n2\n00:00:01,000 --> 00:00:09,000\nlong',
        ),
        'a.srt',
        'en',
      );
      expect(doc.textAt(const Duration(milliseconds: 2500)), 'long\nshort');
      expect(doc.textAt(const Duration(seconds: 4)), 'long');
    });
    test('ASS and SSA fields, commas, breaks, drawing exclusion', () {
      final doc = parseSubtitle(
        bytes(r'''[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.20,0:00:03.50,Default,,0,0,0,,{\b1}Hello, world\N你好
Comment: 0,0:00:01.20,0:00:03.50,Default,,0,0,0,,hidden
Dialogue: 0,0:00:01.20,0:00:03.50,Default,,0,0,0,,{\p1}m 0 0 l 100 100
'''),
        'test.ass',
        'en',
      );
      expect(doc.cues, hasLength(1));
      expect(doc.textAt(const Duration(seconds: 2)), 'Hello, world\n你好');
      final ssa = parseSubtitle(
        bytes(
          '[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,日本語',
        ),
        'a.ssa',
        'ja',
      );
      expect(ssa.cues.single.text, '日本語');
    });
    test('VTT settings, cue IDs, voices and HTML entities', () {
      final doc = parseSubtitle(
        bytes(
          'WEBVTT\n\nNOTE ignore\ncomment\n\ncue-id\n00:01.000 --> 00:03.000 align:start\n<v Speaker><b>Hello &amp; bye</b></v>',
        ),
        'a.vtt',
        'en',
      );
      expect(doc.cues.single.text, 'Hello & bye');
    });
    test('BOM, malformed encoding, unsupported and oversized files', () {
      final source = '1\n00:00:01,000 --> 00:00:02,000\n字幕';
      expect(
        parseSubtitle(
          Uint8List.fromList([239, 187, 191, ...bytes(source)]),
          'a.srt',
          'ja',
        ).cues.single.text,
        '字幕',
      );
      final utf16 = Uint8List.fromList([
        255,
        254,
        ...source.codeUnits.expand((v) => [v & 255, v >> 8]),
      ]);
      expect(parseSubtitle(utf16, 'a.srt', 'ja').cues.single.text, '字幕');
      expect(
        () => parseSubtitle(Uint8List.fromList([0x81, 0xFE]), 'a.srt', 'ja'),
        throwsA(isA<SubtitleFileException>()),
      );
      expect(
        () => parseSubtitle(bytes('test'), 'a.zip', 'ja'),
        throwsA(isA<SubtitleFileException>()),
      );
      expect(
        () => parseSubtitle(Uint8List(maxSubtitleBytes + 1), 'a.srt', 'ja'),
        throwsA(isA<SubtitleFileException>()),
      );
      expect(
        () => parseSubtitle(
          bytes('1\n00:00:04,000 --> 00:00:01,000\nx'),
          'a.srt',
          'ja',
        ),
        throwsA(isA<SubtitleFileException>()),
      );
      expect(
        () => parseSubtitle(bytes('<html>captcha</html>'), 'a.srt', 'ja'),
        throwsA(isA<SubtitleFileException>()),
      );
    });
    test('cache round trip and damaged cache rejection', () {
      expect(
        SubtitleDocument.fromJson(
          jsonDecode(jsonEncode(sample().toJson())),
        )!.textAt(const Duration(seconds: 2)),
        '日本語',
      );
      expect(
        SubtitleDocument.fromJson({
          'cues': [
            {'start': 1, 'end': 0, 'text': 'bad'},
          ],
        }),
        isNull,
      );
    });
    test('language defaults', () {
      expect(suggestedSubtitleLanguage('日语'), 'ja');
      expect(suggestedSubtitleLanguage('en-US'), 'en');
      expect(suggestedSubtitleLanguage('国语'), 'zh-Hans');
      expect(suggestedSubtitleLanguage(''), 'zh-Hans');
    });
  });
  group('filename suggestions', () {
    final episodes = [episode(1), episode(2), episode(3)];
    test('episodes, ranges and specials', () {
      expect(
        matchSubtitleFile(
          '[Group] Show - 02 [1080p].srt',
          episodes,
        ).episode?.number,
        2,
      );
      expect(matchSubtitleFile('Show EP03.ass', episodes).episode?.number, 3);
      expect(matchSubtitleFile('Show 第1集.srt', episodes).episode?.number, 1);
      expect(matchSubtitleFile('Show 01-02.srt', episodes).episode, isNull);
      expect(matchSubtitleFile('Show SP01.srt', episodes).episode, isNull);
      expect(matchSubtitleFile('Show NCOP01.srt', episodes).episode, isNull);
      expect(matchSubtitleFile('Show 2026.srt', episodes).episode, isNull);
    });
    test('missing season never defaults to S01', () {
      expect(matchSubtitleFile('Show S01E01.srt', episodes).episode, isNull);
      final mapped = [episode(13, season: 2, localNumber: 1)];
      expect(matchSubtitleFile('Show S02E01.srt', mapped).episode?.number, 13);
      expect(matchSubtitleFile('Show S01E01.srt', mapped).episode, isNull);
    });
    test('metadata round trips without renumbering stable identity', () {
      final original = episode(13, season: 2, localNumber: 1);
      final restored = AnimeEpisode.fromJson(
        original.toJson(subjectKey: 'bangumi:100'),
      );
      expect(restored.seasonNumber, 2);
      expect(restored.seasonEpisodeNumber, 1);
      expect(restored.number, 13);
      expect(
        restored.identityKey(subjectKey: 'bangumi:100'),
        original.identityKey(subjectKey: 'bangumi:100'),
      );
      expect(AnimeEpisode.fromJson(episode(1).toJson()).seasonNumber, isNull);
    });
  });
  group('session and account boundaries', () {
    void bind(
      SupplementalSubtitleController c, {
      String ep = 'ep1',
      String line = 'a',
    }) => c.bind(
      subject: 'work',
      episode: ep,
      line: line,
      originalLanguage: 'ja',
    );
    test(
      'opt in, per-line offsets, bilingual state, cache and disable',
      () async {
        final c = SupplementalSubtitleController(SubtitleStore());
        addTearDown(c.dispose);
        bind(c);
        expect(c.enabled, isFalse);
        await c.selectDocument(sample(), expectedGeneration: c.generation);
        await c.adjustDelay(500);
        expect(c.textAt(const Duration(milliseconds: 1100)), '');
        bind(c, line: 'b');
        expect(c.delayMs, 0);
        await c.setBilingual(true);
        expect(c.visible, isFalse);
        bind(c, line: 'a');
        expect(c.delayMs, 500);
        expect(c.visible, isTrue);
        bind(c, line: 'b');
        expect(c.bilingual, isTrue);
        await c.setBilingual(false);
        await c.setEnabled(false);
        expect(c.visible, isFalse);
        bind(c);
        expect(c.enabled, isFalse);
      },
    );
    test('source failures are visible but never leak across episodes', () {
      final c = SupplementalSubtitleController(SubtitleStore());
      addTearDown(c.dispose);
      bind(c);
      final generation = c.generation;
      c.reportSource('服务器尚未收录', expectedGeneration: generation);
      expect(c.sourceMessage, '服务器尚未收录');
      expect(c.enabled, isFalse);
      bind(c, ep: 'ep2');
      expect(c.sourceMessage, isNull);
      c.reportSource('上一集错误', expectedGeneration: generation);
      expect(c.sourceMessage, isNull);
    });
    test('stale results rejected after episode change and disposal', () async {
      final c = SupplementalSubtitleController(SubtitleStore());
      bind(c);
      final old = c.generation;
      bind(c, ep: 'ep2');
      expect(
        await c.selectDocument(sample(), expectedGeneration: old),
        isFalse,
      );
      expect(c.document, isNull);
      final current = c.generation;
      c.dispose();
      expect(
        await c.selectDocument(sample(), expectedGeneration: current),
        isFalse,
      );
    });
    test('late persistence cannot populate next episode', () async {
      final pending = Completer<void>();
      final c = SupplementalSubtitleController(
        SubtitleStore(persist: (_) => pending.future),
      );
      addTearDown(c.dispose);
      bind(c);
      final work = c.selectDocument(sample(), expectedGeneration: c.generation);
      await Future<void>.delayed(Duration.zero);
      bind(c, ep: 'ep2');
      pending.complete();
      expect(await work, isFalse);
      expect(c.document, isNull);
    });
    test('separate stores isolate accounts', () async {
      final a = SupplementalSubtitleController(SubtitleStore());
      final b = SupplementalSubtitleController(SubtitleStore());
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      bind(a);
      bind(b);
      await a.selectDocument(sample(), expectedGeneration: a.generation);
      await a.setBilingual(true);
      expect(b.document, isNull);
      expect(b.bilingual, isFalse);
      expect(b.enabled, isFalse);
      await a.clearCache();
      bind(a);
      expect(a.document, isNull);
    });
    test('next episode only reuses its own document', () async {
      final store = SubtitleStore();
      final c = SupplementalSubtitleController(store);
      addTearDown(c.dispose);
      bind(c);
      await c.selectDocument(sample('first'), expectedGeneration: c.generation);
      await store.bindDocument('ep2', sample('next'));
      bind(c, ep: 'ep2');
      expect(c.enabled, isTrue);
      expect(c.textAt(const Duration(seconds: 2)), 'next');
      bind(c, ep: 'ep3');
      expect(c.document, isNull);
    });
  });
}
