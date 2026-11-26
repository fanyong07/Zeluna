import 'package:flutter/material.dart';

import 'section_scaffold.dart';

/// Thin wrappers around the shared [EmptyState] / [ErrorState] so callers can
/// import one place for quiet empty and failure blocks.
///
/// Gallery pages use the default paper/charcoal styling. Player panels should
/// pass [onTheater] so ink stays on the fixed dark-room palette.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
    this.onTheater = false,
    this.compact = false,
  });

  final String title;
  final String? message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool onTheater;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      title: title,
      message: (message ?? '').trim().isEmpty ? ' ' : message!.trim(),
      compact: compact,
      onTheater: onTheater,
      action: actionLabel != null && onAction != null
          ? FilledButton(onPressed: onAction, child: Text(actionLabel!))
          : null,
    );
  }
}

class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    this.title = '出了点问题',
    required this.message,
    this.actionLabel = '重试',
    this.onAction,
    this.onTheater = false,
    this.compact = false,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool onTheater;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ErrorState(
      title: title,
      message: message,
      retryLabel: actionLabel ?? '重试',
      onRetry: onAction,
      compact: compact,
      onTheater: onTheater,
    );
  }
}
