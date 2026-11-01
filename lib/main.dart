import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'playback_service.dart';
import 'bilibili_import.dart';
part 'track_import_dialog.dart';
part 'equalizer_panel.dart';

MusicPlaybackService? playbackService;

const lime = Color(0xffd9fb52), muted = Color(0xff999584);

class LocalTrack {
  const LocalTrack(this.path, this.name, {this.source});
  final String path;
  final String name;
  final String? source;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    playbackService = await AudioService.init(
      builder: MusicPlaybackService.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.aiyue.music.playback',
        androidNotificationChannelName: '爱悦音乐播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
    await playbackService!.configureSession();
  }
  runApp(const MusicApp());
}

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '爱悦音乐',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff13120f),
      colorScheme: const ColorScheme.dark(
        primary: lime,
        surface: Color(0xff25231c),
      ),
      fontFamily: 'PingFang SC',
    ),
    home: const PlayerPage(),
  );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final player = playbackService?.player ?? AudioPlayer();
  final search = TextEditingController();
  final subs = <StreamSubscription<dynamic>>[];
  static const folders = MethodChannel('aiyue/folders');
  List<LocalTrack> tracks = [];
  List<LocalTrack> library = [];
  Set<String> favorites = {};
  String? folder;
  String? androidFolderName;
  int current = -1, token = 0;
  bool scanning = false, searching = false, showingLibrary = false;
  double speed = 1;
  int playbackMode = 0;
  Duration position = Duration.zero, duration = Duration.zero;
  Timer? timer;
  Timer? toastTimer;
  OverlayEntry? toastEntry;
  Future<Uri?>? _artworkUri;
  int sleepMinutes = 0;
  String get title => current < 0 ? '让喜欢的音乐，留在身边' : tracks[current].name;
  @override
  void initState() {
    super.initState();
    playbackService?.next = () async => next();
    playbackService?.previous = () async => next(previous: true);
    _requestNotificationPermission();
    subs.add(
      player.positionStream.listen((v) {
        if (mounted) setState(() => position = v);
      }),
    );
    subs.add(
      player.durationStream.listen((v) {
        if (mounted) setState(() => duration = v ?? Duration.zero);
      }),
    );
    subs.add(
      player.playerStateStream.listen((v) {
        if (!mounted) return;
        setState(() {});
        if (v.processingState == ProcessingState.completed &&
            playbackMode != 1) {
          next();
        }
      }),
    );
    restore();
  }

  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final granted = await folders.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      if (granted == false) {
        message('请允许通知权限，以便显示锁屏播放控制');
      }
    } catch (_) {
      // Older Android versions and tests do not require notification access.
    }
  }

  Future<Uri?> _lockScreenArtwork() => _artworkUri ??= () async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/lock_screen_cover.jpg');
      if (!await file.exists()) {
        final data = await rootBundle.load('assets/night.jpg');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return file.uri;
    } catch (_) {
      return null;
    }
  }();

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => favorites = (prefs.getStringList('favorites') ?? []).toSet(),
    );
    final restoredLibrary = <LocalTrack>[];
    for (final value in prefs.getStringList('libraryTracks') ?? <String>[]) {
      try {
        final item = jsonDecode(value) as Map;
        final path = item['path'] as String;
        if (await File(path).exists()) {
          restoredLibrary.add(
            LocalTrack(
              path,
              item['name'] as String,
              source: item['source'] as String?,
            ),
          );
        }
      } catch (_) {
        /* Ignore invalid saved entries. */
      }
    }
    // Migrate B站 songs saved by versions before the internal library existed.
    if (restoredLibrary.isEmpty) {
      for (final value in prefs.getStringList('bilibiliTracks') ?? <String>[]) {
        try {
          final item = jsonDecode(value) as Map;
          final path = item['path'] as String;
          if (await File(path).exists()) {
            restoredLibrary.add(
              LocalTrack(path, item['name'] as String, source: path),
            );
          }
        } catch (_) {
          /* Ignore invalid legacy entries. */
        }
      }
    }
    if (!mounted) return;
    if (restoredLibrary.isNotEmpty) {
      final playlistPaths = prefs.getStringList('playlistTracks')?.toSet();
      setState(() {
        library = restoredLibrary;
        tracks = playlistPaths == null
            ? [...restoredLibrary]
            : restoredLibrary
                  .where((track) => playlistPaths.contains(track.path))
                  .toList();
      });
      await _saveCollections();
      return;
    }
    final saved = prefs.getString('folder');
    if (Platform.isAndroid) {
      final uri = prefs.getString('androidFolderUri');
      if (uri != null && mounted) {
        await androidFolder(uri: uri, restoring: true);
      }
      return;
    }
    if (saved != null && await Directory(saved).exists() && mounted) {
      await scan(saved, restoring: true);
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _saveCollections() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'libraryTracks',
      library
          .map(
            (track) => jsonEncode({
              'path': track.path,
              'name': track.name,
              'source': track.source,
            }),
          )
          .toList(),
    );
    await prefs.setStringList(
      'playlistTracks',
      tracks.map((track) => track.path).toList(),
    );
  }

  Future<List<LocalTrack>> _copyToInternalLibrary(
    List<LocalTrack> selected,
  ) async {
    final result = <LocalTrack>[];
    final pending = <LocalTrack>[];
    for (final track in selected) {
      final source = track.source ?? track.path;
      final existing = library
          .where((item) => item.source == source)
          .firstOrNull;
      if (existing != null) {
        result.add(existing);
      } else {
        pending.add(track);
      }
    }
    if (pending.isEmpty) return result;
    if (Platform.isAndroid &&
        pending.any((track) => track.path.startsWith('content://'))) {
      final copied = await folders.invokeListMethod<dynamic>('copyTracks', {
        'tracks': pending
            .map((track) => {'uri': track.path, 'name': track.name})
            .toList(),
      });
      for (final value in copied ?? const []) {
        final item = Map<String, dynamic>.from(value as Map);
        result.add(
          LocalTrack(
            item['path'] as String,
            item['name'] as String,
            source: item['source'] as String,
          ),
        );
      }
      return result;
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/music_library');
    await directory.create(recursive: true);
    for (final track in pending) {
      final source = track.source ?? track.path;
      if (track.path.startsWith(support.path)) {
        result.add(LocalTrack(track.path, track.name, source: source));
        continue;
      }
      final stem = p
          .basenameWithoutExtension(track.name)
          .replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]+'), '_');
      final suffix = source.hashCode.toUnsigned(32).toRadixString(16);
      final destination = File('${directory.path}/${stem}_$suffix.mp3');
      if (!await destination.exists()) {
        await File(track.path).copy(destination.path);
      }
      result.add(LocalTrack(destination.path, track.name, source: source));
    }
    return result;
  }

  Future<void> _addToLibraryAndPlaylist(List<LocalTrack> selected) async {
    final imported = await _copyToInternalLibrary(selected);
    if (!mounted) return;
    setState(() {
      for (final track in imported) {
        if (!library.any((item) => item.path == track.path)) library.add(track);
        if (!tracks.any((item) => item.path == track.path)) tracks.add(track);
      }
    });
    await _saveCollections();
  }

  void changePlaybackMode() {
    setState(() => playbackMode = (playbackMode + 1) % 3);
    player.setLoopMode(playbackMode == 1 ? LoopMode.one : LoopMode.off);
    showToast(['全部循环', '单曲循环', '乱序播放'][playbackMode]);
  }

  void showToast(String text) {
    toastTimer?.cancel();
    toastEntry?.remove();
    toastEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: 24,
        right: 24,
        bottom: MediaQuery.paddingOf(context).bottom + 72,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: const Color(0xee35332c),
              borderRadius: BorderRadius.circular(22),
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Text(text, style: const TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(toastEntry!);
    toastTimer = Timer(const Duration(milliseconds: 1600), () {
      toastEntry?.remove();
      toastEntry = null;
    });
  }

  void openCollectionSheet({bool searchImmediately = false}) {
    if (searchImmediately) searching = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, updateSheet) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: SizedBox(
            width: double.infinity,
            child: Material(
              color: const Color(0xff181713),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xff5a574d),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭播放列表',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    fit: FlexFit.loose,
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        14,
                        0,
                        14,
                        20 + MediaQuery.viewPaddingOf(context).bottom,
                      ),
                      child: playlist(sheetSetState: updateSheet),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> importFolder() async {
    if (Platform.isAndroid) {
      await androidFolder();
      return;
    }
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: '选择 MP3 音乐文件夹',
      );
      if (path != null && mounted) await scan(path);
    } catch (e) {
      message('无法打开文件夹：$e');
    }
  }

  Future<void> importBilibili() async {
    final input = TextEditingController();
    final importer = BilibiliImporter();
    BilibiliImporter.log('Import dialog opened');
    BilibiliVideo? video;
    var busy = false;
    var status = '';
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) {
            return PopScope(
              canPop: !busy,
              child: AlertDialog(
                title: const Text('从 B站导入 MP3'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: input,
                        enabled: !busy,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: '粘贴 b23.tv 链接或完整分享文字',
                        ),
                        onChanged: (_) => update(() {
                          video = null;
                          status = '';
                        }),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '仅导入你有权下载的音频。多分P链接导入指定P，默认第1P。',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      if (video != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(video!.title),
                        ),
                      if (status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(status),
                        ),
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(dialogContext),
                    child: const Text('关闭'),
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            update(() {
                              busy = true;
                              status = video == null ? '正在解析链接…' : '正在获取音轨…';
                            });
                            try {
                              if (video == null) {
                                final resolved = await importer.resolve(
                                  input.text.trim(),
                                );
                                update(() {
                                  video = resolved;
                                  status = '请确认视频后导入';
                                });
                              } else {
                                final selected = video!;
                                final path = await importer.download(
                                  selected,
                                  (text) => update(() => status = text),
                                );
                                final track = LocalTrack(
                                  path,
                                  '${selected.title}.mp3',
                                  source: path,
                                );
                                await _addToLibraryAndPlaylist([track]);
                                update(() => status = '已导入曲库，可离线播放');
                              }
                            } catch (e, stackTrace) {
                              BilibiliImporter.log(
                                'UI import action failed',
                                error: e,
                                stackTrace: stackTrace,
                              );
                              update(
                                () => status =
                                    '导入失败：${e is FormatException ? e.message : e}',
                              );
                            } finally {
                              update(() => busy = false);
                            }
                          },
                    child: Text(video == null ? '解析链接' : '下载并导入'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      importer.close();
      input.dispose();
    }
  }

  Future<void> scan(String path, {bool restoring = false}) async {
    if (Platform.isAndroid) {
      await androidFolder(uri: path, restoring: restoring);
      return;
    }
    if (scanning) return;
    setState(() => scanning = true);
    try {
      final found = <LocalTrack>[];
      await for (final entity in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File &&
            p.extension(entity.path).toLowerCase() == '.mp3') {
          found.add(LocalTrack(entity.path, p.basename(entity.path)));
        }
      }
      found.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      final selected = await chooseTracks(found, restoring: restoring);
      if (selected == null || !mounted) return;
      token++;
      await player.stop();
      if (!mounted) return;
      setState(() {
        folder = path;
      });
      await _addToLibraryAndPlaylist(selected);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('folder', path);
      await prefs.setStringList(
        'selectedTracks',
        selected.map((t) => t.path).toList(),
      );
      if (!restoring) message('已导入 ${selected.length} 首 MP3');
    } catch (e) {
      message('扫描失败，请检查文件夹权限：$e');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<void> androidFolder({String? uri, bool restoring = false}) async {
    if (scanning) return;
    setState(() => scanning = true);
    try {
      final result = await folders.invokeMapMethod<String, dynamic>(
        uri == null ? 'pick' : 'scan',
        uri == null ? null : {'uri': uri},
      );
      if (result == null || !mounted) return;
      final found = (result['tracks'] as List).map((value) {
        final item = Map<String, dynamic>.from(value as Map);
        return LocalTrack(item['path'] as String, item['name'] as String);
      }).toList();
      final selected = await chooseTracks(found, restoring: restoring);
      if (selected == null || !mounted) return;
      token++;
      await player.stop();
      if (!mounted) return;
      setState(() {
        folder = result['uri'] as String;
        androidFolderName = result['name'] as String;
      });
      await _addToLibraryAndPlaylist(selected);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('androidFolderUri', result['uri'] as String);
      await prefs.setStringList(
        'selectedTracks',
        selected.map((t) => t.path).toList(),
      );
      if (!restoring) message('已导入 ${selected.length} 首 MP3');
    } on PlatformException catch (e) {
      message(e.message ?? '文件夹访问失败，请重新选择文件夹授权');
    } catch (e) {
      message('导入失败：$e');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<List<LocalTrack>?> chooseTracks(
    List<LocalTrack> found, {
    required bool restoring,
  }) async {
    if (restoring) {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('selectedTracks')?.toSet();
      return saved == null
          ? found
          : found.where((t) => saved.contains(t.path)).toList();
    }
    if (!mounted) return null;
    if (found.isEmpty) {
      message('所选文件夹及子文件夹中没有 MP3 文件');
      return null;
    }
    return showDialog<List<LocalTrack>>(
      context: context,
      builder: (_) => TrackImportDialog(tracks: found),
    );
  }

  Future<void> playTrack(int index) async {
    if (index < 0 || index >= tracks.length) return;
    final request = ++token;
    setState(() {
      current = index;
      position = Duration.zero;
      duration = Duration.zero;
    });
    final artwork = await _lockScreenArtwork();
    if (!mounted || request != token) return;
    playbackService?.mediaItem.add(
      MediaItem(
        id: tracks[index].path,
        title: tracks[index].name,
        album:
            androidFolderName ??
            (folder == null ? '本地音乐' : p.basename(folder!)),
        artist: '爱悦 · 本地音乐',
        artUri: artwork,
      ),
    );
    try {
      final path = tracks[index].path;
      if (path.startsWith('content://')) {
        await player.setAudioSource(AudioSource.uri(Uri.parse(path)));
      } else {
        await player.setFilePath(path);
      }
      if (!mounted || request != token) return;
      await playbackService?.restoreEqualizer();
      await player.setSpeed(speed);
      startPlayback();
    } catch (e) {
      if (request == token) message('无法播放此文件：$e');
    }
  }

  void startPlayback() {
    unawaited(
      player.play().catchError((Object e) {
        message('播放失败：$e');
      }),
    );
  }

  void next({bool previous = false}) {
    if (tracks.isEmpty) return;
    if (playbackMode == 2 && tracks.length > 1) {
      var index = Random().nextInt(tracks.length - 1);
      if (index >= current) index++;
      playTrack(index);
    } else {
      final target = current + (previous ? -1 : 1);
      playTrack((target + tracks.length) % tracks.length);
    }
  }

  Future<void> favorite() async {
    if (current < 0) return;
    final path = tracks[current].path;
    setState(() {
      favorites.contains(path) ? favorites.remove(path) : favorites.add(path);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', favorites.toList());
  }

  void sheet(String title, List<Widget> children) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    ),
  );
  void speeds() => sheet(
    '播放速度',
    [.75, 1.0, 1.25, 1.5, 2.0]
        .map(
          (v) => ListTile(
            title: Text('${v}x'),
            trailing: v == speed ? const Icon(Icons.check, color: lime) : null,
            onTap: () {
              setState(() => speed = v);
              player.setSpeed(v);
              Navigator.pop(context);
            },
          ),
        )
        .toList(),
  );
  void sleep() => sheet(
    '定时停止',
    [0, 15, 30, 45, 60]
        .map(
          (v) => ListTile(
            title: Text(v == 0 ? '关闭定时' : '$v 分钟后停止'),
            onTap: () {
              timer?.cancel();
              setState(() => sleepMinutes = v);
              if (v > 0) {
                timer = Timer(Duration(minutes: v), () {
                  player.pause();
                  if (mounted) setState(() => sleepMinutes = 0);
                });
              }
              Navigator.pop(context);
            },
          ),
        )
        .toList(),
  );
  String clock(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  Widget icon(
    IconData glyph,
    VoidCallback? action, {
    bool active = false,
    String? tip,
  }) => IconButton(
    tooltip: tip,
    onPressed: action,
    icon: Icon(glyph, size: 28, color: active ? lime : null),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: LayoutBuilder(
            builder: (context, size) {
              final wide = size.maxWidth > 800;
              final panel = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  cover(),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 27,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: Text(
                          '${speed}x',
                          style: const TextStyle(color: lime),
                        ),
                        onPressed: speeds,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    current < 0 ? '本地音乐 · 无需上传，自由聆听' : 'MP3 · 本地音频',
                    style: const TextStyle(color: muted, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  Slider(
                    value: position.inMilliseconds.toDouble().clamp(
                      0,
                      max(1, duration.inMilliseconds).toDouble(),
                    ),
                    max: max(1, duration.inMilliseconds).toDouble(),
                    onChanged: current < 0
                        ? null
                        : (v) => player.seek(Duration(milliseconds: v.round())),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(clock(position)),
                      Text(
                        '-${clock(duration > position ? duration - position : Duration.zero)}',
                        style: const TextStyle(color: muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      icon(
                        switch (playbackMode) {
                          1 => Icons.repeat_one,
                          2 => Icons.shuffle,
                          _ => Icons.repeat,
                        },
                        changePlaybackMode,
                        active: true,
                        tip: ['全部循环', '单曲循环', '乱序播放'][playbackMode],
                      ),
                      icon(
                        Icons.skip_previous_rounded,
                        tracks.isEmpty ? null : () => next(previous: true),
                        tip: '上一首',
                      ),
                      SizedBox(
                        width: 86,
                        height: 86,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                          ),
                          onPressed: tracks.isEmpty
                              ? importFolder
                              : () {
                                  if (current < 0) {
                                    playTrack(0);
                                  } else if (player.playing) {
                                    player.pause();
                                  } else {
                                    if (player.processingState ==
                                        ProcessingState.completed) {
                                      player.seek(Duration.zero);
                                    }
                                    startPlayback();
                                  }
                                },
                          child: Icon(
                            player.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 46,
                            color: const Color(0xff17180c),
                          ),
                        ),
                      ),
                      icon(
                        Icons.skip_next_rounded,
                        tracks.isEmpty ? null : () => next(),
                        tip: '下一首',
                      ),
                      icon(
                        Icons.queue_music,
                        openCollectionSheet,
                        tip: '打开播放列表',
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: openEqualizer,
                      icon: const Icon(Icons.tune, size: 19),
                      label: const Text('均衡器'),
                    ),
                  ),
                  Row(
                    children: [
                      tool(Icons.speed, '倍速', speeds),
                      const SizedBox(width: 8),
                      tool(
                        Icons.timer_outlined,
                        sleepMinutes == 0 ? '定时' : '$sleepMinutes分',
                        sleep,
                      ),
                      const SizedBox(width: 8),
                      tool(Icons.queue_music, '列表', openCollectionSheet),
                      const SizedBox(width: 8),
                      tool(
                        Icons.folder_open,
                        '文件夹',
                        scanning ? null : importFolder,
                      ),
                    ],
                  ),
                ],
              );
              return SingleChildScrollView(
                padding: EdgeInsets.all(wide ? 32 : 22),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(
                            color: Color(0xff27251e),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.music_note, color: lime),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                androidFolderName ??
                                    folder ??
                                    'YOUR OFFLINE COLLECTION',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 12,
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${library.length} 首 · 内部曲库',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        icon(
                          Icons.search,
                          () => openCollectionSheet(searchImmediately: true),
                          tip: '搜索歌曲',
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_horiz),
                          onSelected: (v) {
                            if (v == 'import') importFolder();
                            if (v == 'bilibili') importBilibili();
                            if (v == 'scan' && folder != null) scan(folder!);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'bilibili',
                              child: Text('从 B站导入 MP3'),
                            ),
                            const PopupMenuItem(
                              value: 'import',
                              child: Text('导入文件夹'),
                            ),
                            if (folder != null)
                              const PopupMenuItem(
                                value: 'scan',
                                child: Text('重新扫描'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(width: wide ? 520 : null, child: panel),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      '爱悦 MUSIC / 为每一段独处配乐',
                      style: TextStyle(
                        color: muted,
                        fontSize: 10,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  Widget tool(IconData glyph, String label, VoidCallback? action) => Expanded(
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        side: const BorderSide(color: Color(0xff3c392e)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      onPressed: action,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(glyph, size: 17, color: const Color(0xffe6dfc8)),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(color: Color(0xffe6dfc8), fontSize: 12),
          ),
        ],
      ),
    ),
  );
  Widget cover() => AspectRatio(
    aspectRatio: 1,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/night.jpg',
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) => Container(
              color: const Color(0xff14262c),
              child: const Icon(Icons.graphic_eq, size: 100, color: lime),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black26, Colors.transparent, Colors.black87],
              ),
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                '● MP3 / LOCAL',
                style: TextStyle(color: lime, fontSize: 12, letterSpacing: 1),
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: icon(
              current >= 0 && favorites.contains(tracks[current].path)
                  ? Icons.favorite
                  : Icons.favorite_border,
              current < 0 ? null : favorite,
              active: current >= 0 && favorites.contains(tracks[current].path),
              tip: '收藏歌曲',
            ),
          ),
          const Positioned(
            left: 24,
            bottom: 74,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'THE NIGHT',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                Text(
                  'IS YOURS.',
                  style: TextStyle(
                    fontSize: 36,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: lime,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 20,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: const BoxDecoration(
                    color: lime,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.graphic_eq,
                    color: Colors.black,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text('MP3 · 私人音乐收藏', style: TextStyle(fontSize: 13)),
                ),
                const Text('本地', style: TextStyle(color: muted)),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _removeFromPlaylist(LocalTrack track) async {
    final playingPath = current >= 0 && current < tracks.length
        ? tracks[current].path
        : null;
    if (playingPath == track.path) {
      token++;
      await player.stop();
    }
    if (!mounted) return;
    setState(() {
      tracks.removeWhere((item) => item.path == track.path);
      current = playingPath == track.path
          ? -1
          : tracks.indexWhere((item) => item.path == playingPath);
      if (current < 0) {
        position = Duration.zero;
        duration = Duration.zero;
      }
    });
    await _saveCollections();
    message('已从播放列表移除，内部文件仍保留');
  }

  Future<void> _pinTrack(LocalTrack track) async {
    final playingPath = current >= 0 && current < tracks.length
        ? tracks[current].path
        : null;
    setState(() {
      tracks.removeWhere((item) => item.path == track.path);
      tracks.insert(0, track);
      current = tracks.indexWhere((item) => item.path == playingPath);
    });
    await _saveCollections();
    message('已置顶');
  }

  Future<void> _addToPlaylist(LocalTrack track) async {
    if (tracks.any((item) => item.path == track.path)) {
      message('歌曲已在播放列表中');
      return;
    }
    setState(() => tracks.add(track));
    await _saveCollections();
    message('已添加到播放列表');
  }

  Future<void> _deleteFromLibrary(LocalTrack track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从内部曲库删除？'),
        content: Text('“${track.name}”将从播放列表和 App 内部存储中永久删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final playingPath = current >= 0 && current < tracks.length
        ? tracks[current].path
        : null;
    if (playingPath == track.path) {
      token++;
      await player.stop();
    }
    try {
      final file = File(track.path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      message('文件删除失败：$error');
      return;
    }
    if (!mounted) return;
    setState(() {
      library.removeWhere((item) => item.path == track.path);
      tracks.removeWhere((item) => item.path == track.path);
      favorites.remove(track.path);
      current = tracks.indexWhere((item) => item.path == playingPath);
      if (current < 0) {
        position = Duration.zero;
        duration = Duration.zero;
      }
    });
    await _saveCollections();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', favorites.toList());
    message('已从内部曲库和存储空间删除');
  }

  Widget playlist({StateSetter? sheetSetState}) {
    final items = showingLibrary ? library : tracks;
    final indices = List.generate(items.length, (i) => i)
        .where(
          (i) =>
              items[i].name.toLowerCase().contains(search.text.toLowerCase()),
        )
        .toList();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xff222019),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xff353229)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(17),
            child: Row(
              children: [
                Icon(
                  showingLibrary ? Icons.library_music : Icons.queue_music,
                  size: 21,
                  color: muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('播放列表')),
                      ButtonSegment(value: true, label: Text('内部曲库')),
                    ],
                    selected: {showingLibrary},
                    onSelectionChanged: (value) {
                      setState(() => showingLibrary = value.first);
                      sheetSetState?.call(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
          if (searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: search,
                onChanged: (_) {
                  setState(() {});
                  sheetSetState?.call(() {});
                },
                decoration: const InputDecoration(
                  hintText: '搜索文件名…',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
              ),
            ),
          if (scanning)
            const Padding(
              padding: EdgeInsets.all(36),
              child: CircularProgressIndicator(),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  const Icon(
                    Icons.library_music_outlined,
                    size: 42,
                    color: muted,
                  ),
                  const SizedBox(height: 14),
                  const Text('把你的音乐带到这里', style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text(
                    '选择本地文件夹，自动查找其中的 MP3\n包含子文件夹中的音乐',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, height: 1.8),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: importFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('导入音乐文件夹'),
                  ),
                  TextButton.icon(
                    onPressed: importBilibili,
                    icon: const Icon(Icons.link),
                    label: const Text('从 B站分享链接导入'),
                  ),
                ],
              ),
            )
          else if (indices.isEmpty)
            const Padding(padding: EdgeInsets.all(30), child: Text('没有找到匹配的歌曲'))
          else
            ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: indices.length,
              itemBuilder: (context, row) {
                final index = indices[row];
                final track = items[index];
                final playlistIndex = tracks.indexWhere(
                  (item) => item.path == track.path,
                );
                final selected = playlistIndex >= 0 && current == playlistIndex;
                return Container(
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xff2b2c1c) : null,
                    border: const Border(
                      top: BorderSide(color: Color(0xff333026)),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 5,
                    ),
                    leading: Text(
                      '${index + 1}'.padLeft(2, '0'),
                      style: TextStyle(color: selected ? lime : muted),
                    ),
                    title: Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? lime : const Color(0xffece8dc),
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Text(
                      selected && duration > Duration.zero
                          ? 'MP3 · ${clock(duration)}'
                          : 'MP3 · 本地文件',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                    trailing: PopupMenuButton<String>(
                      icon: Icon(
                        selected ? Icons.graphic_eq : Icons.more_vert,
                        color: selected ? lime : muted,
                      ),
                      onSelected: (value) async {
                        if (value == 'pin') await _pinTrack(track);
                        if (value == 'remove') {
                          await _removeFromPlaylist(track);
                        }
                        if (value == 'add') await _addToPlaylist(track);
                        if (value == 'delete') {
                          await _deleteFromLibrary(track);
                        }
                        sheetSetState?.call(() {});
                      },
                      itemBuilder: (_) => showingLibrary
                          ? [
                              if (playlistIndex < 0)
                                const PopupMenuItem(
                                  value: 'add',
                                  child: Text('添加到播放列表'),
                                ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('从内部曲库永久删除'),
                              ),
                            ]
                          : const [
                              PopupMenuItem(value: 'pin', child: Text('置顶')),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('从播放列表移除'),
                              ),
                            ],
                    ),
                    onTap: () async {
                      if (playlistIndex >= 0) {
                        playTrack(playlistIndex);
                      } else {
                        await _addToPlaylist(track);
                        playTrack(
                          tracks.indexWhere((item) => item.path == track.path),
                        );
                      }
                      sheetSetState?.call(() {});
                    },
                  ),
                );
              },
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: const Color(0xff26231b),
            child: Text(
              scanning
                  ? '正在扫描本地文件夹…'
                  : showingLibrary
                  ? '♫ 内部曲库 ${library.length} 首 · 删除会同时删除内部文件'
                  : '♫ 播放列表 ${tracks.length} 首 · 移除不会删除内部文件',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    toastTimer?.cancel();
    toastEntry?.remove();
    for (final s in subs) {
      s.cancel();
    }
    if (playbackService == null) player.dispose();
    playbackService?.next = null;
    playbackService?.previous = null;
    search.dispose();
    super.dispose();
  }
}
