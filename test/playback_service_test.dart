import 'package:aiyue_music/playback_service.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'System controls expose seeking and delegate track navigation',
    () async {
      final handler = MusicPlaybackService();
      var next = 0, previous = 0;
      handler.next = () async {
        next++;
      };
      handler.previous = () async {
        previous++;
      };
      handler.broadcast();
      expect(handler.playbackState.value.controls, contains(MediaControl.play));
      expect(
        handler.playbackState.value.systemActions,
        contains(MediaAction.seek),
      );
      await handler.skipToNext();
      await handler.skipToPrevious();
      expect(next, 1);
      expect(previous, 1);
      await handler.player.dispose();
    },
  );
}
