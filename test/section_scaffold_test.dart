import 'package:anime/src/app/app_theme.dart';
import 'package:anime/src/shared_ui/section_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SectionScaffold keeps expanded page content visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AnimeTheme.dark(),
        home: Scaffold(
          body: SectionScaffold(
            title: '番剧',
            subtitle: '在线资料与播放',
            actions: [
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'all', label: Text('全部')),
                      ButtonSegment(value: 'animation', label: Text('动画')),
                    ],
                    selected: const {'all'},
                  ),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    children: const [Text('孤独摇滚！'), Text('葬送的芙莉莲')],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('孤独摇滚！'), findsOneWidget);
  });
}
