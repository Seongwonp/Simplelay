import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

// 실제 TTS 엔진 대신 발화 내용만 기록
class FakeAppTts extends AppTtsService {
  final utterances = <String>[];

  @override
  Future<void> speak(String text) async {
    utterances.add(text);
  }
}

RpiApiService _apiCompletingJob(String jobId) {
  final client = MockClient((request) async {
    return http.Response.bytes(
      utf8.encode(jsonEncode({
        'running': false,
        'last_status': 'succeeded',
        'last_buttons': [],
        'last_job_id': jobId,
      })),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return RpiApiService('http://rpi5.local:8000', client: client);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('HTTP job 완료 시 결과를 음성으로 안내한다', () async {
    final tts = FakeAppTts();
    final container = ProviderContainer(
      overrides: [ttsServiceProvider.overrideWithValue(tts)],
    );
    addTearDown(container.dispose);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: _apiCompletingJob('job-1'),
          jobId: 'job-1',
          label: '즉석밥 데워줘',
        );
    // 1초 주기 폴링이 완료를 집을 때까지 실제 시간 대기
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(tts.utterances, contains('누름 장치가 다 눌렀다고 알려 왔어요. 가전이 움직이는지 봐 주세요.'));
  });

  test('음성 안내를 끄면 발화하지 않는다', () async {
    SharedPreferences.setMockInitialValues({'voice_guide_enabled': false});
    final tts = FakeAppTts();
    final container = ProviderContainer(
      overrides: [ttsServiceProvider.overrideWithValue(tts)],
    );
    addTearDown(container.dispose);

    // 먼저 provider를 생성(첫 read)해야 prefs 로드가 시작된다 —
    // 그 뒤 로드가 끝나 state가 false가 될 때까지 잠깐 대기
    container.read(voiceGuideProvider);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(voiceGuideProvider), isFalse);

    container.read(executionStatusProvider.notifier).beginHttpJob(
          api: _apiCompletingJob('job-2'),
          jobId: 'job-2',
          label: '즉석밥 데워줘',
        );
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(tts.utterances, isEmpty);
  });
}
