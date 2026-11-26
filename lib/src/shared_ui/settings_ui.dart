import 'package:flutter/material.dart';

import 'app_design.dart';

/// Theme-aware building blocks for settings-style list pages.
///
/// These replace the private `_SettingsCard` / `_ActionRow` / `_SwitchRow`
/// copies that used to live in both the profile and settings pages with
/// hardcoded dark colors. Every color here resolves through the active
/// [ColorScheme] so the same page reads as paper in the light theme and warm
/// charcoal in the dark theme.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = scheme.outlineVariant.withValues(
      alpha: dark ? 0.55 : 0.78,
    );
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: borderColor, width: 0.75),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i != children.length - 1)
                Divider(
                  height: 1,
                  thickness: 0.6,
                  indent: 12,
                  endIndent: 12,
                  color: borderColor,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsDisclosure extends StatefulWidget {
  const SettingsDisclosure({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  State<SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<SettingsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = scheme.outlineVariant.withValues(
      alpha: dark ? 0.55 : 0.78,
    );
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: _expanded
              ? scheme.primary.withValues(alpha: 0.55)
              : borderColor,
          width: 0.75,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            key: ValueKey('settings_disclosure_${widget.title}'),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: _expanded
                          ? scheme.primary.withValues(alpha: 0.14)
                          : scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        widget.icon,
                        color: _expanded ? scheme.primary : scheme.onSurface,
                        size: 17,
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: AppMotion.quick,
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.quick,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    children: [
                      Divider(height: 1, thickness: 0.6, color: borderColor),
                      widget.child,
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({
    super.key,
    required this.title,
    this.subtitle,
    this.onTap,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: subtitle == null ? 58 : 72),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: scheme.onSurfaceVariant, size: 22),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsReadonlyRow extends StatelessWidget {
  const SettingsReadonlyRow({
    super.key,
    required this.title,
    required this.value,
  });

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 58),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum SettingsChoicePresentation { sheet, inline }

class SettingsChoiceRow<T> extends StatefulWidget {
  const SettingsChoiceRow({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.subtitle,
    this.descriptionOf,
    this.presentation = SettingsChoicePresentation.sheet,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<T> options;
  final String Function(T value) labelOf;

  /// Per-option explanation, shown under the option's label. Use it where the
  /// choice has real trade-offs the label cannot carry on its own.
  final String Function(T value)? descriptionOf;
  final ValueChanged<T> onChanged;
  final SettingsChoicePresentation presentation;

  @override
  State<SettingsChoiceRow<T>> createState() => _SettingsChoiceRowState<T>();
}

class _SettingsChoiceRowState<T> extends State<SettingsChoiceRow<T>> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inline = widget.presentation == SettingsChoicePresentation.inline;
    return Column(
      children: [
        InkWell(
          key: ValueKey('setting_choice_${widget.title}'),
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () {
            if (inline) {
              setState(() => _expanded = !_expanded);
            } else {
              _showChoiceSheet(context);
            }
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.subtitle == null ? 48 : 56,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Text(
                        widget.labelOf(widget.value),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: inline && _expanded ? 0.25 : 0,
                    duration: AppMotion.quick,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant,
                      size: 19,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (inline)
          AnimatedSize(
            duration: AppMotion.quick,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                    child: widget.descriptionOf == null
                        ? SizedBox(
                            width: double.infinity,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final option in widget.options)
                                  _InlineChoicePill(
                                    label: widget.labelOf(option),
                                    selected: option == widget.value,
                                    onTap: () {
                                      widget.onChanged(option);
                                      setState(() => _expanded = false);
                                    },
                                  ),
                              ],
                            ),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh.withValues(
                                alpha: 0.7,
                              ),
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Column(
                              children: [
                                for (
                                  var index = 0;
                                  index < widget.options.length;
                                  index++
                                ) ...[
                                  InkWell(
                                    onTap: () {
                                      widget.onChanged(widget.options[index]);
                                      setState(() => _expanded = false);
                                    },
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.sm,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  widget.labelOf(
                                                    widget.options[index],
                                                  ),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color:
                                                            widget.options[index] ==
                                                                widget.value
                                                            ? scheme.primary
                                                            : scheme.onSurface,
                                                        fontWeight:
                                                            widget.options[index] ==
                                                                widget.value
                                                            ? FontWeight.w700
                                                            : FontWeight.w500,
                                                      ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  widget.descriptionOf!(
                                                    widget.options[index],
                                                  ),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                        height: 1.4,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (widget.options[index] ==
                                              widget.value)
                                            Icon(
                                              Icons.check_rounded,
                                              size: 18,
                                              color: scheme.primary,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (index != widget.options.length - 1)
                                    Divider(
                                      height: 1,
                                      thickness: 0.6,
                                      color: scheme.outlineVariant.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }

  void _showChoiceSheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final describe = widget.descriptionOf;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final option in widget.options)
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  isThreeLine: describe != null,
                  title: Text(widget.labelOf(option)),
                  subtitle: describe == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            describe(option),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.45,
                                ),
                          ),
                        ),
                  trailing: option == widget.value
                      ? Icon(Icons.check, color: scheme.primary)
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onChanged(option);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _InlineChoicePill extends StatelessWidget {
  const _InlineChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected ? scheme.onPrimary : scheme.onSurface,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.48,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: enabled ? () => onChanged!(!value) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: subtitle == null ? 48 : 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Switch(
                  key: ValueKey('setting_switch_$title'),
                  value: value,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating "back" affordance shown near the bottom of secondary pages.
class BackPill extends StatelessWidget {
  const BackPill({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: onBack,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: AppShadows.elevated,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back, color: scheme.onSurfaceVariant, size: 24),
              Text(
                '返回',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
