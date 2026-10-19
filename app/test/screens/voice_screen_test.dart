import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/test_helpers.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/navigation_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/services/voice_service.dart';

const _testAppliance = ApplianceMap(
  id: 'custom_test',
  name: '테스트가전',
  category: ApplianceCategory.other,
  rows: 1,
  cols: 2,
  isCustom: true,
  buttons: [
    ApplianceButton(id: 'b1', label: '켜기', x: 0, y: 0),
    ApplianceButton(id: 'b2', label: '끄기', x: 1, y: 0),
  ],
);

class _FakeVoiceService extends VoiceService {
  void Function(String errorId)? _errorCallback;
  void Function(String finalText)? _silenceCallback;
  void Function(double level)? _soundLevelCallback;
  bool _listening = false;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> listen({
    required void Function(String text) onText,
    required void Function(String finalText) onSilence,
    void Function(String errorId)? onError,
    void Function(double level)? onSoundLevel,
    void Function()? onInterrupted,
    void Function(String text)? onFinal,
    void Function()? onDone,
  }) async {
    _listening = true;
    _errorCallback = onError;
    _silenceCallback = onSilence;
    _soundLevelCallback = onSoundLevel;
    onText('부분 인식 문장');
  }

  /// 5초 침묵으로 엔진이 듣기를 끝낸 상황.
  void emitSilence(String finalText) {
    _listening = false;
    _silenceCallback?.call(finalText);
  }

  /// 마이크로 실제 소리가 들어온 상황.
  void emitSoundLevel(double level) => _soundLevelCallback?.call(level);

  void emitError(String errorId) {
    _listening = false;
    _errorCallback?.call(errorId);
  }

  @override
  Future<void> stop() async {
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    _listening = false;
  }
}

/// 권한이 거부됐거나 엔진이 없는 기기.
class _UnavailableVoiceService extends _FakeVoiceService {
  int initializeCalls = 0;

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    return false;
  }
}

// 전송 성공 시 화면이 context.go('/status')로 이동하므로 GoRouter가 필요하다.
Widget _buildScreen(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, __) => const VoiceScreen()),
            GoRoute(
              path: '/status',
              builder: (_, __) =>
                  const Scaffold(body: Text('status-screen-stub')),
            ),
            GoRoute(
              path: '/manual-control',
              builder: (_, __) =>
                  const Scaffold(body: Text('manual-screen-stub')),
            ),
          ],
        ),
      ),
    );

