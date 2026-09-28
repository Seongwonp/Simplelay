// 네이티브 음성 안내 — RPi5에 설치된 espeak-ng CLI를 프로세스로 호출한다.
// dart:io는 이 파일에만 둔다(웹 빌드는 kiosk_tts_runner_web.dart).
import 'dart:io';

Future<void> runTtsCommand(List<String> command) async {
  await Process.run(command.first, command.sublist(1));
}
