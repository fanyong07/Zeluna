import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;

const maxSubtitleBytes = 5 * 1024 * 1024;
const subtitleExtensions = ['srt', 'ass', 'ssa', 'vtt'];

class SubtitleFileException implements Exception {
  const SubtitleFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SubtitleCue {
  const SubtitleCue(this.startMs, this.endMs, this.text);
  final int startMs;
  final int endMs;
  final String text;
  Map<String, Object> toJson() => {
    'start': startMs,
    'end': endMs,
    'text': text,
  };
}

/// An immutable, bounded text timeline. It never controls the player's track.
class SubtitleDocument {
  SubtitleDocument({
    required this.hash,
    required this.fileName,
    required this.language,
    required List<SubtitleCue> cues,
  }) : cues = List.unmodifiable(cues) {
    var end = 0;
    _maxEnds = this.cues
        .map((cue) {
          if (cue.endMs > end) end = cue.endMs;
          return end;
        })
        .toList(growable: false);
  }
  final String hash;
  final String fileName;
  final String language;
  final List<SubtitleCue> cues;
  late final List<int> _maxEnds;

  /// Positive delay means display later. Seek/rate/pause use media time only.
  String textAt(Duration position, {int delayMs = 0}) {
    final time = position.inMilliseconds - delayMs;
    var low = 0;
    var high = cues.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (cues[mid].startMs <= time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final active = <String>[];
    for (var i = low - 1; i >= 0 && _maxEnds[i] > time; i--) {
      final cue = cues[i];
      if (cue.endMs > time && !active.contains(cue.text)) active.add(cue.text);
      if (active.length == 8) break;
    }
    return active.reversed.join('\n');
  }

  Map<String, Object> toJson() => {
    'hash': hash,
    'fileName': fileName,
    'language': language,
    'cues': cues.map((cue) => cue.toJson()).toList(),
  };
  static SubtitleDocument? fromJson(Object? value) {
    if (value is! Map || value['cues'] is! List) return null;
    try {
      final rows = value['cues'] as List;
      if (rows.isEmpty || rows.length > 50000) return null;
      final cues = rows
          .map(
            (row) => SubtitleCue(
              row['start'] as int,
              row['end'] as int,
              row['text'] as String,
            ),
          )
          .toList();
      if (cues.any(
        (c) => c.startMs < 0 || c.endMs <= c.startMs || c.text.length > 10000,
      )) {
        return null;
      }
      cues.sort((a, b) => a.startMs.compareTo(b.startMs));
      return SubtitleDocument(
        hash: value['hash'] as String,
        fileName: value['fileName'] as String,
        language: value['language'] as String,
        cues: cues,
      );
    } catch (_) {
      return null;
    }
  }
}

SubtitleDocument parseSubtitle(
  Uint8List bytes,
  String fileName,
  String language,
) {
  final ext = fileName.split('.').last.toLowerCase();
  if (!subtitleExtensions.contains(ext)) {
    throw const SubtitleFileException('请选择 SRT、ASS、SSA 或 VTT 文件；压缩包请先解压');
  }
  if (bytes.isEmpty || bytes.length > maxSubtitleBytes) {
    throw const SubtitleFileException('字幕文件为空或超过 5 MB');
  }
  final text = _decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.contains('\u0000')) throw const SubtitleFileException('这不是可读取的文本字幕');
  final cues = ext == 'ass' || ext == 'ssa'
      ? _parseAss(text)
      : _parseTimedText(text);
  if (cues.isEmpty) throw const SubtitleFileException('没有读取到有效对白和时间轴，请检查字幕文件');
  if (cues.length > 50000) {
    throw const SubtitleFileException('字幕条目过多，请选择普通文本字幕');
  }
  cues.sort((a, b) => a.startMs.compareTo(b.startMs));
  return SubtitleDocument(
    hash: sha256.convert(bytes).toString(),
    fileName: fileName.split(RegExp(r'[/\\]')).last,
    language: language,
    cues: cues,
  );
}

String _decode(Uint8List bytes) {
  try {
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      if ((bytes.length - 2).isOdd) throw const FormatException();
      final data = ByteData.sublistView(bytes);
      final endian = bytes[0] == 255 ? Endian.little : Endian.big;
      return String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian),
      ]);
    }
    return utf8
        .decode(bytes, allowMalformed: false)
        .replaceFirst(RegExp('^\uFEFF'), '');
  } catch (_) {
    throw const SubtitleFileException('字幕编码无法识别，请将文件另存为 UTF-8 后导入');
  }
}

