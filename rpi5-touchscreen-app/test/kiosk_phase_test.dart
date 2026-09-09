// 키오스크 phase 머신 테스트 — KioskScreen(api:)로 fake 서비스를 주입해
// idle→suggestion→executing→done 전이와 job_id 대조 규칙을 검증한다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_event_stream.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';
import 'package:simplelay_touchscreen/services/kiosk_tts_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

class FakeKioskApi implements KioskApiService {
  List<KioskSuggestion> suggestionList = [];
  // 서버 가전 목록 — 비어 있으면 화면이 내장 목록으로 폴백한다
  List<ApplianceMap> applianceList = const [];
  KioskStatus statusResult = const KioskStatus(running: false);
  AlertState alertState = AlertState.inactive;
  HealthStatus healthResult = const HealthStatus(ok: true);
  Object? executeError;
  String nextJobId = 'job-1';
  final approvedIds = <String>[];
  final rejectedIds = <String>[];
  final mutedIds = <String>[];
  int stopCalls = 0;

  @override
  Future<HealthStatus> checkHealth() async => healthResult;

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
  Future<void> rejectSuggestion(String id, {bool mute = false}) async {
    rejectedIds.add(id);
    if (mute) mutedIds.add(id);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> setDnd(int minutes) async {}

  @override
  Future<void> clearDnd() async {}

  @override
  Future<List<ApplianceMap>> listAppliances() async => applianceList;

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
  KioskSettingsStore? settings,
}) async {
  // tts/events 미지정 테스트에서도 실제 espeak 프로세스·SSE 네트워크
  // 연결(재접속 타이머)을 만들지 않도록 항상 fake를 주입한다.
  // settings는 기본 미주입 — 실제 홈 디렉터리 파일을 건드리지 않는다.
  await tester.pumpWidget(
    MaterialApp(
      home: KioskScreen(
        api: api,
        tts: tts ?? FakeTts(),
        events: events ?? FakeEventStream(),
        settings: settings,
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

  // 새로 지급받은 15인치 패널. 설계 캔버스(800x480)보다 크므로 KioskCanvas가
  // 통째로 확대해 채운다.
  void useFifteenInchViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('연결 안 되어 있으면 대기 화면을 눌러도 조작 화면으로 가지 않는다', (tester) async {
    // 사용자 혼란 방지: "기기 연결 안 됐는데 왜 전자레인지 조작판이 뜨지?"
    // 대기 화면이 이미 "기기 연결이 필요해요"라고 말하는데, 눌렀더니 조작판이
    // 뜨면 모순이다. 연결 없이는 실제로 버튼도 못 누른다.
    useKioskViewport(tester);
    final api = FakeKioskApi()..healthResult = const HealthStatus(ok: false);
    await _pumpKiosk(tester, api);

    // 대기 화면: 연결 안 됐다는 안내가 있다
    expect(find.text('기기 연결이 필요해요'), findsOneWidget);

    // 화면을 눌러도
    await tester.tap(find.text('기기 연결이 필요해요'));
    await tester.pump();

    // 여전히 대기 화면(안내 그대로). 조작판으로 넘어가지 않았다.
    expect(find.text('기기 연결이 필요해요'), findsOneWidget);
  });

  testWidgets('연결돼 있으면 대기 화면을 눌러 조작 화면으로 간다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..healthResult = const HealthStatus(ok: true, actuatorReady: true);
    await _pumpKiosk(tester, api);

    expect(find.text('화면을 눌러 가전 조작'), findsOneWidget);
    await tester.tap(find.text('화면을 눌러 가전 조작'));
    await tester.pump(); // 탭 반영
    await tester.pump(const Duration(milliseconds: 500)); // AnimatedSwitcher 전환

    // 조작 화면으로 넘어감 -- 대기 안내가 사라졌다
    expect(find.text('화면을 눌러 가전 조작'), findsNothing);
  });

  testWidgets('15인치(1920x1080)에서 화면을 채우고, 확대된 좌표에서도 조작이 된다',
      (tester) async {
    useFifteenInchViewport(tester);
    final api = FakeKioskApi()
      ..healthResult = const HealthStatus(ok: true, actuatorReady: true);
    await _pumpKiosk(tester, api);

    // 캔버스가 화면 전체를 차지한다(여백은 배경색으로 채워짐)
    expect(tester.getSize(find.byType(KioskCanvas)), const Size(1920, 1080));

    // 내부는 여전히 800x480 설계 세계 -- 레이아웃/오버플로 보장이 그대로다.
    final idleSize = tester.getSize(find.byType(KioskIdleView));
    expect(idleSize.width, KioskCanvas.design.width); // 논리 폭은 1920이 아니라 800

    // 그리고 실제로 **확대돼 그려진다**. 논리 크기로는 안 잡히므로 변환이
    // 반영된 전역 rect로 본다 (1080/480 = 2.25배 -> 800*2.25 = 1800).
    final painted = tester.getRect(find.byType(KioskIdleView));
    expect(painted.width, greaterThan(KioskCanvas.design.width));
    expect(painted.width, closeTo(1800, 1));

    // 확대 변환을 통과해도 히트테스트가 어긋나지 않는다(실제 터치 시연의 핵심)
    await tester.tap(find.text('화면을 눌러 가전 조작'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // 수동 조작 진입 첫 화면(가전 선택)으로 넘어간다 -- 확대 변환을 통과한
    // 탭이 제대로 히트테스트됐다는 뜻.
    expect(find.byType(KioskApplianceSelectView), findsOneWidget);
  });

  testWidgets('서버 제안이 도착하면 idle → suggestion으로 전환된다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];

    await _pumpKiosk(tester, api);

    expect(find.byType(KioskSuggestionView), findsOneWidget);
    expect(find.text('지금 실행'), findsOneWidget);
  });

  testWidgets('"이 제안 다시 받지 않기"를 누르면 mute=true로 거절하고 대기로 돌아간다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('이 제안 다시 받지 않기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(api.mutedIds, ['s1']);
    expect(find.byType(KioskSuggestionView), findsNothing);
  });

  testWidgets('"이번만 넘기기"는 mute 없이 거절한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('이번만 넘기기'));
    await tester.pump();

    expect(api.rejectedIds, ['s1']);
    expect(api.mutedIds, isEmpty);
  });

  testWidgets('승인 → executing → job 완료 시 done → 자동 idle 복귀', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    // 승인하면 즉시 실행 화면으로 가고, 접수된 job_id를 추적한다
    api.suggestionList = [];
    await tester.tap(find.text('지금 실행'));
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
    await tester.tap(find.text('지금 실행'));
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
    await tester.tap(find.text('지금 실행'));
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
    expect(tts.utterances.single, contains('지금 실행'));

    api.suggestionList = [];
    await tester.tap(find.text('지금 실행'));
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
    await tester.tap(find.text('지금 실행'));
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

  // ── 실패 화면 복구 동선 (디자인 리뷰) ────────────────────────────────────

  testWidgets('실패 화면은 자동으로 사라지지 않고 다음 행동을 제시한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('지금 실행'));
    await tester.pump();
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'failed',
      lastButtons: [],
      lastJobId: 'job-1',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.text('버튼으로 조작'), findsOneWidget);

    // 성공과 달리 자동 복귀 타이머가 없다 — 사용자가 고를 때까지 남는다
    await tester.pump(KioskTimings.doneReturn);
    await tester.pump(KioskTimings.doneReturn);
    expect(find.byType(KioskDoneView), findsOneWidget);
    expect(find.byType(KioskIdleView), findsNothing);
  });

  testWidgets('실패 화면의 다시 시도가 같은 제안을 재실행한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('지금 실행'));
    await tester.pump();
    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'failed',
      lastButtons: [],
      lastJobId: 'job-1',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(api.approvedIds, ['s1']);

    api.nextJobId = 'job-2';
    api.statusResult = const KioskStatus(running: false);
    await tester.tap(find.text('다시 시도'));
    await tester.pump();

    expect(api.approvedIds, ['s1', 's1']); // 같은 제안을 한 번 더
    expect(find.byType(KioskExecutingView), findsOneWidget);
  });

  testWidgets('실패 화면의 버튼으로 조작이 수동 화면으로 보낸다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..suggestionList = [_sug]
      ..executeError = Exception('server down');
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.text('지금 실행'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(KioskDoneView), findsOneWidget);

    // 서버 연결 실패는 '다시 시도'가 또 실패할 가능성이 높아 숨긴다
    expect(find.text('다시 시도'), findsNothing);

    await tester.tap(find.text('버튼으로 조작'));
    await tester.pump();
    expect(find.text('전자레인지'), findsOneWidget);
  });

  // ── 폐루프 재시도 연출 (디자인 리뷰) ─────────────────────────────────────

  testWidgets('재시도 중에는 자동 보정 중이 크게 표시된다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..statusResult = const KioskStatus(
        running: true,
        currentButton: '해동',
        currentAttempt: 2,
        jobId: 'job-r',
      );

    await _pumpKiosk(tester, api);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    // idle→executing 인계 시점엔 진행 데이터가 비어 있다 — 폴링 한 번 더
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    // 심사석에서 읽히는 크기로 승격됐는지 — 14px 보조문구가 아니라 38px hero
    final banner = tester.widget<Text>(find.text('자동 보정 중'));
    expect(banner.style!.fontSize, 38);
    expect(find.textContaining('2번째 시도'), findsWidgets);
  });

  testWidgets('첫 시도에는 자동 보정 배너가 없다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..statusResult = const KioskStatus(
        running: true,
        currentButton: '해동',
        currentAttempt: 1,
        jobId: 'job-n',
      );

    await _pumpKiosk(tester, api);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('자동 보정 중'), findsNothing);
    // 제목과 hero가 같은 라벨을 쓰므로 hero 쪽 부제로 확인한다
    expect(find.text('버튼 누르는 중 · 센서로 눌림 확인'), findsOneWidget);
  });

  // ── 카운트다운·설정 진입 (디자인 리뷰) ──────────────────────────────────

  testWidgets('제안 카운트다운 기본값은 20초다', (tester) async {
    // 10초는 음성 안내를 듣고 걸어와서 읽고 판단하기에 짧았다
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];

    await _pumpKiosk(tester, api);

    expect(KioskTimings.countdownSeconds, 20);
    expect(find.text('누르지 않으면 실행하지 않아요 · 20초'), findsOneWidget);
  });

  testWidgets('저장된 카운트다운 설정이 복원되어 적용된다', (tester) async {
    useKioskViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync('kiosk-cd-test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}settings.json';
    KioskSettingsStore(path: path).save(const KioskSettings(countdownSeconds: 30));

    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api, settings: KioskSettingsStore(path: path));

    expect(find.text('누르지 않으면 실행하지 않아요 · 30초'), findsOneWidget);
  });

  test('목록에 없는 카운트다운 값은 기본값으로 폴백한다', () {
    // 0이 들어오면 제안이 뜨자마자 사라진다
    final parsed = KioskSettings.fromJson({'countdown_seconds': 0});
    expect(parsed.countdownSeconds, KioskTimings.countdownSeconds);
  });

  testWidgets('설정 버튼은 보이지만 2초 길게 눌러야 열린다', (tester) async {
    useKioskViewport(tester);
    await _pumpKiosk(tester, FakeKioskApi());

    // 존재가 드러나야 한다 — 5px 점 3연타는 발견 불가능했다
    final gear = find.byIcon(Icons.settings_outlined);
    expect(gear, findsOneWidget);

    // 짧게 누르면 열리지 않는다 (지나가다 스치는 오조작 방지)
    await tester.tap(gear);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('키오스크 설정'), findsNothing);

    // 2초 유지하면 열린다
    final gesture = await tester.startGesture(tester.getCenter(gear));
    await tester.pump(const Duration(milliseconds: 2100));
    await gesture.up();
    await tester.pump();
    expect(find.text('키오스크 설정'), findsOneWidget);
  });

  // ── 가전 선택 화면 (서버 목록 연동 — 디자인 리뷰 후속) ────────────────────

  const customAppliance = ApplianceMap(
    id: 'custom_fan',
    name: '거실 선풍기',
    category: 'other',
    rows: 1,
    cols: 2,
    buttons: [
      ApplianceButton(id: 'F-01', label: '전원', x: 0, y: 0),
      ApplianceButton(id: 'F-02', label: '약풍', x: 1, y: 0),
    ],
  );

  testWidgets('수동 조작 진입 시 가전이 여럿이면 선택 화면부터 보여준다', (tester) async {
    useKioskViewport(tester);
    await _pumpKiosk(tester, FakeKioskApi()); // 서버 실패 → 내장 2종 폴백

    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();

    expect(find.text('어느 가전을 조작할까요?'), findsOneWidget);
    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('인덕션'), findsOneWidget);

    // 카드를 고르면 그 가전의 조작판으로
    await tester.tap(find.text('인덕션'));
    await tester.pump();
    expect(find.text('어느 가전을 조작할까요?'), findsNothing);
    expect(find.text('화력+'), findsOneWidget); // 인덕션 버튼
  });

  testWidgets('폰에서 등록한 커스텀 가전이 서버 목록으로 키오스크에 뜬다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, kInductionAppliance, customAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump(); // listAppliances 반영

    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();

    expect(find.text('거실 선풍기'), findsOneWidget);

    await tester.tap(find.text('거실 선풍기'));
    await tester.pump();
    expect(find.text('약풍'), findsOneWidget); // 커스텀 버튼판이 그대로 조작판
  });

  testWidgets('가전이 하나뿐이면 선택 화면 없이 바로 조작판으로 간다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();

    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();

    expect(find.text('어느 가전을 조작할까요?'), findsNothing);
    expect(find.text('즉석밥'), findsOneWidget); // 전자레인지 조작판
  });

  testWidgets('조작 중 가전이 폰에서 삭제되면 선택 화면으로 돌아간다', (tester) async {
    // 삭제된 가전의 버튼판을 계속 두면 서버 게이트(404)에 걸리기 전까지
    // 화면과 실물이 어긋난다 (교차 리뷰 치명 #1 클라이언트측)
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, kInductionAppliance, customAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();

    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();
    await tester.tap(find.text('거실 선풍기'));
    await tester.pump();
    expect(find.text('약풍'), findsOneWidget); // 조작판 진입

    // 폰에서 삭제됨 — 다음 목록 폴링(60초)에 반영
    api.applianceList = [kMicrowaveAppliance, kInductionAppliance];
    await tester.pump(const Duration(seconds: 61)); // 목록 폴링 타이머 발화
    await tester.pump(); // listAppliances future 완료
    await tester.pump(const Duration(milliseconds: 300)); // AnimatedSwitcher 소진

    expect(find.text('약풍'), findsNothing);
    expect(find.text('어느 가전을 조작할까요?'), findsOneWidget);
    expect(find.text('거실 선풍기'), findsNothing);
  });

  testWidgets('재부팅 후 저장된 커스텀 가전 선택이 서버 목록 도착 시 복원된다', (tester) async {
    // kAppliances에서만 찾으면 커스텀 선택이 기본값으로 되돌아갔다 (교차 리뷰 #6)
    useKioskViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync('kiosk-custom-restore');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}settings.json';
    KioskSettingsStore(path: path)
        .save(const KioskSettings(applianceId: 'custom_fan'));

    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, kInductionAppliance, customAppliance];
    await _pumpKiosk(
      tester,
      api,
      settings: KioskSettingsStore(path: path),
    );
    await tester.pump(); // 서버 목록 반영

    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();

    // '지난번' 배지가 저장된 커스텀 가전에 붙는다
    final badge = find.text('지난번');
    expect(badge, findsOneWidget);
    final badgeY = tester.getCenter(badge);
    final fanY = tester.getCenter(find.text('거실 선풍기'));
    expect((badgeY.dx - fanY.dx).abs() < 120, isTrue,
        reason: '배지가 거실 선풍기 카드에 있어야 한다');
  });

  // ── 설정 영속화 (재부팅 복원) ────────────────────────────────────────────

  testWidgets('저장된 설정(음성 꺼짐·큰 글씨·가전)이 시작 시 복원된다', (tester) async {
    useKioskViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync('kiosk-restore-test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}settings.json';
    KioskSettingsStore(path: path).save(const KioskSettings(
      ttsEnabled: false,
      largeText: true,
      applianceId: 'induction',
    ));

    final tts = FakeTts();
    await _pumpKiosk(
      tester,
      FakeKioskApi(),
      tts: tts,
      settings: KioskSettingsStore(path: path),
    );

    // 음성 안내 꺼짐 복원
    expect(tts.enabled, false);
    // 큰 글씨(1.22배) 복원 — 화면을 감싸는 MediaQuery에 반영된다
    final scalers = tester
        .widgetList<MediaQuery>(find.byType(MediaQuery))
        .map((m) => m.data.textScaler);
    expect(scalers, contains(const TextScaler.linear(1.22)));
    // 가전 선택 복원 — 대기 화면 탭으로 수동 조작에 들어가면 인덕션 맵
    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();
    expect(find.text('인덕션'), findsOneWidget);
  });

  testWidgets('큰 글씨 모드에서 전 화면(대기·수동·제안·실행·완료)이 800x480에 오버플로 없이 렌더된다',
      (tester) async {
    // 폰트 확대(교차 리뷰 #16) × 큰 글씨 1.22배가 결합해도 소형 화면이
    // 깨지지 않는지 — 오버플로는 테스트에서 FlutterError로 즉시 실패한다.
    useKioskViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync('kiosk-large-test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}settings.json';
    KioskSettingsStore(path: path)
        .save(const KioskSettings(largeText: true));

    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(
      tester,
      api,
      settings: KioskSettingsStore(path: path),
    );
    expect(find.byType(KioskSuggestionView), findsOneWidget); // suggestion

    api.suggestionList = [];
    await tester.tap(find.text('지금 실행')); // executing
    await tester.pump();
    expect(find.byType(KioskExecutingView), findsOneWidget);

    api.statusResult = const KioskStatus(
      running: false,
      lastStatus: 'succeeded',
      lastButtons: [],
      lastJobId: 'job-1',
    );
    await tester.pump(const Duration(seconds: 2)); // done
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);

    await tester.pump(KioskTimings.doneReturn); // 자동 idle 복귀
    await tester.pump();
    expect(find.byType(KioskIdleView), findsOneWidget);

    await tester.tap(find.byType(KioskIdleView)); // manual
    await tester.pump();
    expect(find.text('전자레인지'), findsOneWidget);
  });

  testWidgets('저장된 가전 id가 목록에 없으면 기본 가전으로 폴백한다', (tester) async {
    useKioskViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync('kiosk-fallback-test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}settings.json';
    KioskSettingsStore(path: path)
        .save(const KioskSettings(applianceId: 'no-such-appliance'));

    await _pumpKiosk(
      tester,
      FakeKioskApi(),
      settings: KioskSettingsStore(path: path),
    );

    await tester.tap(find.byType(KioskIdleView));
    await tester.pump();
    expect(find.text('전자레인지'), findsOneWidget);
  });
}
