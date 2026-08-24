// 키오스크 phase 머신 테스트 — KioskScreen(api:)로 fake 서비스를 주입해
// idle→suggestion→executing→done 전이와 job_id 대조 규칙을 검증한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_event_stream.dart';
import 'package:simplelay_touchscreen/services/kiosk_tts_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

class FakeKioskApi implements KioskApiService {
  List<KioskSuggestion> suggestionList = [];
  KioskStatus statusResult = const KioskStatus(running: false);
  AlertState alertState = AlertState.inactive;
  Object? executeError;
  String nextJobId = 'job-1';
  final approvedIds = <String>[];
  int stopCalls = 0;

  @override
  Future<HealthStatus> checkHealth() async => const HealthStatus(ok: true);

  @override
  Future<SensorData?> sensors() async => null;

  @override
  Future<AlertState> alerts() async => alertState;

  @override
  Future<List<KioskSuggestion>> suggestions() async => suggestionList;

  @override
  Future<KioskStatus> status() async => statusResult;

  @override
  Future<KioskJobAccepted> executeButtons(
    List<String> buttons, {
    String? applianceId,
  }) async {
    if (executeError != null) throw executeError!;
    return KioskJobAccepted(jobId: nextJobId);
  }

  @override
  Future<KioskJobAccepted> approveSuggestion(String id) async {
    if (executeError != null) throw executeError!;
    approvedIds.add(id);
    return KioskJobAccepted(jobId: nextJobId);
  }

  @override
  Future<void> rejectSuggestion(String id) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> setDnd(int minutes) async {}

  @override
  Future<void> clearDnd() async {}

  @override
  Future<List<NodeInfo>> listNodes() async => const [];

  @override
  Future<bool> registerNode(String applianceId, String baseUrl) async => true;

  @override
  Future<bool> unregisterNode(String applianceId) async => true;

  @override
  void dispose() {}
}

// SSE 스트림 — 실제 네트워크·재접속 타이머 없이 콜백만 노출
class FakeEventStream extends KioskEventStream {
  void Function(AlertState alert)? alertCallback;
  void Function()? statusCallback;

  @override
  void start({
    required void Function(AlertState alert) onAlert,
    void Function()? onStatusChanged,
  }) {
    alertCallback = onAlert;
    statusCallback = onStatusChanged;
  }

  @override
  void stop() {}
}

// 음성 안내 — 실제 espeak 프로세스 대신 발화 내용만 기록
class FakeTts extends KioskTtsService {
  final utterances = <String>[];

  @override
  Future<void> speak(String text) async {
    if (enabled) utterances.add(text);
  }
}

const _sug = KioskSuggestion(id: 's1', purpose: '우유 데워줘', occurrences: 3);

Future<void> _pumpKiosk(
  WidgetTester tester,
  FakeKioskApi api, {
  FakeTts? tts,
  FakeEventStream? events,
}) async {
  // tts/events 미지정 테스트에서도 실제 espeak 프로세스·SSE 네트워크
  // 연결(재접속 타이머)을 만들지 않도록 항상 fake를 주입한다.
  await tester.pumpWidget(
    MaterialApp(
      home: KioskScreen(
        api: api,
        tts: tts ?? FakeTts(),
        events: events ?? FakeEventStream(),
      ),
    ),
  );
  await tester.pump(); // initState 첫 폴링
  await tester.pump(); // async 응답 반영
}

