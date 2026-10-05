// 키오스크 phase 머신 테스트 — KioskScreen(api:)로 fake 서비스를 주입해
// idle→suggestion→executing→done 전이와 job_id 대조 규칙을 검증한다.
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/estop.dart';
import 'package:simplelay_touchscreen/models/learning_status.dart';
import 'package:simplelay_touchscreen/models/scenario_run.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/services/kiosk_event_stream.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';
import 'package:simplelay_touchscreen/services/kiosk_tts_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_timings.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

class FakeKioskApi implements KioskApiService {
  @override
  Future<Map<String, dynamic>> routineRequest(Map<String, dynamic>? event) async => throw StateError('simulator unavailable');
  // 폰 연결 창은 이 파일의 관심사가 아니다 — 허브 없음으로 흉내 낸다.
  @override
  Future<Map<String, dynamic>> pairingSession({bool create = false}) async => throw StateError('pairing unavailable');
  @override
  Future<void> approvePairing(String requestId, bool approved) async => throw StateError('pairing unavailable');
  @override
  Future<void> closePairing() async {}
  @override
  Future<LearningStatus> learningStatus() async => throw StateError('offline');

  List<KioskSuggestion> suggestionList = [];
  // 서버 가전 목록 — 비어 있으면 화면이 내장 목록으로 폴백한다
  // null = 통신 실패(기본) — 이전의 "빈 목록 = 실패" 시절과 달리 이제 빈
  // 목록은 성공한 답이므로, 목록을 안 정한 테스트는 실패를 흉내 내야
  // 기존처럼 내장 폴백이 유지된다(B11).
  List<ApplianceMap>? applianceList;
  KioskStatus statusResult = const KioskStatus(running: false);
  AlertState alertState = AlertState.inactive;
  HealthStatus healthResult = const HealthStatus(ok: true);
  Object? executeError;
  Object? rejectError;
  String nextJobId = 'job-1';
  Completer<KioskJobAccepted>? approvalPending;
  final approvedIds = <String>[];
  final rejectedIds = <String>[];
  final mutedIds = <String>[];
  final snoozedIds = <String>[];
  final revisedIds = <String>[];
  @override
  Future<Map<String, List<String>>> revisionOptions(String id) async => {'30초 돌려줘': ['30초', '시작']};
  @override
  Future<KioskSuggestion> reviseSuggestion(String id, String purpose) async {
    revisedIds.add(id);
    final revised = KioskSuggestion(id: 'revised', purpose: purpose, occurrences: 0, applianceId: 'microwave', steps: ['30초', '시작']);
    suggestionList = [revised];
    return revised;
  }
  @override
  Future<void> snoozeSuggestion(String id) async {
    if (rejectError != null) throw rejectError!;
    snoozedIds.add(id);
  }
  int stopCalls = 0;

  // 비상정지 해제 확인(2026-10-05). statusAfterAck가 있으면 해제 성공 뒤 /status가 그것이 된다.
  EstopAckResult estopAckResult = const EstopAckResult(EstopAckOutcome.cleared);
  KioskStatus? statusAfterAck;
  int estopAckCalls = 0;

  @override
  Future<EstopAckResult> ackEstop() async {
    estopAckCalls++;
    final after = statusAfterAck;
    if (estopAckResult.cleared && after != null) statusResult = after;
    return estopAckResult;
  }

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
    if (approvalPending != null) return approvalPending!.future;
    return KioskJobAccepted(jobId: nextJobId);
  }

  @override
  Future<void> rejectSuggestion(String id, {bool mute = false}) async {
    if (rejectError != null) throw rejectError!;
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
  Future<List<ApplianceMap>?> listAppliances() async => applianceList;

  @override
  Future<List<NodeInfo>> listNodes() async => const [];

  @override
  Future<bool> registerNode(String applianceId, String baseUrl) async => true;

  @override
  Future<bool> unregisterNode(String applianceId) async => true;

  /// 대상별 준비 상태. 없으면 null(모름 — 막지 않는다).
  Map<String, KioskReadiness> readinessById = {};
  Map<String, String> scenarioNameMap = {};

  @override
  Future<KioskReadiness?> readiness(String applianceId) async =>
      readinessById[applianceId];

  @override
  Future<Map<String, String>> scenarioNames() async => scenarioNameMap;

  /// GET /scenarios/last-run. null이면 기록 없음.
  ScenarioRun? lastRun;
  int lastRunCalls = 0;

  @override
  Future<ScenarioRun?> scenarioLastRun() async {
    lastRunCalls++;
    return lastRun;
  }

  // ── 평소 화면(2026-09-30) ────────────────────────────────────────────
  AmbientInfo? ambientResult;
  List<ConnectionItem>? connectionsResult = kOkConnections;
  int connectionsCalls = 0;
  List<KioskRoutine>? routinesResult;
  RoutineTriggerResult? triggerResult;
  Object? triggerError;
  final triggeredRoutineIds = <String>[];

  int ambientCalls = 0;

  @override
  Future<AmbientInfo?> ambient() async {
    ambientCalls++;
    return ambientResult;
  }

  @override
  Future<List<ConnectionItem>?> connections() async {
    connectionsCalls++;
    return connectionsResult;
  }

  @override
  Future<List<KioskRoutine>?> routines() async => routinesResult;

  @override
  Future<RoutineTriggerResult> triggerRoutine(String id) async {
    triggeredRoutineIds.add(id);
    if (triggerError != null) throw triggerError!;
    return triggerResult ?? const RoutineTriggerResult(notice: '');
  }

  @override
  void dispose() {}
}

