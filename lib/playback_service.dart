import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MusicPlaybackService extends BaseAudioHandler with SeekHandler {
  MusicPlaybackService() {
    player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: Platform.isAndroid ? [equalizer] : [],
      ),
    );
    player.playbackEventStream.listen(
      (event) => broadcast(),
      onError: (Object e, StackTrace s) {
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorCode: 1,
            errorMessage: e.toString(),
          ),
        );
      },
    );
    player.durationStream.listen((duration) {
      final item = mediaItem.value;
      if (item != null) mediaItem.add(item.copyWith(duration: duration));
    });
  }
  late final AudioPlayer player;
  final equalizer = AndroidEqualizer();
  Future<void> Function()? next;
  Future<void> Function()? previous;
  Future<void> configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  bool _eqRestored = false;
  Future<void> restoreEqualizer() async {
    if (!Platform.isAndroid || _eqRestored) return;
    try {
      final parameters = await equalizer.parameters.timeout(
        const Duration(seconds: 3),
      );
      final prefs = await SharedPreferences.getInstance();
      final gains = prefs.getStringList('eqGains') ?? [];
      for (var i = 0; i < parameters.bands.length && i < gains.length; i++) {
        await parameters.bands[i].setGain(
          (double.tryParse(gains[i]) ?? 0).clamp(
            parameters.minDecibels,
            parameters.maxDecibels,
          ),
        );
      }
      await equalizer.setEnabled(prefs.getBool('eqEnabled') ?? false);
      _eqRestored = true;
    } catch (_) {
      /* An unavailable effect must not prevent music playback. */
    }
  }

  void broadcast() {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          player.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: player.playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (player.processingState == ProcessingState.completed) {
      await player.seek(Duration.zero);
    }
    unawaited(
      player.play().catchError((Object error) {
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            playing: false,
            errorCode: 1,
            errorMessage: error.toString(),
          ),
        );
      }),
    );
  }

  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> skipToNext() async {
    await next?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await previous?.call();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }
}
