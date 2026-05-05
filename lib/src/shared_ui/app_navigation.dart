import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

void safeNavigateBack(BuildContext context, {String fallbackRoute = '/'}) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
    return;
  }
  GoRouter.of(context).go(fallbackRoute);
}
