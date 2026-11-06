import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const Map<String, String> defaultFishVoices = {
  'cf71d823861b4e0eadff1672d646da36': '几何女声 (知性自然)',
  'b445c7474b504a39b26f5578dd20be0e': '郭德纲 响沉',
  '188fedbaa43e40508a8fefdaddac66c6': '女播音腔 (慢速中音)',
  'a688f2129bea41d1ae6042462892ecf8': '说书人 男老 袁阔成',
  '25c485bfedd84344a8952a38813b3906': '中年男声 (速度自然)',
  'fbe02f8306fc4d3d915e9871722a39d5': '女清新明亮 (嘉岚3.0)',
  'b7daab7a1ba2481f81f8f5d0e0d0c819': '女热情快读 (广告社交)',
};

const Map<String, String> defaultMsVoices46 = {
  'zh-CN-XiaoxiaoMultilingualNeural': '晓晓多语 (双语温柔女声)',
  'zh-CN-YunxiNeural': '云希 (阳光青年·叙事主力)',
  'zh-CN-XiaoxiaoNeural': '晓晓 (温柔少女·多情感)',
  'zh-CN-YunyeNeural': '云野 (沉稳大叔·角色小说)',
  'zh-CN-YunjianNeural': '云健 (热血解说·低沉质感)',
  'zh-CN-XiaomoNeural': '晓墨 (多角色变换·细腻)',
  'zh-CN-YunzeNeural': '云泽 (纪录片·厚重长辈)',
  'zh-CN-XiaohanNeural': '晓涵 (高亮温柔·抒情女声)',
  'zh-CN-YunyangNeural': '云扬 (专业男主播·新闻质感)',
  'zh-CN-XiaoyiNeural': '晓伊 (甜亮活泼·少女校园)',
  'zh-CN-YunfengNeural': '云枫 (清朗书生·自然叙事)',
  'zh-CN-XiaoruiNeural': '晓睿 (睿智沉稳·长者播报)',
  'zh-CN-XiaoxuanNeural': '晓萱 (温婉自然·书卷质感)',
  'zh-CN-XiaoyanNeural': '晓颜 (清亮活泼·日常播读)',
  'zh-CN-XiaozhenNeural': '晓甄 (温柔亲和·故事旁白)',
  'zh-CN-YunhaoNeural': '云浩 (磁性成熟·故事旁白)',
  'zh-CN-YunxiaNeural': '云夏 (青春少年·朝气蓬勃)',
  'zh-CN-YunjieNeural': '云杰 (从容淡定·社科解说)',
  'zh-CN-XiaochenNeural': '晓辰 (清新自然·电台女声)',
  'zh-CN-XiaomengNeural': '晓梦 (梦幻柔美·睡前故事)',
  'zh-CN-XiaoshuangNeural': '晓双 (活泼萌趣·儿童角色)',
  'zh-CN-XiaozhiNeural': '晓芷 (恬静雅致·文艺叙事)',
  'zh-CN-XiaofeiNeural': '晓菲 (生动亲切·情感电台)',
  'zh-CN-XiaonuoNeural': '晓诺 (童声稚嫩·儿童故事)',
  'zh-CN-XiaoyouNeural': '晓悠 (轻快纯真·少儿读物)',
  'zh-CN-XiaolinNeural': '晓霖 (温厚大方·知识讲解)',
  'zh-CN-XiaoyuNeural': '晓羽 (轻柔治愈·抒情旁白)',
  'zh-CN-YunfengMultilingualNeural': '云枫多语 (双语小说推荐)',
  'zh-CN-liaoning-XiaobeiNeural': '晓北 (辽宁东北话)',
  'zh-CN-liaoning-YunbiaoNeural': '云彪 (辽宁东北话·男声)',
  'zh-CN-shaanxi-XiaoniNeural': '晓妮 (陕西关中方言)',
  'zh-CN-shaanxi-YunxiangNeural': '云翔 (陕西话·男声)',
  'zh-CN-sichuan-YunxiNeural': '云希 (四川话·男声)',
  'zh-CN-sichuan-XiaobaoNeural': '晓宝 (四川话·女声)',
  'zh-CN-shandong-YunxiangNeural': '云翔 (山东话·男声)',
  'zh-CN-henan-YundengNeural': '云登 (中原官话·河南话)',
  'wuu-CN-XiaotongNeural': '晓彤 (吴语上海话·女声)',
  'wuu-CN-YunzheNeural': '云哲 (吴语上海话·男声)',
  'yue-CN-XiaoMinNeural': '晓敏 (粤语广州话·女声)',
  'yue-CN-YunSongNeural': '云松 (粤语广州话·男声)',
  'zh-HK-HiuMaanNeural': '晓曼 (粤语香港话·女声)',
  'zh-HK-WanLungNeural': '云龙 (粤语香港话·男声)',
  'zh-HK-HiuGaaiNeural': '晓佳 (粤语香港话·活泼)',
  'zh-TW-HsiaoChenNeural': '曉臻 (台湾普通话)',
  'zh-TW-YunJheNeural': '雲哲 (台湾普通话·男声)',
  'zh-TW-HsiaoYuNeural': '曉雨 (台湾普通话·甜美)',
};

