// 네이티브 음성 안내 — RPi5에 espeak-ng가 있으면 그것을 부르고, 없으면(보드 기본 이미지, 10/25 확인) 본체가 만든 음성(POST /tts)을
// 받아 보드의 재생 도구(paplay)로 튼다. dart:io는 이 파일에만 둔다(웹 빌드는 kiosk_tts_runner_web.dart).
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _hub = 'http://localhost:8000';
const _timeout = Duration(seconds: 10);

Future<void> runTtsCommand(List<String> command) async {
  try {
    final r = await Process.run(command.first, command.sublist(1));
    if (r.exitCode == 0) return;
  } on ProcessException {
    // 보드에 espeak-ng가 없다 — 본체에서 만든다
  }
  await _playFrom(() => http.post(Uri.parse('$_hub/tts'),
      headers: const {'Content-Type': 'application/json'}, body: jsonEncode({'text': command.last})));
}

/// 제안 알림음(본체 GET /tts/chime).
Future<void> playChime() => _playFrom(() => http.get(Uri.parse('$_hub/tts/chime')));

Future<void> _playFrom(Future<http.Response> Function() request) async {
  try {
    final res = await request().timeout(_timeout);
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return;
    final f = File('${Directory.systemTemp.path}/simplelay-tts-${DateTime.now().microsecondsSinceEpoch}.wav');
    await f.writeAsBytes(res.bodyBytes);
    try {
      await Process.run('paplay', [f.path]);
    } finally {
      try {
        await f.delete();
      } catch (_) {}
    }
  } catch (_) {
    // 음성은 보조 채널 — 본체가 없거나 재생 도구가 없으면 조용히 넘어간다
  }
}
