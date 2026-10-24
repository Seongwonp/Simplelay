import 'package:routine_rehearsal/routine_rehearsal.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;

import 'package:flutter/material.dart';

import '../models/action_name.dart';
import '../models/ambient.dart';
import '../models/appliance.dart';
import '../models/auto_run.dart';
import '../models/command_result.dart';
import '../models/estop.dart';
import '../models/josa.dart';
import '../models/kiosk_history.dart';
import '../models/thinq.dart';
import '../models/scenario_run.dart';
import '../models/thinq_run.dart';
import '../services/kiosk_api_service.dart';
import '../services/kiosk_event_stream.dart';
import '../services/kiosk_settings_store.dart';
import '../services/kiosk_tts_service.dart';
import '../theme/kiosk_colors.dart';
import '../widgets/kiosk/appliance_select_view.dart';
import '../widgets/kiosk/auto_run_view.dart';
import '../widgets/kiosk/auto_run_notice.dart';
import '../widgets/kiosk/danger_alert_overlay.dart';
import '../widgets/kiosk/dnd_overlay.dart';
import '../widgets/kiosk/estop_banner.dart';
import '../widgets/kiosk/done_view.dart';
import '../widgets/kiosk/connection_status.dart';
import '../widgets/kiosk/executing_view.dart';
import '../widgets/kiosk/history_view.dart';
import '../widgets/kiosk/hold_view.dart';
import '../widgets/kiosk/idle_top.dart' show connectionsForDisplay;
import '../widgets/kiosk/idle_view.dart';
import '../widgets/kiosk/kiosk_canvas.dart';
import '../widgets/kiosk/kiosk_modal.dart';
import '../widgets/kiosk/kiosk_phase.dart';
import '../widgets/kiosk/kiosk_tab_bar.dart';
import '../widgets/kiosk/kiosk_timings.dart';
import '../widgets/kiosk/manual_view.dart';
import '../widgets/kiosk/past_result_line.dart';
import '../widgets/kiosk/suggestion_view.dart';
import '../widgets/kiosk/settings_overlay.dart';
import '../widgets/kiosk/top_progress_bar.dart';

/// 잠시 쉬기 저장이 실패해 이번 세션에만 적용됐을 때(서버 `persisted: false`, 2026-10-14 HIGH 재확인 M-R1) — 폰과 같은 문장.
const kSettingNotSavedNotice = '저장하지 못해 지금만 바뀌어요. 본체를 다시 켜면 예전 설정으로 돌아가요.';

/// 방해 금지 요청이 본체에 닿지 않았다(통신 끊김·본체 오류) — 바뀐 줄 알지 않게 말하고 창을 둔다(검토 10/19 코어 6차).
/// 켜기·끄기 둘 다 같은 창에서 보내므로 '바꾸지 못했어요'로 말한다.
const kDndNotSentNotice = '방해 금지를 바꾸지 못했어요. 잠시 뒤 다시 눌러 주세요.';

/// 실행 접수 응답을 받지 못했을 때(검토 10/19) — 본체가 이미 시작했을 수 있다. 정지 단추는 그대로 둔다.
const kAdmitUnknownMessage = "본체 답을 받지 못했어요. 시작됐을 수 있어요. 멈추려면 '정지'를 누르세요.";

const _pollInterval = Duration(milliseconds: 2000);
const _healthInterval = Duration(seconds: 10);

/// 안내 한 줄(/ambient) 조회가 이만큼 연속으로 실패하면 마지막 안내를 접는다(Copilot#4). 그전에는 유지한다.
const _ambientStaleAfter = Duration(minutes: 10);
const _sensorInterval = Duration(seconds: 60);
const _alertInterval = Duration(seconds: 3);
// 가전 줄 '켜짐' — 서버 기억만 읽으므로(ThinQ 호출 없음) 짧아도 된다(2026-10-16).
const _powerInterval = Duration(seconds: 10);
// 타이밍 상수는 KioskTimings(위젯과 공유) 참조 — 여기 별도 정의 금지
// 카운트다운 길이는 설정(KioskSettings.countdownSeconds)에서 온다 —
// 여기 상수는 설정이 없을 때의 기본값 경로로만 쓰인다.
const _doneReturnDuration = KioskTimings.doneReturn;
// 실행 중 /status가 이 시간 동안 한 번도 응답하지 않으면 서버 유실로 판정 —
// "실행 중" 화면에 영원히 갇히는 대신 실패 화면으로 탈출한다.
const _statusLostTimeout = Duration(seconds: 30);
// 접수 응답을 잃은 뒤 본체가 쉬고 결과도 그대로인 폴링이 이만큼 이어지면 결과 화면('어떻게 됐는지 확인하지 못했어요')으로.
const _admitUnknownIdlePolls = 3;
// 접수 응답 전에 누른 정지를, 실행을 못 찾은 채로 지키는 시간 — 늦게 접수된 실행도 멈춘다. 지나면 남의 실행을 멈추지 않게 버린다.
const _pendingStopWindow = Duration(seconds: 20);

/// 조용한 시간에 화면을 만지면 이만큼 평소 밝기로 둔다(사용자 결정 10/18 — 예: 30초).
const kQuietWakeDuration = Duration(seconds: 30);

/// 제안 화면 '시간 더 주기'가 늘리는 초(접근성 감사 10/18).
const kSuggestionExtendSeconds = 60;

class KioskScreen extends StatefulWidget {
  const KioskScreen({
    super.key,
    this.appliance = kMicrowaveAppliance,
    this.api,
    this.tts,
    this.events,
    this.settings,
  });

  final ApplianceMap appliance;

  /// 테스트에서 fake를 주입하기 위한 지점 — 미지정 시 localhost 기본 서비스.
  final KioskApiService? api;

  /// 음성 안내(espeak-ng) — 테스트에서 발화 내용 검증용 주입 지점.
  final KioskTtsService? tts;

  /// SSE 이벤트 스트림 — 테스트에서 실제 네트워크 연결·재접속 타이머를
  /// 만들지 않도록 fake를 주입하는 지점.
  final KioskEventStream? events;

  /// 설정 영속화(파일). null이면 세션 한정으로만 동작 — 테스트가 실제
  /// 홈 디렉터리 파일을 건드리지 않게 하는 기본값이고, 프로덕션은
  /// main.dart가 명시적으로 주입한다.
  final KioskSettingsStore? settings;

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  late final KioskApiService _api = widget.api ?? KioskApiService();
  // 주입받은 서비스는 호출자 소유 — 내부 생성분만 dispose한다
  late final bool _ownsApi = widget.api == null;
  late final KioskTtsService _tts = widget.tts ?? KioskTtsService();
  late final KioskEventStream _events =
      widget.events ?? KioskEventStream();
  // 큰 글씨 모드 — settings 주입 시 파일에 영속화, 아니면 세션 한정
  bool _largeText = false;

  /// 고대비(사용자 결정 10/18) — 큰 글씨와 같은 파일에 저장. 색 토큰([KioskColors])을 바꾸고 화면 전체를 다시 그린다.
  bool _highContrast = false;

  /// 어두운 화면(시안 B 10/24, 설정 '어두운 화면'). 기본은 밝은 화면.
  bool _darkMode = false;

  /// 조용한 시간에 화면을 만져 잠시 평소 밝기다([kQuietWakeDuration] 뒤 다시 어둡게).
  bool _quietAwake = false;
  Timer? _quietWakeTimer;

  /// 처음 화면 '지난 일' 한 줄(사용자 결정 10/18) — 실패·'확인 못 함' 결과. '확인'을 누르거나 다른 기기(폰 '기록 보기')에서
  /// 확인할 때까지 남는다(본체 확인 표시, 2026-10-19).
  KioskPastResult? _pastResult;

  /// 사람이 확인한 실행(본체 GET /acks, 2026-10-19) — 키오스크·폰 어디서 확인했든. 지난 일 줄·가전 칸 '!'이 이것을 본다.
  Map<String, String> _ackedJobs = const {};

  /// 결과 화면이 뜬 시각 — 지난 일 한 줄의 시각.
  DateTime _doneAt = DateTime.now();

  late ApplianceMap _currentAppliance;
  // 서버 가전 목록 — 폰에서 등록한 커스텀 가전이 여기로 들어온다.
  // 서버가 죽어 있으면 하드코딩 내장 목록으로 폴백(오프라인 우선).
  List<ApplianceMap> _appliances = kAppliances;
  // 위 목록이 서버에서 온 것인가. 내장 폴백일 때는 대기 화면이 가전 이름을
  // 말하지 않는다 -- 설치한 적 없는 전자레인지를 세우게 된다.
  bool _appliancesFromServer = false;
  // 수동 조작에서 지금 다루는 가전. null이면 선택 화면을 보여준다.
  ApplianceMap? _manualAppliance;
  // 저장된 가전 id가 내장 목록에 없으면(커스텀) 서버 목록 도착까지 보류 —
  // 재부팅 직후 kAppliances에서만 찾으면 커스텀 선택이 기본값으로
  // 되돌아갔다 (교차 리뷰 #6).
  String? _pendingRestoreApplianceId;
  bool _showSettings = false;

  KioskPhase _phase = KioskPhase.idle;
  HealthStatus _health = HealthStatus.disconnected;
  SensorData? _sensorData;
  String _executionMode = 'unknown';
  DateTime _now = DateTime.now();
  bool _showDnd = false;

  /// 잠시 쉬기 요청이 오가는 중 — 다른 시간·닫기를 받지 않는다(검토 10/19 코어 6차). 겹친 요청은 먼저 끝난 응답이 창을 닫고
  /// 늦게 끝난 쪽 시간이 남았다.
  bool _dndBusy = false;
  AlertState _alert = AlertState.inactive;
  bool _alertAcknowledged = false;

  KioskSuggestion? _currentSuggestion;
  // 무응답은 거절로 보내지 않는다. 현재 서버 목록의 카드별 자동 노출만
  // 한 번으로 제한한다. 재시작 고유 ID를 서버가 발급하므로 새 제안은 보인다.
  final Set<String> _shownSuggestionIds = {};
  bool _dismissingSuggestion = false;
  int _cdRemaining = KioskTimings.countdownSeconds;
  // 이번 제안 카드의 카운트다운 전체 길이 — 설정 값에서 시작해 '시간 더 주기'로 늘어난다(진행 막대가 1을 넘지 않게).
  int _cdTotal = KioskTimings.countdownSeconds;
  int _countdownSeconds = KioskTimings.countdownSeconds;
  Timer? _countdownTimer;

  String _execTitle = '';
  // 위쪽 진행 막대. **서버가 준 단계 수로만** 채운다 -- 예전의 9초짜리 시간
  // 채움은 남은 시간을 아는 척하는 가짜 진행이었다.
  double _execBarValue = 0;
  List<KioskButtonResult>? _lastButtons;

  // job 모델: 이 화면이 따라가는 실행의 job_id. 내가 시작한 실행은 접수 응답에서,
  // 폰 앱이 시작한 실행은 idle 폴링의 /status.job_id에서 얻는다. 완료 판정은
  // last_job_id 대조 — 이전 실행 결과를 내 것으로 오인하는 레이스가 없다.
  String? _activeJobId;
  // 따라가는 실행이 루틴이면(본체가 GET /jobs에 routine_run_id를 실었다, 검토 10/19) 그 루틴 실행 번호·지금 차례·그 구간의
  // 실행 번호와 구간 사이 기다림. 정지는 그 루틴만 멈추는 /routines/runs/{id}/stop으로 먼저 보낸다.
  String? _execRoutineRunId;
  int? _execRoutineSegment;
  String? _execRoutineSegmentJobId;
  bool _execRoutineWaiting = false;
  DateTime? _lastStatusOk;
  bool _pollInFlight = false;
  // 내 job의 흔적이 안 보인 연속 폴링 수 — 시작 직후 창은 정상, 계속되면
  // (서버 재시작·추월 유실) 실행 화면 고착 대신 실패로 탈출한다.
  int _foreignPolls = 0;

  // 실행 화면에서 정지를 누른 뒤의 상태(검토 10/19) — 보냈으면 '멈추는 중', 닿지 않았으면 그 말과 정지 단추 그대로.
  KioskExecStop _execStop = KioskExecStop.none;

  // 실행 접수(/approve·/execute-buttons) 세대와 응답 대기(검토 10/19). 실행 화면에 들어설 때마다 세대가 바뀌고,
  // 응답은 자기 세대일 때만 화면·_activeJobId를 바꾼다. 응답을 기다리는 동안·실행 화면에서는 새 접수를 받지 않는다.
  int _admitGen = 0;
  bool _accepting = false;
  bool get _admitting => _accepting || _phase == KioskPhase.executing;

  // 접수 응답 전에 정지를 눌렀다(검토 10/19) — 그때 본체에는 아직 실행이 없어 /stop이 아무것도 멈추지 못할 수 있다.
  // job_id가 오는 대로 /stop을 다시 보낸다. 그동안 화면은 '멈추는 중'.
  // 응답이 끊겨도·본체에서 실행을 이어받아도 지우지 않는다(검토 10/19 코어 4차) — 그 실행이 끝나거나 본체가 쉴 때까지
  // 폴링마다 다시 보낸다([_followPendingStop]). 새로 시작하는 실행에는 넘기지 않는다.
  bool _stopWhileAccepting = false;
  DateTime? _stopAskedAt;

  // 접수 응답을 잃었다(시간 초과·연결 끊김·5xx, 검토 10/19 코어 4차) — 본체가 이미 시작했을 수 있다. 실행 화면과 정지 단추를
  // 그대로 두고 /status에서 도는 실행을 이어받는다. 접수 전 마지막 결과 번호와 다른 결과가 보이면 그 사이 끝난 실행이다.
  bool _admitUnknown = false;
  int _admitUnknownPolls = 0;
  bool _admitBaseKnown = false;
  String? _admitBase;

  // 지금 접수의 요청 번호(본체 client_request_id, 검토 10/19). 응답을 잃으면 이 번호로 내 실행을 찾는다 —
  // 그때 마침 도는 실행(자동 실행·폰)을 내 것으로 이어받지 않는다. 옛 본체(조회 없음)일 때만 종전처럼 /status로 찾는다.
  String? _admitRequestId;

  String? _currentButton;

  // 이 실행에서 이미 누른 버튼(화면이 본 차례대로, 평가 3차 10/18) — 실행 화면 버튼판의 끝난 칸 ✓.
  // 서버는 지금 버튼만 준다. 지금 버튼이 다른 버튼으로 바뀌면 앞 버튼은 누른 것이다(사이를 놓친 버튼은 표시하지 않는다).
  List<String> _execDoneButtons = const [];

  /// 승인한 카드에 묶인 버튼(명령 하나·누름 장치 경로·버튼 둘 이상일 때만, 10/24 QA). 본체는 승인 명령 수를 단계 수로 실어
  /// '30초 → 시작'(명령 하나에 버튼 둘)이 '누를 버튼 1개 중 1번째'로 보였다 — 이때 진행은 이 버튼 수로 센다. 첫 차례에만 쓴다.
  List<String>? _execPlanButtons;
  int? _currentAttempt;
  int? _completedSteps;
  double? _verificationConfidence;
  String? _verificationDetail;
  int? _totalSteps;
  // 이 실행이 대상으로 삼은 가전 -- 제안 승인은 제안의 대상, 수동은 조작판의
  // 가전, 폰이 시작한 실행은 서버가 말해준 대상.
  String? _execApplianceId;

  /// 이 실행이 LG 가전 명령 하나뿐인가(사용자 요청 10/18) — 실행·결과 화면을 버튼판 없이 기다림·결과 창으로.
  /// 승인에 묶인 명령이 LG 가전 하나(또는 LG 가전 상세에서 바꾼 것)일 때만. 이어받은 실행·섞인 루틴은 종전 화면.
  bool _execThinqOnly = false;

  /// LG 가전 실행의 하려는 일을 알아볼 문장(승인에 묶인 명령 요약·LG 가전 상세에서 고른 이름, 평가 10차 10/18).
  /// 이어받은 실행은 모른다(null) — 화면이 지어내지 않고 '설정을 바꾸고 있어요'.
  String? _execThinqActionText;

  /// 이어받은 실행을 LG 가전 화면으로 보일까(평가 10차 10/18) — 서버가 지금 단계 경로 thinq·전체 1단계라고 말하고,
  /// 대상 가전을 알면 그 가전도 LG 가전일 때만([isAdoptedThinqRun]).
  bool _adoptedThinq(KioskStatus st) {
    final id = st.applianceId;
    final a = id == null ? null : _findIn(_appliances, id);
    return isAdoptedThinqRun(route: st.route, totalSteps: st.totalSteps, applianceIsThinq: a?.isThinq);
  }

  bool _doneSuccess = true;
  String _doneLabel = '';
  KioskFailureReason? _doneReason;
  // 끝난 실행의 경로·확인 수준(서버 값, 옛 서버면 null).
  String? _doneRoute;
  String? _doneConfirmation;
  /// 끝난 실행의 확인 근거 원값(2026-10-14, /status last_confirmation) — ThinQ 성공 문장을 확인한 사실만큼 고른다.
  String? _doneRawConfirmation;
  String? _doneDetail;
  // L3(가전 동작) 판정. null은 '판정하지 않았다' — 화면이 말하지 않는다.
  bool? _doneOperationConfirmed;
  String? _doneOperationSource;

  /// 모션 걸림 등으로 재시도 없이 멈춘 원인(2026-10-14, /status last_abort_reason).
  String? _doneAbortReason;

  /// 이미 화면에 반영한 마지막 job(서버 last_job_id, 2026-10-14 발견 3). 첫 조회에서 정한다 — 켜기 전 결과는
  /// 띄우지 않는다. 폴링 사이에 시작해 끝난 짧은 실행(0.45 s)·다른 단말 정지를 이 값이 바뀐 것으로 잡는다.
  String? _seenLastJobId;
  bool _seenLastJobInit = false;

  /// 자동 실행 결과 한 줄(2026-10-14, C2). 이미 알린 job과 첫 조회 때의 job은 다시 알리지 않는다.
  String? _seenAutoJobId;
  bool _seenAutoInit = false;
  String? _autoNotice;
  Timer? _autoNoticeTimer;

  /// 정지로 멈춘 실행의 확인 단계(2026-10-13, /status last_stop_level).
  String? _doneStopLevel;
  int? _doneStopAckMs;