/// 세 연결이 모두 정상인 응답 — 배지가 없는 기본 상태.
const kOkConnections = [
  ConnectionItem(
      id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: '허브와 잘 연결돼 있어요.'),
  ConnectionItem(
      id: 'press', state: 'ok', title: '누름 장치가 준비됐어요', message: '지금은 연습용 누름 장치로 동작해요.'),
  ConnectionItem(
      id: 'plug', state: 'ok', title: '플러그가 연결돼 있어요', message: '가전이 끝나면 알려 드릴게요.'),
];

// ── G4: 다단계 실행의 단계별 결과(2026-09-29) ─────────────────────────────
// 두 단계 픽스처 — ThinQ 상태 확인됨 + 물리 실행기 보고.
const kTwoStepRun = ScenarioRun(
  jobId: 'job-1',
  scenarioId: 'evening_rest',
  status: 'succeeded',
  steps: [
    ScenarioRunStep(
      targetId: 'air_purifier',
      route: 'thinq',
      action: 'set_wind_strength',
      summary: '공기청정기 풍량 약하게',
      status: 'succeeded',
      receipt: 'accepted',
      confirmation: 'state_confirmed',
      executionMode: 'mock',
    ),
    ScenarioRunStep(
      targetId: 'microwave',
      route: 'physical',
      summary: '전자레인지 즉석밥',
      status: 'succeeded',
      receipt: 'accepted',
      confirmation: 'reported',
      executionMode: 'mock',
    ),
  ],
);

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

// 실행까지 가는 제안은 대상 가전이 있어야 한다(B10) — 대상 없는 제안은
// 실행 버튼이 잠기므로, 승인 흐름 테스트의 표본에는 대상을 명시한다.
// 다가오면 카드의 두 버튼(시작·다음에). '시작'은 버튼판 라벨과 겹쳐 키로 찾는다.
const _approveKey = ValueKey('suggestion-approve');
const _laterKey = ValueKey('suggestion-later');

