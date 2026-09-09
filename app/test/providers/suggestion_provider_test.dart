import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/suggestion_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

ProviderContainer makeContainer({List<Override> overrides = const []}) {
  final c = ProviderContainer(overrides: overrides);
  addTearDown(c.dispose);
  return c;
}

// GET /suggestions 응답만 고정해서 돌려주는 가짜 RPi API. 다른 엔드포인트는
// approve/reject 호출 여부 확인용으로 요청을 그대로 기록만 한다.
class _FakeSuggestionsSetup {
  _FakeSuggestionsSetup(List<Map<String, dynamic>> suggestionsJson) {
    final client = MockClient((request) async {
      calls.add(request);
      if (request.method == 'GET' && request.url.path == '/suggestions') {
        return http.Response.bytes(
          utf8.encode(jsonEncode(suggestionsJson)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 200);
    });
    service = RpiApiService('http://rpi5.local:8000', client: client);
  }

  final calls = <http.Request>[];
  late final RpiApiService service;
}

void main() {
  // SuggestionNotifier가 생성 시 rpiApiServiceProvider(→ SharedPreferences)를
  // 읽어 HTTP 폴링 여부를 판단하므로, 순수 test()에서도 플랫폼 채널 mock이 필요하다.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SuggestionNotifier', () {
    test('initially empty', () {
      final c = makeContainer();
      expect(c.read(suggestionProvider), isEmpty);
    });

    test('adds suggestion when BLE suggestion message arrives', () async {
      final c = makeContainer();
      c.read(suggestionProvider); // initialise notifier

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'test-001',
        'label': '우유 데우기',
        'steps': ['BT-08', 'BT-03', 'BT-05'],
      });

      await Future<void>.delayed(Duration.zero);
      final suggestions = c.read(suggestionProvider);
      expect(suggestions.length, 1);
      expect(suggestions.first.sequenceId, 'test-001');
      expect(suggestions.first.label, '우유 데우기');
    });

    test('replaces existing suggestion with same sequenceId', () async {
      final c = makeContainer();
      c.read(suggestionProvider);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'dup-001',
        'label': '첫 번째',
        'steps': ['BT-01'],
      });
      await Future<void>.delayed(Duration.zero);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'dup-001',
        'label': '업데이트됨',
        'steps': ['BT-02'],
      });
      await Future<void>.delayed(Duration.zero);

      final suggestions = c.read(suggestionProvider);
      expect(suggestions.length, 1);
      expect(suggestions.first.label, '업데이트됨');
    });

    test('ignores non-suggestion messages', () async {
      final c = makeContainer();
      c.read(suggestionProvider);

      c.read(bleServiceProvider).injectMessage({'type': 'sensor', 'current_ma': 300.0});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(suggestionProvider), isEmpty);
    });

    test('respond removes suggestion from state', () async {
      final c = makeContainer();
      c.read(bleServiceProvider).simulateConnected(); // demo mode so send is no-op
      c.read(suggestionProvider);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'remove-me',
        'label': '삭제될 제안',
        'steps': ['BT-05'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.read(suggestionProvider).length, 1);

      await c.read(suggestionProvider.notifier).respond(
            c.read(suggestionProvider).first,
            false,
          );
      expect(c.read(suggestionProvider), isEmpty);
    });
  });

  group('SuggestionNotifier — HTTP 제안 폴링', () {
    test('RPi URL이 설정되면 /suggestions를 폴링해 상태에 반영한다', () async {
      final fake = _FakeSuggestionsSetup([
        {
          'id': 'http-001',
          'purpose': '우유 데워줘',
          'time_band': '아침',
          'occurrences': 3,
          'steps': ['해동', '시작'], // 백엔드는 라벨 문자열로 준다
          'appliance_id': 'microwave',
        },
      ]);
      final c = makeContainer(overrides: [
        rpiApiServiceProvider.overrideWithValue(fake.service),
        ...installedOverrides([kTestAppliance]),
      ]);

      c.read(suggestionProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final suggestions = c.read(suggestionProvider);
      expect(suggestions.length, 1);
      expect(suggestions.first.sequenceId, 'http-001');
      expect(suggestions.first.label, '우유 데워줘');
      expect(suggestions.first.source, SuggestionSource.http);
      // **대상 가전**의 버튼맵으로 라벨→코드 역매핑됨: "해동"→BT-07, "시작"→BT-05
      expect(suggestions.first.steps, ['BT-07', 'BT-05']);
    });

    test('버튼맵에 없는 라벨은 그대로 남긴다', () async {
      final fake = _FakeSuggestionsSetup([
        {
          'id': 'http-002',
          'purpose': '우유 데워줘',
          'time_band': '아침',
          'occurrences': 3,
          'steps': ['시간 90초'], // 실제 버튼맵엔 없는 라벨 — 데이터 불일치 케이스
        },
      ]);
      final c = makeContainer(overrides: [
        rpiApiServiceProvider.overrideWithValue(fake.service),
      ]);

      c.read(suggestionProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(c.read(suggestionProvider).first.steps, ['시간 90초']);
    });

    test('HTTP 출처 제안에 respond()를 호출해도 BLE로 보내지 않는다', () async {
      final fake = _FakeSuggestionsSetup([
        {
          'id': 'http-003',
          'purpose': '우유 데워줘',
          'time_band': '아침',
          'occurrences': 3,
          'steps': <String>[],
        },
      ]);
      final c = makeContainer(overrides: [
        rpiApiServiceProvider.overrideWithValue(fake.service),
      ]);

      c.read(suggestionProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final suggestion = c.read(suggestionProvider).first;

      // BLE는 연결(simulateConnected)도, 데모 모드도 아니므로 BLE로 보내려 하면
      // ble_service.dart의 send()가 StateError를 던진다 — 여기선 던지지 않아야 한다.
      await c.read(suggestionProvider.notifier).respond(suggestion, true);

      expect(c.read(suggestionProvider), isEmpty);
    });

    test('BLE 제안과 HTTP 제안이 서로의 목록을 지우지 않고 공존한다', () async {
      final fake = _FakeSuggestionsSetup([
        {
          'id': 'http-004',
          'purpose': '우유 데워줘',
          'time_band': '아침',
          'occurrences': 3,
          'steps': <String>[],
        },
      ]);
      final c = makeContainer(overrides: [
        rpiApiServiceProvider.overrideWithValue(fake.service),
      ]);

      c.read(suggestionProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(suggestionProvider).length, 1);

      c.read(bleServiceProvider).injectMessage({
        'type': 'suggestion',
        'sequence_id': 'ble-005',
        'label': 'BLE로 온 제안',
        'steps': ['BT-05'],
      });
      await Future<void>.delayed(Duration.zero);

      final ids = c.read(suggestionProvider).map((s) => s.sequenceId).toSet();
      expect(ids, {'http-004', 'ble-005'});
    });
  });
}