int? _time(String raw) {
  final m = RegExp(
    r'^(?:(\d{1,3}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final h = int.parse(m[1] ?? '0');
  final min = int.parse(m[2]!);
  final sec = int.parse(m[3]!);
  if (min > 59 || sec > 59) return null;
  return ((h * 60 + min) * 60 + sec) * 1000 + int.parse(m[4]!.padRight(3, '0'));
}

void _append(List<SubtitleCue> cues, int? start, int? end, String text) {
  text = text.trim();
  if (start == null || end == null || end <= start || text.isEmpty) return;
  if (text.length > 10000) throw const SubtitleFileException('字幕单条内容过长');
  cues.add(SubtitleCue(start, end, text));
}

List<SubtitleCue> _parseTimedText(String text) {
  final cues = <SubtitleCue>[];
  for (final block in text.split(RegExp(r'\n[ \t]*\n'))) {
    final lines = block.split('\n');
    if (lines.first.trim().startsWith('NOTE') ||
        lines.first.trim() == 'STYLE' ||
        lines.first.trim() == 'REGION') {
      continue;
    }
    final index = lines.indexWhere((line) => line.contains('-->'));
    if (index < 0) continue;
    final times = lines[index].split('-->');
    if (times.length != 2) continue;
    final body = lines
        .skip(index + 1)
        .join('\n')
        .replaceAll(RegExp(r'<(?:\d{2}:)?\d{2}:\d{2}\.\d{3}>'), '')
        .replaceAll(RegExp(r'</?(?:v|c|lang)(?:[. ][^>]*)?>'), '');
    _append(
      cues,
      _time(times[0]),
      _time(times[1].trim().split(RegExp(r'\s+')).first),
      html.parseFragment(body).text ?? '',
    );
  }
  return cues;
}

List<SubtitleCue> _parseAss(String text) {
  final cues = <SubtitleCue>[];
  var inEvents = false;
  var fields = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inEvents = line.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;
    if (line.toLowerCase().startsWith('format:')) {
      fields = line
          .substring(7)
          .split(',')
          .map((s) => s.trim().toLowerCase())
          .toList();
    } else if (line.toLowerCase().startsWith('dialogue:') &&
        fields.isNotEmpty) {
      // ASS/SSA text is the last field and may itself contain commas.
      if (fields.last != 'text') continue;
      final parts = line.substring(9).split(',');
      if (parts.length < fields.length) continue;
      final start = fields.indexOf('start');
      final end = fields.indexOf('end');
      if (start < 0 || end < 0) continue;
      final body = parts.skip(fields.length - 1).join(',');
      if (RegExp(r'\\p[1-9]').hasMatch(body)) continue; // drawing, not dialogue
      final plain = body
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', ' ');
      _append(cues, _time(parts[start]), _time(parts[end]), plain);
    }
  }
  return cues;
}

String suggestedSubtitleLanguage(String originalLanguage) {
  final lang = originalLanguage.trim().toLowerCase();
  if (lang == 'ja' ||
      lang.startsWith('ja-') ||
      lang.contains('日语') ||
      lang.contains('日本語')) {
    return 'ja';
  }
  if (lang == 'en' ||
      lang.startsWith('en-') ||
      lang.contains('英语') ||
      lang.contains('英文')) {
    return 'en';
  }
  return 'zh-Hans';
}
