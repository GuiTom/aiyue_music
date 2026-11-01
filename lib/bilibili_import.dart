import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class BilibiliVideo {
  const BilibiliVideo(this.bvid, this.cid, this.title);
  final String bvid, title;
  final int cid;
}

class BilibiliImporter {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
  static const _agent = 'Mozilla/5.0';

  static void log(String message, {Object? error, StackTrace? stackTrace}) {
    final entry = StringBuffer(
      '${DateTime.now().toIso8601String()} [AIYUE_BILI] $message',
    );
    if (error != null) entry.write('\nERROR: $error');
    if (stackTrace != null) entry.write('\nSTACK: $stackTrace');
    final text = entry.toString();

    // Some Logcat configurations hide developer.log, so also write short
    // chunks through Flutter's standard console output.
    for (final line in text.split('\n')) {
      if (line.isEmpty) continue;
      for (var start = 0; start < line.length; start += 800) {
        debugPrintSynchronously(
          line.substring(start, min(start + 800, line.length)),
        );
      }
    }
    developer.log(
      text,
      name: 'AIYUE_BILI',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    log('HTTP GET host=${uri.host} path=${uri.path}');
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 30));
    request.headers.set('User-Agent', _agent);
    request.headers.set('Referer', 'https://www.bilibili.com/');
    final response = await request.close().timeout(const Duration(seconds: 30));
    log(
      'HTTP response status=${response.statusCode} '
      'contentLength=${response.contentLength} host=${uri.host}',
    );
    if (response.statusCode != 200) {
      throw FormatException('B站暂时拒绝访问（HTTP ${response.statusCode}），请稍后重试');
    }
    return response;
  }

  Future<Map<String, dynamic>> _api(
    String endpoint,
    Map<String, String> query,
  ) async {
    log('API request endpoint=$endpoint queryKeys=${query.keys.join(',')}');
    final response = await _get(Uri.https('api.bilibili.com', endpoint, query));
    final body = await utf8.decoder.bind(response).join();
    log('API response endpoint=$endpoint bodyLength=${body.length}');
    final data = jsonDecode(body) as Map<String, dynamic>;
    log(
      'API result endpoint=$endpoint code=${data['code']} message=${data['message']}',
    );
    if (data['code'] != 0 || data['data'] is! Map) {
      throw FormatException('无法访问视频：${data['message'] ?? '需要登录或视频不可用'}');
    }
    return Map<String, dynamic>.from(data['data'] as Map);
  }

  Future<BilibiliVideo> resolve(String text) async {
    log('Resolve started inputLength=${text.length}');
    final normalized = text
        .replaceAll(RegExp(r'[\u200B-\u200D\u2060\uFEFF]'), '')
        .replaceAll('：', ':')
        .replaceAll('／', '/');
    final preview = normalized
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    log(
      'Normalized input preview=${preview.substring(0, min(preview.length, 240))}',
    );
    final match = RegExp(
      r'''(?:https?://)?(?:(?:www|m)\.)?(?:b23\.tv|bilibili\.com|bili2233\.cn)/[^\s【】<>"']+''',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (match == null) throw const FormatException('请粘贴 B站视频链接或完整分享文字');
    var rawUrl = match.group(0)!.replaceFirst(RegExp(r'[，。！？、；：,.!?;:]+$'), '');
    if (!rawUrl.toLowerCase().startsWith('http')) {
      rawUrl = 'https://$rawUrl';
    }
    var uri = Uri.parse(rawUrl);
    log('Extracted share URL host=${uri.host} path=${uri.path}');
    if (uri.host == 'b23.tv' || uri.host == 'bili2233.cn') {
      final request = await _client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final location = response.headers.value(HttpHeaders.locationHeader);
      log(
        'Short URL response status=${response.statusCode} hasLocation=${location != null}',
      );
      await response.drain<void>();
      if (location == null) throw const FormatException('短链接已失效或暂时无法解析');
      uri = uri.resolve(location);
      log(
        'Short URL resolved host=${uri.host} path=${uri.path} p=${uri.queryParameters['p']}',
      );
    }
    if (uri.host != 'www.bilibili.com' &&
        uri.host != 'm.bilibili.com' &&
        uri.host != 'bilibili.com') {
      throw const FormatException('分享链接未指向 B站视频');
    }
    final id = RegExp(
      r'/video/(BV[0-9A-Za-z]+|av\d+)',
    ).firstMatch(uri.path)?.group(1);
    if (id == null) throw const FormatException('目前支持普通 B站视频链接');
    final data = await _api('/x/web-interface/view', {
      if (id.startsWith('BV')) 'bvid': id else 'aid': id.substring(2),
    });
    final pages = data['pages'] as List;
    final pageNumber = int.tryParse(uri.queryParameters['p'] ?? '1') ?? 1;
    if (pageNumber < 1 || pageNumber > pages.length) {
      throw const FormatException('视频分P不存在');
    }
    final page = pages[pageNumber - 1] as Map;
    log(
      'Resolve succeeded bvid=${data['bvid']} cid=${page['cid']} '
      'page=$pageNumber/${pages.length} title=${data['title']}',
    );
    return BilibiliVideo(
      data['bvid'] as String,
      page['cid'] as int,
      '${data['title']}${pages.length > 1 ? ' - ${page['part']}' : ''}',
    );
  }

  Future<String> download(
    BilibiliVideo video,
    void Function(String) progress,
  ) async {
    log(
      'Download started bvid=${video.bvid} cid=${video.cid} title=${video.title}',
    );
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/bilibili',
    );
    await directory.create(recursive: true);
    final output = File('${directory.path}/${video.bvid}_${video.cid}.mp3');
    log('Output file path=${output.path}');
    if (await output.exists() && await output.length() > 0) {
      log('Using existing MP3 bytes=${await output.length()}');
      return output.path;
    }
    final source = File('${output.path}.source');
    final temporary = File('${output.path}.part.mp3');
    try {
      final data = await _api('/x/player/playurl', {
        'bvid': video.bvid,
        'cid': '${video.cid}',
        'fnval': '16',
        'qn': '16',
        'fourk': '0',
      });
      if (data['is_preview'] == 1 || data['is_preview'] == true) {
        throw const FormatException('该视频仅提供试看，无法导入完整音轨');
      }
      final audio = (data['dash'] as Map?)?['audio'] as List?;
      log(
        'Play URL parsed preview=${data['is_preview']} '
        'dashAudioCount=${audio?.length ?? 0} durlCount=${(data['durl'] as List?)?.length ?? 0}',
      );
      String? url;
      if (audio != null && audio.isNotEmpty) {
        final sorted = [...audio]
          ..sort(
            (a, b) => (b['bandwidth'] as num).compareTo(a['bandwidth'] as num),
          );
        url = (sorted.first['baseUrl'] ?? sorted.first['base_url']) as String?;
        log(
          'Selected DASH audio id=${sorted.first['id']} '
          'bandwidth=${sorted.first['bandwidth']} codecs=${sorted.first['codecs']}',
        );
      } else {
        final segments = data['durl'] as List?;
        if (segments?.length == 1) url = segments!.first['url'] as String?;
      }
      if (url == null) throw const FormatException('没有可下载音轨，视频可能需要登录或付费');
      final response = await _get(Uri.parse(url));
      final sink = source.openWrite();
      var received = 0;
      var lastLoggedPercent = -10;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 45),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (response.contentLength > 0) {
            final percent = (received * 100 / response.contentLength).floor();
            if (percent >= lastLoggedPercent + 10 || percent == 100) {
              lastLoggedPercent = percent;
              log(
                'Download progress=$percent% bytes=$received/${response.contentLength}',
              );
            }
          }
          progress(
            response.contentLength > 0
                ? '正在下载 ${(received * 100 / response.contentLength).floor()}%'
                : '正在下载 ${(received / 1048576).toStringAsFixed(1)} MB',
          );
        }
      } finally {
        await sink.close();
      }
      log('Download completed bytes=$received source=${source.path}');
      progress('正在转换为 MP3…');
      log('FFmpeg conversion started');
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        source.path,
        '-vn',
        '-codec:a',
        'libmp3lame',
        '-q:a',
        '2',
        temporary.path,
      ]);
      final returnCode = await session.getReturnCode();
      final ffmpegOutput = await session.getOutput();
      log(
        'FFmpeg finished returnCode=$returnCode\n'
        '${ffmpegOutput == null || ffmpegOutput.isEmpty ? '(no FFmpeg output)' : ffmpegOutput}',
      );
      if (!ReturnCode.isSuccess(returnCode) ||
          !await temporary.exists() ||
          await temporary.length() == 0) {
        throw const FormatException('MP3 转换失败，请重试');
      }
      await temporary.rename(output.path);
      log(
        'Import succeeded outputBytes=${await output.length()} path=${output.path}',
      );
      return output.path;
    } catch (error, stackTrace) {
      log('Download/import failed', error: error, stackTrace: stackTrace);
      rethrow;
    } finally {
      if (await source.exists()) {
        log('Cleaning source temporary file');
        await source.delete();
      }
      if (await temporary.exists()) {
        log('Cleaning MP3 temporary file');
        await temporary.delete();
      }
    }
  }

  void close() => _client.close(force: true);
}