  /// 결과 화면 '다시 멈추기'(누름 장치가 멈췄는지 모르는 정지, 평가 15차 10/18)를 누른 결과 — 'sent' | 'failed' | null.
  String? _doneStopAgain;

  /// 결과가 먼저 오고 정지 보고가 늦게 올 때의 짧은 후속 조회(평가 2026-10-13 M1). 화면 문구만 고친다.
  Timer? _stopFollowTimer;

  /// 정지로 끝난 job의 확인 보고(stop_level)를 아직 기다리는 중(평가 8차 10/18) — 결과 화면은 그동안 진행 상태
  /// ('멈추는 중이에요', 처음 화면 단추 없음)로 보이고, 보고가 오거나 기다리기를 그만두면 결과(멈췄어요/확인하지 못했어요)로 바뀐다.
  bool _stopPending = false;
  // 화면의 '길어도 N초' 말과 같은 값(휴리스틱 평가 10/18) — 한 곳([KioskTimings])에서.
  static const _stopFollowInterval = KioskTimings.stopFollowInterval;
  static const _stopFollowTries = KioskTimings.stopFollowTries;
  String? _doneOperationDetail;
  // 끝난 다단계 실행의 단계별 결과(G4). **이 job의 기록일 때만** 채운다.
  List<ScenarioRunStep> _doneRunSteps = const [];

  // 시나리오 카드 — 이름(GET /scenarios)과 대상별 준비 상태(GET /readiness/{id}).
  Map<String, String> _scenarioNames = const {};
  String? _scenarioBlockedWhy;
  // 실패 화면의 '다시 시도'가 무엇을 다시 할지 — 실행을 시작한 쪽이 심는다.
  Future<void> Function()? _retryAction;

  // ── 평소 화면(2026-09-30) ───────────────────────────────────────────
  AmbientInfo? _ambient;
  int _ambientFailures = 0;
  // null = 허브에 못 닿음. 첫 응답 전에는 _connectionsLoaded가 거짓이다.
  List<ConnectionItem>? _connections;
  bool _connectionsLoaded = false;
  bool _connectionsChecking = false;
  // 열려 있는 연결 모달의 항목 id — 다시 확인하면 새 내용으로 바뀐다.
  String? _openConnectionId;
  // 사용자 루틴(GET /routines). null = 아직 못 받음.
  List<KioskRoutine>? _routines;
  // 가전 줄의 순서 근거 — /status에서 읽는다.
  Set<String> _runningIds = const {};
  Set<String> _attentionIds = const {};
  // 켜져 있다고 확인된 ThinQ 가전 — GET /thinq/power(서버 기억, 클라우드 호출 없음). 실패·모름은 빈 집합.
  Set<String> _onIds = const {};

  /// 꺼져 있다고 서버가 본 ThinQ 가전(평가 10차 10/18) — 같은 GET /thinq/power 응답.
  Set<String> _offIds = const {};
  // 공기청정기 센서 공기질 — GET /thinq/air(서버 기억, 클라우드 호출 없음, 2026-10-16). 모름·오래됨·실패는 null(줄 없음).
  KioskAirReading? _air;
  KioskNextRun? _nextRun;

  /// 아래 탭(시안 B 10/24) — 평소 화면에서 고른 탭(홈·자동 실행·기록). 가전 고르기·조작 화면은 늘 '가전'이다.
  /// 처음 화면으로 돌아갈 때([_toIdle]) 홈으로.
  KioskTab _homeTab = KioskTab.home;

  /// 화면 안 확인 창(누르기 확인·LG 가전 설정 확인·보내는 중)이 떠 있는 수 — 0보다 크면 탭 줄을 숨긴다.
  final ValueNotifier<int> _tabSuppress = ValueNotifier(0);

  /// '자동 실행' 탭 목록(GET /routines/next, 읽기만). null = 못 불러옴.
  List<KioskNextRun>? _upcomingRuns;
  bool _upcomingLoading = false;

  /// '기록' 탭 목록(GET /history, 읽기만). null = 못 불러옴.
  List<KioskHistoryEntry>? _historyEntries;
  bool _historyLoading = false;

  /// '오늘은 건너뛰기'·'되돌리기'를 보내는 중(2026-10-18) — 그동안 단추를 막아 같은 요청을 두 번 보내지 않는다.
  bool _nextRunBusy = false;

  /// 건너뛰기 실패 안내 한 줄(서버 detail 또는 짧은 말). 잠시 뒤 지운다.
  String? _nextRunNotice;
  Timer? _nextRunNoticeTimer;

  /// 건너뛰기 응답이 오면 늘린다 — 그 전에 떠난 GET /routines/next 응답이 새 상태를 덮지 않게.
  int _nextRunGen = 0;

  // ── 동작 중: 정지 버튼 대기·보관(2026-09-30) ─────────────────────────
  KioskStatus? _hold;
  DateTime _holdSince = DateTime.now();

  /// 사람이 '처음 화면으로'로 나온 연습 대기(평가 12차 10/18) — 같은 대기를 평소 화면 조회가 다시 띄우지 않게 기억한다.
  /// 서버 대기는 그대로다(연습 가전이 끝나면 보관, 새 실행이 시작되면 풀린다). 대기가 사라지면 잊는다.
  String? _leftPracticeHold;
  bool _holdStopRequested = false;
  bool _holdStopFailed = false;
  // 짧게 보여 주고 평소 화면으로 돌아가는 타이머(보관 완료).
  Timer? _doneReturnTimer;
  bool _doneHeld = false;
  // 성공 결과 화면이 처음 화면으로 돌아가기까지 남은 초(접근성 감사 10/18 — 화면에 숫자로 보인다).
  int? _doneRemaining;
  Timer? _holdReturnTimer;
  // 사람이 확인해야 하는 결과(미확인·이상)를 한 번만 말하기 위한 기록.
  String? _holdSpokenKey;

  // ── 비상정지 걸림(2026-10-05) — /status.estop_latched. 해제는 사람이 확인한 뒤에만.
  bool _estopLatched = false;
  String? _estopDetail;
  // 경고 안에서 확인 문장을 보이는 중.
  bool _estopConfirming = false;
  bool _estopAcking = false;
  // 마지막 해제 시도가 실패한 이유 — 풀릴 때까지 남긴다.
  String? _estopMessage;

  Timer? _pollTimer;
  Timer? _healthTimer;
  Timer? _clockTimer;
  Timer? _sensorTimer;
  Timer? _alertTimer;
  Timer? _powerTimer;

  // 토글·가전 변경 시 현재 상태를 파일로 저장 (settings 미주입이면 no-op)
  void _persistSettings() {
    widget.settings?.save(KioskSettings(
      ttsEnabled: _tts.enabled,
      largeText: _largeText,
      highContrast: _highContrast,
      darkMode: _darkMode,
      applianceId: _currentAppliance.id,
      countdownSeconds: _countdownSeconds,
    ));
  }

