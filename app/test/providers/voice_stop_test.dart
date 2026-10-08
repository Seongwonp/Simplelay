// 실행 중 음성 '멈춰' 정지(2026-10-07, 9/30 결정).
//
// - 실행 중(또는 정지 버튼 위 대기 중)에만 듣는다. 듣는 동안 "듣는 중".
// - 짧은 정지 말이면 화면 정지 버튼과 같은 호출(emergencyStop)을 탄다.
// - 실행 중이 아니면 무시, 정지 요청은 한 번만, 인식 오류·권한 거부는 조용히
//   무시하고 정지 버튼은 그대로. 실행 문장은 듣는 중에도 아무것도 하지 않는다.
//
// 인식기는 가짜다 — 실물 마이크 인식률은 실측 필요.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/estop_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/tts_provider.dart';
import 'package:simplelay/providers/voice_stop_provider.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/services/app_tts_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/services/voice_service.dart';
import 'package:simplelay/widgets/voice_stop_indicator.dart';

class _FakeRecognizer implements SpeechRecognizer {
  bool available = true;
  bool throwOnInit = false;
  int initializeCalls = 0;
  int listenCalls = 0;
  int cancelCalls = 0;
  bool _listening = false;
  void Function(String)? _onText;
  void Function(String)? _onSilence;
  void Function(String)? _onError;
  void Function()? _onInterrupted;
  void Function(String)? _onFinal;
  void Function()? _onDone;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async {
    initializeCalls++;
    if (throwOnInit) throw Exception('no engine');
    return available;
  }

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
    listenCalls++;
    _listening = true;
    _onText = onText;
    _onSilence = onSilence;
    _onError = onError;
    _onInterrupted = onInterrupted;
    _onFinal = onFinal;
    _onDone = onDone;
  }

  /// 엔진이 **부분** 인식 문장을 준다.
  void say(String text) => _onText?.call(text);

  /// 엔진이 **최종** 인식 문장을 준다(VoiceService처럼 onText 뒤에 onFinal).
  void sayFinal(String text) {
    _onText?.call(text);
    _onFinal?.call(text);
  }

  /// 엔진이 스스로 세션을 끝냈다(speech_to_text 'done').
  void done() {
    _listening = false;
    final cb = _onDone;
    _onDone = null;
    cb?.call();
  }

  /// 5초 침묵으로 세션이 끝난다.
  void silence() {
    _listening = false;
    _onSilence?.call('');
  }

  void fail(String errorId) {
    _listening = false;
    _onError?.call(errorId);
  }

  /// 다른 화면(홈 '말로 조작하기')이 엔진을 가져갔다.
  void interruptByOther() {
    final cb = _onInterrupted;
    _onInterrupted = null;
    _listening = false;
    cb?.call();
  }

  @override
  Future<void> stop() async => _listening = false;

  @override
  Future<void> cancel() async {
    cancelCalls++;
    _listening = false;
  }
}

/// 진짜 실행 추적기에서 정지만 센다 — 정지 버튼과 같은 호출이 몇 번 왔는지.
class _CountingExecution extends ExecutionStatusNotifier {
  _CountingExecution(super.ref);

  int stops = 0;
  int begins = 0;
  Completer<void>? gate;

  void seed(ExecutionPhase phase, {String? sequenceId}) => state =
      ExecutionStatus(phase: phase, label: '즉석밥 데우기', sequenceId: sequenceId);

  @override
  Future<bool> emergencyStop() async {
    stops++;
    final g = gate;
    if (g != null) await g.future;
    return true;
  }
}

class _SilentTts extends AppTtsService {
  @override
  Future<void> speak(String text) async {}
}

/// 허브 흉내 — /status 본문을 바꿔 끼우고, /stop은 정해 둔 순서대로 실패·성공한다.
class _Hub {
  Map<String, dynamic> status = {
    'running': false, 'last_status': null, 'last_buttons': null,
  };
  bool statusFails = false;
  final List<int> stopCodes = [];
  int stopPosts = 0;

