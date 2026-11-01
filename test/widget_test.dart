import 'package:aiyue_music/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Import keeps selection across search results', (tester) async {
    List<LocalTrack>? imported;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                imported = await showDialog<List<LocalTrack>>(
                  context: context,
                  builder: (_) => const TrackImportDialog(
                    tracks: [
                      LocalTrack('/a.mp3', 'a.mp3'),
                      LocalTrack('/b.mp3', 'b.mp3'),
                      LocalTrack('/c.mp3', 'c.mp3'),
                    ],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('a.mp3'));
    await tester.enterText(find.byType(TextField), 'b.mp3');
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选搜索结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 2 首'));
    await tester.pumpAndSettle();
    expect(imported!.map((t) => t.name), ['a.mp3', 'b.mp3']);
  });
  testWidgets('Library opens as a bottom sheet and mode uses a toast', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MusicApp());
    await tester.pump();
    expect(find.text('0 首 · 内部曲库'), findsOneWidget);
    expect(find.text('播放列表'), findsNothing);
    await tester.tap(find.byTooltip('全部循环'));
    await tester.pump();
    expect(find.text('单曲循环'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byTooltip('打开播放列表'));
    await tester.pumpAndSettle();
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('导入音乐文件夹'), findsOneWidget);
    expect(find.byTooltip('关闭播放列表'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭播放列表'));
    await tester.pumpAndSettle();
    expect(find.text('播放列表'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