class MicrosoftTranslatorTTS {
  static const authUrl = 'https://dev.microsofttranslator.com/apps/endpoint?api-version=1.0';
  static const clientConstant = 'oik6PdDdMnOXemTbwvMn9de/h9lFnfBaCWbGMMZqqoSaQaqUOqjVGm5NqsmjcBI1x+sS9ugjB55HEJWRiFXYFw==';
  static String? _token;
  static String? _region;
  static int _expires = 0;

  static String _stamp(DateTime value) {
    const days = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
    const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    String two(int v) => v < 10 ? '0$v' : '$v';
    final d = value.toUtc();
    return '${days[d.weekday % 7]}, ${two(d.day)} ${months[d.month - 1]} ${d.year} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}gmt';
  }

  static String _signature(String stamp, String nonce) {
    final url = Uri.encodeComponent(authUrl.split('://')[1]);
    final data = ('MSTranslatorAndroidApp$url$stamp$nonce').toLowerCase();
    final mac = Hmac(sha256, base64Decode(clientConstant)).convert(utf8.encode(data));
    return 'MSTranslatorAndroidApp::${base64Encode(mac.bytes)}::$stamp::$nonce';
  }

  static Future<Map<String, String>> getEndpoint() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_token != null && _region != null && _expires > now + 60000) return {'token': _token!, 'region': _region!};
    final stamp = _stamp(DateTime.now());
    final nonce = DateTime.now().microsecondsSinceEpoch.toString().padLeft(32, '0');
    final res = await http.post(Uri.parse(authUrl), headers: {
      'X-MT-Signature': _signature(stamp, nonce),
      'X-ClientVersion': '4.0.530a 5fe1dc6c',
      'X-UserId': nonce.substring(0, 16),
      'X-HomeGeographicRegion': 'zh-Hans-CN',
      'X-ClientTraceId': nonce,
      'Accept-Language': 'zh-Hans',
      'User-Agent': 'okhttp/4.5.0',
      'Content-Type': 'application/json; charset=utf-8',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('微软认证失败：HTTP ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final token = data['t'] as String;
    final region = data['r'] as String;
    var expires = now + 600000;
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        var payloadPart = parts[1].replaceAll('-', '+').replaceAll('_', '/');
        while (payloadPart.length % 4 != 0) { payloadPart += '='; }
        final payload = jsonDecode(utf8.decode(base64Decode(payloadPart)));
        if (payload['exp'] is num) expires = (payload['exp'] as num).toInt() * 1000;
      }
    } catch (_) {}
    _token = token;
    _region = region;
    _expires = expires;
    return {'token': token, 'region': region};
  }

  /// 适配 64kbps / 128kbps 音频输出规格
  static Future<Uint8List> synthesize(
    String text,
    String voice, {
    double speed = 1,
    int bitrate = 64,
    int timeoutSeconds = 60,
  }) async {
    final endpoint = await getEndpoint();
    final rateValue = ((speed - 1) * 100).round();
    final rate = rateValue >= 0 ? '+$rateValue%' : '$rateValue%';
    final escaped = text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
    final ssml = '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="zh-CN"><voice name="$voice"><prosody rate="$rate" pitch="+0%" volume="+0%">$escaped</prosody></voice></speak>';
    final url = Uri.parse('https://${endpoint['region']}.tts.speech.microsoft.com/cognitiveservices/v1');

    // 默认 64kbps (标准低延时)，备用 128kbps (高音质)
    final format = bitrate == 128 ? 'audio-16khz-128kbitrate-mono-mp3' : 'audio-16khz-64kbitrate-mono-mp3';

    final res = await http.post(url, headers: {
      'Authorization': endpoint['token']!,
      'X-Microsoft-OutputFormat': format,
      'User-Agent': 'okhttp/4.5.0',
      'Content-Type': 'application/ssml+xml',
    }, body: utf8.encode(ssml)).timeout(Duration(seconds: timeoutSeconds));
    if (res.statusCode != 200) throw Exception('微软合成失败：HTTP ${res.statusCode}');
    return res.bodyBytes;
  }

  static Future<Map<String, dynamic>> testConnectivity() async {
    final watch = Stopwatch()..start();
    try {
      final endpoint = await getEndpoint();
      watch.stop();
      return {'success': true, 'latency': watch.elapsedMilliseconds, 'msg': '认证可用，区域 ${endpoint['region']}'};
    } catch (e) {
      watch.stop();
      return {'success': false, 'latency': watch.elapsedMilliseconds, 'msg': '$e'};
    }
  }
}