Future<ProviderContainer> _makeContainer({
  List<Override> extra = const [],
}) async {
  // 이 파일의 테스트는 '조작할 가전이 있는 사용자'를 다룬다. 가전이 없는
  // 사용자는 마이크 자체가 안 나오므로 별도 테스트에서 확인한다.
  final container = ProviderContainer(
    overrides: [...installedOverrides([kTestAppliance]), ...extra],
  );
  addTearDown(container.dispose);
  await container.read(customAppliancesProvider.notifier).ensureLoaded();
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('음성 엔진 오류 시 즉시 듣기 상태를 해제하고 사용자 안내를 표시한다', (tester) async {
    final voice = _FakeVoiceService();
    final container = await _makeContainer(
      extra: [voiceServiceProvider.overrideWithValue(voice)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('말하기 시작'));
    await tester.pump();

    expect(container.read(voiceListeningProvider), true);
    expect(container.read(voiceTextProvider), '부분 인식 문장');

    voice.emitError('error_audio_error');
    await tester.pump();
    // 파형 전환 애니메이션(120ms)까지 소진한다.
    await tester.pump(const Duration(milliseconds: 200));

    expect(container.read(voiceListeningProvider), false);
    expect(container.read(voiceTextProvider), isEmpty);
    // 스낵바와 화면에 남는 실패 안내 두 곳에 같은 문장이 뜬다 -- 스낵바는
    // 사라지지만 화면 쪽은 다음 시도까지 남는다.
    expect(
      find.text('마이크를 사용할 수 없어요. 다른 앱이 사용 중인지 확인해 주세요.'),
      findsNWidgets(2),
    );
  });

  testWidgets('인식이 실패하면 다시 말하기·버튼으로 조작 두 경로를 남긴다',
      (tester) async {
    // 실패를 스낵바로만 알리면 몇 초 뒤 사라지고, 화면에는 "마이크를 눌러
    // 말해보세요"만 남는다 -- 사용자가 할 수 있는 일이 같은 시도의 반복뿐이다.
    final voice = _FakeVoiceService();
    final container = await _makeContainer(
      extra: [voiceServiceProvider.overrideWithValue(voice)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('말하기 시작'));
    await tester.pump();

    voice.emitError('error_audio_error');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 스낵바가 사라져도 화면에 이유가 남는다
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('다시 말하기'), findsOneWidget);
    expect(find.text('버튼으로 하기'), findsOneWidget);

    // 다시 말하기를 누르면 실패 안내가 걷히고 듣기가 다시 시작된다
    await tester.tap(find.text('다시 말하기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(container.read(voiceListeningProvider), true);
    expect(find.text('버튼으로 하기'), findsNothing);
  });

  testWidgets('침묵으로 듣기가 끝나도 자동 전송하지 않고 확인을 묻는다', (tester) async {
    final voice = _FakeVoiceService();
    var executeCalls = 0;
    final api = RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async {
        // 가전 목록 조회 같은 다른 요청은 세지 않는다 -- 관심사는 실행 전송이다.
        if (request.url.path == '/execute') executeCalls++;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'job_id': 'job-1'})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final container = await _makeContainer(extra: [
      voiceServiceProvider.overrideWithValue(voice),
      rpiApiServiceProvider.overrideWithValue(api),
    ]);

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('말하기 시작'));
    await tester.pump();

    voice.emitSilence('즉석밥 데워줘');
    await tester.pump();
    // 파형 막대의 예약 타이머(최대 150ms)를 소진시킨다.
    await tester.pump(const Duration(milliseconds: 200));

    // 말하다 잠깐 멈춘 것이 곧바로 물리 조작이 되면 안 된다.
    expect(executeCalls, 0);
    expect(container.read(voiceListeningProvider), false);
    expect(find.text('이대로 할까요?'), findsOneWidget);
    expect(find.text('이대로 하기'), findsOneWidget);
    expect(find.text('다시 말하기'), findsOneWidget);
  });

  testWidgets('다른 탭으로 이동하면 음성 세션과 확인 대기가 정리된다', (tester) async {
    final voice = _FakeVoiceService();
    final container = await _makeContainer(
      extra: [voiceServiceProvider.overrideWithValue(voice)],
    );

    // 음성 화면이 사는 탭(홈)에 있는 상태에서 시작한다(AppShell이 하는 일).
    // 2026-09-30부터 음성은 탭이 아니라 홈 위에 얹는 화면이다.
    container.read(currentTabIndexProvider.notifier).state = voiceTabIndex;
    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('말하기 시작'));
    await tester.pump();
    expect(container.read(voiceListeningProvider), true);

    // 탭 브랜치는 화면을 떠나도 살아 있다 -- 숨겨진 화면이 계속 듣거나
    // 나중에 옛 문장을 실행하면 안 된다.
    container.read(currentTabIndexProvider.notifier).state = routinesTabIndex;
    await tester.pump();
    await tester.pump();
    // 파형 막대의 예약 타이머(최대 150ms)를 소진시킨다.
    await tester.pump(const Duration(milliseconds: 200));

    expect(voice.isListening, false);
    expect(container.read(voiceListeningProvider), false);
    expect(container.read(voiceTextProvider), isEmpty);
  });

  testWidgets('앱이 뒤로 가면 마이크를 놓는다', (tester) async {
    final voice = _FakeVoiceService();
    final container = await _makeContainer(
      extra: [voiceServiceProvider.overrideWithValue(voice)],
    );

    await tester.pumpWidget(_buildScreen(container));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('말하기 시작'));
    await tester.pump();
    expect(container.read(voiceListeningProvider), true);

    // 화면이 꺼지거나 다른 앱으로 전환됐는데 계속 듣고 있으면 안 된다.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    // 파형 막대의 예약 타이머(최대 150ms)를 소진시킨다.
    await tester.pump(const Duration(milliseconds: 200));

    expect(voice.isListening, false);
    expect(container.read(voiceListeningProvider), false);
  });

  testWidgets('전송이 시작되면 실행 버튼이 잠긴다', (tester) async {
    final voice = _FakeVoiceService();
    var executeCalls = 0;
    final api = RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async {
        if (request.url.path != '/execute') {
          // 가전 목록 조회는 이 테스트의 관심사가 아니다. 지연 없이 빈 응답.
          return http.Response('[]', 200);
        }
        executeCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // 409로 끝내 job 추적(주기 폴링)이 시작되지 않게 한다 -- 이
        // 테스트의 관심사는 전송 잠금이지 실행 추적이 아니다.
        return http.Response.bytes(
          utf8.encode(jsonEncode({'detail': 'busy'})),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final container = await _makeContainer(extra: [
      voiceServiceProvider.overrideWithValue(voice),
      rpiApiServiceProvider.overrideWithValue(api),
    ]);

    await tester.pumpWidget(_buildScreen(container));
    container.read(voiceTextProvider.notifier).state = '즉석밥 데워줘';
    await tester.pump();

    await tester.tap(find.text('이대로 하기'));
    await tester.pump();

    // 연타·중복 경로가 같은 명령을 두 번 실행하지 못하게 잠근다.
    expect(find.text('보내는 중…'), findsOneWidget);
    expect(find.text('이대로 하기'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100)); // 응답 도착
    expect(executeCalls, 1);
    // 안내 스낵바·파형 타이머를 소진시킨다.
    await tester.pump(const Duration(seconds: 5));
  });

  group('D3 — 음성 화면의 상태 구분', () {
    testWidgets('어느 가전에게 말하는지 위에 보여준다', (tester) async {
      // 여러 가전을 다루므로 말이 어디로 가는지 먼저 보여야 한다.
      final container = await _makeContainer(
        extra: [voiceServiceProvider.overrideWithValue(_FakeVoiceService())],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('전자레인지에게'), findsOneWidget);
    });

    testWidgets('듣는 중에는 언제 멈추는지 미리 말한다', (tester) async {
      // 생각하다 멈춘 사이에 조용히 끝나 버리면 마이크가 고장 났다고 여긴다.
      final container = await _makeContainer(
        extra: [voiceServiceProvider.overrideWithValue(_FakeVoiceService())],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.mic_rounded));
      await tester.pump();

      expect(find.text('5초 동안 조용하면 듣기를 멈추고 물어봐요.'),
          findsOneWidget);
    });

    testWidgets('음성 인식을 쓸 수 없으면 다시 말하기 대신 버튼 조작을 권한다',
        (tester) async {
      // 한 번 못 알아들은 것(다시 말하면 된다)과 아예 쓸 수 없는 것(아무리
      // 말해도 소용없다)을 같은 안내로 뭉개지 않는다.
      final voice = _UnavailableVoiceService();
      final container = await _makeContainer(
        extra: [voiceServiceProvider.overrideWithValue(voice)],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.mic_rounded));
      await tester.pumpAndSettle();

      expect(find.text('이 폰에서는 말로 하기를 쓸 수 없어요. 버튼으로 해 주세요'), findsOneWidget);
      expect(find.text('다시 말하기'), findsNothing);
      // 마이크를 그려 두고 눌러도 안 되게 하지 않는다.
      expect(find.byIcon(Icons.mic_rounded), findsNothing);

      await tester.tap(find.text('버튼으로 하기'));
      await tester.pumpAndSettle();
      expect(find.text('manual-screen-stub'), findsOneWidget);
    });

    testWidgets('권한을 고친 뒤 다시 확인하면 마이크가 돌아온다', (tester) async {
      final voice = _UnavailableVoiceService();
      final container = await _makeContainer(
        extra: [voiceServiceProvider.overrideWithValue(voice)],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.mic_rounded));
      await tester.pumpAndSettle();
      expect(voice.initializeCalls, 1);

      await tester.tap(find.text('권한을 켰어요. 다시 보기'));
      await tester.pumpAndSettle();

      // 다시 초기화를 시도했고, 여전히 안 되면 같은 안내가 남는다.
      expect(voice.initializeCalls, 2);
      expect(find.text('이 폰에서는 말로 하기를 쓸 수 없어요. 버튼으로 해 주세요'), findsOneWidget);
    });
  });

  group('내장 가전 선택 시 (기존 동작 유지)', () {
    testWidgets('힌트는 "즉석밥 데워줘" 예시를 보여준다', (tester) async {
      final container = await _makeContainer();
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('예: 즉석밥 데워줘'), findsOneWidget);
    });

    // 공기청정기 화면에 전자레인지 예시를 보이면 안 되는 말을 가르친다(첫 사용자 검토 10/19 #10).
    testWidgets('LG 공기청정기는 그 가전의 말 예시를 보여준다', (tester) async {
      const purifier = ApplianceMap(
        id: 'thinq_air',
        name: '거실 공기청정기',
        category: ApplianceCategory.airPurifier,
        rows: 0,
        cols: 0,
        isCustom: true,
        buttons: [],
        controlPath: 'thinq',
      );
      final container = ProviderContainer(overrides: installedOverrides([purifier]));
      addTearDown(container.dispose);
      await container.read(customAppliancesProvider.notifier).ensureLoaded();
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('예: 공기청정기 켜 줘'), findsOneWidget);
      expect(find.text('예: 즉석밥 데워줘'), findsNothing);
    });

    testWidgets('전송 시 /execute를 호출하고 상태 화면으로 이동한다', (tester) async {
      http.Request? captured;
      final client = MockClient((request) async {
        if (request.url.path == '/execute') captured = request;
        if (request.url.path == '/status') {
          // beginHttpJob의 폴링 — 즉시 완료로 응답해 타이머를 정리시킨다
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'running': false,
              'last_status': 'succeeded',
              'last_buttons': [],
              'last_job_id': 'job-1',
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'job_id': 'job-1', 'status': 'accepted'})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await _makeContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '즉석밥 데워줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();

      expect(captured!.url.path, '/execute');
      expect(jsonDecode(captured!.body), {
        'text': '즉석밥 데워줘',
        'source': 'voice',
        'appliance_id': 'microwave',
        'client_request_id': matches(RegExp(r'^[A-Za-z0-9_-]{1,64}$')), // 요청 번호(검토 10/19)
      });
      // 접수 후 상태 화면으로 이동한다
      await tester.pumpAndSettle();
      expect(find.text('status-screen-stub'), findsOneWidget);

      // beginHttpJob의 1초 폴링이 완료 응답을 받고 타이머를 정리할 시간을 준다
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });
  });

  group('사용자 정의 가전 선택 시', () {
    Future<ProviderContainer> makeCustomContainer({
      List<Override> extra = const [],
    }) async {
      final container = await _makeContainer(extra: extra);
      await container
          .read(customAppliancesProvider.notifier)
          .add(_testAppliance);
      await container
          .read(selectedApplianceProvider.notifier)
          .select(_testAppliance);
      return container;
    }

    testWidgets('힌트가 등록된 실제 버튼 라벨로 바뀐다', (tester) async {
      final container = await makeCustomContainer();
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('예: 켜기 해줘'), findsOneWidget);
      expect(find.text('예: 즉석밥 데워줘'), findsNothing);
    });

    testWidgets('RPi 연결이 없으면 안내만 뜨고 전송하지 않는다', (tester) async {
      // 전제를 명시한다. 기본 주소가 기기에서 올라오면 서비스가 생기므로,
      // '서버 없음'은 오버라이드로 만들어야 한다.
      final container = await makeCustomContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(null)],
      );
      container.read(voiceTextProvider.notifier).state = '켜줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();

      expect(
        find.text('말로 하려면 본체와 연결해야 해요. 설정에서 본체 연결을 봐 주세요.'),
        findsOneWidget,
      );
      // 서버 가전 목록 조회의 완료가 남긴 0초 타이머를 비운다.
      await tester.pump(Duration.zero);
    });

    testWidgets('전송 시 /execute-for-appliance를 등록된 버튼 어휘와 함께 호출한다',
        (tester) async {
      http.Request? captured;
      final client = MockClient((request) async {
        if (request.url.path == '/execute-for-appliance') captured = request;
        if (request.url.path == '/status') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'running': false,
              'last_status': 'succeeded',
              'last_buttons': [],
              'last_job_id': 'job-2',
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'job_id': 'job-2', 'status': 'accepted'})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await makeCustomContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '켜줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();

      expect(captured!.url.path, '/execute-for-appliance');
      expect(jsonDecode(captured!.body), {
        'text': '켜줘',
        'known_buttons': ['켜기', '끄기'],
        'appliance_id': 'custom_test',
        'client_request_id': matches(RegExp(r'^[A-Za-z0-9_-]{1,64}$')), // 요청 번호(검토 10/19)
      });
      await tester.pumpAndSettle();
      expect(find.text('status-screen-stub'), findsOneWidget);

      // beginHttpJob의 1초 폴링이 완료 응답을 받고 타이머를 정리할 시간을 준다
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });

    testWidgets('LLM 미설정 등으로 503이 오면 오류 메시지를 보여준다', (tester) async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': 'no LLM client configured'}),
          503,
        ),
      );
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await makeCustomContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '켜줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();

      // raw 예외 문자열 대신 사용자 언어로 안내한다
      expect(
        find.text('본체에서 말 알아듣기가 꺼져 있어요. 버튼으로 해 주세요.'),
        findsOneWidget,
      );
      // 서버 가전 목록 조회의 완료가 남긴 0초 타이머를 비운다.
      await tester.pump(Duration.zero);
    });
  });

  group('듣는 중 표시', () {
    // 가운데 막대의 높이 범위. _WaveVisualizer와 같은 값이어야 한다.
    const minHeight = 28.0;
    const maxHeight = 56.0;

    Future<double> centerBarHeight(WidgetTester tester) async {
      final bar = find.descendant(
        of: find.byKey(const ValueKey('wave-bar-2')),
        matching: find.byType(AnimatedContainer),
      );
      return tester.getSize(bar).height;
    }

    Future<_FakeVoiceService> startListening(WidgetTester tester) async {
      final voice = _FakeVoiceService();
      final container = await _makeContainer(
        extra: [voiceServiceProvider.overrideWithValue(voice)],
      );
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('말하기 시작'));
      await tester.pump();
      return voice;
    }

    testWidgets('음량이 오기 전에는 흔들리지 않는다', (tester) async {
      // 예전 파형은 마이크가 아무것도 못 듣고 있어도 정해진 애니메이션으로
      // 춤을 췄다. 그것이 "잘 듣고 있다"는 인상을 만들어, 인식이 안 될 때
      // 사용자가 더 크게 말할지 마이크를 의심할지 판단할 근거를 지웠다.
      await startListening(tester);

      await tester.pump(const Duration(milliseconds: 500));

      expect(await centerBarHeight(tester), minHeight);
    });

    testWidgets('실제 음량이 크면 막대가 커진다', (tester) async {
      final voice = await startListening(tester);

      voice.emitSoundLevel(10);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(await centerBarHeight(tester), maxHeight);
    });

    testWidgets('소리가 잦아들면 막대도 같이 내려간다', (tester) async {
      final voice = await startListening(tester);
      voice.emitSoundLevel(10);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      voice.emitSoundLevel(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(await centerBarHeight(tester), minHeight);
    });

    testWidgets('듣기를 마치면 지난 음량이 남지 않는다', (tester) async {
      final voice = await startListening(tester);
      voice.emitSoundLevel(10);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      voice.emitSilence('즉석밥 데워줘');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(await centerBarHeight(tester), minHeight);
    });
  });

  // 안전 보고 G7(2026-10-16): 홈 '말로 하기'의 "멈춰"·"그만"은 정지다. 서버는 /execute의 정지어를 /stop의 뜻으로
  // 받고 `status: "stopped"`·`job_id: ""`를 돌려준다 — 폰이 그 빈 job을 따라가면 '하는 중이에요'으로 머물다
  // "연결이 끊겨 동작을 확인할 수 없어요"를 띄웠다. 이제 폰은 정지어면 /execute 대신 정지 버튼과 같은 정지를 보내고,
  // 서버가 `stopped`로 답하면(두 번째 방어) 정지 문구만 보이고 따라가지 않는다.
  group('G7 — 정지어', () {
    http.Response json(Object body) => http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    const idleStop = <String, Object?>{
      'ok': true,
      'was_running': false,
      'stop_level': null,
      'stop_job_id': null,
    };

    /// 새 서버처럼 답한다: /execute → stopped(정지어로 받음), /stop → 정지 결과, /status → 이 job의 정지 결과.
    RpiApiService stopServer(List<String> paths,
            {Map<String, Object?> stop = idleStop, String executeJobId = ''}) =>
        RpiApiService('http://rpi5.local:8000',
            client: MockClient((request) async {
          paths.add(request.url.path);
          return switch (request.url.path) {
            '/execute' =>
              json({'job_id': executeJobId, 'status': 'stopped', 'stop': stop}),
            '/stop' => json(stop),
            '/status' => json({
                'running': false,
                'last_status': 'safety_stopped',
                'last_outcome': 'stopped',
                'last_buttons': [],
                'last_job_id': executeJobId.isEmpty ? null : executeJobId,
              }),
            _ => http.Response('[]', 200),
          };
        }));

    testWidgets('쉬는 중 "멈춰"는 /execute가 아니라 정지 요청이고 실행을 따라가지 않는다',
        (tester) async {
      final paths = <String>[];
      final container = await _makeContainer(
          extra: [rpiApiServiceProvider.overrideWithValue(stopServer(paths))]);
      container.read(voiceTextProvider.notifier).state = '멈춰';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();
      await tester.pump();

      expect(paths.where((p) => p == '/execute'), isEmpty);
      expect(paths.where((p) => p == '/stop').length, 1);
      expect(find.text('멈추라고 보냈어요. 하던 일은 없었어요.'), findsOneWidget);
      // 빈 job을 따라가 '하는 중이에요'·'연결이 끊겨…'로 가지 않는다.
      expect(find.text('status-screen-stub'), findsNothing);
      expect(container.read(executionStatusProvider).phase, ExecutionPhase.idle);
      expect(container.read(voiceTextProvider), isEmpty);
      await tester.pump(const Duration(seconds: 5)); // 스낵바·타이머 소진
    });

    testWidgets('실행을 따라가는 중 "그만"은 화면 정지 버튼과 같은 정지다', (tester) async {
      final paths = <String>[];
      final api = stopServer(paths,
          stop: const {
            'ok': true,
            'was_running': true,
            'stop_level': 'verified',
            'stop_ack_ms': 12,
            'stop_confirmed': true,
            'stop_job_id': 'job-7',
          },
          executeJobId: 'job-7');
      final container = await _makeContainer(
          extra: [rpiApiServiceProvider.overrideWithValue(api)]);
      container
          .read(executionStatusProvider.notifier)
          .beginHttpJob(api: api, jobId: 'job-7', label: '즉석밥 데워줘');
      container.read(voiceTextProvider.notifier).state = '그만';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();
      await tester.pump();

      expect(paths.where((p) => p == '/execute'), isEmpty);
      expect(paths.where((p) => p == '/stop').length, 1);
      // 정지 버튼(emergencyStop)과 같은 문장 — 이 job의 정지 단계까지만.
      expect(container.read(executionStatusProvider).message, '누름 장치가 멈췄어요');
      await tester.pumpAndSettle();
      expect(find.text('status-screen-stub'), findsOneWidget);
      // 상태 폴링이 이 job의 정지 결과를 받고 타이머를 정리할 시간을 준다.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('서버가 stopped로 답하면 정지 문구만 보이고 따라가지 않는다', (tester) async {
      // 두 번째 방어 — 폰 목록에 없는 말을 서버가 정지어로 받은 경우(서버 목록이 앞선 판 등).
      final paths = <String>[];
      final container = await _makeContainer(
          extra: [rpiApiServiceProvider.overrideWithValue(stopServer(paths))]);
      container.read(voiceTextProvider.notifier).state = '즉석밥 데워줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pump();
      await tester.pump();

      expect(paths.where((p) => p == '/execute').length, 1);
      expect(find.text('멈추라고 보냈어요. 하던 일은 없었어요.'), findsOneWidget);
      expect(find.text('status-screen-stub'), findsNothing);
      expect(container.read(executionStatusProvider).phase, ExecutionPhase.idle);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('못 알아들은 말(422) — 후보·할 수 있는 일', () {
    http.Response json(Object body, [int code = 200]) => http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          code,
          headers: {'content-type': 'application/json'},
        );

    Future<(ProviderContainer, List<String>)> setUpScreen(
        WidgetTester tester, Object body422) async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/execute') return json(body422, 422);
        return http.Response('[]', 200);
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await _makeContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '즉석밥 대워줘';
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('이대로 하기'));
      await tester.pumpAndSettle();
      return (container, paths);
    }

    const newBody = {
      'detail': "'즉석밥 대워줘'을(를) 알아듣지 못했어요",
      'suggestion': {'purpose': '즉석밥 데워줘', 'label': '즉석밥 데우기'},
      'choices': [
        {'purpose': '해동해줘', 'label': '해동'},
        {'purpose': '30초 돌려줘', 'label': '30초 돌리기'},
      ],
    };

    testWidgets('이유 문장·혹시 이것?·할 수 있는 일·말 예시를 화면에 남긴다', (tester) async {
      await setUpScreen(tester, newBody);

      expect(find.text("'즉석밥 대워줘'을(를) 알아듣지 못했어요"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '혹시 이것인가요? 즉석밥 데우기'), findsOneWidget);
      expect(find.text('${kTestAppliance.displayName}가 할 수 있는 일이에요'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '해동'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '30초 돌리기'), findsOneWidget);
      expect(find.text('이렇게 말해 보세요: 해동해줘'), findsOneWidget);
      // 다시 말하기·버튼으로 하기 길도 남는다.
      expect(find.text('다시 말하기'), findsOneWidget);
      expect(find.text('버튼으로 하기'), findsOneWidget);
    });

    testWidgets('후보를 누르면 바로 실행하지 않고 그 말로 확인을 다시 묻는다', (tester) async {
      final (container, paths) = await setUpScreen(tester, newBody);
      final sent = paths.where((p) => p == '/execute').length;

      await tester.tap(find.text('혹시 이것인가요? 즉석밥 데우기'));
      await tester.pumpAndSettle();

      expect(paths.where((p) => p == '/execute').length, sent);
      expect(container.read(voiceTextProvider), '즉석밥 데워줘');
      expect(find.text('이대로 할까요?'), findsOneWidget);
      expect(find.text('이대로 하기'), findsOneWidget);
      expect(find.text('혹시 이것인가요? 즉석밥 데우기'), findsNothing);
    });

    testWidgets('할 수 있는 일을 눌러도 확인부터 묻는다', (tester) async {
      final (container, paths) = await setUpScreen(tester, newBody);
      final sent = paths.where((p) => p == '/execute').length;

      final choice = find.widgetWithText(OutlinedButton, '30초 돌리기');
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();

      expect(paths.where((p) => p == '/execute').length, sent);
      expect(container.read(voiceTextProvider), '30초 돌려줘');
      expect(find.text('이대로 할까요?'), findsOneWidget);
    });

    testWidgets('옛 서버(detail만)면 종전 안내 그대로', (tester) async {
      await setUpScreen(tester, {'detail': 'not understood'});

      expect(find.text('무슨 말인지 몰랐어요. 다시 말해 주세요.'), findsOneWidget);
      expect(find.textContaining('혹시 이것인가요?'), findsNothing);
      expect(find.textContaining('할 수 있는 일이에요'), findsNothing);
    });

    // 못 알아들은 말이 '이대로 하기' 앞에 그대로 남으면 같은 말을 다시 보내게 된다(첫 사용자 검토 10/19 #12).
    testWidgets('옛 서버 422 뒤에는 못 알아들은 말을 지우고 다시 말하기·버튼으로 하기를 남긴다', (tester) async {
      final (container, _) = await setUpScreen(tester, {'detail': 'not understood'});

      expect(container.read(voiceTextProvider), '');
      expect(find.text('이대로 하기'), findsNothing);
      expect(find.text('다시 말하기'), findsOneWidget);
      expect(find.text('버튼으로 하기'), findsOneWidget);
    });
  });
}
