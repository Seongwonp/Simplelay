// 웹 음성 안내 — 브라우저 Web Speech API(speechSynthesis)로 말한다.
//
// 웹에는 프로세스 실행이 없어 espeak-ng를 부를 수 없다. 같은 명령 모양
// (['espeak-ng', '-v', 'ko', '-s', '150', ..., 문장])을 받아 **마지막 인자(문장)**만
// 읽는다. 실제 발화 여부는 브라우저·OS 음성 엔진에 달렸다 — 리눅스 Chromium은
// speech-dispatcher 등 음성 엔진이 없으면 조용히 아무 소리도 내지 않는다
// (RPi 실기기 미확인). 음성은 보조 채널이므로 실패는 호출자가 삼킨다.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<void> runTtsCommand(List<String> command) async {
  if (command.isEmpty) return;
  final synth = html.window.speechSynthesis;
  if (synth == null) return;
  final utterance = html.SpeechSynthesisUtterance(command.last)
    ..lang = 'ko-KR'
    // espeak -s 150(기본 175 대비 약간 느림)에 맞춘 비율
    ..rate = 0.86
    ..volume = 1.0;
  synth.speak(utterance);
}