  @override
  void initState() {
    super.initState();
    _currentAppliance = widget.appliance;
    // 저장된 설정 복원 — 재부팅 후에도 음성 안내·큰 글씨·가전 선택 유지.
    // 저장된 가전 id가 현재 빌드의 가전 목록에 없으면(맵 개편 등) 기본값.
    final saved = widget.settings?.load();
    if (saved != null) {
      _tts.enabled = saved.ttsEnabled;
      _largeText = saved.largeText;
      _highContrast = saved.highContrast;
      _darkMode = saved.darkMode;
      _countdownSeconds = saved.countdownSeconds;
      var restored = false;
      for (final a in kAppliances) {
        if (a.id == saved.applianceId) {
          _currentAppliance = a;
          restored = true;
          break;
        }
      }
      if (!restored && saved.applianceId != null) {
        // 커스텀 가전 — 서버 목록이 오면 _fetchAppliances가 마저 복원한다
        _pendingRestoreApplianceId = saved.applianceId;
      }
    }
    // 고대비는 저장값으로(없으면 평소 색). 색 토큰은 앱 전체가 함께 쓰는 값이다.
    KioskColors.setDarkMode(_darkMode);
    KioskColors.setHighContrast(_highContrast);
    _checkHealth();
    _fetchSensors();
    _fetchAppliances();
    _fetchAmbient();
    _fetchConnections();
    _fetchRoutines();
    _fetchAlert();
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    _healthTimer = Timer.periodic(_healthInterval, (_) {
      _checkHealth();
      _fetchConnections(); // 연결 아이콘도 같은 주기로
      // 안내 한 줄도 같은 주기로 — 루틴 안내(세탁 끝·복약)가 1분 늦게 뜨지 않게(2026-10-06, 시연 v3 S5).
      // 예보는 서버가 캐시하므로 기상청 호출은 늘지 않는다.
      _fetchAmbient();
    });
    _sensorTimer = Timer.periodic(_sensorInterval, (_) {
      _fetchSensors();
      _fetchAppliances(); // 가전 목록도 같은 주기로 — 폰 등록이 1분 안에 반영
      _fetchRoutines();
    });
    _alertTimer = Timer.periodic(_alertInterval, (_) => _fetchAlert());
    _fetchPower();
    _fetchAir();
    _fetchAcks();
    _powerTimer = Timer.periodic(_powerInterval, (_) {
      _fetchPower();
      _fetchAir();
      _fetchAcks();
    });
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _now = DateTime.now()),
    );
    // SSE — 위험 경보는 즉시, 상태 변화는 즉시 폴링 트리거로.
    // 스트림이 끊겨도 위의 폴링 타이머들이 그대로 커버한다.
    _events.start(
      onAlert: (alert) {
        if (mounted) _applyAlert(alert);
      },
      onStatusChanged: () {
        if (mounted) _poll();
      },
    );
  }

  @override
  void dispose() {
    _quietWakeTimer?.cancel();
    _tabSuppress.dispose();
    // 색 토큰은 정적 값이다 — 이 화면이 사라지면 평소 색으로 돌린다(다음 화면·시험이 고대비를 물려받지 않게).
    KioskColors.setHighContrast(false);
    KioskColors.setDarkMode(false);
    KioskColors.setQuietNight(false);
    _doneReturnTimer?.cancel();
    _doneHoldGrace?.cancel();
    _nextRunNoticeTimer?.cancel();
    _holdReturnTimer?.cancel();
    _stopFollowTimer?.cancel();
    _autoNoticeTimer?.cancel();
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    _healthTimer?.cancel();
    _clockTimer?.cancel();
    _sensorTimer?.cancel();
    _alertTimer?.cancel();
    _powerTimer?.cancel();
    _events.stop();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    final health = await _api.checkHealth();
    if (mounted) setState(() => _health = health);
  }

  Future<void> _fetchSensors() async {
    final data = await _api.sensors();
    if (mounted) setState(() => _sensorData = data);
  }

  Future<void> _fetchAmbient() async {
    final info = await _api.ambient();
    if (!mounted) return;
    if (info != null) {
      _ambientFailures = 0;
      setState(() => _ambient = info);
      return;
    }
    // 조회 실패(null) — 오프라인 우선: 마지막으로 받은 안내를 바로 지우지 않는다(Copilot#4, 2026-10-06).
    // 실패가 _ambientStaleAfter만큼 이어지면 묵은 안내를 접고 인사말 없는 화면(예보 없음과 같다)으로 둔다.
    // 시각 대신 조회 주기(_healthInterval) × 연속 실패 수로 잰다 — 화면 시계와 무관하게 같은 규칙이다.
    _ambientFailures++;
    if (_ambient != null &&
        _healthInterval * _ambientFailures >= _ambientStaleAfter) {
      setState(() => _ambient = null);
    }
  }

  Future<void> _fetchConnections() async {
    final items = await _api.connections();
    if (!mounted) return;
    setState(() {
      _connections = items;
      _connectionsLoaded = true;
    });
  }

  Future<void> _fetchRoutines() async {
    final list = await _api.routines();
    // 실패는 마지막으로 안 목록을 유지한다(오프라인 우선).
    if (!mounted || list == null) return;
    setState(() => _routines = list);
  }

  /// 연결 아이콘 세 개에 보일 항목. 허브에 못 닿으면 와이파이 자리에 그 사실을
  /// 세우고, 나머지는 **모른다**고만 둔다(허브 너머라 확인할 수 없다).
  List<ConnectionItem> get _connectionItems {
    const unreachable = [
      ConnectionItem(
          id: 'press',
          state: 'unreachable',
          title: '누름 장치 상태를 볼 수 없어요',
          message: '본체와 연결되면 볼 수 있어요.'),
      ConnectionItem(
          id: 'plug',
          state: 'unreachable',
          title: '전기 플러그 상태를 볼 수 없어요',
          message: '본체와 연결되면 볼 수 있어요.'),
    ];
    if (!_connectionsLoaded) {
      return const [
        ConnectionItem(
            id: 'network',
            state: 'unreachable',
            title: '연결을 보고 있어요',
            message: '잠시만 기다려 주세요.'),
        ...unreachable,
      ];
    }
    final items = _connections;
    if (items == null || items.isEmpty) {
      return const [ConnectionItem.hubUnreachable, ...unreachable];
    }
    return items;
  }

  Future<void> _recheckConnections() async {
    if (_connectionsChecking) return;
    setState(() => _connectionsChecking = true);
    await Future.wait([_fetchConnections(), _checkHealth()]);
    if (mounted) setState(() => _connectionsChecking = false);
  }

  /// 가전 줄의 순서 근거를 /status에서 읽는다 — 동작 중(실행 중이거나 정지 버튼
  /// 위 대기 중)과 확인 필요(마지막 실행이 끝까지 되지 않음, 서버 /ambient와 같은 규칙).
  void _trackStrip(KioskStatus st) {
    final running = <String>{
      if (st.running && st.applianceId != null) st.applianceId!,
      if (_holdActive(st.holdState) && st.holdApplianceId != null)
        st.holdApplianceId!,
    };
    final attention = <String>{};
    final last = st.lastApplianceId;
    _lastAttentionJobId = st.lastJobId;
    // 사람이 확인한 실행이면(키오스크 지난 일 확인·답, 폰 '기록 보기' — 본체 확인 표시, 2026-10-19) 내린다. 새 실패는 다시 뜬다.
    final acked = st.lastJobId != null && _ackedJobs.containsKey(st.lastJobId);
    if (!st.running && !acked && last != null &&
        (st.lastOutcome != null || st.lastStatus != null)) {
      final kind = resultKindOf(outcome: st.lastOutcome, status: st.lastStatus);
      if (kind == ResultKind.failed || kind == ResultKind.safetyStop) {
        attention.add(last);
      }
    }
    if (!_sameSet(running, _runningIds) || !_sameSet(attention, _attentionIds)) {
      setState(() {
        _runningIds = running;
        _attentionIds = attention;
      });
    }
  }

  /// 사람이 확인한 실행을 본체에서 읽는다(2026-10-19) — 폰에서 '기록 보기'로 본 실패도 여기서 사라진다. 못 읽으면 그대로(null).
  /// 읽었으면(본체에 닿으면) 아직 적지 못한 답을 다시 보낸다([retry], 검토 10/19 코어 5차 #9).
  Future<Map<String, String>?> _fetchAcks({bool retry = true}) async {
    final acked = await _api.ackedJobs();
    if (!mounted || acked == null) return null;
    // 화면이 먼저 보인 답은 본체 목록에 나타날 때까지 지킨다(검토 10/19 #9) — POST보다 먼저 온 조회가 덮어써 '!'이 다시 떴다.
    _pendingAcks.removeWhere((id, answer) => acked[id] == answer);
    _unsentAcks.removeWhere((id, e) => acked[id] == e.answer);
    _applyAcks({...acked, ..._pendingAcks});
    if (retry) {
      for (final id in _unsentAcks.keys.toList()) {
        unawaited(_sendAck(id));
      }
    }
    return acked;
  }

  /// 화면에는 보였지만 본체 목록(GET /acks)에 아직 없는 답 — 실행 번호 → 답. 본체에 나타나거나, 본체에 닿는데 적지 못했으면 뺀다.
  final Map<String, String> _pendingAcks = {};

  /// 본체가 아직 적지 않은 답(검토 10/19 코어 5차 #9) — 실행 번호 → (답, 되살릴 지난 일 줄, 본체에 닿고도 못 적은 횟수).
  /// POST가 성공하거나 본체 목록에 같은 답이 보일 때까지 지키고, 본체 목록을 다시 읽을 수 있을 때마다(연결이 돌아오면) 다시 보낸다.
  /// 예전에는 POST가 한 번 실패하면 버려, 끊긴 동안 답한 확인이 본체에 끝내 남지 않았다.
  final Map<String, ({String answer, KioskPastResult? restore, int failures})> _unsentAcks = {};
  final Set<String> _ackSending = {};
  static const _maxUnsentAcks = 64;

  /// 본체에 닿는데도 이만큼 못 적으면(본체가 계속 거절) 그 답은 그만 보낸다 — 10초마다 보내므로 약 5분.
  static const _maxAckFailures = 30;

  void _applyAcks(Map<String, String> acked) {
    final past = _pastResult;
    final clearPast = past?.jobId != null && acked.containsKey(past!.jobId);
    final attention = {
      for (final id in _attentionIds)
        if (!(_lastAttentionJobId != null && acked.containsKey(_lastAttentionJobId))) id,
    };
    if (!clearPast && attention.length == _attentionIds.length && mapEquals(acked, _ackedJobs)) return;
    setState(() {
      _ackedJobs = acked;
      if (clearPast) _pastResult = null;
      _attentionIds = attention;
    });
  }

  /// 사람이 봤다·답했다를 본체에 적는다(2026-10-19) — 화면은 바로 반영하고, 적지 못해도 막지 않는다.
  /// 화면에 보인 그 실행 하나만(검토 10/19). 실행 번호를 모르면(접수 전에 끊긴 실행) 적지 않는다 — 무엇을 봤는지 댈 수 없다.
  /// [restore]는 화면이 먼저 지운 지난 일 줄 — 본체가 적지 못하면 되살린다(검토 10/19 코어 4차 #11).
  void _ack(String? jobId, String answer, {KioskPastResult? restore}) {
    if (jobId == null) return;
    _pendingAcks[jobId] = answer;
    _unsentAcks.remove(jobId);
    _unsentAcks[jobId] = (answer: answer, restore: restore, failures: 0);
    if (_unsentAcks.length > _maxUnsentAcks) _unsentAcks.remove(_unsentAcks.keys.first);
    _applyAcks({..._ackedJobs, jobId: answer});
    unawaited(_sendAck(jobId));
  }

  /// 아직 적지 않은 답 하나를 본체에 보낸다(POST /acks). 적었으면 대기에서 뺀다 — 다시 보내서 적었으면 화면에도 다시 보인다.
  /// 적지 못하면(검토 10/19 #9) 본체 목록을 다시 읽는다. 본체에 닿는데 그 답이 없으면(분명히 못 적음) 화면의 답을 거두고 지운
  /// 지난 일 줄을 되살린다 — 본체에 없는 확인을 화면만 지어내지 않는다. 목록을 못 읽으면(옛 본체·끊김) 화면은 종전처럼 둔다.
  /// 어느 쪽이든 답은 대기에 남아, 본체 목록을 다시 읽을 수 있을 때 [_fetchAcks]가 다시 보낸다.
  Future<void> _sendAck(String jobId) async {
    final entry = _unsentAcks[jobId];
    if (entry == null || !_ackSending.add(jobId)) return;
    final bool ok;
    try {
      ok = await _api.postAck(jobId: jobId, answer: entry.answer);
    } finally {
      _ackSending.remove(jobId);
    }
    if (!mounted || _unsentAcks[jobId]?.answer != entry.answer) return; // 그사이 새 답 — 그 답이 따로 간다
    if (ok) {
      _unsentAcks.remove(jobId);
      if (_ackedJobs[jobId] != entry.answer) {
        _pendingAcks[jobId] = entry.answer;
        _applyAcks({..._ackedJobs, jobId: entry.answer});
      }
      return;
    }
    final acked = await _fetchAcks(retry: false);
    if (!mounted || acked == null || acked[jobId] == entry.answer) return;
    final current = _unsentAcks[jobId];
    if (current == null || current.answer != entry.answer) return;
    final failures = current.failures + 1;
    if (failures >= _maxAckFailures) {
      _unsentAcks.remove(jobId);
    } else {
      _unsentAcks[jobId] = (answer: current.answer, restore: null, failures: failures);
    }
    if (_pendingAcks[jobId] == entry.answer) {
      _pendingAcks.remove(jobId);
      _applyAcks({...acked, ..._pendingAcks});
    }
    final restore = current.restore;
    if (restore == null || acked.containsKey(jobId) || _pastResult != null) return;
    setState(() => _pastResult = restore);
  }

  /// 가전 칸 '!'(확인 필요)를 만든 실행 번호 — 사람이 확인하면 표시를 내린다.
  String? _lastAttentionJobId;

  /// 가전 줄의 '켜짐'(2026-10-16) — 서버가 최근 ThinQ 조회로 본 전원만. 평소 화면일 때만 묻는다.
  Future<void> _fetchPower() async {
    if (_phase != KioskPhase.idle) return;
    final on = await _api.thinqPowerOn();
    final off = _api.thinqPowerOff;
    if (!mounted || (_sameSet(on, _onIds) && _sameSet(off, _offIds))) return;
    setState(() {
      _onIds = on;
      _offIds = off;
    });
  }

  /// 평소 화면의 '실내 공기' 한 줄(2026-10-16) — 서버가 최근 ThinQ 조회로 본 센서 값만. 평소 화면일 때만 묻는다.
  /// 실패·모름이면 줄을 내린다(묵은 값을 붙들지 않는다 — 서버도 600초 넘은 값은 주지 않는다).
  Future<void> _fetchAir() async {
    if (_phase != KioskPhase.idle) return;
    final air = await _api.thinqAir();
    if (!mounted) return;
    final gen = _nextRunGen;
    final next = await _api.nextRoutine();
    if (!mounted) return;
    setState(() {
      _air = air;
      // 그사이 건너뛰기 응답이 왔으면 이 (먼저 떠난) 응답으로 덮지 않는다.
      if (gen == _nextRunGen) _nextRun = next;
    });
  }

  /// 다음 루틴 '오늘은 건너뛰기'·'되돌리기'(2026-10-18 사용자 결정). 확인 창은 없다(되돌리기가 있다).
  /// 보내는 동안은 단추를 막는다. 실패하면 짧은 안내, 409·404면 다음 루틴을 다시 불러온다.
  /// 건너뛰기는 실행을 멈추지 않는다 — 정지는 늘 /stop이다(서버 계약).
  Future<void> _toggleNextRunSkip(KioskNextRun next) async {
    if (_nextRunBusy || !next.canSkip) return;
    final skip = !next.skipped;
    _nextRunNoticeTimer?.cancel();
    setState(() {
      _nextRunBusy = true;
      _nextRunNotice = null;
    });
    final result = await _api.setNextRoutineSkip(next, skip: skip);
    if (!mounted) return;
    _nextRunGen++;
    final changed = result.item;
    setState(() {
      _nextRunBusy = false;
      // '자동 실행' 탭에서 뒤 회차를 건너뛰어도 처음 화면 다음 루틴을 그 회차로 바꾸지 않는다 — 같은 회차일 때만.
      if (changed != null && (_nextRun == null || _sameRun(_nextRun!, next))) _nextRun = changed;
      final upcoming = _upcomingRuns;
      if (changed != null && upcoming != null) {
        _upcomingRuns = [for (final r in upcoming) _sameRun(r, next) ? changed : r];
      }
      _nextRunNotice = changed == null ? result.message : null;
    });
    if (_nextRunNotice != null) {
      _nextRunNoticeTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _nextRunNotice = null);
      });
    }
    if (result.reload) {
      if (_upcomingRuns != null) _fetchUpcoming();
      final gen = _nextRunGen;
      final fresh = await _api.nextRoutine();
      if (!mounted || gen != _nextRunGen) return;
      setState(() => _nextRun = fresh);
    }
  }

  /// 같은 루틴의 같은 회차인가(건너뛰기 요청 본문과 같은 두 값).
  static bool _sameRun(KioskNextRun a, KioskNextRun b) => a.routineId == b.routineId && a.at == b.at;

  /// '자동 실행' 탭 목록을 다시 읽는다(읽기 전용 GET /routines/next).
  Future<void> _fetchUpcoming() async {
    if (_upcomingLoading) return;
    setState(() => _upcomingLoading = true);
    final runs = await _api.nextRoutines(limit: 10);
    if (!mounted) return;
    setState(() {
      _upcomingLoading = false;
      _upcomingRuns = runs;
    });
  }

  /// '기록' 탭 목록을 다시 읽는다(읽기 전용 GET /history).
  Future<void> _fetchHistory() async {
    if (_historyLoading) return;
    setState(() => _historyLoading = true);
    final entries = await _api.history(limit: 20);
    if (!mounted) return;
    setState(() {
      _historyLoading = false;
      _historyEntries = entries;
    });
  }

  /// 아래 탭 줄을 둘까 — 평소 화면(조용한 시간으로 어둡지 않을 때)·가전 고르기·가전 조작에서만. 제안·확인·누르는 중·결과·
  /// 정지 대기에서는 두지 않는다(정지·승인이 앞선다). 화면 안 확인 창은 [_tabSuppress]가 따로 가린다.
  /// 화면 안 창(메뉴·설정·방해 금지·연결·확인 창)이 떠 있다 — 패널 전체를 막 색으로.
  bool get _scrimOn =>
      _tabSuppress.value > 0 || _showSettings || _showDnd || _openConnectionId != null || _estopConfirming;

  /// 화면 전체를 덮는 창(방해 금지·연결·설정)이 떠 있다 — 뒤 화면을 화면 읽기에서 뺀다(10/24 QA).
  bool get _overlayOpen => _showDnd || _showSettings || (_openConnectionId != null && _phase == KioskPhase.idle);

  bool get _showTabs =>
      !_estopConfirming && !_showSettings && !_showDnd && _openConnectionId == null && ((_phase == KioskPhase.idle && !_quietDim) || _phase == KioskPhase.manual);

  /// 지금 탭 — 가전 고르기·조작 화면은 '가전'.
  KioskTab get _currentTab => _phase == KioskPhase.manual ? KioskTab.appliances : _homeTab;

  /// 아래 탭을 눌렀다. '가전'은 가전 고르기 화면(가전을 고르면 그 조작판), 나머지는 평소 화면의 그 탭.
  /// 평소·가전 화면에서만 받는다 — 확인 창이 떠 있으면 탭 줄이 없어 여기로 오지 않지만, 한 번 더 막는다.
  void _onTab(KioskTab tab) {
    if (_phase != KioskPhase.idle && _phase != KioskPhase.manual) return;
    if (_tabSuppress.value > 0) return;
    if (tab == KioskTab.appliances) {
      if (_phase == KioskPhase.manual) {
        // 이미 가전 화면 — 고르기 목록으로(조작판에서 '가전'을 누르면 다른 가전을 고른다).
        if (_manualAppliance != null) setState(() => _manualAppliance = null);
        return;
      }
      // 본체에 닿지 않으면 가전 화면을 열지 않는다 — 가전 타일과 같은 규칙([_toMyAppliance]).
      if (!_health.ok) {
        setState(() => _openConnectionId = 'network');
        return;
      }
      setState(() {
        _phase = KioskPhase.manual;
        _manualAppliance = null;
        _homeTab = KioskTab.home;
      });
      _fetchRoutines();
      return;
    }
    setState(() {
      if (_phase == KioskPhase.manual) {
        _phase = KioskPhase.idle;
        _manualAppliance = null;
      }
      _homeTab = tab;
    });
    if (tab == KioskTab.auto) _fetchUpcoming();
    if (tab == KioskTab.history) _fetchHistory();
  }

  /// ThinQ 가전 상세에서 확인을 거쳐 접수된 조작 — 다른 실행처럼 실행 화면이 job_id로 따라간다.
  /// 다시 시도는 두지 않는다(설정 변경은 상태를 다시 읽고 사람이 다시 고른다).
  void _onThinqAccepted(String jobId, String label) {
    if (!mounted || _phase != KioskPhase.manual) return;
    _stopWhileAccepting = false; // 새 실행 — 앞 실행의 남은 정지를 넘기지 않는다
    _toExecuting(label,
        applianceId: _manualAppliance?.id,
        jobId: jobId,
        thinqOnly: _manualAppliance?.isThinq ?? false,
        thinqActionText: label,
        continueApplianceId: _manualAppliance?.id);
    _poll();
  }

  /// /status의 비상정지 걸림을 화면에 옮긴다. **해제 요청은 여기서 보내지 않는다.**
  /// 새로 걸리는 순간에만 한 번 말한다(풀렸다 다시 걸리면 다시 말한다).
  void _trackEstop(KioskStatus st) {
    final latched = st.estopLatched;
    if (latched && !_estopLatched) _tts.speak(estopSpokenFor(st.estopDetail));
    final detail = latched ? st.estopDetail : null;
    if (latched == _estopLatched && detail == _estopDetail) return;
    setState(() {
      _estopLatched = latched;
      _estopDetail = detail;
      if (!latched) {
        _estopConfirming = false;
        _estopMessage = null;
      }
    });
  }

  /// 경고의 '해제' — 사람이 확인 문장을 본 뒤에만 불린다.
  Future<void> _onEstopConfirm() async {
    if (_estopAcking) return;
    // 전원 꺼짐 걸림(가전 콘센트 장치가 다시 켜짐)이면 해제 뒤 서버가 콘센트 전원을 다시 켠다 — 결과 문장이 다르다.
    final powerRestore = estopIsPowerLoss(_estopDetail);
    setState(() {
      _estopAcking = true;
      _estopConfirming = false;
      _estopMessage = null;
    });
    final result = await _api.ackEstop();
    if (!mounted) return;
    setState(() {
      _estopAcking = false;
      if (result.cleared) {
        _estopLatched = false;
        _estopDetail = null;
      } else {
        _estopMessage = result.messageFor(powerRestore: powerRestore);
      }
    });
    if (!result.cleared) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.messageFor(powerRestore: powerRestore))));
    // 해제 응답만 믿지 않고 상태를 다시 읽는다 — 그사이 다시 걸렸을 수 있다.
    try {
      final st = await _api.status();
      if (mounted) _trackEstop(st);
    } catch (_) {}
  }

  /// 경고는 **모든 화면**에 보인다(2026-10-15 문구 개선 §2-3) — 예전에는 제안·수동 조작·완료 화면에서 사라져,
  /// 걸린 채로 제안을 승인하거나 버튼을 고르게 됐다. 화면을 덮지 않고 위에 줄을 더할 뿐이다.
  /// 걸림 값은 평소·실행·동작 중 화면의 /status 조회가 옮긴다(다른 화면에서는 마지막 값을 유지한다).
  bool get _showEstop => _estopLatched;

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// 사람이 정지 버튼을 눌러야 할 수 있는 대기 상태.
  static bool _holdActive(String? state) =>
      state == 'hovering_stop' || state == 'stopping' || state == 'parking';

  Future<void> _fetchAlert() async {
    final alert = await _api.alerts();
    if (!mounted) return;
    _applyAlert(alert);
  }

  // 폴링(3초)과 SSE(즉시)가 같은 경보 상태를 공급한다 — 엣지 판정이
  // 여기 한 곳이라 두 채널이 겹쳐도 발화·재알림은 1회만 된다.
  void _applyAlert(AlertState alert) {
    // 새로 켜지는 엣지에서만 음성 경보 — 반복 발화하지 않는다.
    // DND 중에도 발화한다: 안전 경보는 방해 금지보다 우선한다.
    if (alert.active && !_alert.active) {
      _tts.speak('경보 소리가 들려요. 불이 났는지, 가스가 새는지 살펴 주세요. 연기나 냄새가 나면 먼저 밖으로 나가 도움을 요청해 주세요. $kDanger119.');
    }
    setState(() {
      // 새로 켜지는 순간(엣지)엔 "확인" 눌렀던 기록을 리셋 — 계속 같은
      // 경보가 이어지는 중엔 확인 상태 유지, 한 번 꺼졌다 다시 울리면 재알림.
      if (alert.active && !_alert.active) _alertAcknowledged = false;
      _alert = alert;
    });
  }

  Future<void> _poll() async {
    if (_pollInFlight) return; // 폴링 오버랩 가드 (2초 주기 vs 4초 타임아웃)
    _pollInFlight = true;
    try {
      if (_phase == KioskPhase.idle) {
        await _pollIdle();
      } else if (_phase == KioskPhase.executing) {
        await _pollExecuting();
      } else if (_phase == KioskPhase.suggestion) {
        await _pollSuggestion();
      } else if (_phase == KioskPhase.hold) {
        await _pollHold();
      } else if (_phase == KioskPhase.done) {
        await _pollDone();
      } else if (_phase == KioskPhase.manual) {
        await _pollManual();
      }
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _pollIdle() async {
    // 폰 앱이 시작한 실행도 키오스크가 같이 보여준다 — /status에서 진행 중인
    // job을 발견하면 그 job_id를 이어받아 실행 화면으로 전환.
    try {
      final st = await _api.status();
      if (!mounted || _phase != KioskPhase.idle) return;
      _trackStrip(st);
      _trackEstop(st);
      if (_adoptableJobId(st) != null) {
        _adoptRunning(st);
        _followPendingStop(st);
        return;
      }
      _followPendingStop(st);
      // 버튼을 다 누른 뒤 가전이 돌아가는 중 — 동작 중 화면(정지 버튼 대기).
      // 제안보다 먼저 본다: 안내는 한 번에 하나다.
      if (_holdDue(st)) {
        _toHold(st);
        return;
      }
      _trackAutoRun(st);
      if (_catchMissedResult(st)) return;
    } catch (_) {}
    try {
      final list = await _api.suggestions();
      if (!mounted || _phase != KioskPhase.idle) return;
      final ids = list.map((s) => s.id).toSet();
      _shownSuggestionIds.retainAll(ids);
      final next = list.where((s) => !_shownSuggestionIds.contains(s.id)).firstOrNull;
      if (next != null) {
        _toSuggestion(next);
      }
    } catch (_) {}
  }

  /// 정지 대기(동작 중 화면)로 갈 차례인가 — 평소·결과·조작판 화면이 같은 규칙을 쓴다(코드 검토 10/24: 연속 조작으로 결과·조작판에
  /// 머무는 동안 대기 화면이 끝내 뜨지 않았다). 연습 대기에서 사람이 나간 것은 다시 띄우지 않는다. 대기가 없으면 나간 기록을 지운다.
  bool _holdDue(KioskStatus st) {
    if (!_holdActive(st.holdState)) {
      _leftPracticeHold = null;
      _holdJob = null;
      return false;
    }
    final key = _practiceHoldName(st);
    if (key == null) return true; // 실제 대기 — 정지 버튼이 닿아야 한다
    // 연습 대기는 결과 화면·조작판을 덮지 않는다(10/24 실패널, 사용자 지적): 실제 가전이 없어 꺼야 할 것이 없는데
    // '연습을 마쳤어요' 뒤에 '연습이 끝났어요 · 취소 위에서 기다리는 중'이 또 떴다. 처음 화면에서만(닫은 대기는 빼고) 보인다.
    // 사람이 확인해야 하는 대기(구동부 이상 등)는 어디서든 보인다.
    if (_phase != KioskPhase.idle && !_holdNeedsPerson(st)) return false;
    return key != _leftPracticeHold;
  }

  /// 조작판 화면 — 비상 멈춤 걸림과 정지 대기를 본다(코드 검토 10/24). 대기는 사람이 조작판을 쓰는 중에도 띄운다: 정지 버튼이
  /// 닿아야 한다(평소 화면과 같은 규칙). 스스로 뜬 제안은 종전처럼 조작판을 빼앗지 않는다 — 서버에 남아 처음 화면에서 뜬다.
  Future<void> _pollManual() async {
    try {
      final st = await _api.status();
      if (!mounted || _phase != KioskPhase.manual) return;
      _trackEstop(st);
      if (_holdDue(st)) _toHold(st);
    } catch (_) {
      // 통신 실패는 걸림이 풀렸다는 증거가 아니다 — 마지막 값을 유지한다.
    }
  }

  /// 제안·수동 조작 화면에서도 비상 멈춤 걸림을 따라간다(2026-10-15) — 경고 띠가 모든 화면에 보이려면
  /// 그 화면에 있는 동안 새로 걸린 것도 알아야 한다. 걸림만 읽고 다른 상태는 건드리지 않는다.
  Future<void> _pollEstopOnly() async {
    try {
      final st = await _api.status();
      if (!mounted) return;
      _trackEstop(st);
    } catch (_) {
      // 통신 실패는 걸림이 풀렸다는 증거가 아니다 — 마지막 값을 유지한다.
    }
  }

  Future<void> _pollSuggestion() async {
    await _pollEstopOnly();
    final id = _currentSuggestion?.id;
    try {
      final list = await _api.suggestions();
      if (!mounted ||
          _phase != KioskPhase.suggestion ||
          _currentSuggestion?.id != id ||
          _dismissingSuggestion) {
        return;
      }
      // 다른 단말에서 처리되었거나 만료된 제안의 실행 버튼을 내린다.
      final updated = list.where((s) => s.id == id).firstOrNull;
      if (updated == null) {
        _toIdle();
      } else if (updated.reason != _currentSuggestion?.reason) {
        // Refresh evidence without restarting the countdown or speaking again.
        setState(() => _currentSuggestion = updated);
      }
    } catch (_) {
      // 통신 실패는 제안 만료라는 증거가 아니다. 승인은 서버가 재검사한다.
    }
  }

  Future<void> _pollExecuting() async {
    final jobId = _activeJobId;
    if (jobId == null) {
      // 접수 응답 전에는 다른 작업 상태를 사용하지 않는다. 응답을 잃었으면 본체에서 그 실행을 찾는다.
      if (_admitUnknown && !_accepting) await _pollAdmitUnknown();
      return;
    }
    try {
      final st = await _api.status();
      if (!mounted || _phase != KioskPhase.executing ||
          _activeJobId != jobId) {
        return;
      }
      // 이 실행의 진행·결과는 실행 번호로 따로 묻는다 — 기기 전체 값(비상정지·대기·자동 실행·정지 재전송)은 /status([st])에서.
      final lookup = await _api.jobStatus(jobId);
      if (!mounted || _phase != KioskPhase.executing ||
          _activeJobId != jobId) {
        return;
      }
      if (lookup.unsupported && _execRoutineRunId != null) {
        // 루틴을 따라가는데 실행 번호 조회가 실패했다(본체는 조회를 안다) — /status로 보지 않는다. 루틴이 도는 동안 /status는
        // 구간 번호만 내놓아 남의 실행처럼 셌다(검토 10/19). 정지·비상정지만 옮기고, 조회가 오래 안 되면 결과 화면으로.
        _trackEstop(st);
        throw StateError('routine job lookup failed');
      }
      // 옛 본체(조회 없음)·조회 실패면 /status의 마지막 한 건으로 종전처럼. null이면 본체가 그 실행을 모른다(흔적 없음과 같다).
      final job = lookup.unsupported ? st : lookup.status;
      final root = job?.routineRunId;
      if (job != null && !lookup.unsupported && root != null && root != jobId) {
        // 루틴의 구간 번호를 따라가고 있었다(검토 10/19) — 구간의 끝은 루틴의 끝이 아니다. 루틴 첫 번호로 갈아타고 다음 조회부터
        // 루틴 전체 수명을 본다. 이 구간의 끝을 결과 화면으로 띄우지 않는다.
        _lastStatusOk = DateTime.now();
        _foreignPolls = 0;
        _trackStrip(st);
        _trackEstop(st);
        setState(() {
          _activeJobId = root;
          _execRoutineRunId = root;
          _execRoutineSegment = job.routineSegment ?? _execRoutineSegment;
          _execRoutineSegmentJobId = job.routineSegmentJobId ?? jobId;
        });
        _followPendingStop(st);
        return;
      }
      _lastStatusOk = DateTime.now();
      _trackStrip(st);
      _trackEstop(st);
      _followPendingStop(st);

      // ① 완료 판정 최우선 — 내 job 완료 직후 다른 클라이언트의 새 job이
      // 시작되면 running=true여도 last_job_id는 내 job이다. running을 먼저
      // 처리하면 그 완료를 영영 놓친다(추월 레이스).
      // 끝났다고 한 답만(finished, 검토 10/19 — 루틴은 모든 구간이 끝나야 참). 옛 본체·/status는 null이라 종전처럼.
      if (job != null && job.lastJobId != null && job.lastJobId == _activeJobId && job.finished != false) {
        if (st.lastAutoRun?.jobId == jobId) {
          // 자동 실행(허용 규칙)은 완료 화면 대신 위 한 줄로 실제 결과를 알린다(C2).
          _seenLastJobId = jobId;
          _toIdle();
          _trackAutoRun(st);
          return;
        }
        _completeFromStatus(job, jobId);
        return;
      }

      if (job != null && job.running) {
        final mine = _activeJobId == null || job.jobId == _activeJobId;
        if (mine) {
          _foreignPolls = 0;
          if (job.routineRunId != null && _followRoutine(job)) return;
          setState(() {
            _executionMode = job.executionMode;
            final prevButton = _currentButton;
            final nowButton = job.currentButton;
            if (prevButton != null && nowButton != null && nowButton != prevButton) {
              _execDoneButtons = [..._execDoneButtons, prevButton];
            }
            _currentButton = nowButton ?? _currentButton;
            _currentAttempt = job.currentAttempt ?? _currentAttempt;
            _completedSteps = job.completedSteps ?? _completedSteps;
            _verificationConfidence =
                job.verificationConfidence ?? _verificationConfidence;
            _verificationDetail =
                job.verificationDetail ?? _verificationDetail;
            _execApplianceId = job.applianceId ?? _execApplianceId;
            // 이어받은 실행이 첫 조회에 경로를 몰랐다가 알게 되면 LG 가전 화면으로(평가 10차 10/18). 거꾸로는 하지 않는다 —
            // 승인 때 정한 판정을 서버 값 하나로 내리지 않는다(누름 장치 경로면 [isAdoptedThinqRun]이 거짓이다).
            if (!_execThinqOnly && _adoptedThinq(job)) _execThinqOnly = true;
            // 서버가 단계 수를 줄 때만 진행을 채운다
            final total = job.totalSteps;
            if (total != null && total > 0) {
              _totalSteps = total;
              _execBarValue =
                  ((job.completedSteps ?? 0) / total).clamp(0.0, 0.95);
            }
            // 카드에 묶인 버튼이 더 많으면(명령 하나에 버튼 여럿) 그 버튼 수로 센다 — 끝낸 수는 화면이 본 바뀐 버튼 수.
            final plan = _execPlanButtons;
            if (plan != null && (_execRoutineSegment ?? 1) <= 1 && (_totalSteps ?? 0) < plan.length) {
              _totalSteps = plan.length;
              _completedSteps = _execDoneButtons.length.clamp(0, plan.length);
              _execBarValue = (_completedSteps! / plan.length).clamp(0.0, 0.95);
            }
          });
          return;
        }
      }

      // ② 내 job의 흔적 없음 — 접수 응답 대기 창(_activeJobId null 포함)은
      // 정상이므로 몇 번은 기다리고, 계속되면 고착 대신 탈출.
      if (_activeJobId != null) {
        _foreignPolls++;
        if (_foreignPolls >= 5) {
          _toDone(false, _execTitle,
              reason: KioskFailureReason.serverLost);
        }
      }
    } catch (_) {
      if (!mounted || _phase != KioskPhase.executing ||
          _activeJobId != jobId) {
        return;
      }
      // 연속 실패가 길어지면 서버 유실로 판정하고 실행 화면에서 탈출
      final since = _lastStatusOk;
      if (since != null &&
          DateTime.now().difference(since) > _statusLostTimeout) {
        _toDone(false, _execTitle,
            reason: KioskFailureReason.serverLost);
      }
    }
  }

  /// /status에서 이어받을 실행 번호(검토 10/19) — 루틴이 돌면(구간 사이 기다림 포함) 그 루틴의 첫 번호, 아니면 도는 실행 번호.
  /// 구간 번호를 따라가면 구간 하나의 끝을 루틴의 끝으로 말한다. 옛 본체(루틴 필드 없음)는 종전처럼 job_id.
  String? _adoptableJobId(KioskStatus st) {
    final routine = st.routineRunId;
    if (routine != null && (st.routineStatus == null || st.routineStatus == 'running')) return routine;
    return st.running ? st.jobId : null;
  }

  /// 본체에서 도는 실행(폰·자동 실행·루틴)을 이어받아 실행 화면으로. 루틴이면 첫 번호를 따라가고 정지는 그 루틴만 멈추는 경로로.
  void _adoptRunning(KioskStatus st) {
    _toExecuting(st.currentButton ?? _nameOf(st.applianceId),
        applianceId: st.applianceId, jobId: _adoptableJobId(st), thinqOnly: _adoptedThinq(st));
    final routine = st.routineRunId;
    if (routine != null && _activeJobId == routine) {
      _execRoutineRunId = routine;
      _execRoutineSegment = st.routineSegment;
      _execRoutineSegmentJobId = st.routineSegmentJobId;
    }
  }

  /// 도는 루틴의 차례를 옮긴다(검토 10/19). 구간이 바뀌면 앞 구간의 누른 버튼·칸 수·확인을 지운다 — 루틴 전체가 아니라 그
  /// 구간 것이다. 구간 사이(진행 필드 없음)면 누르는 버튼 없이 '다음 차례를 기다리는 중'으로 두고 true(진행 갱신 없음).
  bool _followRoutine(KioskStatus job) {
    final segmentJob = job.routineSegmentJobId;
    final waiting = job.currentButton == null && job.applianceId == null;
    setState(() {
      _execRoutineRunId = job.routineRunId;
      _execRoutineSegment = job.routineSegment ?? _execRoutineSegment;
      _execRoutineWaiting = waiting;
      // 처음 본 구간은 지울 것이 없다 — 승인 때 정한 LG 가전 표시도 그대로 둔다.
      final previous = _execRoutineSegmentJobId;
      _execRoutineSegmentJobId = segmentJob;
      if (previous != null && segmentJob != previous) {
        _currentButton = null;
        _execDoneButtons = const [];
        _currentAttempt = null;
        _completedSteps = null;
        _totalSteps = null;
        _execBarValue = 0;
        _verificationConfidence = null;
        _verificationDetail = null;
        // 구간마다 경로가 다르다(LG 가전 단계·누름 단계) — 아래 진행 갱신이 이 구간 값으로 다시 정한다.
        _execThinqOnly = false;
      }
      if (waiting) _currentButton = null;
    });
    return waiting;
  }

  /// 서버가 보고한 [jobId]의 끝을 완료 화면으로 옮긴다(내 job·이어받은 job·놓친 짧은 실행 공통).
  void _completeFromStatus(KioskStatus st, String jobId) {
    _seenLastJobId = jobId;
    _executionMode = st.lastExecutionMode;
    // last_outcome이 정지 요청(stopped)과 안전 정지·실패를 가른다. 옛 서버는
    // last_status로 판정한다(종전 동작). ThinQ 확인 못 함은 실패가 아니다.
    final kind =
        resultKindOf(outcome: st.lastOutcome, status: st.lastStatus);
    _doneRoute = st.lastRoute;
    _doneRawConfirmation = st.lastConfirmation;
    _doneConfirmation = confirmationLabel(
      route: st.lastRoute,
      receipt: st.lastReceipt,
      confirmation: st.lastConfirmation,
      kind: kind,
      executionMode: st.lastExecutionMode,
    );
    _doneDetail = st.lastDetail;
    _doneOperationConfirmed = st.lastOperationConfirmed;
    _doneOperationSource = st.lastOperationSource;
    // 이 job의 정지 단계만(평가 H1). 아직 없으면 아래에서 짧게 다시 묻는다(M1).
    _doneStopLevel = st.stopLevelOf(jobId);
    _doneStopAckMs = st.stopAckMsOf(jobId);
    _doneOperationDetail = st.lastOperationDetail;
    _doneAbortReason = st.lastAbortReason;
    _finishExecuting(
      success: kind == ResultKind.success,
      buttons: st.lastButtons ?? const [],
      reason: failureReasonOf(kind,
          route: st.lastRoute, receipt: st.lastReceipt),
    );
    _loadRunSteps(jobId);
    if (kind == ResultKind.stopped && _doneStopLevel == null) {
      _followStopReport(jobId);
    }
  }

  /// 폴링 사이에 시작해 끝난 실행(짧은 실행·다른 단말의 정지)을 놓치지 않는다(2026-10-14, 보드 날 발견 3).
  /// 서버 last_job_id가 이미 반영한 값과 다르면 그 결과를 완료 화면으로 띄운다. 첫 조회는 기준만 잡는다.
  /// 자동 실행 job은 완료 화면 대신 위 한 줄 알림(_trackAutoRun)으로만 알린다. 띄웠으면 true.
  bool _catchMissedResult(KioskStatus st) {
    final last = st.lastJobId;
    if (!_seenLastJobInit) {
      _seenLastJobInit = true;
      _seenLastJobId = last;
      return false;
    }
    if (st.running || last == null || last == _seenLastJobId ||
        last == _activeJobId) {
      return false;
    }
    _seenLastJobId = last;
    if (st.lastAutoRun?.jobId == last) return false;
    _toExecuting(_nameOf(st.lastApplianceId), applianceId: st.lastApplianceId, jobId: last);
    _completeFromStatus(st, last);
    return true;
  }

  /// 완료 화면에서도 서버를 본다(2026-10-14, 발견 3) — 실패 화면은 스스로 사라지지 않아서, 그동안 폰이 시작한
  /// 다음 실행과 그 정지를 놓쳤다. 새 실행이 돌면 실행 화면으로, 새 결과가 있으면 그 결과로 바꾼다.
  Future<void> _pollDone() async {
    try {
      final st = await _api.status();
      if (!mounted || _phase != KioskPhase.done) return;
      _trackEstop(st);
      _trackAutoRun(st);
      final adopt = _adoptableJobId(st);
      if (adopt != null && adopt != _activeJobId) {
        _adoptRunning(st);
        _followPendingStop(st);
        return;
      }
      _followPendingStop(st);
      // 정지 대기(코드 검토 10/24) — 연속 조작·사람 확인·실패 결과는 저절로 닫히지 않아 평소 화면의 대기 판정에 닿지 못했다.
      // 결과를 읽을 시간(종전 자동 복귀 길이)이 지나면 평소 화면과 같은 규칙으로 정지 대기 화면으로 간다.
      // 스스로 뜬 제안은 결과 화면을 빼앗지 않는다(종전과 같음) — 서버에 남아 처음 화면으로 가면 뜬다.
      if (_doneHoldGrace?.isActive != true && _holdDue(st)) {
        _rememberPastResult();
        _toHold(st);
        return;
      }
      _catchMissedResult(st);
    } catch (_) {}
  }

  /// 결과를 읽을 시간 — 끝나기 전에는 결과 화면에서 정지 대기 화면으로 가지 않는다([_pollDone]).
  Timer? _doneHoldGrace;

  /// 자동 실행(허용 규칙) 결과 한 줄(2026-10-14, C2). 새 job일 때 한 번만 보이고 말한다. 첫 조회 때 이미 있던 결과는
  /// 알리지 않는다. 평소·완료 화면 위에만 그린다 — 실행·동작 중 화면의 정지 버튼·상태를 가리지 않는다.
  void _trackAutoRun(KioskStatus st) {
    final run = st.lastAutoRun;
    if (!_seenAutoInit) {
      _seenAutoInit = true;
      _seenAutoJobId = run?.jobId;
      return;
    }
    if (run == null || run.jobId == _seenAutoJobId) return;
    _seenAutoJobId = run.jobId;
    final text = autoRunNotice(run);
    _autoNoticeTimer?.cancel();
    setState(() => _autoNotice = text);
    if (_health.speakGeneral) _tts.speak('자동으로 하기, $text'); // 조용한 시간·모름에는 소리 없이 한 줄만
    _autoNoticeTimer = Timer(KioskTimings.autoRunNotice, () {
      if (mounted) setState(() => _autoNotice = null);
    });
  }

  /// 정지로 끝난 job [jobId]의 정지 확인 단계가 결과보다 늦게 서버에 닿는 경우(평가 2026-10-13 M1) —
  /// 짧은 횟수만 /status를 다시 물어 완료 화면의 정지 줄만 고친다. 음성은 다시 말하지 않는다.
  /// 다른 단말이 멈춘 실행도 이 경로로 단계가 보인다. 옛 RPi4(보고 없음)는 몇 번 뒤 그만둔다.
  /// 새 실행이 시작되면(_activeJobId가 바뀌면) 바로 그만둔다. 정지 전송과는 무관하다(이미 나갔다).
  void _followStopReport(String jobId) {
    _stopFollowTimer?.cancel();
    var tries = 0;
    var inFlight = false;
    _stopPending = true;
    // 기다리기를 끝낸다. 이 job의 결과 화면이 떠 있으면 바뀐 결과(멈췄어요/확인하지 못했어요)를 그때 한 번 말한다 —
    // 결과 화면이 뜰 때는 '멈추는 중이에요'만 말했다(평가 8차 10/18).
    void end(Timer timer, {bool result = true}) {
      timer.cancel();
      if (!_stopPending) return;
      if (!mounted) {
        _stopPending = false;
        return;
      }
      setState(() => _stopPending = false);
      if (result && _phase == KioskPhase.done && _activeJobId == jobId) {
        _tts.speak(finishedMessage(
            kind: ResultKind.stopped, stopLevel: _doneStopLevel, executionMode: _executionMode));
      }
    }

    var ticks = 0;
    _stopFollowTimer = Timer.periodic(_stopFollowInterval, (timer) async {
      // 조회가 응답 없이 걸려 있어도 기다림(처음 화면 단추 숨김)이 길어지지 않게 시각으로도 끊는다(평가 8차 10/18).
      if (++ticks > _stopFollowTries + 2) {
        end(timer);
        return;
      }
      if (inFlight) return;
      if (!mounted || _activeJobId != jobId ||
          (_phase != KioskPhase.executing && _phase != KioskPhase.done)) {
        end(timer, result: false);
        return;
      }
      if (tries >= _stopFollowTries) {
        end(timer); // 옛 RPi4(보고 없음)·늦은 보고 — 확인하지 못한 정지로 끝낸다
        return;
      }
      tries++;
      inFlight = true;
      try {
        final st = await _api.status();
        if (!mounted || _activeJobId != jobId || !timer.isActive) return;
        if (st.lastJobId != jobId) {
          end(timer); // 그사이 다른 실행이 끝났다 — 이 job의 단계가 아니다
          return;
        }
        final level = st.stopLevelOf(jobId);
        if (level != null) {
          setState(() {
            _doneStopLevel = level;
            _doneStopAckMs = st.stopAckMsOf(jobId);
          });
          end(timer);
        }
      } catch (_) {
        // 통신 실패 — 남은 횟수 안에서 다시 묻는다.
      } finally {
        inFlight = false;
      }
    });
  }

  /// 끝난 job [jobId]의 단계별 결과를 받아 둔다(G4). last-run이 다른 job의
  /// 기록이면 버린다 — 다른 실행의 단계를 이 결과로 보이지 않는다. 그사이 새
  /// 실행이 시작됐어도 버린다.
  Future<void> _loadRunSteps(String jobId) async {
    final run = await _api.scenarioLastRun();
    if (!mounted || run == null || run.jobId != jobId) return;
    if (_activeJobId != jobId) return;
    if (_phase != KioskPhase.executing && _phase != KioskPhase.done) return;
    setState(() => _doneRunSteps = run.steps);
  }

  void _toHold(KioskStatus st) {
    // 동작 중 화면으로 가는 실행의 끝은 이미 본 것으로 둔다 — 돌아온 뒤 그 결과를 늦게 띄우지 않는다(발견 3).
    if (st.lastJobId != null) _seenLastJobId = st.lastJobId;
    _holdReturnTimer?.cancel();
    _holdReturnTimer = null;
    _holdSpokenKey = null;
    setState(() {
      _phase = KioskPhase.hold;
      _hold = st;
      _holdSince = DateTime.now();
      _holdStopRequested = false;
      _holdStopFailed = false;
      _showDnd = false;
    });
  }

  Future<void> _pollHold() async {
    try {
      final st = await _api.status();
      if (!mounted || _phase != KioskPhase.hold) return;
      _trackStrip(st);
      _trackEstop(st);
      // 폰이 새 실행을 시작했다 — 그 실행을 따라간다.
      if (_adoptableJobId(st) != null) {
        _holdReturnTimer?.cancel();
        _adoptRunning(st);
        return;
      }
      _applyHold(st);
    } catch (_) {
      // 통신 실패는 상태 변화의 증거가 아니다 — 정지 버튼은 계속 닿는다.
    }
  }

  void _applyHold(KioskStatus st) {
    final state = st.holdState;
    // 대기 보고가 사라졌거나 풀렸다 — 보여 줄 대기가 없다.
    if (state == null || state == 'released') {
      _toIdle();
      return;
    }
    final prev = _hold?.holdState;
    setState(() {
      _hold = st;
      // 대기에서 벗어나면 "정지 요청을 보냈어요"는 다음 상태 문장이 대신한다.
      if (state != 'hovering_stop') _holdStopRequested = false;
      if (state != prev) _holdStopFailed = false;
    });
    final needsPerson = _holdNeedsPerson(st);
    if (needsPerson) {
      final key = '${st.holdState}/${st.holdStopOutcome}';
      if (_holdSpokenKey != key) {
        _holdSpokenKey = key;
        _tts.speak(st.holdState == 'fault' || st.holdStopOutcome == 'drive_fault'
            ? '누름 장치에 문제가 생겼어요. 가전 전원을 직접 꺼 주세요.'
            : '가전이 멈췄는지 확인하지 못했어요. 지금 가전 정지 버튼을 손으로 눌러 주세요.');
      }
      return;
    }
    // 보관 완료 — "보관 위치로 이동했어요"를 짧게 보인 뒤 평소 화면으로.
    if (state == 'parked' && _holdReturnTimer == null) {
      _holdReturnTimer = Timer(_doneReturnDuration, () {
        _holdReturnTimer = null;
        if (mounted && _phase == KioskPhase.hold) _toIdle();
      });
    }
  }

  /// 연습 대기 하나를 가리키는 값 — 연습(mock)일 때만. 실제 대기는 null이라 언제나 다시 띄운다(정지가 닿아야 한다).
  static String? _practiceHoldKey(KioskStatus st) => st.holdExecutionMode == 'mock' ? (st.holdApplianceId ?? '') : null;

  /// 지금 연습 대기를 만든 실행 번호 — 대기 중인 **그 가전의** 실행일 때만 바꾼다(10/24 실패널: 대기 중 공기청정기를 켜자
  /// 마지막 실행 번호가 바뀌어 닫은 연습 대기가 새 대기로 읽혀 다시 떴다). 대기가 끝나면 [_holdDue]가 지운다.
  String? _holdJob;

  /// 연습 대기의 이름(가전 | 그 가전의 실행 번호). 같은 가전의 새 실행이면 새 대기라 다시 보인다.
  String? _practiceHoldName(KioskStatus st) {
    final app = _practiceHoldKey(st);
    if (app == null) return null;
    if (st.lastApplianceId != null && st.lastApplianceId == st.holdApplianceId && st.lastJobId != null) {
      _holdJob = st.lastJobId;
    }
    return '$app|${_holdJob ?? ''}';
  }

  /// 연습 대기에서 '처음 화면으로'(평가 12차 10/18) — 정지를 보내지 않고 평소 화면으로. 실제 가전은 움직이지 않았다.
  void _leavePracticeHold() {
    final st = _hold;
    if (st == null) return;
    _leftPracticeHold = _practiceHoldName(st);
    _toIdle();
  }

  /// 사람이 확인하고 닫아야 하는 결과 — 멈췄는지 모름, 구동부 이상.
  static bool _holdNeedsPerson(KioskStatus st) =>
      st.holdState == 'fault' ||
      st.holdStopOutcome == 'drive_fault' ||
      (st.holdState == 'parked' &&
          st.holdStopOutcome == 'requested_unconfirmed');

  Future<void> _onHoldStop() async {
    // 정지 "요청"만 보낸다 — 판정(정지됨·미확인)은 서버가 옮겨 오는 값으로만.
    try {
      await _api.stop();
      if (!mounted || _phase != KioskPhase.hold) return;
      setState(() {
        _holdStopRequested = true;
        _holdStopFailed = false;
      });
    } catch (_) {
      if (!mounted || _phase != KioskPhase.hold) return;
      setState(() => _holdStopFailed = true);
    }
  }

  /// 결과 화면을 떠나는 순간 — 실패·'확인 못 함'이면 처음 화면 '지난 일' 한 줄로 남긴다(사용자 결정 10/18). 성공은 남기지 않는다.
  /// 결과 화면이 보이는 동안의 최종 글(정지 보고를 받은 뒤의 말)을 쓴다. 새 지난 일은 이전 것을 바꾼다.
  void _rememberPastResult() {
    if (_phase != KioskPhase.done) return;
    // 사람이 가전을 보고 답했으면 남길 것이 없다(휴리스틱 평가 10/18).
    if (_doneAnswered) return;
    final view = _doneView();
    final headline = view.pastHeadline;
    if (headline == null) return;
    final name = actionName(_doneLabel);
    final label = name.isNotEmpty ? name : (view.target?.displayName ?? '');
    _pastResult = KioskPastResult(at: _doneAt, label: label, headline: headline, jobId: _activeJobId);
  }

  /// 조용한 시간에 화면을 만졌다 — 잠시 평소 밝기로(사용자 결정 10/18). 만질 때마다 다시 센다.
  void _noteIdleTouch() {
    if (!_health.quietActive) return;
    _quietWakeTimer?.cancel();
    _quietWakeTimer = Timer(kQuietWakeDuration, () {
      if (mounted) setState(() => _quietAwake = false);
    });
    if (!_quietAwake) setState(() => _quietAwake = true);
  }

  /// 처음 화면을 어둡게 할까(사용자 결정 10/18) — 매일 조용한 시간(서버 quiet.reason=schedule) 동안 처음 화면에서만(잠시 쉬기는 어둡게 하지 않는다). 실행·정지 대기·결과·
  /// 제안·비상 화면은 어둡게 하지 않는다(안전): 처음 화면이 아니면, 비상 버튼 띠·위험 신호음 창이 떠 있으면, 설정·잠시 쉬기·
  /// 연결 창이 열려 있으면, 만진 뒤 [kQuietWakeDuration] 동안은 밝게 둔다.
  bool get _quietDim =>
      _phase == KioskPhase.idle &&
      _health.quietScheduleActive &&
      !_quietAwake &&
      !_showEstop &&
      !_alert.active &&
      !_showSettings &&
      !_showDnd &&
      _openConnectionId == null;

  /// 고대비를 켜고 끈다 — 색 토큰을 바꾸고 화면을 통째로 다시 그린다(같은 위젯 인스턴스도 새 색을 읽게).
  void _setHighContrast(bool on) {
    setState(() => _highContrast = on);
    KioskColors.setHighContrast(on);
    _repaintAll();
  }

  /// 밝은·어두운 화면을 고른다(시안 B 10/24) — 고대비와 같은 방식으로 다시 그리고 저장한다.
  void _setDarkMode(bool on) {
    setState(() => _darkMode = on);
    KioskColors.setDarkMode(on);
    _repaintAll();
  }

  void _repaintAll() {
    _rebuildAll();
    _persistSettings();
  }

  /// 색 한 벌이 바뀌면 같은 위젯 인스턴스도 새 색을 읽게 화면 전체를 다시 그린다.
  void _rebuildAll() {
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  /// 지금 결과의 복귀 문맥(R7) — 사람이 직접 고른 가전. [_toExecuting]이 실행마다 새로 정한다.
  String? _continueApplianceId;

  /// 복귀 문맥의 보던 칸 — 버튼판에서 누른 실행이면 true(계속 조작은 버튼판으로), 저장된 동작이면 false(10/24 QA).
  bool _continueOnBoard = false;

  /// 이번에 여는 조작판을 버튼판부터 보일까(계속 조작·실패 뒤 화면 조작). 가전을 새로 고르면 false.
  bool _manualOpenBoard = false;

  /// 조작판 루틴에서 만든 카드(카드 id, 그 조작판의 가전 id) — 승인하면 결과 뒤 그 조작판으로 돌아간다.
  (String, String)? _routineCard;

  /// 사람이 이 키오스크에서 저장된 동작을 눌러 만든 마지막 카드 id(10/24 QA) — 그 카드는 '제안'이 아니라 '확인'으로 묻는다.
  String? _ownCardId;

  /// 결과 화면의 '이 가전 계속 조작' — 같은 가전 조작판으로 **돌아가기만** 한다(직전 명령을 다시 보내지 않는다).
  /// 최신 설치 목록에서 다시 찾고, 없으면(그사이 삭제) 가전 고르기로 — 다른 가전으로 메우지 않는다.
  void _continueSameAppliance() {
    _toManualAfterResult(pickOther: false);
  }

  /// 결과 화면의 '다른 가전 고르기'.
  void _pickOtherAppliance() {
    _toManualAfterResult(pickOther: true);
  }

  /// 조작판으로 갔으면 true. 본체에 닿지 않아 연결 창만 열었으면 false(결과 화면 그대로).
  bool _toManualAfterResult({required bool pickOther}) {
    if (_phase != KioskPhase.done) return false;
    _leavePracticeResult();
    // 본체에 닿지 않으면 조작판을 열지 않는다(처음 화면 가전 줄과 같은 규칙) — 무엇이 안 되는지 말하는 연결 창.
    if (!_health.ok) {
      setState(() => _openConnectionId = 'network');
      return false;
    }
    final id = _continueApplianceId;
    final target = pickOther || id == null ? null : _findIn(_appliances, id);
    _rememberPastResult();
    _doneReturnTimer?.cancel();
    _doneReturnTimer = null;
    _countdownTimer?.cancel();
    setState(() {
      _phase = KioskPhase.manual;
      _manualAppliance = target;
      _manualOpenBoard = target != null && _continueOnBoard;
      if (target != null) _currentAppliance = target;
      _currentSuggestion = null;
      _showDnd = false;
    });
    _persistSettings();
    _fetchRoutines();
    return true;
  }

  /// 연습 결과를 사람이 닫았다 — 같은 실행의 연습 대기(누름 장치가 정지 버튼 위에서 기다림)는 다시 띄우지 않는다(10/24 모의 보드
  /// 시험: '연습이 끝났어요' → 처음 화면 → 대기 화면이 다시 떴다). 실제 실행의 대기는 그대로 뜬다 — 정지 버튼이 닿아야 한다.
  void _leavePracticeResult() {
    if (_phase != KioskPhase.done || _executionMode != 'mock') return;
    final appliance = _execApplianceId;
    final job = _activeJobId;
    if (appliance == null || job == null) return;
    _holdJob = job;
    _leftPracticeHold = '$appliance|$job';
  }

  void _toIdle() {
    _leavePracticeResult();
    _rememberPastResult();
    _continueApplianceId = null;
    _routineCard = null;
    _holdReturnTimer?.cancel();
    _holdReturnTimer = null;
    _doneReturnTimer?.cancel();
    _doneReturnTimer = null;
    _countdownTimer?.cancel();
    setState(() {
      _phase = KioskPhase.idle;
      _homeTab = KioskTab.home;
      _currentSuggestion = null;
      _showDnd = false;
    });
    _checkHealth();
  }

  ApplianceMap? _findIn(List<ApplianceMap> list, String id) {
    for (final a in list) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 이어받은 실행의 이름 — 가전 이름, 모르면 빈 문자열(2026-10-14). 예전에는 '실행'으로 메워
  /// "실행 — 다시 누르지 않았어요"가 됐다. 빈 이름이면 완료 화면·음성이 이름 머리를 붙이지 않는다.
  String _nameOf(String? applianceId) =>
      applianceId == null ? '' : (_findIn(_appliances, applianceId)?.displayName ?? '');

  Future<void> _fetchAppliances() async {
    final list = await _api.listAppliances();
    // null = 통신 실패 → 마지막으로 안 목록을 유지한다(오프라인 우선).
    // 빈 목록은 **성공한 답**이다(마지막 가전 삭제, B11) — 이전처럼
    // 실패와 함께 버리면 서버에 없는 가전의 조작판이 계속 남는다.
    if (!mounted || list == null) return;
    setState(() {
      _appliances = list;
      _appliancesFromServer = true;
      // 재부팅 복원 보류분(커스텀 가전) — 서버 목록이 왔으니 마저 복원
      final pendingId = _pendingRestoreApplianceId;
      if (pendingId != null) {
        _pendingRestoreApplianceId = null;
        final pending = _findIn(list, pendingId);
        if (pending != null) _currentAppliance = pending;
      }
      // 정의가 갱신됐으면(버튼 교체 등) 현재 가전도 새 정의로 바꿔 끼운다
      final updated = _findIn(list, _currentAppliance.id);
      if (updated != null) _currentAppliance = updated;
      // 조작 중인 가전도 최신 정의로. 폰에서 삭제됐다면 조작판을 닫는다 —
      // 삭제된 가전의 버튼을 계속 누르게 두면 서버 게이트(404)에 걸리기
      // 전까지 화면과 실물이 어긋난다 (교차 리뷰 치명 #1).
      final manual = _manualAppliance;
      if (manual != null) {
        final refreshed = _findIn(list, manual.id);
        if (refreshed != null) {
          _manualAppliance = refreshed;
        } else if (_phase == KioskPhase.manual) {
          // 평소 화면으로 — 삭제 사실은 가전 줄에서 빠진 것으로 자명하다.
          _manualAppliance = null;
          _phase = KioskPhase.idle;
        }
      }
    });
  }

  /// 평소 화면의 가전 아이콘 → 내 가전.
  void _toMyAppliance(ApplianceMap appliance) {
    if (_phase != KioskPhase.idle) return;
    // 허브에 닿지 않으면 버튼판을 열지 않는다 — 연결 없이는 실제로 버튼도 못
    // 누른다. 대신 무엇이 안 되는지 말하는 연결 모달을 연다.
    if (!_health.ok) {
      setState(() => _openConnectionId = 'network');
      return;
    }
    setState(() {
      _phase = KioskPhase.manual;
      _manualAppliance = appliance;
      _manualOpenBoard = false;
      _currentAppliance = appliance; // 실행 라우팅의 기준
    });
    _persistSettings();
    _fetchRoutines();
  }

  /// 내 가전의 루틴 → 카드(다가오면). 실행은 카드의 "지금 실행"(승인) 뒤에만.
  Future<void> _onRoutine(KioskRoutine routine) async {
    // 처음 화면 '무엇을 할까요?' 카드(시안 B 10/24)에서도 온다 — 그때는 카드가 끝나면 처음 화면으로(돌아갈 가전 없음).
    final startedFrom = _phase;
    if (startedFrom != KioskPhase.manual && startedFrom != KioskPhase.idle) return;
    try {
      final result = await _api.triggerRoutine(routine.id);
      if (!mounted || _phase != startedFrom) return;
      final card = result.suggestion;
      if (card != null) {
        final from = startedFrom == KioskPhase.manual ? _manualAppliance : null;
        _routineCard = from == null ? null : (card.id, from.id);
        _ownCardId = card.id;
        _toSuggestion(card);
        return;
      }
      final notice = result.notice;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(notice == null || notice.isEmpty
            ? '알림만 보내는 루틴이에요. 가전은 누르지 않아요.'
            : notice),
      ));
    } on KioskApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.detail.isNotEmpty ? e.detail : '루틴 카드를 만들지 못했어요.'),
      ));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('루틴 카드를 만들지 못했어요. 연결을 봐 주세요.'),
      ));
    }
  }

  void _onManualApplianceSelected(ApplianceMap appliance) {
    setState(() {
      _manualAppliance = appliance;
      _manualOpenBoard = false;
      _currentAppliance = appliance; // 실행 라우팅·"지난번" 배지의 기준
    });
    _persistSettings();
  }

  void _fromManual() => setState(() {
        _phase = KioskPhase.idle;
        _manualAppliance = null; // 다음 진입 때 다시 선택(공간 허브 의미)
      });

  /// 실패 화면의 '다시 시도' — 직전 실행을 그대로 한 번 더 시도한다.
  void _onRetryFailed() {
    final retry = _retryAction;
    if (retry == null) {
      _toIdle();
      return;
    }
    retry();
  }

  /// 실패 화면의 '화면으로 조작하기' — 자동 실행을 포기하고 사람이 직접 고르는
  /// 화면으로 보낸다. _toManual은 idle에서만 동작하므로 phase를 먼저 되돌린다.
  void _onManualFromFailure() {
    _rememberPastResult();
    _countdownTimer?.cancel();
    setState(() {
      _phase = KioskPhase.manual;
      // 직접 고른 가전에서 실패했으면 그 가전(R7) — 예전에는 가전이 여럿이면 선택을 비웠다.
      final ctx = _continueApplianceId == null ? null : _findIn(_appliances, _continueApplianceId!);
      _manualAppliance = ctx ?? (_appliances.length == 1 ? _appliances.single : null);
      _manualOpenBoard = ctx != null && _continueOnBoard;
      _currentSuggestion = null;
      _showDnd = false;
    });
  }

  void _toSuggestion(KioskSuggestion suggestion) {
    _shownSuggestionIds.add(suggestion.id);
    // 제안 도착을 소리로도 알린다 — 사용자가 화면 근처에 없어도 알 수 있게.
    // 화면의 제목·버튼과 **같은 말**을 쓴다 -- 음성을 듣고 화면을 보는 사용자가
    // '승인'을 찾다가 '지금 실행'을 못 알아보면 그 순간 막힌다.
    // 시나리오 질문은 서버 문장이 이미 물음으로 끝난다("…바꿀까요?").
    // 조용한 시간(2026-10-14)에는 일반 안내 소리를 내지 않는다 — 화면 카드는 그대로.
    if (_health.speakGeneral) {
      final ownName = suggestion.id == _ownCardId ? suggestion.routineName : null;
      // 직접 누른 저장된 동작이면 화면 질문과 같은 말('30초 데우기를 할까요?', 10/24 QA).
      _tts.speak(ownName != null && ownName.isNotEmpty
          ? '${withObject(ownName)} 할까요? 화면에서 지금 하기를 눌러 주세요.'
          : suggestion.isScenario
          ? '${suggestion.purpose} 화면에서 지금 하기를 눌러 주세요.'
          : '${actionName(suggestion.purpose)}, 지금 할까요? 화면에서 지금 하기를 눌러 주세요.');
    }
    setState(() {
      _phase = KioskPhase.suggestion;
      _currentSuggestion = suggestion;
      _cdRemaining = _countdownSeconds;
      _cdTotal = _countdownSeconds;
      _scenarioBlockedWhy = null;
    });
    if (suggestion.isScenario) _loadScenarioContext(suggestion);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cdRemaining--);
      if (_cdRemaining <= 0) {
        timer.cancel();
        _toIdle();
      }
    });
  }

  /// 제안 화면을 만졌다(접근성 감사 10/18 — 시간 제한 조절) — 남은 시간을 처음 길이로 되돌린다. 이미 더 남았으면 그대로.
  void _touchSuggestion() {
    if (_phase != KioskPhase.suggestion || _cdRemaining >= _countdownSeconds) return;
    setState(() => _cdRemaining = _countdownSeconds);
  }

  /// '시간 더 주기' — 60초 더. 이 시간은 화면 타이머다(서버 제안 카드는 따로 만료된다 — 거절·실행을 보내지 않는다).
  void _extendSuggestion() {
    if (_phase != KioskPhase.suggestion) return;
    setState(() {
      _cdRemaining += kSuggestionExtendSeconds;
      if (_cdRemaining > _cdTotal) _cdTotal = _cdRemaining;
    });
  }

  /// 시나리오 카드의 이름과 대상별 준비 상태를 받는다. 실패는 막지 않는다 —
  /// 모름을 '안 됨'으로 단정하지 않고, 서버가 실행 직전에 다시 검사한다.
  Future<void> _loadScenarioContext(KioskSuggestion suggestion) async {
    final names = await _api.scenarioNames();
    String? blocked;
    for (final c in suggestion.commands) {
      final r = await _api.readiness(c.targetId);
      if (r != null && !r.canExecute) {
        final who = c.summary.isNotEmpty ? c.summary : '가전';
        blocked = r.reasons.isNotEmpty
            ? '$who. ${r.reasons.first}'
            : '$who. 아직 쓸 수 없어요. 휴대폰 앱에서 봐 주세요';
        break;
      }
    }
    if (!mounted ||
        _phase != KioskPhase.suggestion ||
        _currentSuggestion?.id != suggestion.id) {
      return;
    }
    setState(() {
      if (names.isNotEmpty) _scenarioNames = names;
      _scenarioBlockedWhy = blocked;
    });
  }

  /// [continueApplianceId] — 키오스크에서 사람이 직접 고른 가전에서 시작한 실행이면 그 가전(R7 연속 조작, 2026-10-24).
  /// 결과 화면이 '이 가전 계속 조작'으로 같은 조작판에 돌아가고 처음 화면으로 저절로 가지 않는다. 이어받은 실행·스스로 뜬
  /// 제안은 null — 직접 조작하던 화면이 없다. 실행 job의 대상([applianceId])과 섞지 않는다.
  void _toExecuting(String title,
      {String? applianceId,
      String? jobId,
      bool thinqOnly = false,
      String? thinqActionText,
      String? continueApplianceId,
      bool continueOnBoard = false}) {
    _rememberPastResult();
    _continueApplianceId = continueApplianceId;
    _continueOnBoard = continueApplianceId != null && continueOnBoard;
    _execThinqOnly = thinqOnly;
    _execThinqActionText = thinqOnly ? thinqActionText : null;
    _executionMode = 'unknown';
    _doneRoute = null;
    _doneConfirmation = null;
    _doneRawConfirmation = null;
    _doneDetail = null;
    _doneOperationConfirmed = null;
    _doneOperationSource = null;
    _doneAbortReason = null;
    _doneStopLevel = null;
    _doneStopAckMs = null;
    _doneStopAgain = null;
    _stopFollowTimer?.cancel();
    _stopPending = false;
    _doneOperationDetail = null;
    _doneRunSteps = const [];
    _activeJobId = jobId;
    _execRoutineRunId = null;
    _execRoutineSegment = null;
    _execRoutineSegmentJobId = null;
    _execRoutineWaiting = false;
    _execPlanButtons = null;
    _retryAction = null;
    _lastStatusOk = DateTime.now();
    _foreignPolls = 0;
    // 남은 정지(접수 응답 전에 누른 정지)는 이어받은 실행에도 지킨다(검토 10/19 코어 4차) — 새 실행을 시작하는 쪽이 지운다.
    _execStop = _stopWhileAccepting ? KioskExecStop.stopping : KioskExecStop.none;
    _admitGen++;
    _accepting = false;
    _admitUnknown = false;
    _admitUnknownPolls = 0;
    setState(() {
      _phase = KioskPhase.executing;
      _execTitle = title;
      _execApplianceId = applianceId;
      _lastButtons = null;
      _execBarValue = 0;
      _totalSteps = null;
      _currentButton = null;
      _execDoneButtons = const [];
      _currentAttempt = null;
      _completedSteps = null;
      _verificationConfidence = null;
      _verificationDetail = null;
    });
  }

  void _finishExecuting({
    required bool success,
    required List<KioskButtonResult> buttons,
    KioskFailureReason reason = KioskFailureReason.execution,
  }) {
    // 지연 도착한 approve/execute 응답이 이미 끝난(정지·완료된) 실행을
    // 되살려 idle 화면을 완료 화면으로 점프시키는 것을 막는다.
    // 지연 콜백에서도 phase와 job ID를 다시 확인한다.
    if (_phase != KioskPhase.executing) return;
    setState(() {
      _lastButtons = buttons;
      _execBarValue = 1.0;
    });
    final jobId = _activeJobId;
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted && _phase == KioskPhase.executing &&
          _activeJobId == jobId) {
        _toDone(success, _execTitle, reason: reason);
      }
    });
  }

  void _toDone(
    bool success,
    String label, {
    KioskFailureReason reason = KioskFailureReason.execution,
  }) {
    // 실행 결과 음성 안내. '서버 응답 없음'은 라벨이 아니라 오류 상황이라
    // 문장을 따로 쓴다 ("서버 응답 없음, 실행하지 못했어요"는 어색).
    // 이름을 모르면(빈 문자열) 이름 머리 없이 말한다(2026-10-14).
    // 음성도 화면 제목과 같은 행동 이름('즉석밥 데우기', 평가 4차 10/18).
    final lead = label.isEmpty ? '' : '${actionName(label)}, ';
    // LG 가전 결과 창이면 창과 같은 말(사용자 요청 10/18).
    final thinqCopy = KioskDoneView(
      success: success,
      label: label,
      reason: success ? null : reason,
      thinqOnly: _execThinqOnly,
      thinqActionText: _execThinqActionText,
      route: _doneRoute,
      resultConfirmation: _doneRawConfirmation,
      detail: _doneDetail,
      executionMode: _executionMode,
      target: _execApplianceId == null ? null : _findIn(_appliances, _execApplianceId!),
    ).thinqCopy;
    _tts.speak(thinqCopy != null ? thinqCopy.spoken :
      // 화면과 같은 말. '완료되었습니다'는 조리·세탁이 끝났다고 들린다 --
      // 이 시스템이 끝낸 것은 버튼 조작이다.
      success
          ? '$lead${finishedMessage(kind: ResultKind.success, executionMode: _executionMode, route: _doneRoute, confirmation: _doneRawConfirmation, detail: _doneDetail, operationVerified: _doneOperationConfirmed == true && _doneOperationSource == 'real' && _executionMode != 'mock')}'
          : switch (reason) {
              KioskFailureReason.serverLost =>
                '어떻게 됐는지 확인하지 못했어요. 가전을 봐 주세요.',
              // 정지 단계만큼(2026-10-15). 단계 보고를 아직 기다리면 화면과 같은 진행 말만 하고, 결과는 보고가 오거나
              // 기다리기를 그만둘 때 말한다(평가 8차 10/18).
              KioskFailureReason.stopped => _stopPending && _doneStopLevel == null
                  ? '$kStopPendingHeadline.'
                  : finishedMessage(
                      kind: ResultKind.stopped, stopLevel: _doneStopLevel, executionMode: _executionMode),
              KioskFailureReason.safetyStop =>
                '$lead${finishedMessage(kind: ResultKind.safetyStop, abortReason: _doneAbortReason)}',
              KioskFailureReason.unconfirmed =>
                '$lead${unconfirmedSentence()}',
              KioskFailureReason.receiptUnknown =>
                '$lead${unconfirmedSentence(receipt: 'unknown')}',
              KioskFailureReason.notExecuted =>
                '$lead가전을 바꾸지 못했어요. 가전 연결을 봐 주세요.',
              KioskFailureReason.execution =>
                '$lead눌렸는지 확인하지 못했어요. 가전을 봐 주세요.',
            },
    );
    _doneReturnTimer?.cancel();
    _doneReturnTimer = null;
    _doneRemaining = null;
    _doneAt = DateTime.now();
    _doneAnswered = false;
    _doneHoldGrace?.cancel();
    _doneHoldGrace = Timer(_largeText ? KioskTimings.doneReturnLarge : _doneReturnDuration, () {});
    setState(() {
      _phase = KioskPhase.done;
      _doneSuccess = success;
      _doneLabel = label;
      _doneReason = success ? null : reason;
      _doneHeld = false;
    });
    // 실패는 자동으로 사라지지 않는다 — 사용자가 다음 행동을 고를 때까지
    // 화면에 남아야 한다(고령 사용자가 이유도 모른 채 놓치는 것을 막는다).
    if (!success) return;
    // 버튼 누름 보고만(가전은 사람이 본다) — 사람이 답할 때까지 닫지 않는다(2차 독립 평가 C, 10/18).
    if (_doneView().personCheck != null) return;
    // 직접 고른 가전에서 시작한 실행(R7, 2026-10-24) — 사용 중인 사람을 처음 화면으로 튕기지 않는다. 다음 행동은 사람이 고른다.
    if (_continueApplianceId != null) return;
    // 취소할 수 있는 타이머 — 화면을 만지면 멈춘다(UI 평가 10/17). 예전 Future.delayed는 다음 결과 화면까지 닫을 수 있었다.
    // 큰 글씨는 두 배 — 스크롤해서 읽는 동안 닫히지 않게(UI 평가 4차 10/17).
    // 1초씩 세어 남은 초를 화면에 숫자로 말한다(접근성 감사 10/18 — '잠시 뒤'는 얼마나 남았는지 몰랐다). 전체 길이는 종전과 같다.
    final total = _largeText ? KioskTimings.doneReturnLarge : _doneReturnDuration;
    _doneRemaining = total.inSeconds;
    _doneReturnTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _phase != KioskPhase.done) {
        timer.cancel();
        if (identical(_doneReturnTimer, timer)) _doneReturnTimer = null;
        return;
      }
      final left = (_doneRemaining ?? 0) - 1;
      setState(() => _doneRemaining = left);
      if (left <= 0) {
        timer.cancel();
        _doneReturnTimer = null;
        _toIdle();
      }
    });
  }

  /// 결과 화면을 만졌다 — 자동 복귀를 멈춘다(천천히 읽는 사람, 시간 제한 조절). '처음 화면으로'는 그대로 된다.
  void _holdDone() {
    final timer = _doneReturnTimer;
    if (timer == null || !mounted || _phase != KioskPhase.done) return;
    timer.cancel();
    _doneReturnTimer = null;
    setState(() => _doneHeld = true);
  }

  Future<void> _onApprove({KioskSuggestion? suggestion}) async {
    if (_dismissingSuggestion || _admitting) return;
    suggestion ??= _currentSuggestion;
    if (suggestion == null) return;
    // 대상을 모르는 제안은 실행하지 않는다(백로그 B10). 화면이 이미 실행
    // 버튼을 잠갔지만, 재시도 콜백 등 다른 경로로 와도 같은 규칙이다 --
    // 서버도 409로 거절하므로 실행 화면으로 넘어가 봐야 실패만 보여준다.
    final targetId = suggestion.applianceId;
    // 시나리오 카드는 서버가 고정한 명령으로 승인한다 — ThinQ 가전은 조작판
    // 목록에 없다. 준비 안 된 대상이 있으면 실행을 내걸지 않는다.
    if (suggestion.isScenario) {
      if (_scenarioBlockedWhy != null) return;
    } else if (targetId == null || _findIn(_appliances, targetId) == null) {
      return;
    }
    _countdownTimer?.cancel();
    setState(() => _currentSuggestion = null);
    // 실행·완료 화면은 카드의 질문이 아니라 무엇을 하는지(평서형)를 말한다.
    final label =
        suggestion.doneLabel(scenarioName: _scenarioNames[suggestion.scenarioId]);
    // LG 가전 명령 하나뿐인 카드면 버튼판 없는 기다림·결과 창(사용자 요청 10/18). 판정은 승인에 묶인 명령의 경로로.
    final thinqOnly = isSingleThinqCommand([for (final c in suggestion.commands) c.route]);
    _beginAdmission();
    final fromRoutine = _routineCard;
    _routineCard = null; // 한 번 쓰면 끝 — 같은 카드가 나중에 스스로 떠도 이 조작판으로 돌아가지 않는다(코드 검토 10/24)
    _toExecuting(label,
        applianceId: suggestion.applianceId,
        thinqOnly: thinqOnly,
        thinqActionText: thinqOnly ? suggestion.commands.single.summary : null,
        // 조작판의 루틴에서 만든 카드면 그 조작판으로 돌아간다. 스스로 뜬 제안은 돌아갈 조작판이 없다.
        continueApplianceId: fromRoutine != null && fromRoutine.$1 == suggestion.id ? fromRoutine.$2 : null);
    final commands = suggestion.commands;
    _execPlanButtons = commands.length == 1 && commands.single.route == 'physical' && commands.single.buttons.length > 1
        ? List.unmodifiable(commands.single.buttons)
        : null;
    final gen = _admitGen;
    _accepting = true;
    _retryAction = () => _onApprove(suggestion: suggestion);

    try {
      // job 모델: 즉시 접수 — 진행·완료는 _pollExecuting이 job_id 대조로 따라간다
      final accepted = await _api.approveSuggestion(suggestion.id, clientRequestId: _admitRequestId);
      if (gen != _admitGen) return;
      _accepting = false;
      _activeJobId = accepted.jobId;
      _stopIfAskedWhileAccepting();
    } catch (e) {
      if (gen != _admitGen) return;
      _accepting = false;
      if (!mounted || _phase != KioskPhase.executing) return;
      // 본체가 분명히 거절한 것(4xx)만 '시작하지 않음'이다. 시간 초과·끊김·5xx는 시작됐을 수 있다(검토 10/19 코어 4차).
      if (e is! KioskApiException || e.statusCode >= 500) {
        _admissionLost();
        return;
      }
      _stopWhileAccepting = false; // 거절됐다 — 멈출 내 실행이 없다
      if (e.isApprovalChanged || e.statusCode == 412) {
        // 승인 재검사 실패: 서버가 카드를 내렸다. 실패 화면('다시 시도')으로
        // 보내면 옛 승인을 또 누르게 된다 — 처음 화면으로 돌아가 새 카드를 받는다.
        // 412(준비 안 됨)는 서버 문장이 이유를 말한다.
        final message = e.isApprovalChanged
            ? kApprovalChangedMessage
            : (e.detail.isNotEmpty ? e.detail : '가전을 아직 쓸 수 없어요. 휴대폰 앱에서 가전 설정을 봐 주세요.');
        _tts.speak(message);
        _toIdle();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        _poll();
        return;
      }
      // 접수 거절(409 등) — 올 수 없는 완료를 기다리는 대신 즉시 실패 화면으로 탈출한다.
      _toDone(false, label,
          reason: KioskFailureReason.serverLost);
    }
  }

  /// 새 실행 접수를 시작한다 — 앞 실행의 남은 정지는 넘기지 않고, 새 요청 번호와 응답을 잃을 때 견줄 마지막 결과 번호를 잡는다.
  void _beginAdmission() {
    _stopWhileAccepting = false;
    _admitRequestId = newKioskRequestId();
    _admitBaseKnown = _seenLastJobInit;
    _admitBase = _seenLastJobId;
  }

  /// 접수 응답을 잃었다 — '못 보냈다'로 끝내지 않는다. 시작됐을 수 있다고 말하고 정지 단추를 둔 채 [_pollAdmitUnknown]이 찾는다.
  void _admissionLost() {
    _admitUnknown = true;
    _admitUnknownPolls = 0;
    _lastStatusOk = DateTime.now();
    _tts.speak(kAdmitUnknownMessage);
    final notice = ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(kAdmitUnknownMessage)));
    _admitUnknownNotice = notice;
    // 스스로 닫힌 알림은 다시 닫지 않는다(알림 줄은 앞 것이 닫혀야 다음 것이 뜬다 — 닫히기 전에는 늘 맨 앞이다).
    notice.closed.then((_) {
      if (identical(_admitUnknownNotice, notice)) _admitUnknownNotice = null;
    });
  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _admitUnknownNotice;

  /// 응답을 잃은 접수가 풀렸다(이어받음·결과 찾음·포기) — '시작됐을 수 있어요' 알림을 내린다. 결과 화면 단추를 가리지 않게.
  void _endAdmitUnknown() {
    _admitUnknown = false;
    // 아직 열린 알림이면 맨 앞이다 — 바로 걷는다(닫히는 움직임 동안에도 결과 화면 단추를 가렸다).
    if (_admitUnknownNotice != null) ScaffoldMessenger.of(context).removeCurrentSnackBar();
    _admitUnknownNotice = null;
  }

  /// 응답을 잃은 접수의 실행을 본체에서 찾는다 — 요청 번호로 찾으면 그 실행을 따라가고, 본체가 모르는 번호라고 하면 남의 실행을
  /// 이어받지 않고 기다리다 결과 화면('어떻게 됐는지 확인하지 못했어요'). 옛 본체(요청 번호 조회 없음)만 종전처럼: 돌고 있으면 이어받고,
  /// 그 사이 끝났으면 그 결과를, 계속 쉬면 결과 화면.
  Future<void> _pollAdmitUnknown() async {
    final gen = _admitGen;
    final requestId = _admitRequestId;
    bool stale() =>
        !mounted || gen != _admitGen || _phase != KioskPhase.executing || !_admitUnknown || _activeJobId != null;
    try {
      final st = await _api.status();
      if (stale()) return;
      _trackStrip(st);
      _trackEstop(st);
      final lookup = requestId == null
          ? const KioskRequestLookup(KioskRequestLookupKind.unsupported)
          : await _api.jobByRequest(requestId);
      if (stale()) return;
      // 무엇도 알지 못했다 — 끊김과 같이 센다(오래 이어지면 [_statusLostTimeout]으로 결과 화면).
      if (lookup.kind == KioskRequestLookupKind.failed) throw StateError('job lookup failed');
      _lastStatusOk = DateTime.now();
      if (lookup.kind == KioskRequestLookupKind.found) {
        _endAdmitUnknown();
        _foreignPolls = 0;
        setState(() => _activeJobId = lookup.jobId);
        // 그 실행이 아직 돌면 남은 정지를 다시 보낸다. 끝났으면 다음 조회가 그 결과를 보인다.
        _followPendingStop(st);
        return;
      }
      if (lookup.kind == KioskRequestLookupKind.unknown) {
        // 본체가 이 요청을 접수하지 않았다(아직이거나 실패) — 지금 도는 실행은 남의 것이다. 정지도 그 실행에 다시 보내지 않는다.
        if (++_admitUnknownPolls >= _admitUnknownIdlePolls) {
          _stopWhileAccepting = false;
          _endAdmitUnknown();
          _toDone(false, _execTitle, reason: KioskFailureReason.serverLost);
        }
        return;
      }
      final adopt = _adoptableJobId(st);
      if (adopt != null) {
        _endAdmitUnknown();
        _foreignPolls = 0;
        setState(() {
          _activeJobId = adopt;
          if (adopt == st.routineRunId) _execRoutineRunId = adopt;
          _execApplianceId = st.applianceId ?? _execApplianceId;
        });
        _followPendingStop(st);
        return;
      }
      final last = st.lastJobId;
      if (_admitBaseKnown && last != null && last != _admitBase) {
        _endAdmitUnknown();
        _activeJobId = last;
        _followPendingStop(st);
        _completeFromStatus(st, last);
        return;
      }
      _followPendingStop(st);
      if (++_admitUnknownPolls >= _admitUnknownIdlePolls) {
        // 찾지 못하고 포기한다 — 남은 정지도 버린다. 남기면 결과 화면이 그 뒤 이어받은 남의 실행에 보냈다(검토 10/19 코어 6차).
        _stopWhileAccepting = false;
        _endAdmitUnknown();
        _toDone(false, _execTitle, reason: KioskFailureReason.serverLost);
      }
    } catch (_) {
      if (stale()) return;
      final since = _lastStatusOk;
      if (since != null && DateTime.now().difference(since) > _statusLostTimeout) {
        _stopWhileAccepting = false;
        _endAdmitUnknown();
        _toDone(false, _execTitle, reason: KioskFailureReason.serverLost);
      }
    }
  }

  Future<void> _onReject() => _dismissSuggestion(mute: false);

  Future<void> _dismissSuggestion({required bool mute}) async {
    final suggestion = _currentSuggestion;
    if (suggestion == null || _dismissingSuggestion) return;
    _dismissingSuggestion = true;
    _countdownTimer?.cancel();
    try {
      await _api.rejectSuggestion(suggestion.id, mute: mute);
      if (mounted && _phase == KioskPhase.suggestion &&
          _currentSuggestion?.id == suggestion.id) {
        _toIdle();
      }
    } catch (_) {
      if (mounted && _phase == KioskPhase.suggestion &&
          _currentSuggestion?.id == suggestion.id) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("'이번엔 안 할게요'를 보내지 못했어요. 연결을 확인하고 다시 눌러 주세요."),
        ));
      }
    } finally {
      _dismissingSuggestion = false;
    }
  }

  Future<void> _onManualExecute(ApplianceButton button) async {
    // 두 번 누름은 요청 하나만(검토 10/19) — 둘째의 409가 첫 실행을 실패 화면 뒤에 숨기던 것.
    if (_admitting) return;
    _beginAdmission();
    _toExecuting(button.label,
        applianceId: _currentAppliance.id,
        continueApplianceId: _manualAppliance?.id ?? _currentAppliance.id,
        continueOnBoard: true);
    final gen = _admitGen;
    _accepting = true;
    _retryAction = () => _onManualExecute(button);
    try {
      final accepted = await _api.executeButtons(
        [button.label],
        applianceId: _currentAppliance.id,
        clientRequestId: _admitRequestId,
      );
      if (gen != _admitGen) return;
      _accepting = false;
      _activeJobId = accepted.jobId;
      _stopIfAskedWhileAccepting();
    } catch (e) {
      if (gen != _admitGen) return;
      _accepting = false;
      if (!mounted || _phase != KioskPhase.executing) return;
      // 응답을 잃었으면 시작됐을 수 있다(검토 10/19 코어 4차). 분명한 거절(4xx)만 즉시 실패 화면으로 탈출 (고착 방지).
      if (e is! KioskApiException || e.statusCode >= 500) {
        _admissionLost();
        return;
      }
      _stopWhileAccepting = false;
      _toDone(false, button.label,
          reason: KioskFailureReason.serverLost);
    }
  }

  /// 결과 화면의 '다시 멈추기'(평가 15차 10/18) — 정지 대기 화면의 '다시 멈추기'와 같은 정지 경로(/stop). 판정은 하지 않는다:
  /// 본체가 받았는지만 화면에 말하고, 멈췄는지는 사람이 누름 장치를 본다.
  Future<void> _onDoneStopAgain() async {
    try {
      await _api.stop();
      if (!mounted || _phase != KioskPhase.done) return;
      setState(() => _doneStopAgain = 'sent');
    } catch (_) {
      if (!mounted || _phase != KioskPhase.done) return;
      setState(() => _doneStopAgain = 'failed');
    }
  }

  Future<void> _onStop() async {
    // 정지 "요청"만 보낸다 — 화면 전환은 폴링이 safety_stopped 완료를 받은 뒤.
    // 하드웨어가 멈추기 전에 '정지됨' 화면부터 띄우면 실제 상태와 어긋난다.
    // 접수 응답 전이면 지금 보내는 정지가 아무것도 멈추지 못할 수 있다 — job_id가 오는 대로 다시 보낸다(검토 10/19).
    // 접수 응답을 잃어 실행을 아직 못 찾았을 때도 같다(검토 10/19 코어 4차).
    if ((_accepting || _admitUnknown) && _activeJobId == null) {
      _stopWhileAccepting = true;
      _stopAskedAt = DateTime.now();
      setState(() => _execStop = KioskExecStop.stopping);
    }
    await _sendExecStop();
  }

  /// 접수 응답 전에 정지를 눌렀으면 받은 job을 멈추려고 /stop을 한 번 더 보낸다. 남은 정지는 [_followPendingStop]이 지운다.
  void _stopIfAskedWhileAccepting() {
    if (!_stopWhileAccepting) return;
    _sendExecStop();
  }

  /// 남은 정지를 본체 상태에 맞춘다(검토 10/19 코어 4차) — 내 실행(또는 아직 못 찾은 실행)이 돌면 /stop을 다시 보낸다(같은 정지라 여러 번
  /// 보내도 된다). 내 실행이 끝났거나 다른 실행으로 바뀌었으면, 실행을 못 찾은 채로는 [_pendingStopWindow]가 지나면 버린다.
  void _followPendingStop(KioskStatus st) {
    if (!_stopWhileAccepting) return;
    final mine = _activeJobId;
    final askedAt = _stopAskedAt;
    final fresh = askedAt != null && DateTime.now().difference(askedAt) <= _pendingStopWindow;
    // 루틴을 따라가면(내 번호가 루틴 첫 번호) 구간 사이 기다림·다음 구간도 내 실행이다(검토 10/19).
    final routineMine = mine != null && st.routineRunId == mine;
    if (routineMine || (st.running && st.jobId != null && (mine == null ? fresh : st.jobId == mine))) {
      unawaited(_sendExecStop());
      return;
    }
    if (mine != null || !fresh) _stopWhileAccepting = false;
  }

  Future<void> _sendExecStop() async {
    final gen = _admitGen;
    final routineRunId = _execRoutineRunId;
    if (routineRunId != null) {
      // 루틴이면 그 루틴만 멈춘다(남은 구간을 보내지 않고, 누르는 중이면 본체가 긴급 정지도 보낸다, 검토 10/19). 본체가 받지 않으면
      // (진행 중인 루틴이 아님·옛 본체·끊김) 아래 본체 전체 정지로 갈음한다 — 멈추라는 뜻은 그대로 전한다.
      try {
        await _api.stopRoutineRun(routineRunId);
        if (!mounted || gen != _admitGen || _phase != KioskPhase.executing) return;
        setState(() => _execStop = KioskExecStop.stopping);
        return;
      } catch (_) {
        if (!mounted || gen != _admitGen || _phase != KioskPhase.executing) return;
      }
    }
    try {
      await _api.stop();
      if (!mounted || gen != _admitGen || _phase != KioskPhase.executing) return;
      setState(() => _execStop = KioskExecStop.stopping);
    } catch (_) {
      // 정지 요청조차 실패(통신·본체 거절) — 실행 화면과 정지 단추를 그대로 두고 닿지 않았다고 말한다(검토 10/19).
      // 통신이 계속 끊기면 30초 탈출 타이머가(_pollExecuting의 _statusLostTimeout) 결국 실패 화면으로 빼낸다.
      if (!mounted || gen != _admitGen || _phase != KioskPhase.executing) return;
      setState(() => _execStop = KioskExecStop.failed);
    }
  }

  Future<void> _onSetDnd(int minutes) => _sendDnd(() => _api.setDnd(minutes));

  Future<void> _onClearDnd() => _sendDnd(_api.clearDnd);

  Future<void> _sendDnd(Future<bool?> Function() send) async {
    if (_dndBusy) return;
    setState(() => _dndBusy = true);
    bool? persisted;
    var sent = true;
    try {
      persisted = await send();
    } catch (_) {
      sent = false;
    }
    try {
      await _checkHealth();
    } finally {
      if (mounted) {
        setState(() {
          _dndBusy = false;
          // 못 보냈으면 창을 둔다 — 닫고 말이 없으면 쉬는 줄 알았다(검토 10/19 코어 6차). 다시 누르거나 닫는다.
          if (sent) _showDnd = false;
        });
      }
    }
    if (!sent) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(kDndNotSentNotice)));
      }
      return;
    }
    _notSaved(persisted);
  }

  /// 저장 실패(서버 `persisted: false`)면 이번 세션만 적용됐다고 알린다(2026-10-14 HIGH 재확인 M-R1).
  void _notSaved(bool? persisted) {
    if (persisted != false || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(kSettingNotSavedNotice)));
  }

  @override
  Widget build(BuildContext context) {
    // 큰 글씨 모드 — 설정 오버레이 토글. 800x480 설계 캔버스 기준이라 1.22배가
    // 레이아웃 오버플로 없이 전 화면(시계·제안·실행·수동)에 안전한 상한.
    //
    // 배율 MediaQuery가 KioskCanvas **바깥**에 있어야 한다 — 캔버스가 이걸
    // 물려받아 크기만 덮어쓰기 때문. 순서를 뒤집으면 캔버스의 크기 지정이
    // 실제 화면 크기로 되돌아간다.
    final media = MediaQuery.of(context);
    final base = Theme.of(context);
    // 조용한 시간 어둡게면 밝은 화면도 그동안 어두운 색(시안 B 10/24) — 바뀌는 순간 화면 전체를 새 색으로 다시 그린다.
    final night = _quietDim;
    if (KioskColors.quietNight != night) {
      KioskColors.setQuietNight(night);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _rebuildAll();
      });
    }
    // Material 기본 색(스위치 바탕·구분선·대화 창 면)도 지금 색 한 벌(밝은·어두운 화면·고대비)을 따른다
    // (고대비 사용자 결정 10/18, 밝은·어두운 화면 시안 B 10/24).
    // 앱 테마(대화 창이 쓰는 색, main.dart)와 같은 규칙이다.
    final theme = KioskColors.theme(base);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(_largeText ? 1.22 : 1.0),
      ),
      child: Theme(
          data: theme,
          // 화면 안 창이 떠 있으면 가장자리 띠도 어둡게(실패널 10/24).
          child: ValueListenableBuilder<int>(
            valueListenable: _tabSuppress,
            builder: (context, suppressed, _) => KioskCanvas(
              dim: _quietDim,
              scrim: _scrimOn,
              child: _buildScaffold(),
            ),
          )),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      floatingActionButton: const bool.fromEnvironment('SIMPLELAY_ROUTINE_MOCK') && _phase == KioskPhase.idle && !_showSettings && !_showDnd && !_alert.active
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RoutineRehearsalScreen(request: _api.routineRequest),
              )),
              label: const Text('여러 가전 연습'), icon: const Icon(Icons.science_outlined),
            ) : null,
      // 조용한 시간이면 바탕만 어둡게(접근성 감사 10/18) — 캔버스 바탕과 같은 색이라 안쪽 사각형 테두리가 드러나지 않는다.
      // 창이 떠 있으면 바탕도 막과 같은 색 — 맨 위 3px(진행 막대 자리)·캔버스 가장자리가 밝은 선으로 남았다(실패널 10/24).
      backgroundColor: _scrimOn
          ? Color.alphaBlend(Colors.black.withValues(alpha: KioskCanvas.scrimAlpha), _quietDim ? KioskCanvas.quietBg : KioskColors.bg)
          : (_quietDim ? KioskCanvas.quietBg : KioskColors.bg),
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 4,
            child: TopProgressBar(phase: _phase, execBarValue: _execBarValue),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              // 비상정지 경고는 화면 **위에 한 줄**을 차지한다 — 덮지 않으므로
              // 실행·동작 중 화면의 정지 버튼이 그대로 닿는다. 겹쳐 뜨는 창(잠시 쉬기·위험 신호음·
              // 연결·설정)도 경고 **아래** 자리에 뜬다 — 경고는 어느 화면에서도 가려지지 않는다(2026-10-15).
              child: KioskEstopLayout(
                banner: _showEstop
                    ? KioskEstopBanner(
                        detail: _estopDetail,
                        confirming: _estopConfirming,
                        acking: _estopAcking,
                        message: _estopMessage,
                        onRequest: () => setState(() => _estopConfirming = true),
                        onConfirm: _onEstopConfirm,
                        onCancel: () => setState(() => _estopConfirming = false),
                      )
                    : null,
                child: Stack(
                  children: [
                    // 자동 실행 결과 한 줄(C2)도 위에 줄을 더할 뿐 덮지 않는다. 평소·완료 화면에서만 —
                    // 실행·동작 중 화면의 정지 버튼과 실행 상태는 그대로 둔다.
                    Positioned.fill(
                      // 창(방해 금지·연결·설정)이 떠 있으면 뒤 화면은 화면 읽기에서 뺀다(10/24 QA) — 창만 읽히고 눌린다.
                      // 비상 멈춤 띠는 이 바깥이라 그대로 읽힌다.
                      child: ExcludeSemantics(
                        excluding: _overlayOpen,
                        child: KioskEstopLayout(
                        banner: _topNotices(),
                        // 아래 탭 줄(시안 B 10/24) — 평소·가전 화면에서만. 화면 안 확인 창이 뜨면 숨는다([_tabSuppress]).
                        child: KioskTabSuppressScope(
                          count: _tabSuppress,
                          child: Column(children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: _buildScreen(),
                              ),
                            ),
                            if (_showTabs)
                              ValueListenableBuilder<int>(
                                valueListenable: _tabSuppress,
                                builder: (context, suppressed, _) => suppressed > 0
                                    ? const SizedBox.shrink()
                                    : KioskTabBar(current: _currentTab, onSelect: _onTab),
                              ),
                          ]),
                        ),
                      ),
                      ),
                    ),
                    if (_showDnd)
                      Positioned.fill(
                        child: KioskModalSemantics(
                          label: kDndName,
                          child: DndOverlay(
                            dndUntil: _health.dndUntil,
                            dndScope: _health.dndScope,
                            quietSchedule: _health.quietSchedule,
                            busy: _dndBusy,
                            onSet: _onSetDnd,
                            onClear: _onClearDnd,
                            onDismiss: () => setState(() => _showDnd = false),
                          ),
                        ),
                      ),
                    if (_alert.active && !_alertAcknowledged)
                      Positioned.fill(
                        child: DangerAlertOverlay(
                          onAcknowledge: () => setState(() => _alertAcknowledged = true),
                        ),
                      ),
                    if (_openConnectionId != null && _phase == KioskPhase.idle)
                      Positioned.fill(child: KioskModalSemantics(label: '연결', child: _buildConnectionModal())),
                    if (_showSettings)
                      Positioned.fill(
                        child: KioskModalSemantics(
                        label: '본체 화면 설정',
                        child: KioskSettingsOverlay(
                          currentAppliance: _currentAppliance,
                          appliances: _appliances,
                          api: _api,
                          ttsEnabled: _tts.enabled,
                          onTtsChanged: (enabled) {
                            setState(() => _tts.enabled = enabled);
                            _persistSettings();
                          },
                          largeTextEnabled: _largeText,
                          onLargeTextChanged: (enabled) {
                            setState(() => _largeText = enabled);
                            _persistSettings();
                          },
                          highContrastEnabled: _highContrast,
                          onHighContrastChanged: _setHighContrast,
                          darkModeEnabled: _darkMode,
                          onDarkModeChanged: _setDarkMode,
                          countdownSeconds: _countdownSeconds,
                          onCountdownChanged: (seconds) {
                            setState(() => _countdownSeconds = seconds);
                            _persistSettings();
                          },
                          onDismiss: () => setState(() => _showSettings = false),
                          // 조용한 시간은 보여 주기만 — 방해 금지는 메뉴 한 곳에만 둔다(사용자 결정 10/19).
                          quietSchedule: _health.quietSchedule,
                        ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 평소·결과 화면 위에 줄을 더하는 알림들 — 자동 실행 결과 한 줄(C2)과 처음 화면의 '지난 일'(사용자 결정 10/18).
  /// 지난 일은 처음 화면에서만(결과 화면에는 그 결과가 이미 크게 보인다). 둘 다 없으면 null.
  Widget? _topNotices() {
    final auto = _autoNotice != null && (_phase == KioskPhase.idle || _phase == KioskPhase.done)
        ? KioskAutoRunNotice(
            text: _autoNotice!,
            onClose: () => setState(() => _autoNotice = null),
          )
        : null;
    final past = _pastResult != null && _phase == KioskPhase.idle
        ? KioskPastResultLine(
            result: _pastResult!,
            now: _now,
            onAcknowledge: () {
              // 본체에 '봤다'로 적는다 — 폰 홈 못 한 일 경고·설정 탭 배지에서도 사라진다(2026-10-19).
              final shown = _pastResult;
              setState(() => _pastResult = null);
              _ack(shown?.jobId, 'seen', restore: shown);
            },
          )
        : null;
    if (auto == null || past == null) return auto ?? past;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [auto, past]);
  }

  /// 결과 화면 — 화면과 '지난 일' 판정이 같은 값을 쓴다.
  KioskDoneView _doneView() => KioskDoneView(
        executionMode: _executionMode,
        key: const ValueKey('done'),
        success: _doneSuccess,
        label: _doneLabel,
        autoReturnHeld: _doneHeld,
        autoReturnSeconds: _doneRemaining,
        onHold: _holdDone,
        // 이 실행에서 누름 장치가 누른 버튼(실행 화면이 끝날 때 받은 기록) — 버튼판에 누른 칸을 표시한다(10/18).
        pressed: _lastButtons,
        target: _execApplianceId == null
            ? null
            : _findIn(_appliances, _execApplianceId!),
        reason: _doneReason,
        route: _doneRoute,
        thinqOnly: _execThinqOnly,
        thinqActionText: _execThinqActionText,
        confirmation: _doneConfirmation,
        resultConfirmation: _doneRawConfirmation,
        detail: _doneDetail,
        operationConfirmed: _doneOperationConfirmed,
        operationSource: _doneOperationSource,
        operationDetail: _doneOperationDetail,
        runSteps: _doneRunSteps,
        stopLevel: _doneStopLevel,
        stopAckMs: _doneStopAckMs,
        stopPending: _stopPending && _doneStopLevel == null,
        abortReason: _doneAbortReason,
        // 다시 보낼 요청이 없으면(폰이 시작한 실행·이어받은 실행·놓친 결과, 2026-10-15 B2) '다시 시도'를
        // 그리지 않는다 — 예전에는 보였지만 누르면 처음 화면으로만 갔다.
        // 서버 연결이 끊긴 경우엔 '다시 시도'가 또 실패할 가능성이 높다 —
        // 그때는 수동 조작(사람이 직접 고르기)을 앞세운다.
        // ThinQ 확인 못 함·접수 불명은 다시 보내면 중복 실행이 될 수 있어
        // '다시 시도'를 내걸지 않는다.
        // 모션 걸림·재시작 등(2026-10-14)도 권하지 않는다 — 장치를 먼저 봐야 하고 되풀이하면 또 걸린다.
        onRetry: _retryAction == null ||
                _doneReason == KioskFailureReason.serverLost ||
                (_doneReason?.isUnconfirmed ?? false) ||
                (_doneReason == KioskFailureReason.safetyStop &&
                    motionAbortSentence(_doneAbortReason) != null)
            ? null
            : _onRetryFailed,
        // ThinQ 명령에는 누를 조작판이 없다.
        onManual: _doneRoute == 'thinq' ? null : _onManualFromFailure,
        // 누름 장치가 멈췄는지 모르는 정지 결과에만 그려진다(화면이 가른다). 연습은 실제로 움직인 것이 없다.
        onStopAgain: _executionMode == 'mock' ? null : _onDoneStopAgain,
        stopAgain: _doneStopAgain,
        onDismiss: _toIdle,
        onContinue: _continueApplianceId == null ? null : _continueSameAppliance,
        onPickOther: _continueApplianceId == null ? null : _pickOtherAppliance,
        continueName: _continueApplianceId == null ? null : _nameOf(_continueApplianceId),
        // 사람 확인 흐름(휴리스틱 평가 10/18) — 답하면 키오스크 안에 기억하고 처음 화면으로('지난 일' 줄은 남기지 않는다).
        onChecked: _onDoneChecked,
        // '안 바뀌었어요·안 켜졌어요'라고 답한 뒤의 '한 번 더 하기' — 다시 보낼 요청이 있고, 본체 끊김·누름 장치 걸림이 아닐 때.
        // LG 가전 확인 못 함도 사람이 바뀌지 않았다고 본 뒤에는 연다(같은 설정을 다시 보내는 것 — 이미 그 값이면 서버가 보내지 않는다).
        onRetryAfterCheck: _retryAction == null ||
                _doneReason == KioskFailureReason.serverLost ||
                (_doneReason == KioskFailureReason.safetyStop && motionAbortSentence(_doneAbortReason) != null)
            ? null
            : () {
                // 사람이 '안 …'이라고 답한 뒤의 다시 하기 — 답했으니 옛 결과를 '지난 일'로 남기지 않는다. 답은 본체에 적는다.
                _doneAnswered = true;
                if (_activeJobId != null) _ack(_activeJobId, 'not_moved');
                _onRetryFailed();
              },
      );

  /// 결과 화면 '가전을 보고 알려 주세요'에 사람이 답했다(휴리스틱 평가 10/18). 답은 본체에 적는다(POST /acks, 2026-10-19 —
  /// 예전에는 키오스크 안에만 기억해 폰에는 여전히 못 한 일이었다). 답했으니 처음 화면 '지난 일' 줄은 남기지 않는다.
  void _onDoneChecked(bool worked) {
    // 한 결과에 답은 한 번(코드 검토 10/24) — 두 번 누르면 기록·본체 답이 두 번 적혔다.
    if (_phase != KioskPhase.done || _doneAnswered) return;
    final view = _doneView();
    final name = actionName(_doneLabel);
    _personChecks.add(KioskPersonCheck(
      at: DateTime.now(),
      jobId: _activeJobId,
      label: name.isNotEmpty ? name : (view.target?.displayName ?? ''),
      worked: worked,
    ));
    if (_personChecks.length > kPersonCheckKeep) _personChecks.removeAt(0);
    if (_activeJobId != null) _ack(_activeJobId, worked ? 'moved' : 'not_moved');
    _doneAnswered = true;
    // 직접 고른 가전이면 답한 뒤 그 조작판으로(R7) — 처음 화면을 강제하지 않는다. 본체에 닿지 않아 조작판을 열 수 없으면
    // 종전처럼 처음 화면으로(코드 검토 10/24 — 답한 물음이 결과 화면에 남아 있었다). 연결 창은 그대로 열려 있다.
    if (_continueApplianceId != null && _toManualAfterResult(pickOther: false)) return;
    _toIdle();
  }

  /// 사람이 가전을 보고 답한 기록(키오스크 안, 최근 [kPersonCheckKeep]개).
  final List<KioskPersonCheck> _personChecks = [];

  /// 지금 결과 화면에 사람이 답했다 — 처음 화면으로 갈 때 '지난 일'을 남기지 않는다. 새 결과마다 지운다.
  bool _doneAnswered = false;

  /// 시험용 — 사람 확인 기록(읽기 전용).
  @visibleForTesting
  List<KioskPersonCheck> get personChecks => List.unmodifiable(_personChecks);

  Widget _buildConnectionModal() {
    final id = _openConnectionId;
    // 평소 화면 칩과 같은 목록(본체에 닿지 않으면 지난 목록 대신 '본체와 연결되지 않았어요', 평가 7차 10/18).
    final item = connectionsForDisplay(_connectionItems, connected: _health.ok)
            .where((c) => c.id == id)
            .firstOrNull ??
        ConnectionItem.hubUnreachable;
    return KioskConnectionModal(
      item: item,
      checking: _connectionsChecking,
      onRecheck: _recheckConnections,
      onClose: () => setState(() => _openConnectionId = null),
    );
  }

  /// 처음 화면 — 탭 화면의 메뉴 창([KioskMenuHost])도 이 설정에서 방해 금지·연결·설정 값을 읽는다(같은 창 한 벌).
  KioskIdleView _idleView() => KioskIdleView(
      key: const ValueKey('idle'),
      now: _now,
      connected: _health.ok,
      ambient: _ambient,
      connections: _connectionItems,
      // 서버 목록에서 확인된 가전만 줄에 세운다 — 내장 폴백으로 설치한 적
      // 없는 가전을 세우지 않는다.
      appliances: _appliancesFromServer ? _appliances : null,
      running: _runningIds,
      attention: _attentionIds,
      on: _onIds,
      off: _offIds,
      air: _air,
      nextRun: _nextRun,
      nextRunBusy: _nextRunBusy,
      nextRunNotice: _nextRunNotice,
      onToggleNextRunSkip: _toggleNextRunSkip,
      dndUntil: _health.dndUntil,
      dndScope: _health.dndScope,
      quietUntil: _health.quietScheduleActive ? _health.quietSchedule?.$2 : null,
      temperature: _sensorData?.mocked == false ? _sensorData?.temperature : null,
      humidity: _sensorData?.mocked == false ? _sensorData?.humidity : null,
      onSelectAppliance: _toMyAppliance,
      onOpenConnection: (item) =>
          setState(() => _openConnectionId = item.id),
      onDndGesture: () => setState(() => _showDnd = true),
      onSettingsGesture: () => setState(() => _showSettings = true),
      // 비상 버튼이 눌려 있을 때 상태 칩·못 쓰는 가전 타일을 누르면 위 띠의 풀기 안내를 연다(평가 4차 10/18).
      onEstopGuide: () => setState(() => _estopConfirming = true),
      // '무엇을 할까요?' 카드(시안 B 10/24) — 내 가전 화면 루틴 칸과 같은 길(확인 카드가 승인).
      routines: _routines,
      onRoutine: _onRoutine,
      quietDim: _quietDim,
      onTouch: _noteIdleTouch,
    );

  Widget _buildScreen() {
    switch (_phase) {
      case KioskPhase.idle:
        // '자동 실행'·'기록' 탭(시안 B 10/24) — 읽기만 하는 화면. 조용한 시간으로 어두우면 처음 화면(큰 시계)이 앞선다.
        if (!_quietDim && _homeTab == KioskTab.auto) {
          return Listener(
            key: const ValueKey('auto-run'),
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _noteIdleTouch(),
            // 위 오른쪽 '메뉴'는 처음 화면과 같은 창(QA 10/25).
            child: KioskMenuHost(
              view: _idleView(),
              builder: (openMenu) => KioskAutoRunView(
                runs: _upcomingRuns,
                loading: _upcomingLoading,
                busy: _nextRunBusy,
                notice: _nextRunNotice,
                // 처음 화면 '오늘은 건너뛰기'와 같은 길.
                onToggleSkip: _toggleNextRunSkip,
                onReload: _fetchUpcoming,
                onMenu: openMenu,
              ),
            ),
          );
        }
        if (!_quietDim && _homeTab == KioskTab.history) {
          return Listener(
            key: const ValueKey('history'),
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _noteIdleTouch(),
            child: KioskMenuHost(
              view: _idleView(),
              builder: (openMenu) => KioskHistoryView(
                entries: _historyEntries,
                loading: _historyLoading,
                now: _now,
                applianceNames: {for (final a in _appliances) a.id: a.displayName},
                onReload: _fetchHistory,
                onMenu: openMenu,
              ),
            ),
          );
        }
        return _idleView();
      case KioskPhase.hold:
        final st = _hold!;
        final buttons = st.lastButtons;
        return KioskHoldView(
          key: const ValueKey('hold'),
          appliance: st.holdApplianceId == null
              ? null
              : _findIn(_appliances, st.holdApplianceId!),
          holdState: st.holdState ?? 'hovering_stop',
          stopOutcome: st.holdStopOutcome,
          detail: st.holdDetail,
          stopButton: st.holdStopButton,
          executionMode: st.holdExecutionMode,
          elapsed: _now.difference(_holdSince).isNegative
              ? Duration.zero
              : _now.difference(_holdSince),
          // 누름 보고는 마지막 실행이 이 가전의 성공일 때만 센다.
          buttonsPressed: buttons != null &&
                  st.lastApplianceId == st.holdApplianceId &&
                  st.lastOutcome == 'success'
              ? buttons.where((b) => b.success).length
              : null,
          operationConfirmed: st.lastOperationConfirmed,
          operationSource: st.lastOperationSource,
          stopRequested: _holdStopRequested,
          stopFailed: _holdStopFailed,
          onStop: _onHoldStop,
          // 연습 대기는 나가도 된다(평가 12차 10/18) — 실제 가전이 없다. 실제 대기는 정지가 닿아야 해서 나가는 단추가 없다.
          onClose: _holdNeedsPerson(st)
              ? _toIdle
              : _practiceHoldKey(st) != null
                  ? _leavePracticeHold
                  : null,
          // 비상 멈춤이 걸려 있으면 제목이 위 띠와 같은 말을 한다(돌아가고 있다고 말하지 않는다).
          estopTitle: _estopLatched ? estopTitleFor(_estopDetail) : null,
        );
      case KioskPhase.manual:
        final manualAppliance = _manualAppliance;
        if (manualAppliance == null) {
          return KioskMenuHost(
            key: const ValueKey('appliance-select-host'),
            view: _idleView(),
            builder: (openMenu) => KioskApplianceSelectView(
              key: const ValueKey('appliance-select'),
              appliances: _appliances,
              lastUsedId: _currentAppliance.id,
              onSelect: _onManualApplianceSelected,
              onCancel: _fromManual,
              onMenu: openMenu,
            ),
          );
        }
        return KioskManualView(
          key: const ValueKey('manual'),
          appliance: manualAppliance,
          onExecute: _onManualExecute,
          onCancel: _fromManual,
          initialShowBoard: _manualOpenBoard,
          routines: _routines
              ?.where((r) => r.involves(manualAppliance.id))
              .toList(),
          onRoutine: _onRoutine,
          applianceNames: {for (final a in _appliances) a.id: a.displayName},
          thinqRead: () => _api.thinqStatus(manualAppliance.id),
          thinqSend: (action, args, requestId) =>
              _api.thinqCommand(manualAppliance.id, action, args, clientRequestId: requestId),
          thinqLookup: _api.jobByRequest,
          onThinqAccepted: _onThinqAccepted,
        );
      case KioskPhase.suggestion:
        // 승인 직후 카드를 내린 한 프레임(실행 화면으로 넘어가기 전)에도 무너지지 않게 — 예전에는 그 사이 오류가 나면 화면이
        // 회색으로 멈췄다(10/24 웹 점검).
        final suggestion = _currentSuggestion;
        if (suggestion == null) return ColoredBox(key: const ValueKey('suggestion-closing'), color: KioskColors.bg);
        final targetId = suggestion.applianceId;
        return KioskSuggestionView(
          key: const ValueKey('suggestion'),
          suggestion: suggestion,
          // 제안 **자신의** 대상. 지금 고른 가전(_currentAppliance)으로 메우면
          // 화면과 실제로 눌릴 가전이 어긋난다.
          target: targetId == null ? null : _findIn(_appliances, targetId),
          cdRemaining: _cdRemaining,
          cdTotal: _cdTotal,
          onTouch: _touchSuggestion,
          onExtend: _extendSuggestion,
          scenarioName: _scenarioNames[suggestion.scenarioId],
          blockedWhy: suggestion.isScenario ? _scenarioBlockedWhy : null,
          onApprove: _onApprove,
          onReject: _onReject,
          startedByUser: _ownCardId != null && _ownCardId == suggestion.id,
        );
      case KioskPhase.executing:
        return KioskExecutingView(
          executionMode: _executionMode,
          key: const ValueKey('executing'),
          title: _execTitle,
          target: _execApplianceId == null
              ? null
              : _findIn(_appliances, _execApplianceId!),
          lastButtons: _lastButtons,
          currentButton: _currentButton,
          doneButtons: _execDoneButtons,
          currentAttempt: _currentAttempt,
          completedSteps: _completedSteps,
          totalSteps: _totalSteps,
          verificationConfidence: _verificationConfidence,
          verificationDetail: _verificationDetail,
          onStop: _onStop,
          stopState: _execStop,
          routineSegment: _execRoutineSegment,
          routineWaiting: _execRoutineWaiting,
          thinqOnly: _execThinqOnly,
          thinqActionText: _execThinqActionText,
        );
      case KioskPhase.done:
        return _doneView();
    }
  }
}