  late final api =
      RpiApiService('http://hub:8000', client: MockClient((req) async {
    if (req.method == 'POST' && req.url.path == '/stop') {
      stopPosts++;
      final code = stopCodes.isEmpty ? 200 : stopCodes.removeAt(0);
      return http.Response('{}', code);
    }
    if (req.url.path == '/status') {
      if (statusFails) throw http.ClientException('hub unreachable');
      return http.Response.bytes(utf8.encode(jsonEncode(status)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 404);
  }));
}

class _HoldEstop extends EstopNotifier {
  _HoldEstop() : super(null);

  void hold(String? holdState) => state = EstopState(holdState: holdState);
}

class _Rig {
  _Rig(this.container, this.recognizer, this._exec, this._estop);
  final ProviderContainer container;
  final _FakeRecognizer recognizer;
  final _CountingExecution? _exec;
  final _HoldEstop? _estop;

  _CountingExecution get exec => _exec!;
  _HoldEstop get estop => _estop!;

  VoiceStopState get voice => container.read(voiceStopProvider);
}

Future<_Rig> _rig(
  WidgetTester tester, {
  _FakeRecognizer? recognizer,
  RpiApiService? api,
  bool realExecution = false,
  bool realEstop = false,
}) async {
  final fake = recognizer ?? _FakeRecognizer();
  _CountingExecution? exec;
  _HoldEstop? estop;
  final container = ProviderContainer(overrides: [
    speechRecognizerProvider.overrideWithValue(fake),
    ttsServiceProvider.overrideWithValue(_SilentTts()),
    if (!realExecution)
      executionStatusProvider
          .overrideWith((ref) => exec = _CountingExecution(ref)),
    if (realEstop)
      estopPollIntervalProvider.overrideWithValue(null)
    else
      estopProvider.overrideWith((ref) => estop = _HoldEstop()),
    rpiApiServiceProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  // 앱(main.dart)처럼 시작부터 살려 둔다.
  container.listen(voiceStopProvider, (_, __) {});
  container.read(executionStatusProvider);
  container.read(estopProvider);
  await tester.pump();
  return _Rig(container, fake, exec, estop);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 600));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('isStopPhrase', () {
    test('짧은 정지 말과 가까운 변형을 받는다', () {
      for (final t in [
        '멈춰', '멈춰줘', '멈춰 줘', '멈춰!', '멈춰요', '정지', '정지해', '그만',
        '그만해', '스톱', '스탑', '멈춰 멈춰', ' 정지. ',
      ]) {
        expect(isStopPhrase(t), isTrue, reason: t);
      }
    });

    test('실행 문장·긴 문장·빈 말은 정지 말이 아니다', () {
      for (final t in [
        '즉석밥 데워줘', '세탁기 시작해줘', '정지 버튼이 어디야', '전자레인지 멈춰 있어',
        '', '   ', '멈', '그만 데워줘',
      ]) {
        expect(isStopPhrase(t), isFalse, reason: t);
      }
    });
  });

  testWidgets('실행 중 "멈춰" → 정지 버튼과 같은 호출이 한 번', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);

    expect(r.recognizer.listenCalls, 1);
    expect(r.voice.listening, isTrue);

    r.recognizer.say('멈춰');
    await _settle(tester);
    expect(r.exec.stops, 1);
  });

  testWidgets('대기(idle)에서 "멈춰" → 아무것도 안 한다, 듣지도 않는다', (tester) async {
    final r = await _rig(tester);
    await _settle(tester);

    expect(r.recognizer.listenCalls, 0);
    expect(r.voice.listening, isFalse);
    r.recognizer.say('멈춰');
    await _settle(tester);
    expect(r.exec.stops, 0);
  });

