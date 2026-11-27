import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/anime_controller.dart';

Future<bool> isUnmeteredNetwork({MethodChannel? channel}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    final status =
        channel ?? const MethodChannel('app.anime.anime/network-status');
    return await status.invokeMethod<bool>('isUnmetered') ?? true;
  } on MissingPluginException {
    return true;
  } on PlatformException {
    return true;
  }
}

final unmeteredNetworkCheckerProvider = Provider<Future<bool> Function()>(
  (ref) => isUnmeteredNetwork,
);

Future<bool> confirmDownloadNetwork(BuildContext context, WidgetRef ref) async {
  if (!ref.read(animeControllerProvider).requireValue.misc.wifiOnlyCache ||
      await ref.read(unmeteredNetworkCheckerProvider)()) {
    return true;
  }
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('当前不是 Wi-Fi 网络'),
          content: const Text('继续缓存可能消耗移动流量。仅本次允许，不会更改缓存设置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仅本次使用流量下载'),
            ),
          ],
        ),
      ) ??
      false;
}