const _sug = KioskSuggestion(
  id: 's1',
  purpose: '즉석밥 데워줘',
  occurrences: 3,
  applianceId: 'microwave',
);

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
  testWidgets('환경 근거 갱신은 음성을 반복하거나 표시 시간을 늘리지 않는다', (tester) async {
    final api = FakeKioskApi()..suggestionList = const [KioskSuggestion(
      id: 'env1', purpose: '에어컨 켜줘', occurrences: 0, timeBand: '환경',
      applianceId: 'aircon', reason: '지금 30°C — 더워요',
    )];
    final tts = FakeTts();
    await _pumpKiosk(tester, api, tts: tts);
    final spoken = tts.utterances.length;
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    api.suggestionList = const [KioskSuggestion(
      id: 'env1', purpose: '에어컨 켜줘', occurrences: 0, timeBand: '환경',
      applianceId: 'aircon', reason: '지금 31°C — 더워요',
    )];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('지금 31°C — 더워요'), findsOneWidget);
    expect(tts.utterances.length, spoken);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(KioskSuggestionView), findsNothing);
    expect(api.rejectedIds, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('무응답 제안은 같은 카드와 음성을 반복하지 않고 새 제안은 표시한다',
      (tester) async {
    final api = FakeKioskApi()..suggestionList = [_sug];
    final tts = FakeTts();
    await _pumpKiosk(tester, api, tts: tts);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(KioskSuggestionView), findsNothing);
    expect(tts.utterances.where((s) => s.contains('지금 할까요')), hasLength(1));
    expect(api.rejectedIds, isEmpty); // 무응답을 싫다는 피드백으로 보내지 않음
    api.suggestionList = const [KioskSuggestion(
      id: 's2', purpose: '새 제안', occurrences: 3, applianceId: 'microwave',
    )];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(KioskSuggestionView), findsOneWidget);
    expect(tts.utterances.where((s) => s.contains('지금 할까요')), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('다른 단말 처리 또는 서버 만료로 사라진 제안은 화면에서도 내린다',
      (tester) async {
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    expect(find.byType(KioskSuggestionView), findsOneWidget);
    api.suggestionList = [];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(KioskSuggestionView), findsNothing);
    expect(api.approvedIds, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('넘김 전달 실패는 카드와 재시도 수단을 유지한다', (tester) async {
    final api = FakeKioskApi()
      ..suggestionList = [_sug]
      ..rejectError = Exception('offline');
    await _pumpKiosk(tester, api);
    await tester.tap(find.byKey(_laterKey));
    await tester.pump();
    expect(find.byType(KioskSuggestionView), findsOneWidget);
    // 문구 통일(3c064ec) 뒤에도 실패를 알리고 카드를 남긴다.
    expect(find.textContaining('다음에 실행하겠다는 요청을 보내지 못했어요'), findsOneWidget);
    api.rejectError = null;
    await tester.tap(find.byKey(_laterKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(api.rejectedIds, ['s1']);
    expect(find.byType(KioskSuggestionView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 800x480 실기기 해상도에 맞춰 오버플로 없는 레이아웃으로 테스트
  void useKioskViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // 15.8형 패널 — 제품 사양표상 1920x1080(하드웨어-연결-설계 §0-1).
  // 설계 캔버스(800x480)보다 크므로 KioskCanvas가 통째로 확대해 채운다.
  void useFifteenInchViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('연결 안 되어 있으면 가전을 눌러도 버튼판 대신 연결 안내가 뜬다', (tester) async {
    // 사용자 혼란 방지: 연결 없이는 실제로 버튼도 못 누른다. 버튼판을 여는
    // 대신 무엇이 안 되는지 말하는 연결 모달을 연다.
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..healthResult = const HealthStatus(ok: false)
      ..applianceList = const [kMicrowaveAppliance];
    await _pumpKiosk(tester, api);

    await tester.tap(find.byKey(const ValueKey('strip-microwave')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(KioskIdleView), findsOneWidget);
    expect(find.byType(KioskConnectionModal), findsOneWidget);
  });

  testWidgets('연결돼 있으면 가전 아이콘을 눌러 내 가전으로 간다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..healthResult = const HealthStatus(ok: true, actuatorReady: true)
      ..applianceList = const [kMicrowaveAppliance, kInductionAppliance];
    await _pumpKiosk(tester, api);

    await tester.tap(find.byKey(const ValueKey('strip-induction')));
    await tester.pump(); // 탭 반영
    await tester.pump(const Duration(milliseconds: 500)); // AnimatedSwitcher 전환

    // 고른 가전의 판으로 바로 간다 — 다시 묻지 않는다
    expect(find.byType(KioskIdleView), findsNothing);
    expect(find.text('내 인덕션'), findsOneWidget);
  });

  testWidgets('평소 화면은 서버 목록에서 확인된 가전만 줄에 세운다', (tester) async {
    // 서버를 못 봤을 때 내장 폴백의 전자레인지를 세우면, 설치한 적 없는
    // 가전이 평소 화면에 선다.
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..healthResult = const HealthStatus(ok: true, actuatorReady: true);
    await _pumpKiosk(tester, api);

    expect(find.byType(KioskIdleView), findsOneWidget);
    expect(find.text('전자레인지'), findsNothing);

    api.applianceList = const [
      ApplianceMap(
        id: 'microwave',
        name: '전자레인지',
        category: 'microwave',
        rows: 1,
        cols: 1,
        buttons: [],
      ),
    ];
    // 가전 목록은 센서와 같은 60초 주기로 다시 받는다.
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();

    expect(find.text('전자레인지'), findsOneWidget);
  });

  testWidgets('15인치 사양 해상도(1920x1080)에서 가장자리 여백 안을 채우고, 확대된 좌표에서도 조작이 된다',
      (tester) async {
    useFifteenInchViewport(tester);
    final api = FakeKioskApi()
      ..healthResult = const HealthStatus(ok: true, actuatorReady: true)
      ..applianceList = const [kMicrowaveAppliance];
    await _pumpKiosk(tester, api);

    // 캔버스가 화면 전체를 차지한다(여백은 배경색으로 채워짐)
    expect(tester.getSize(find.byType(KioskCanvas)), const Size(1920, 1080));

    // 내부는 여전히 800x480 설계 세계 -- 레이아웃/오버플로 보장이 그대로다.
    final idleSize = tester.getSize(find.byType(KioskIdleView));
    expect(idleSize.width, KioskCanvas.design.width); // 논리 폭은 1920이 아니라 800

    // 그리고 실제로 **확대돼 그려진다**. 가장자리 48px을 비우고 남은
    // 1824x984 안에서 세로가 먼저 닿는다(984/480 = 2.05배 -> 800*2.05 = 1640).
    final painted = tester.getRect(find.byType(KioskIdleView));
    expect(painted.width, closeTo(1640, 1));
    final body = tester.getRect(find.byType(Scaffold));
    expect(body.top, closeTo(48, 1));
    expect(body.bottom, closeTo(1080 - 48, 1));

    // 확대 변환을 통과해도 히트테스트가 어긋나지 않는다(실제 터치 시연의 핵심)
    await tester.tap(find.byKey(const ValueKey('strip-microwave')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('내 전자레인지'), findsOneWidget);
  });

  testWidgets('서버 제안이 도착하면 idle → suggestion으로 전환된다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];

    await _pumpKiosk(tester, api);

    expect(find.byType(KioskSuggestionView), findsOneWidget);
    expect(find.byKey(_approveKey), findsOneWidget);
  });

  testWidgets('"다음에"는 mute 없이 거절한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    api.suggestionList = [];
    await tester.tap(find.byKey(_laterKey));
    await tester.pump();

    expect(api.rejectedIds, ['s1']);
    expect(api.mutedIds, isEmpty);
  });

  testWidgets('서버 재시작으로 작업이 사라지면 확인 불가, 복귀 후 진행 작업을 다시 추적한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    final tts = FakeTts();
    await _pumpKiosk(tester, api, tts: tts);
    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
    await tester.pump();
    // 재시작한 서버는 과거 job을 기억하지 못한다.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('실행 상태를 확인할 수 없어요'), findsOneWidget);
    expect(find.text('실행을 멈췄어요'), findsNothing);
    expect(find.text('다시 시도'), findsNothing);
    expect(tts.utterances.last, contains('상태를 확인할 수 없어요'));
    await tester.tap(find.text('닫기'));
    await tester.pump();
    api.statusResult = const KioskStatus(running: true,
        jobId: 'phone-job', applianceId: 'microwave');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(KioskExecutingView), findsOneWidget);
    expect(api.approvedIds, ['s1']); // 복구는 관찰만, 재전송하지 않는다.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('두 번째 접수를 기다리는 동안 이전 완료를 재사용하지 않는다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
    await tester.pump();
    api.statusResult = const KioskStatus(running: false,
        lastJobId: 'job-1', lastStatus: 'succeeded');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(KioskTimings.doneReturn);
    api.suggestionList = [const KioskSuggestion(id: 's2', purpose: '다시 데워줘',
        occurrences: 3, applianceId: 'microwave')];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    api.approvalPending = Completer<KioskJobAccepted>();
    await tester.tap(find.byKey(_approveKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsNothing);
    expect(find.byType(KioskExecutingView), findsOneWidget);
    api.approvalPending!.complete(const KioskJobAccepted(jobId: 'job-2'));
    await tester.pump();
    api.statusResult = const KioskStatus(running: false,
        lastJobId: 'job-2', lastStatus: 'safety_stopped');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.widget<KioskDoneView>(find.byType(KioskDoneView)).reason,
        KioskFailureReason.stopped);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('승인 → executing → job 완료 시 done → 자동 idle 복귀', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);

    // 승인하면 즉시 실행 화면으로 가고, 접수된 job_id를 추적한다
    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
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
    await tester.tap(find.byKey(_approveKey));
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
    await tester.tap(find.byKey(_approveKey));
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
    expect(tts.utterances.single, contains('즉석밥 데워줘'));
    expect(tts.utterances.single, contains('시작을 눌러'));

    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
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
    // 화면과 같은 말 -- '완료되었습니다'는 조리·세탁이 끝났다고 들린다.
    // 실행 환경을 모르면 눌렀다고 단정하지 않고 가전 확인을 부탁한다.
    expect(tts.utterances.last, contains('실제로 눌렀는지 가전을 확인해 주세요'));
    expect(tts.utterances.last, isNot(contains('완료')));
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
    await tester.tap(find.byKey(_approveKey));
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
    await tester.tap(find.byKey(_approveKey));
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
    await tester.tap(find.byKey(_approveKey));
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
    await tester.tap(find.byKey(_approveKey));
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

  testWidgets('재시도 중에는 보정 후 다시 시도 중이 크게 표시된다', (tester) async {
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

    // 심사석에서 읽히는 크기인지 — 보조문구가 아니라 상태 구절 자체가 크다.
    // 폰 실행 화면과 같은 말을 쓴다('자동 보정 중' → '보정 후 다시 시도 중').
    final banner = tester.widget<Text>(find.text('보정 후 다시 시도 중'));
    expect(banner.style!.fontSize, greaterThanOrEqualTo(30));
    expect(find.byIcon(Icons.autorenew), findsOneWidget);
    // 재시도 중에도 긴급 정지는 그대로 있다.
    expect(find.text('정지'), findsOneWidget);
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

    expect(find.text('보정 후 다시 시도 중'), findsNothing);
    // 제목과 hero가 같은 라벨을 쓰므로 hero 쪽 상태 구절로 확인한다
    expect(find.text('누르는 중'), findsOneWidget);
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

  testWidgets('제안 화면은 지금 고른 가전이 아니라 제안 자신의 대상을 말한다',
      (tester) async {
    useKioskViewport(tester);
    const fan = ApplianceMap(
      id: 'custom_fan',
      name: '거실 선풍기',
      category: 'other',
      rows: 1,
      cols: 1,
      buttons: [ApplianceButton(id: 'F-01', label: '전원', x: 0, y: 0)],
    );
    final api = FakeKioskApi()
      ..applianceList = const [kMicrowaveAppliance, fan]
      ..suggestionList = const [
        KioskSuggestion(
          id: 's-fan',
          purpose: '선풍기 켜줘',
          occurrences: 0,
          applianceId: 'custom_fan',
        ),
      ];

    await _pumpKiosk(tester, api);

    expect(find.byType(KioskSuggestionView), findsOneWidget);
    expect(find.text('거실 선풍기'), findsOneWidget);
    // 기본 선택(전자레인지)으로 메우지 않는다
    expect(find.text('전자레인지'), findsNothing);
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

  testWidgets('위 줄 방해 금지 단추를 누르면 방해 금지 선택이 열려요', (tester) async {
    useKioskViewport(tester);
    await _pumpKiosk(tester, FakeKioskApi());
    expect(find.byType(DndOverlay), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dnd-entry')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DndOverlay), findsOneWidget);
    expect(find.text('30분'), findsOneWidget);
  });

  testWidgets('설정에도 방해 금지 줄이 있고 같은 선택을 열어요', (tester) async {
    useKioskViewport(tester);
    await _pumpKiosk(tester, FakeKioskApi());
    await tester.tap(find.byKey(const ValueKey('settings-entry')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('settings-dnd')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('settings-dnd')));
    await tester.tap(find.byKey(const ValueKey('settings-dnd')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('키오스크 설정'), findsNothing);
    expect(find.byType(DndOverlay), findsOneWidget);
  });

  testWidgets('설정은 보이는 버튼을 한 번 눌러 열어요', (tester) async {
    useKioskViewport(tester);
    await _pumpKiosk(tester, FakeKioskApi());
    await tester.tap(find.byKey(const ValueKey('settings-entry')));
    await tester.pump(const Duration(milliseconds: 300));
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

  testWidgets('가전 아이콘을 누르면 묻지 않고 그 가전의 판으로 간다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, kInductionAppliance];
    await _pumpKiosk(tester, api);

    await tester.tap(find.byKey(const ValueKey('strip-induction')));
    await tester.pump();

    expect(find.text('어느 가전을 조작할까요?'), findsNothing);
    expect(find.text('화력+'), findsOneWidget); // 인덕션 버튼
  });

  testWidgets('루틴 안내(안내 한 줄)는 1분을 기다리지 않고 10초 안에 평소 화면에 뜬다', (tester) async {
    // 시연 v3 ④ 세탁 완료 장면은 40초다 — 60초 주기면 키오스크에 안 보인 채 넘어갔다(2026-10-06).
    useKioskViewport(tester);
    final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();
    expect(find.textContaining('빨래를 꺼내'), findsNothing);

    api.ambientResult = const AmbientInfo(
      greeting: '좋은 오후예요.',
      tip: AmbientTip(kind: 'routine', text: '세탁이 끝났어요. 빨래를 꺼내 널어 주세요', icon: 'notice'),
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(find.textContaining('빨래를 꺼내'), findsOneWidget);
  });

  testWidgets('폰에서 등록한 커스텀 가전이 서버 목록으로 키오스크에 뜬다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, kInductionAppliance, customAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump(); // listAppliances 반영

    expect(find.text('거실 선풍기'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('strip-custom_fan')));
    await tester.pump();
    expect(find.text('약풍'), findsOneWidget); // 커스텀 버튼판이 그대로 조작판
  });

  testWidgets('가전이 하나뿐이어도 줄에 서고, 누르면 그 판으로 간다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('strip-microwave')));
    await tester.pump();

    expect(find.text('어느 가전을 조작할까요?'), findsNothing);
    expect(find.text('즉석밥'), findsOneWidget); // 전자레인지 조작판
  });

  testWidgets('조작 중 가전이 폰에서 삭제되면 평소 화면으로 돌아간다', (tester) async {
    // 삭제된 가전의 버튼판을 계속 두면 서버 게이트(404)에 걸리기 전까지
    // 화면과 실물이 어긋난다 (교차 리뷰 치명 #1 클라이언트측)
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..applianceList = [kMicrowaveAppliance, kInductionAppliance, customAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('strip-custom_fan')));
    await tester.pump();
    expect(find.text('약풍'), findsOneWidget); // 조작판 진입

    // 폰에서 삭제됨 — 다음 목록 폴링(60초)에 반영
    api.applianceList = [kMicrowaveAppliance, kInductionAppliance];
    await tester.pump(const Duration(seconds: 61)); // 목록 폴링 타이머 발화
    await tester.pump(); // listAppliances future 완료
    await tester.pump(const Duration(milliseconds: 300)); // AnimatedSwitcher 소진

    expect(find.text('약풍'), findsNothing);
    expect(find.byType(KioskIdleView), findsOneWidget);
    expect(find.text('거실 선풍기'), findsNothing);
  });

  testWidgets('마지막 가전까지 삭제된 빈 목록도 성공한 답으로 반영된다', (tester) async {
    // 빈 목록을 실패와 함께 버리면(B11) 서버에 없는 가전의 조작판이
    // 계속 남는다 — 빈 목록은 "조작할 가전이 없다"는 사실이다.
    useKioskViewport(tester);
    final api = FakeKioskApi()..applianceList = [customAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('strip-custom_fan')));
    await tester.pump();
    expect(find.text('약풍'), findsOneWidget);

    api.applianceList = const []; // 폰에서 마지막 가전 삭제
    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('약풍'), findsNothing);
    expect(find.text('앱에서 가전을 추가해 주세요'), findsOneWidget);
  });

  testWidgets('목록 조회 실패는 보고 있던 가전 목록을 지우지 않는다', (tester) async {
    // 실패(null)와 빈 목록([])의 구분 — 일시적 통신 실패가 조작판을
    // 무너뜨리면 안 된다(B11).
    useKioskViewport(tester);
    final api = FakeKioskApi()..applianceList = [customAppliance];
    await _pumpKiosk(tester, api);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('strip-custom_fan')));
    await tester.pump();
    expect(find.text('약풍'), findsOneWidget);

    api.applianceList = null; // 서버에 못 닿음
    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('약풍'), findsOneWidget); // 유지
  });

  /// 제안 승인이 접수부터 실패 → 실패 화면의 '버튼으로 조작' → 가전 선택.
  Future<void> failToManual(WidgetTester tester, FakeKioskApi api) async {
    api
      ..suggestionList = [_sug]
      ..executeError = Exception('server down');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('버튼으로 조작'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

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

    // 가전 선택은 실패 화면의 '버튼으로 조작'에서 연다(평소 화면은 가전을
    // 아이콘으로 직접 고른다).
    await failToManual(tester, api);

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
    final api = FakeKioskApi();
    await _pumpKiosk(
      tester,
      api,
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
    // 가전 선택 복원 — 실패 화면의 가전 선택에서 '지난번'이 인덕션에 붙는다
    await failToManual(tester, api);
    final badge = tester.getCenter(find.text('지난번'));
    final induction = tester.getCenter(find.text('인덕션'));
    expect((badge.dx - induction.dx).abs() < 120, isTrue,
        reason: '배지가 인덕션 카드에 있어야 한다');
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

    final api = FakeKioskApi()
      ..suggestionList = [_sug]
      ..applianceList = [kMicrowaveAppliance];
    await _pumpKiosk(
      tester,
      api,
      settings: KioskSettingsStore(path: path),
    );
    expect(find.byType(KioskSuggestionView), findsOneWidget); // suggestion

    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey)); // executing
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
    // 완료 화면도 대상 줄('전자레인지')을 갖게 되어(B10 표본에 대상 명시),
    // 전환이 소진되기 전에 다음 화면을 열면 두 화면의 같은 글자가 겹친다.
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('strip-microwave'))); // 내 가전
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('내 전자레인지'), findsOneWidget);
    await tester.tap(find.text('해동')); // 누르기 확인
    await tester.pump();
    expect(find.text('누르기'), findsOneWidget);
    await tester.tap(find.text('그만두기'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('manual-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 동작 중(정지 버튼 대기)
    api.statusResult = const KioskStatus(
      running: false,
      holdState: 'hovering_stop',
      holdApplianceId: 'microwave',
      holdStopButton: '취소',
      holdExecutionMode: 'mock',
      lastOutcome: 'success',
      lastApplianceId: 'microwave',
      lastButtons: [KioskButtonResult(button: '해동', success: true)],
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskHoldView), findsOneWidget);
  });

  testWidgets('저장된 가전 id가 목록에 없으면 기본 가전으로 폴백한다', (tester) async {
    useKioskViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync('kiosk-fallback-test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}settings.json';
    KioskSettingsStore(path: path)
        .save(const KioskSettings(applianceId: 'no-such-appliance'));

    final api = FakeKioskApi();
    await _pumpKiosk(
      tester,
      api,
      settings: KioskSettingsStore(path: path),
    );

    await failToManual(tester, api);
    final badge = tester.getCenter(find.text('지난번'));
    final microwave = tester.getCenter(find.text('전자레인지'));
    expect((badge.dx - microwave.dx).abs() < 120, isTrue);
  });

  // ── 2026-09-29: last_outcome·ThinQ 경로·시나리오 카드 ──────────────────

  Future<KioskDoneView> finishWith(WidgetTester tester, FakeKioskApi api,
      KioskStatus status) async {
    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
    await tester.pump();
    api.statusResult = status;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    return tester.widget<KioskDoneView>(find.byType(KioskDoneView));
  }

  testWidgets('원격 실패(last_outcome=failed)는 정지 문구가 아니라 실행 실패로 안내한다',
      (tester) async {
    useKioskViewport(tester);
    final tts = FakeTts();
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api, tts: tts);
    final done = await finishWith(
      tester,
      api,
      // 옛 필드는 여전히 safety_stopped — 예전 화면은 이걸 '멈췄어요'로 읽었다.
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'safety_stopped',
          lastOutcome: 'failed',
          lastRoute: 'physical'),
    );
    expect(done.reason, KioskFailureReason.execution);
    expect(find.text('실행을 멈췄어요'), findsNothing);
    expect(tts.utterances.last, isNot(contains('멈췄어요')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('안전 정지(safety_stop)와 정지 요청(stopped)을 가른다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    final done = await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'safety_stopped',
          lastOutcome: 'safety_stop'),
    );
    expect(done.reason, KioskFailureReason.safetyStop);
    expect(find.text('안전하게 멈췄어요'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  const scenario = KioskSuggestion(
    id: 'sc1',
    purpose: '공기청정기 강풍으로 바꿀까요?',
    occurrences: 0,
    timeBand: '시나리오',
    reason: '전자레인지 모의 실행 성공 — 실제 가열을 확인한 것은 아니에요',
    isDemo: true,
    applianceId: 'air_purifier',
    scenarioId: 'cook_then_air',
    commands: [
      KioskSuggestionCommand(
        targetId: 'air_purifier',
        route: 'thinq',
        action: 'set_wind_strength',
        summary: '공기청정기 풍량 강풍',
      ),
    ],
  );

  testWidgets('시나리오 카드: 이름·근거·고정 명령·ThinQ 배지를 보이고 조작판 없이도 승인할 수 있다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..suggestionList = [scenario]
      ..scenarioNameMap = {'cook_then_air': '조리 확인 → 공기 관리'};
    await _pumpKiosk(tester, api);
    await tester.pump();

    expect(find.text('시나리오 · 조리 확인 → 공기 관리'), findsOneWidget);
    expect(find.text('공기청정기 풍량 강풍'), findsOneWidget);
    expect(find.text('ThinQ'), findsOneWidget);
    expect(find.textContaining('근거: 전자레인지 모의 실행'), findsOneWidget);
    final run = tester.widget<ElevatedButton>(find.byKey(_approveKey));
    expect(run.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('시나리오 카드: ThinQ 대상이 준비 안 됐으면 실행을 막고 이유를 말한다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..suggestionList = [scenario]
      ..readinessById = {
        'air_purifier': const KioskReadiness(
            applianceId: 'air_purifier',
            route: 'thinq',
            canExecute: false,
            reasons: ['가전이 오프라인이에요']),
      };
    await _pumpKiosk(tester, api);
    await tester.pump();

    expect(find.textContaining('가전이 오프라인이에요'), findsOneWidget);
    final run = tester.widget<ElevatedButton>(find.byKey(_approveKey));
    expect(run.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('승인 재검사 실패(409)면 실패 화면이 아니라 다시 확인 안내 후 처음 화면으로',
      (tester) async {
    useKioskViewport(tester);
    final tts = FakeTts();
    final api = FakeKioskApi()
      ..suggestionList = [scenario]
      ..executeError = KioskApiException(409,
          '승인한 내용과 지금 실행할 내용이 달라졌어요 — 다시 확인하고 승인해 주세요');
    await _pumpKiosk(tester, api, tts: tts);
    await tester.pump();

    api.suggestionList = [];
    await tester.tap(find.byKey(_approveKey));
    await tester.pump();
    await tester.pump();

    expect(find.byType(KioskDoneView), findsNothing);
    expect(find.byType(KioskIdleView), findsOneWidget);
    expect(find.text('제안 내용이 바뀌어 다시 확인이 필요해요'), findsOneWidget);
    expect(tts.utterances.last, '제안 내용이 바뀌어 다시 확인이 필요해요');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ThinQ 확인 못 함은 실패가 아니다 — 다시 시도 없이 접수 수준을 말한다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [scenario];
    await _pumpKiosk(tester, api);
    await tester.pump();
    final done = await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'unconfirmed',
          lastOutcome: 'unconfirmed',
          lastRoute: 'thinq',
          lastReceipt: 'accepted',
          lastConfirmation: 'none',
          lastExecutionMode: 'mock'),
    );
    expect(done.reason, KioskFailureReason.unconfirmed);
    expect(find.text('보냈지만 확인하지 못했어요'), findsOneWidget);
    expect(find.text('ThinQ · 접수됨'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
    expect(find.text('버튼으로 조작'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ThinQ 접수 불명은 접수 불명으로 말한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [scenario];
    await _pumpKiosk(tester, api);
    await tester.pump();
    final done = await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'unconfirmed',
          lastOutcome: 'unconfirmed',
          lastRoute: 'thinq',
          lastReceipt: 'unknown',
          lastConfirmation: 'none'),
    );
    expect(done.reason, KioskFailureReason.receiptUnknown);
    // 문구 통일(3c064ec): '접수 불명' → '받았는지 확인이 필요해요'. 확인됨으로 올리지 않는다.
    expect(find.text('ThinQ · 받았는지 확인이 필요해요'), findsOneWidget);
    expect(find.textContaining('상태 확인됨'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ThinQ 상태 확인됨만 성공이고, 모의면 실제 가전이 아니라고 말한다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [scenario];
    await _pumpKiosk(tester, api);
    await tester.pump();
    final done = await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'succeeded',
          lastOutcome: 'success',
          lastRoute: 'thinq',
          lastReceipt: 'accepted',
          lastConfirmation: 'state_confirmed',
          lastExecutionMode: 'mock'),
    );
    expect(done.success, isTrue);
    expect(find.text('가전 상태를 확인했어요'), findsOneWidget);
    expect(find.text('ThinQ · 상태 확인됨'), findsOneWidget);
    expect(find.textContaining('실제 가전 아님'), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ── 2026-09-29 후속: L3(가전 동작) 판정 · 세탁 완료 카드 ────────────────

  testWidgets('L3 확인됨이면 완료 화면이 가전 동작까지 확인했다고 말한다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    final done = await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'succeeded',
          lastOutcome: 'success',
          lastRoute: 'physical',
          lastConfirmation: 'operation_confirmed',
          lastExecutionMode: 'real',
          lastOperationConfirmed: true,
          lastOperationSource: 'mock',
          lastOperationDetail: '전력 파형에서 가열 시작을 확인했어요'),
    );
    expect(done.operationConfirmed, isTrue);
    expect(find.text('가전 동작도 확인했어요'), findsOneWidget);
    // 모의 판정의 true는 실제 동작 근거가 아니다 — 그 사실을 같이 말한다.
    expect(find.textContaining('모의 판정'), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('L3 미확인(false)은 확인하지 못했다고 말한다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'succeeded',
          lastOutcome: 'success',
          lastRoute: 'physical',
          lastExecutionMode: 'real',
          lastOperationConfirmed: false,
          lastOperationDetail: '전력 변화가 없었어요'),
    );
    expect(find.text('가전 동작은 확인하지 못했어요'), findsOneWidget);
    expect(find.text('가전 동작도 확인했어요'), findsNothing);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('L3 판정이 없으면 가전 동작 이야기를 새로 하지 않는다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    await finishWith(
      tester,
      api,
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'succeeded',
          lastOutcome: 'success',
          lastRoute: 'physical',
          lastExecutionMode: 'real'),
    );
    expect(find.textContaining('가전 동작'), findsNothing);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('실행 환경을 모르면 버튼 조작을 마쳤다고 단정하지 않는다', (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()..suggestionList = [_sug];
    await _pumpKiosk(tester, api);
    await finishWith(
      tester,
      api,
      // last_execution_mode 없음(unknown) · 확인 근거 없음.
      const KioskStatus(
          running: false,
          lastJobId: 'job-1',
          lastStatus: 'succeeded',
          lastOutcome: 'success',
          lastRoute: 'physical',
          lastConfirmation: 'none'),
    );
    expect(find.text('버튼 조작을 마쳤어요'), findsNothing);
    expect(find.textContaining('실제 조작 여부는 확인하지 못했어요'), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('세탁 완료 → 제습기(wash_then_dry) 카드도 조작판 없이 보여 준다',
      (tester) async {
    useKioskViewport(tester);
    const washThenDry = KioskSuggestion(
      id: 'sc2',
      purpose: '세탁이 끝났어요. 실내 건조를 위해 제습기를 켤까요?',
      occurrences: 0,
      timeBand: '시나리오',
      reason: '세탁기가 세탁 완료를 알렸어요 — 빨래를 실내에 널면 습도가 올라가요',
      isDemo: true,
      applianceId: 'dehumidifier',
      scenarioId: 'wash_then_dry',
      commands: [
        KioskSuggestionCommand(
          targetId: 'dehumidifier',
          route: 'thinq',
          action: 'set_power',
          summary: '제습기 전원 켜기',
        ),
      ],
    );
    final api = FakeKioskApi()
      ..suggestionList = [washThenDry]
      ..scenarioNameMap = {'wash_then_dry': '세탁 후 건조'};
    await _pumpKiosk(tester, api);
    await tester.pump();

    expect(find.text('시나리오 · 세탁 후 건조'), findsOneWidget);
    expect(find.textContaining('세탁이 끝났어요'), findsWidgets);
    expect(find.text('제습기 전원 켜기'), findsOneWidget);
    expect(find.text('ThinQ'), findsOneWidget);
    final run = tester.widget<ElevatedButton>(find.byKey(_approveKey));
    expect(run.onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ── G4: 끝난 job의 단계별 결과 ──────────────────────────────────────────

  const lastStep = KioskStatus(
      running: false,
      lastJobId: 'job-1',
      lastStatus: 'succeeded',
      lastOutcome: 'success',
      lastRoute: 'physical',
      lastReceipt: 'accepted',
      lastConfirmation: 'reported',
      lastExecutionMode: 'mock');

  testWidgets('다단계 실행이 끝나면 완료 화면이 그 job의 단계별 결과를 보인다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..suggestionList = [scenario]
      ..lastRun = kTwoStepRun;
    await _pumpKiosk(tester, api);
    await tester.pump();
    final done = await finishWith(tester, api, lastStep);
    await tester.pump();

    expect(api.lastRunCalls, greaterThan(0));
    expect(done.success, isTrue);
    expect(find.text('1. 공기청정기 풍량 약하게'), findsOneWidget);
    expect(find.text('ThinQ · 모의 실행 · 상태 확인됨 · 성공'), findsOneWidget);
    expect(find.text('2. 전자레인지 즉석밥'), findsOneWidget);
    expect(find.text('물리 버튼 · 모의 실행 · 누름 장치의 응답을 받았어요 · 성공'),
        findsOneWidget);
    // 한 줄 요약(마지막 단계 기준)은 그대로 남는다.
    expect(find.text('물리 버튼 · 누름 장치의 응답을 받았어요'), findsOneWidget);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('last-run이 다른 job의 기록이면 단계 목록을 보이지 않는다',
      (tester) async {
    useKioskViewport(tester);
    final api = FakeKioskApi()
      ..suggestionList = [scenario]
      ..lastRun = const ScenarioRun(
        jobId: 'job-0',
        status: 'succeeded',
        steps: [
          ScenarioRunStep(
              targetId: 'a', route: 'thinq', summary: '이전 단계 1', status: 'succeeded'),
          ScenarioRunStep(
              targetId: 'b', route: 'physical', summary: '이전 단계 2', status: 'succeeded'),
        ],
      );
    await _pumpKiosk(tester, api);
    await tester.pump();
    await finishWith(tester, api, lastStep);
    await tester.pump();

    expect(find.textContaining('이전 단계'), findsNothing);
    expect(find.textContaining('1. '), findsNothing);
    await tester.pump(KioskTimings.doneReturn);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