  testWidgets('실행이 끝나면 듣기를 놓고, 늦게 온 "멈춰"는 무시한다', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    expect(r.voice.listening, isTrue);

    r.exec.seed(ExecutionPhase.completed);
    await _settle(tester);
    expect(r.voice.listening, isFalse);
    expect(r.recognizer.cancelCalls, greaterThanOrEqualTo(1));

    r.recognizer.say('멈춰'); // 끝난 세션의 늦은 콜백
    await _settle(tester);
    expect(r.exec.stops, 0);
  });

  testWidgets('실행 중 "즉석밥 데워줘" → 아무것도 안 한다(음성 실행 금지)', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);

    r.recognizer.say('즉석밥 데워줘');
    await _settle(tester);
    expect(r.exec.stops, 0);
    expect(r.container.read(executionStatusProvider).phase,
        ExecutionPhase.running);
    expect(r.voice.listening, isTrue); // 계속 정지 말만 기다린다
  });

  testWidgets('"멈춰"가 여러 번 와도 정지 요청은 한 번', (tester) async {
    final r = await _rig(tester);
    r.exec.gate = Completer<void>();
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);

    r.recognizer.say('멈춰'); // 부분 결과
    r.recognizer.say('멈춰 멈춰'); // 같은 세션의 다음 부분 결과
    await _settle(tester);
    expect(r.exec.stops, 1); // 보내는 중에는 다시 보내지 않는다

    r.exec.gate!.complete();
    await _settle(tester);
    r.recognizer.say('정지');
    await _settle(tester);
    expect(r.exec.stops, 1); // 이번 실행에서는 이미 보냈다
  });

  testWidgets('인식 오류·권한 거부 → 조용히 멈추고, 정지 버튼은 그대로 동작', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    expect(r.voice.listening, isTrue);

    r.recognizer.fail('error_insufficient_permissions');
    await _settle(tester);
    expect(r.voice.listening, isFalse);
    expect(r.exec.stops, 0);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: r.container,
      child: const MaterialApp(
        home: Scaffold(
          body: Column(children: [VoiceStopIndicator(), RunningStopStrip()]),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('듣는 중'), findsNothing);
    await tester.tap(find.byKey(const Key('shell-stop')));
    await tester.pump();
    expect(r.exec.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('엔진을 못 쓰면(초기화 실패·예외) 조용히 넘어간다', (tester) async {
    final fake = _FakeRecognizer()..throwOnInit = true;
    final r = await _rig(tester, recognizer: fake);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    expect(r.voice.listening, isFalse);
    expect(fake.listenCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('한 번 못 알아들으면(no_match) 다시 듣는다', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    r.recognizer.fail('error_no_match');
    await _settle(tester);
    expect(r.recognizer.listenCalls, 2);
    r.recognizer.silence();
    await _settle(tester);
    expect(r.recognizer.listenCalls, 3);
    r.recognizer.say('그만');
    await _settle(tester);
    expect(r.exec.stops, 1);
  });

  testWidgets('다른 화면이 마이크를 가져갔다가 놓으면 다시 듣는다', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    r.recognizer.interruptByOther();
    await _settle(tester);
    expect(r.recognizer.listenCalls, 2);
    expect(r.voice.listening, isTrue);
  });

  testWidgets('정지 버튼 위 대기 중이면 듣고, "멈춰"는 같은 POST /stop', (tester) async {
    var stopPosts = 0;
    final api = RpiApiService('http://hub:8000',
        client: MockClient((req) async {
          if (req.method == 'POST' && req.url.path == '/stop') stopPosts++;
          return http.Response('{}', 200);
        }));
    final r = await _rig(tester, api: api);
    r.exec.seed(ExecutionPhase.completed);
    r.estop.hold('hovering_stop');
    await _settle(tester);
    expect(r.voice.listening, isTrue);

    r.recognizer.say('멈춰');
    r.recognizer.say('멈춰');
    await _settle(tester);
    expect(stopPosts, 1);

    r.estop.hold('stopping');
    await _settle(tester);
    expect(r.voice.listening, isFalse);
  });

  testWidgets('듣는 동안 화면에 "듣는 중"', (tester) async {
    final r = await _rig(tester);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: r.container,
      child: const MaterialApp(home: Scaffold(body: VoiceStopIndicator())),
    ));
    expect(find.text('듣는 중'), findsNothing);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    expect(find.text('듣는 중'), findsOneWidget);
  });

  // ── 2026-10-08 인계 5차 §1~3 ──────────────────────────────────────────

  testWidgets('정지 요청이 HTTP 실패면 보낸 것으로 치지 않는다 — 다시 말하면 다시 요청',
      (tester) async {
    // 진짜 실행 추적기 + 가짜 허브(/stop 첫 번째 500, 두 번째 200).
    final hub = _Hub()
      ..status = {
        'running': true, 'job_id': 'j1', 'last_status': null, 'last_buttons': null,
      }
      ..stopCodes.addAll([500, 200]);
    final r = await _rig(tester, api: hub.api, realExecution: true);
    r.container.read(executionStatusProvider.notifier).beginHttpJob(
        api: hub.api, jobId: 'j1', label: '즉석밥 데우기');
    await _settle(tester);
    expect(r.voice.listening, isTrue);

    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 1);
    expect(r.voice.listening, isTrue, reason: '실패했으니 다시 듣는다');

    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 2, reason: '두 번째 "멈춰"는 다시 요청해야 한다');
    expect(r.voice.listening, isFalse, reason: '보냈으면 이번 실행에서는 그만 듣는다');

    // 서버가 정지 결과를 내면 추적이 끝난다(남은 폴링 타이머 정리).
    hub.status = {
      'running': false, 'job_id': null, 'last_job_id': 'j1',
      'last_status': 'safety_stopped', 'last_outcome': 'stopped', 'last_buttons': [],
    };
    await _settle(tester);
    expect(r.container.read(executionStatusProvider).phase,
        isNot(ExecutionPhase.running));
  });

  testWidgets('키오스크·루틴이 시작한 실행(서버 running)도 듣고, "멈춰"는 POST /stop',
      (tester) async {
    final hub = _Hub()
      ..status = {
        'running': true, 'job_id': 'kiosk-1', 'last_status': null, 'last_buttons': null,
      };
    final r = await _rig(tester, api: hub.api, realEstop: true);
    await _settle(tester);
    // 폰은 이 실행을 추적하지 않는다(idle) — 서버 상태로 듣는다.
    expect(r.container.read(executionStatusProvider).phase, ExecutionPhase.idle);
    expect(r.voice.listening, isTrue);

    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 1);
    expect(r.exec.stops, 0, reason: '폰이 추적하지 않는 실행은 같은 POST /stop으로');

    hub.status = {'running': false, 'last_status': 'safety_stopped', 'last_buttons': []};
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isFalse);
  });

  testWidgets('/status 조회가 실패하면 듣기를 끈다(이전 값을 붙들지 않는다)',
      (tester) async {
    final hub = _Hub()
      ..status = {
        'running': false, 'hold_state': 'hovering_stop',
        'last_status': null, 'last_buttons': null,
      };
    final r = await _rig(tester, api: hub.api, realEstop: true);
    await _settle(tester);
    expect(r.voice.listening, isTrue);

    hub.statusFails = true;
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isFalse);
    expect(r.container.read(estopProvider).holdingAtStop, isFalse);
  });

  testWidgets('엔진이 스스로 끝나면(done) "듣는 중"을 바로 끄고 다시 연다', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    expect(r.voice.listening, isTrue);
    expect(r.recognizer.listenCalls, 1);

    r.recognizer.done();
    await tester.pump();
    expect(r.voice.listening, isFalse, reason: '엔진이 끝났는데 듣는 중이라고 하지 않는다');

    await _settle(tester);
    expect(r.recognizer.listenCalls, 2);
    expect(r.voice.listening, isTrue);
  });

  testWidgets('부분 결과 "그만"으로는 정지하지 않는다 — "그만 데워줘"가 이어지면 무시',
      (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);

    r.recognizer.say('그만');
    await tester.pump(const Duration(milliseconds: 300));
    r.recognizer.say('그만 데워줘');
    await tester.pump(const Duration(milliseconds: 300));
    r.recognizer.sayFinal('그만 데워줘');
    await _settle(tester);
    expect(r.exec.stops, 0);
    expect(r.voice.listening, isTrue);

    // 최종 결과가 정지 말이면 바로 보낸다.
    r.recognizer.sayFinal('그만');
    await tester.pump();
    await tester.pump();
    expect(r.exec.stops, 1);
  });

  testWidgets('정지 말뿐인 부분 결과 뒤 짧게 조용하면 정지한다', (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);

    r.recognizer.say('멈춰');
    await tester.pump(const Duration(milliseconds: 300));
    expect(r.exec.stops, 0, reason: '부분 결과 즉시는 아니다');
    await _settle(tester);
    expect(r.exec.stops, 1);
  });

  // ── 2026-10-08 리뷰 수리(침묵 종료·실행 식별) ─────────────────────────

  testWidgets('침묵 종료(no_match·speech_timeout)가 6번 이어져도 "멈춰"는 정지 한 번',
      (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    for (var i = 0; i < 6; i++) {
      r.recognizer.fail(i.isEven ? 'error_no_match' : 'error_speech_timeout');
      await _settle(tester);
    }
    expect(r.recognizer.listenCalls, 7, reason: '침묵은 오류가 아니다 — 매번 다시 연다');
    expect(r.voice.listening, isTrue);

    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(r.exec.stops, 1);
  });

  testWidgets('다른 인식 오류가 이어져도 포기하지 않고 간격을 늘려 다시 연다',
      (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running);
    await _settle(tester);
    for (var i = 0; i < 8; i++) {
      r.recognizer.fail('error_network');
      // 늘어나는 간격의 상한보다 넉넉히 기다린다.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(r.recognizer.listenCalls, 9);
    expect(r.voice.listening, isTrue);

    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(r.exec.stops, 1);
  });

  testWidgets('음성으로 멈춘 실행 A 뒤 곧바로 실행 B가 시작되면 B의 "멈춰"도 보낸다',
      (tester) async {
    final r = await _rig(tester);
    r.exec.seed(ExecutionPhase.running, sequenceId: 'job-A');
    await _settle(tester);
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(r.exec.stops, 1);
    expect(r.voice.listening, isFalse);

    // 듣기 구간이 끊기지 않은 채(5초 조회 사이) 다음 실행이 시작됐다.
    r.exec.seed(ExecutionPhase.running, sequenceId: 'job-B');
    await _settle(tester);
    expect(r.voice.listening, isTrue, reason: '새 실행이면 다시 듣는다');
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(r.exec.stops, 2);
  });

  testWidgets('서버만 아는 실행도 job_id가 바뀌면 다시 듣는다', (tester) async {
    final hub = _Hub()
      ..status = {
        'running': true, 'job_id': 'kiosk-1', 'last_status': null, 'last_buttons': null,
      };
    final r = await _rig(tester, api: hub.api, realEstop: true);
    await _settle(tester);
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 1);
    expect(r.voice.listening, isFalse);

    hub.status = {
      'running': true, 'job_id': 'kiosk-2', 'last_job_id': 'kiosk-1',
      'last_status': 'safety_stopped', 'last_buttons': [],
    };
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isTrue);
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 2);

    // 같은 실행이 이어지면 다시 보내지 않는다.
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isFalse);
  });

  testWidgets('조회 한 번 실패 뒤 같은 job_id가 다시 보이면 다시 듣지도 보내지도 않는다',
      (tester) async {
    final hub = _Hub()
      ..status = {
        'running': true, 'job_id': 'kiosk-X', 'last_status': null, 'last_buttons': null,
      };
    final r = await _rig(tester, api: hub.api, realEstop: true);
    await _settle(tester);
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 1);
    expect(r.voice.listening, isFalse);

    // 조회 한 번 실패 — 실행 중을 모름(꺼진 것으로 본다).
    hub.statusFails = true;
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isFalse);

    // 다음 조회는 같은 실행 X가 아직 도는 중 — 듣기 구간이 다시 열린 것처럼 보이지만
    // 이미 음성으로 멈춘 실행이다.
    hub.statusFails = false;
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isFalse, reason: '같은 실행이면 마이크를 다시 열지 않는다');
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 1, reason: '같은 실행에 정지를 두 번 보내지 않는다');

    // 실패를 한 번 더 거친 뒤 새 실행 Y면 다시 듣는다.
    hub.statusFails = true;
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    hub
      ..statusFails = false
      ..status = {
        'running': true, 'job_id': 'kiosk-Y', 'last_job_id': 'kiosk-X',
        'last_status': 'safety_stopped', 'last_buttons': [],
      };
    await r.container.read(estopProvider.notifier).refresh();
    await _settle(tester);
    expect(r.voice.listening, isTrue, reason: '새 실행이면 다시 듣는다');
    r.recognizer.sayFinal('멈춰');
    await _settle(tester);
    expect(hub.stopPosts, 2);
  });
}
