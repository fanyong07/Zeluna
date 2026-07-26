final RegExp _hanTextPattern = RegExp(r'[\u3400-\u9fff]');
final RegExp _kanaTextPattern = RegExp(
  r'[\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fd-\u30ff'
  r'\u31f0-\u31ff\uff66-\uff9d]',
);
final RegExp _hangulTextPattern = RegExp(
  r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]',
);
final RegExp _placeholderPunctuationPattern = RegExp(
  r'[\s。.!！?？,，:：;；、·…_\-]+',
);

const _metadataPlaceholders = <String>{
  '暂无简介',
  '暂无中文简介',
  '暂无资料',
  '暂无中文资料',
  '简介待补充',
  '内容资料正在完善',
  '角色资料待bangumi返回',
};

bool isMetadataPlaceholder(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    _placeholderPunctuationPattern,
    '',
  );
  return normalized.isEmpty || _metadataPlaceholders.contains(normalized);
}

/// Whether [value] is suitable for a Chinese title field.
///
/// A Han character alone is not enough: Japanese titles commonly contain
/// Kanji as well. Kana or Hangul therefore disqualifies a title from being
/// used as a Chinese localization.
bool isLikelyChineseTitle(String value) {
  final text = value.trim();
  return text.isNotEmpty &&
      !isMetadataPlaceholder(text) &&
      _hanTextPattern.hasMatch(text) &&
      !_kanaTextPattern.hasMatch(text) &&
      !_hangulTextPattern.hasMatch(text);
}

/// Whether [value] is suitable for a Chinese description.
///
/// Chinese descriptions may quote a short Japanese title, so a very small
/// amount of kana is accepted only when the surrounding Chinese text clearly
/// dominates. This still rejects normal Japanese summaries.
bool isLikelyChineseText(String value) {
  final text = value.trim();
  if (text.isEmpty || isMetadataPlaceholder(text)) return false;
  final hanCount = _hanTextPattern.allMatches(text).length;
  if (hanCount == 0 || _hangulTextPattern.hasMatch(text)) return false;
  final kanaCount = _kanaTextPattern.allMatches(text).length;
  return kanaCount == 0 || (hanCount >= 12 && hanCount >= kanaCount * 4);
}

String? verifiedChineseText(String? value, {bool title = false}) {
  final text = value?.trim() ?? '';
  final valid = title ? isLikelyChineseTitle(text) : isLikelyChineseText(text);
  return valid ? text : null;
}
