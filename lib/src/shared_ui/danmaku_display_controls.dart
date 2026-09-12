import 'package:flutter/material.dart';

import '../domain/anime_models.dart';
import 'app_design.dart';

/// Shared controls for the player drawer and the full settings page.
/// Changes use the existing account-scoped settings persistence path.
class DanmakuDisplayControls extends StatelessWidget {
  const DanmakuDisplayControls({
    super.key,
    required this.settings,
    required this.onChanged,
    this.theater = false,
  });

  final DanmakuSettings settings;
  final Future<void> Function(DanmakuSettings) onChanged;
  final bool theater;

  Future<void> _save(BuildContext context, DanmakuSettings value) async {
    try {
      await onChanged(value);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('弹幕设置未保存，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ink = theater ? AppColors.theaterInk : colors.onSurface;
    final muted = theater ? AppColors.theaterMuted : colors.onSurfaceVariant;
    final accent = theater ? AppColors.primary2 : colors.primary;
    Widget slider(
      String label,
      String key,
      double value,
      double min,
      double max,
      int divisions,
      String valueLabel,
      DanmakuSettings Function(double) update,
    ) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: TextStyle(color: ink, fontSize: 13)),
              ),
              Text(valueLabel, style: TextStyle(color: muted, fontSize: 12)),
            ],
          ),
          SizedBox(
            height: 38,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                key: ValueKey(key),
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: accent,
                semanticFormatterCallback: (_) => '$label $valueLabel',
                onChanged: (v) => _save(context, update(v)),
              ),
            ),
          ),
        ],
      ),
    );
    Widget mode(String label, bool blocked, DanmakuSettings value) => Expanded(
      child: Semantics(
        toggled: blocked,
        child: OutlinedButton(
          key: ValueKey('danmakuBlock$label'),
          onPressed: () => _save(context, value),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 40),
            foregroundColor: blocked ? accent : ink,
            backgroundColor: blocked
                ? accent.withValues(alpha: .15)
                : Colors.transparent,
            side: BorderSide(
              color: blocked ? accent : muted.withValues(alpha: .35),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (blocked) ...[
                const Icon(Icons.check_rounded, size: 12),
                const SizedBox(width: 2),
              ],
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('playerDanmakuEnabled'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('显示弹幕', style: TextStyle(color: ink, fontSize: 14)),
            subtitle: Text(
              settings.enabled ? '即时生效，自动保存' : '已关闭，设置仍会保留',
              style: TextStyle(color: muted, fontSize: 11),
            ),
            value: settings.enabled,
            activeTrackColor: accent,
            onChanged: (v) => _save(context, settings.copyWith(enabled: v)),
          ),
          Divider(height: 16, color: muted.withValues(alpha: .2)),
          slider(
            '透明度',
            'danmakuOpacity',
            settings.opacity,
            .2,
            1,
            16,
            '${(settings.opacity * 100).round()}%',
            (v) => settings.copyWith(opacity: v),
          ),
          const SizedBox(height: 8),
          Text('显示区域', style: TextStyle(color: ink, fontSize: 13)),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final entry in <double, String>{
                  .25: '1/4屏',
                  .5: '半屏',
                  .75: '3/4屏',
                  1: '全屏',
                }.entries)
                  SizedBox(
                    width: (constraints.maxWidth - 15) / 4,
                    child: Semantics(
                      selected: (settings.displayArea - entry.key).abs() < .01,
                      child: OutlinedButton(
                        key: ValueKey('danmakuArea${entry.key}'),
                        onPressed: () => _save(
                          context,
                          settings.copyWith(displayArea: entry.key),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 36),
                          foregroundColor:
                              (settings.displayArea - entry.key).abs() < .01
                              ? accent
                              : ink,
                          backgroundColor:
                              (settings.displayArea - entry.key).abs() < .01
                              ? accent.withValues(alpha: .13)
                              : Colors.transparent,
                          side: BorderSide(
                            color:
                                (settings.displayArea - entry.key).abs() < .01
                                ? accent
                                : muted.withValues(alpha: .3),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        child: Text(
                          entry.value,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          slider(
            '字号',
            'danmakuFontSize',
            settings.fontSize,
            12,
            28,
            16,
            settings.fontSize.round().toString(),
            (v) => settings.copyWith(fontSize: v),
          ),
          slider(
            '速度',
            'danmakuSpeed',
            settings.speed,
            .5,
            2,
            6,
            '${settings.speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×',
            (v) => settings.copyWith(speed: v),
          ),
          const SizedBox(height: 8),
          Text('屏蔽类型', style: TextStyle(color: ink, fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            children: [
              mode(
                '滚动',
                settings.blockScroll,
                settings.copyWith(blockScroll: !settings.blockScroll),
              ),
              const SizedBox(width: 6),
              mode(
                '顶部',
                settings.blockTop,
                settings.copyWith(blockTop: !settings.blockTop),
              ),
              const SizedBox(width: 6),
              mode(
                '底部',
                settings.blockBottom,
                settings.copyWith(blockBottom: !settings.blockBottom),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('选中的类型将不再显示', style: TextStyle(color: muted, fontSize: 11)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('danmakuResetDisplay'),
              onPressed: () => _save(
                context,
                DanmakuSettings(
                  enabled: settings.enabled,
                  blockKeywords: settings.blockKeywords,
                ),
              ),
              child: const Text('恢复默认显示', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small visual switch with a separate 40px touch target beside the settings icon.
class DanmakuQuickSwitch extends StatelessWidget {
  const DanmakuQuickSwitch({
    super.key,
    required this.enabled,
    required this.onChanged,
  });
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final toggle = onChanged == null ? null : () => onChanged!(!enabled);
    final indicator = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 28,
      height: 16,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: enabled
            ? AppColors.primary2
            : AppColors.theaterMuted.withValues(alpha: .35),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 160),
        alignment: enabled ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
          ),
        ),
      ),
    );
    return Semantics(
      key: const ValueKey('playerDanmakuQuickToggle'),
      label: '弹幕开关',
      toggled: enabled,
      enabled: toggle != null,
      onTap: toggle,
      child: ExcludeSemantics(
        child: Tooltip(
          message: enabled ? '关闭弹幕' : '开启弹幕',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: toggle,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(child: indicator),
            ),
          ),
        ),
      ),
    );
  }
}
