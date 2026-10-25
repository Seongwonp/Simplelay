// 네이티브 음성 안내 — RPi5에 espeak-ng가 있으면 그것을 부르고, 없으면(보드 기본 이미지, 10/25 확인) 본체에 '틀어 달라'고
// 맡긴다(POST /tts/play). 키오스크 앱은 격리돼 보드의 재생 도구를 쓰지 못한다 — 본체 컨테이너가 보드 소리 서버로 튼다.
// dart:io는 이 파일에만 둔다(웹 빌드는 kiosk_tts_runner_web.dart).
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _hub = 'http://localhost:8000';
const _timeout = Duration(seconds: 5);

Future<void> runTtsCommand(List<String> command) async {
  try {
    final r = await Process.run(command.first, command.sublist(1));
    if (r.exitCode == 0) return;
  } on ProcessException {
    // 보드에 espeak-ng가 없다 — 본체가 만들어 튼다
  }
  await _askHub({'text': command.last});
}

/// 제안 알림음(본체가 튼다). 본체 재생 줄이 차례를 지켜 뒤따르는 말과 겹치지 않는다.
Future<void> playChime() => _askHub({'chime': true});

Future<void> _askHub(Map<String, Object> body) async {
  try {
    await http
        .post(Uri.parse('$_hub/tts/play'), headers: const {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(_timeout);
  } catch (_) {
    // 음성은 보조 채널 — 본체에 닿지 않으면 조용히 넘어간다
  }
}