void main() {
  // 800x480 실기기 해상도에 맞춰 오버플로 없는 레이아웃으로 테스트
  void useKioskViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('서버 제안이 도착하면 idle → suggestion으로 전환된다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];

    await _pumpKiosk(tester, api);

    expect(find.byType(KioskSuggestionView), findsOneWidget);
    expect(find.text('승인'), findsOneWidget);
  });

  testWidgets('승인 → executing → job 완료 시 done → 자동 idle 복귀', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    // 승인하면 즉시 실행 화면으로 가고, 접수된 job_id를 추적한다
    api.suggestionList = [];
    await tester.tap(find.text('승인'));
    await tester.pump();
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(api.approvedIds, ['s1']);

    // 서버가 내 job(job-1)의 완료를 보고하면 done으로
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'succeeded',
      lastButtons: [],
      lastJobId: 'job-1',
    );
    await tester.pump(const Duration(seconds: 2)); // 폴링 주기
    await tester.pump(); // 응답 반영
    await tester.pump(const Duration(milliseconds: 900)); // 완료 연출 지연
    expect(find.byType(KioskDoneView), findsOneWidget);

    // done은 자동으로 idle로 복귀한다
    await tester.pump(KioskTimings.doneReturn);
    await tester.pump();
    expect(find.byType(KioskIdleView), findsOneWidget);
  });

  testWidgets('이전 실행의 결과(last_job_id 불일치)는 완료로 오인하지 않는다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('승인'));
    await tester.pump();

    // 서버에 남아 있던 "이전" 실행의 결과 — 내 job-1이 아니므로 무시해야 한다
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'succeeded',
      lastButtons: [],
      lastJobId: 'job-OLD',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(find.byType(KioskDoneView), findsNothing);

    // 내 job의 완료가 오면 그때 done
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'succeeded',
      lastButtons: [],
      lastJobId: 'job-1',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn); // 복귀 타이머 소진
  });

  testWidgets('폰 앱이 시작한 실행을 idle 폴링이 감지해 실행 화면으로 이어받는다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..statusResult = const KioskStatus(
        running: true,
        currentButton: '해동',
        jobId: 'job-phone',
      );

    await _pumpKiosk(tester, api);

    expect(find.byType(KioskExecutingView), findsOneWidget);

    // 그 job의 완료도 정상적으로 집는다
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'succeeded',
      lastButtons: [],
      lastJobId: 'job-phone',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn);
  });

  testWidgets('승인 접수 자체가 실패하면 고착 없이 즉시 실패 화면으로 탈출한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..suggestionList = [_sug]
      ..executeError = Exception('server down');
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('승인'));
    await tester.pump(); // 접수 실패
    await tester.pump();

    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn); // 복귀 타이머 소진
  });

  // ── 음성 안내 (TTS) ──────────────────────────────────────────────────────

  testWidgets('제안 도착·실행 완료를 음성으로 안내한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    final tts = FakeTts();
    await _pumpKiosk(tester, api, tts: tts);

    // 제안 도착 발화 — 목적이 포함된 문장
    expect(tts.utterances.single, contains('우유 데워줘'));
    expect(tts.utterances.single, contains('승인'));

    api.suggestionList = [];
    await tester.tap(find.text('승인'));
    await tester.pump();
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'succeeded',
      lastButtons: [],
      lastJobId: 'job-1',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    // 완료 발화
    expect(tts.utterances.last, contains('완료되었습니다'));
    await tester.pump(KioskTimings.doneReturn);
  });

  testWidgets('위험 경보는 새로 켜지는 엣지에서 1회만 발화한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi();
    final tts = FakeTts();
    await _pumpKiosk(tester, api, tts: tts);
    expect(tts.utterances, isEmpty);

    api.alertState = const AlertState(active: true, kind: 'fire_alarm');
    await tester.pump(const Duration(seconds: 3)); // alert 폴링 주기
    await tester.pump();
    expect(tts.utterances.where((u) => u.contains('위험')).length, 1);

    // 경보가 이어지는 동안 반복 발화하지 않는다
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tts.utterances.where((u) => u.contains('위험')).length, 1);
  });

  testWidgets('음성 안내를 끄면 발화하지 않는다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    final tts = FakeTts()..enabled = false;
    await _pumpKiosk(tester, api, tts: tts);

    expect(tts.utterances, isEmpty);
  });

  // ── SSE 이벤트 스트림 ────────────────────────────────────────────────────

  testWidgets('SSE 경보는 폴링 주기를 기다리지 않고 즉시 반영·발화된다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi();
    final tts = FakeTts();
    final events = FakeEventStream();
    await _pumpKiosk(tester, api, tts: tts, events: events);
    expect(tts.utterances, isEmpty);

    // 3초 폴링을 기다리지 않고 SSE 콜백으로 바로 도착
    events.alertCallback!(
      const AlertState(active: true, kind: 'fire_alarm'),
    );
    await tester.pump();

    expect(tts.utterances.single, contains('위험'));

    // 이어서 폴링이 같은 경보를 또 가져와도(중복 공급) 재발화하지 않는다
    api.alertState = const AlertState(active: true, kind: 'fire_alarm');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tts.utterances.length, 1);
  });

  testWidgets('다른 job이 이어서 실행 중이어도 내 job의 완료를 놓치지 않는다 (추월 레이스)',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('승인'));
    await tester.pump(); // job-1 접수

    // 내 job-1은 완료됐지만, 폰이 시작한 job-2가 이미 실행 중인 상태
    api.statusResult = const KioskStatus(
      running: true,
      jobId: 'job-2',
      lastJobId: 'job-1',
      lastStatus: 'succeeded',
      lastButtons: [],
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn);
  });

  test('SseLineParser는 event/data 라인 쌍을 이벤트로 조립한다', () {
    final parser = SseLineParser();

    expect(parser.feed('event: alert'), isNull);
    final event = parser.feed('data: {"active": true, "kind": "fire_alarm"}');
    expect(event!.name, 'alert');
    expect(event.data['active'], true);

    // 빈 줄(이벤트 경계)·keepalive 주석·data 없는 라인은 무시
    expect(parser.feed(''), isNull);
    expect(parser.feed(': keepalive'), isNull);
    // event 없이 온 data는 버린다
    expect(parser.feed('data: {"orphan": 1}'), isNull);
    // 손상된 JSON은 조용히 버린다
    parser.feed('event: alert');
    expect(parser.feed('data: {broken'), isNull);
  });
}