class FishAudioTTS {
  FishAudioTTS({required this.apiKey, required this.voices});
  final String apiKey;
  final Map<String, String> voices;

  Future<Map<String, dynamic>> testConnectivity() async {
    final watch = Stopwatch()..start();
    try {
      final response = await http.get(Uri.parse('https://api.fish.audio/model?page_size=1')).timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) throw Exception('HTTP ${response.statusCode}');
      if (apiKey.isEmpty) {
        watch.stop();
        return {'success': true, 'latency': watch.elapsedMilliseconds, 'msg': '服务可达，但未填写 API Key'};
      }
      final auth = await http.get(Uri.parse('https://api.fish.audio/model?self=true&page_size=1'), headers: {'Authorization': 'Bearer $apiKey'}).timeout(const Duration(seconds: 8));
      watch.stop();
      return {'success': auth.statusCode == 200, 'latency': watch.elapsedMilliseconds, 'msg': auth.statusCode == 200 ? '网络与 API Key 正常' : 'API Key 校验失败：HTTP ${auth.statusCode}'};
    } catch (e) {
      watch.stop();
      return {'success': false, 'latency': watch.elapsedMilliseconds, 'msg': '$e'};
    }
  }

  Future<Uint8List> textToSpeech(String text, String voice, {double speed = 1, int bitrate = 64, int timeoutSeconds = 60}) async {
    if (apiKey.isEmpty) throw Exception('请先填写 Fish Audio API Key');
    final ref = voices.containsKey(voice) ? voice : voices.keys.first;
    final body = <String, dynamic>{'text': text, 'format': 'mp3', 'reference_id': ref, 'normalize': true, 'mp3_bitrate': bitrate};
    if ((speed - 1).abs() >= 0.05) body['prosody'] = {'speed': double.parse(speed.toStringAsFixed(2))};
    final response = await http.post(Uri.parse('https://api.fish.audio/v1/tts'), headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'model': 's2.1-pro-free',
    }, body: jsonEncode(body)).timeout(Duration(seconds: timeoutSeconds));
    if (response.statusCode != 200) throw Exception('Fish Audio 合成失败：HTTP ${response.statusCode} ${utf8.decode(response.bodyBytes, allowMalformed: true)}');
    return response.bodyBytes;
  }
}
