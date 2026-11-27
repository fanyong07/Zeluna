import 'dart:io';

import 'package:flutter/services.dart';

class ExternalPlayerApp {
  const ExternalPlayerApp({
    required this.id,
    required this.name,
    required this.executablePath,
  });
  final String id, name, executablePath;
}

bool isExternalMediaUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.isScheme('http') || uri.isScheme('https')) &&
      uri.host.isNotEmpty;
}

Future<bool> launchAndroidExternalPlayer({
  required String url,
  String? title,
}) async {
  if (!isExternalMediaUrl(url)) return false;
  try {
    return await const MethodChannel(
          'app.anime.anime/external-player',
        ).invokeMethod<bool>('openVideoUrl', {'url': url, 'title': title}) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

const _players = [
  (id: 'mpv', name: 'mpv', paths: [r'mpv\mpv.exe']),
  (
    id: 'potplayer',
    name: 'PotPlayer',
    paths: [
      r'DAUM\PotPlayer\PotPlayerMini64.exe',
      r'DAUM\PotPlayer\PotPlayer64.exe',
    ],
  ),
  (id: 'vlc', name: 'VLC', paths: [r'VideoLAN\VLC\vlc.exe']),
];

Future<List<ExternalPlayerApp>> detectWindowsExternalPlayers() async {
  if (!Platform.isWindows) return const [];
  final env = Platform.environment;
  final paths = (env['PATH'] ?? '')
      .split(';')
      .map((p) => p.trim().replaceAll('"', ''))
      .where((p) => Directory(p).isAbsolute);
  final roots = [
    env['ProgramFiles'],
    env['ProgramFiles(x86)'],
    if (env['LOCALAPPDATA'] case final String local) '$local\\Programs',
  ].whereType<String>();
  final found = <ExternalPlayerApp>[];
  for (final player in _players) {
    final candidates = {
      for (final root in roots)
        for (final relative in player.paths) '$root\\$relative',
      for (final dir in paths)
        for (final relative in player.paths)
          '$dir\\${relative.split('\\').last}',
    };
    for (final path in candidates) {
      if (await File(path).exists()) {
        found.add(
          ExternalPlayerApp(
            id: player.id,
            name: player.name,
            executablePath: path,
          ),
        );
        break;
      }
    }
  }
  return found;
}

Future<bool> launchWindowsExternalPlayer(
  ExternalPlayerApp app, {
  required String url,
}) async {
  if (!Platform.isWindows || !isExternalMediaUrl(url)) return false;
  final file = File(app.executablePath);
  if (!file.isAbsolute) return false;
  final name = file.uri.pathSegments.last.toLowerCase();
  final known = _players.any(
    (p) =>
        p.id == app.id &&
        p.paths.any((path) => path.split('\\').last.toLowerCase() == name),
  );
  if (!known || !await file.exists()) return false;
  try {
    await Process.start(file.path, [url], mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}
