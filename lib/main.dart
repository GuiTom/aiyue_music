import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'playback_service.dart';
part 'track_import_dialog.dart';
part 'equalizer_panel.dart';

MusicPlaybackService? playbackService;

const lime = Color(0xffd9fb52), muted = Color(0xff999584);

class LocalTrack {
  const LocalTrack(this.path, this.name);
  final String path;
  final String name;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    playbackService = await AudioService.init(
      builder: MusicPlaybackService.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.aiyue.music.playback',
        androidNotificationChannelName: '爱悦音乐播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
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
  Set<String> favorites = {};
  String? folder;
  String? androidFolderName;
  int current = -1, token = 0;
  bool scanning = false, searching = false, shuffle = false;
  double speed = 1;
  int repeat = 0;
  Duration position = Duration.zero, duration = Duration.zero;
  Timer? timer;
  int sleepMinutes = 0;
  String get title => current < 0 ? '让喜欢的音乐，留在身边' : tracks[current].name;
  @override
  void initState() {
    super.initState();
    playbackService?.next = () async => next();
    playbackService?.previous = () async => next(previous: true);
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
        if (v.processingState == ProcessingState.completed && repeat != 2) {
          next();
        }
      }),
    );
    restore();
  }

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => favorites = (prefs.getStringList('favorites') ?? []).toSet(),
    );
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
        tracks = selected;
        folder = path;
        current = -1;
        position = Duration.zero;
        duration = Duration.zero;
      });
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
        tracks = selected;
        folder = result['uri'] as String;
        androidFolderName = result['name'] as String;
        current = -1;
        position = Duration.zero;
        duration = Duration.zero;
      });
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
    playbackService?.mediaItem.add(
      MediaItem(
        id: tracks[index].path,
        title: tracks[index].name,
        album:
            androidFolderName ??
            (folder == null ? '本地音乐' : p.basename(folder!)),
        artist: '爱悦 · 本地音乐',
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
    if (shuffle && tracks.length > 1) {
      var index = Random().nextInt(tracks.length - 1);
      if (index >= current) index++;
      playTrack(index);
    } else {
      final target = current + (previous ? -1 : 1);
      if (target >= tracks.length && repeat == 0) {
        player.pause();
        return;
      }
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
                        Icons.shuffle,
                        () => setState(() => shuffle = !shuffle),
                        active: shuffle,
                        tip: '随机播放',
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
                        repeat == 2 ? Icons.repeat_one : Icons.repeat,
                        () {
                          setState(() => repeat = (repeat + 1) % 3);
                          player.setLoopMode(
                            repeat == 2 ? LoopMode.one : LoopMode.off,
                          );
                        },
                        active: repeat > 0,
                        tip: ['顺序播放', '列表循环', '单曲循环'][repeat],
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
                      tool(
                        Icons.queue_music,
                        '列表',
                        () => setState(() => searching = !searching),
                      ),
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
                                '${tracks.length} 首 · 本地文件夹',
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
                          () => setState(() => searching = !searching),
                          tip: '搜索歌曲',
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_horiz),
                          onSelected: (v) {
                            if (v == 'import') importFolder();
                            if (v == 'scan' && folder != null) scan(folder!);
                          },
                          itemBuilder: (_) => [
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
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: panel),
                          const SizedBox(width: 32),
                          Expanded(child: playlist()),
                        ],
                      )
                    else ...[
                      panel,
                      const SizedBox(height: 24),
                      playlist(),
                    ],
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
  Widget playlist() {
    final indices = List.generate(tracks.length, (i) => i)
        .where(
          (i) =>
              tracks[i].name.toLowerCase().contains(search.text.toLowerCase()),
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
                const Icon(Icons.folder_outlined, size: 21, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    androidFolderName ??
                        (folder == null ? '你的音乐资料库' : p.basename(folder!)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Text(
                  '下一首自动连播',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
          ),
          if (searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
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
          else if (tracks.isEmpty)
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
                ],
              ),
            )
          else if (indices.isEmpty)
            const Padding(padding: EdgeInsets.all(30), child: Text('没有找到匹配的歌曲'))
          else
            SizedBox(
              height: min(indices.length * 78.0, 480),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: indices.length,
                itemBuilder: (context, row) {
                  final index = indices[row], selected = current == index;
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
                        tracks[index].name,
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
                      trailing: selected
                          ? const Icon(Icons.graphic_eq, color: lime)
                          : const Icon(Icons.play_arrow_rounded, color: muted),
                      onTap: () => playTrack(index),
                    ),
                  );
                },
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: const Color(0xff26231b),
            child: Text(
              scanning
                  ? '正在扫描本地文件夹…'
                  : folder == null
                  ? '♫ 音乐仅在本机播放，文件不会上传'
                  : '♫ 已发现 ${tracks.length} 首 MP3 · 点击歌曲播放',
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
