import 'package:routine_rehearsal/routine_rehearsal.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/ambient.dart';
import '../models/appliance.dart';
import '../models/auto_run.dart';
import '../models/command_result.dart';
import '../models/estop.dart';
import '../models/thinq.dart';
import '../models/scenario_run.dart';
import '../services/kiosk_api_service.dart';
import '../services/kiosk_event_stream.dart';
import '../services/kiosk_settings_store.dart';
import '../services/kiosk_tts_service.dart';
import '../theme/kiosk_colors.dart';
import '../widgets/kiosk/appliance_select_view.dart';
import '../widgets/kiosk/auto_run_notice.dart';
import '../widgets/kiosk/danger_alert_overlay.dart';
import '../widgets/kiosk/dnd_overlay.dart';
import '../widgets/kiosk/estop_banner.dart';
import '../widgets/kiosk/done_view.dart';
import '../widgets/kiosk/connection_status.dart';
import '../widgets/kiosk/executing_view.dart';
import '../widgets/kiosk/hold_view.dart';
import '../widgets/kiosk/idle_view.dart';
import '../widgets/kiosk/kiosk_canvas.dart';
import '../widgets/kiosk/kiosk_phase.dart';
import '../widgets/kiosk/kiosk_timings.dart';
import '../widgets/kiosk/manual_view.dart';
import '../widgets/kiosk/suggestion_view.dart';
import '../widgets/kiosk/settings_overlay.dart';
import '../widgets/kiosk/top_progress_bar.dart';

/// 잠시 쉬기 저장이 실패해 이번 세션에만 적용됐을 때(서버 `persisted: false`, 2026-10-14 HIGH 재확인 M-R1) — 폰과 같은 문장.
const kSettingNotSavedNotice = '저장하지 못해 지금만 적용돼요. SimpleLay 본체를 다시 켜면 이전 설정으로 돌아가요.';

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
  AlertState _alert = AlertState.inactive;
  bool _alertAcknowledged = false;

  KioskSuggestion? _currentSuggestion;
  // 무응답은 거절로 보내지 않는다. 현재 서버 목록의 카드별 자동 노출만
  // 한 번으로 제한한다. 재시작 고유 ID를 서버가 발급하므로 새 제안은 보인다.
  final Set<String> _shownSuggestionIds = {};
  bool _dismissingSuggestion = false;
  int _cdRemaining = KioskTimings.countdownSeconds;
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
  DateTime? _lastStatusOk;
  bool _pollInFlight = false;
  // 내 job의 흔적이 안 보인 연속 폴링 수 — 시작 직후 창은 정상, 계속되면
  // (서버 재시작·추월 유실) 실행 화면 고착 대신 실패로 탈출한다.
  int _foreignPolls = 0;

  String? _currentButton;
  int? _currentAttempt;
  int? _completedSteps;
  double? _verificationConfidence;
  String? _verificationDetail;
  int? _totalSteps;
  // 이 실행이 대상으로 삼은 가전 -- 제안 승인은 제안의 대상, 수동은 조작판의
  // 가전, 폰이 시작한 실행은 서버가 말해준 대상.
  String? _execApplianceId;

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

  /// 결과가 먼저 오고 정지 보고가 늦게 올 때의 짧은 후속 조회(평가 2026-10-13 M1). 화면 문구만 고친다.
  Timer? _stopFollowTimer;
  static const _stopFollowInterval = Duration(seconds: 1);
  static const _stopFollowTries = 3;
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
  // 공기청정기 센서 공기질 — GET /thinq/air(서버 기억, 클라우드 호출 없음, 2026-10-16). 모름·오래됨·실패는 null(줄 없음).
  KioskAirReading? _air;

  // ── 동작 중: 정지 버튼 대기·보관(2026-09-30) ─────────────────────────
  KioskStatus? _hold;
  DateTime _holdSince = DateTime.now();
  bool _holdStopRequested = false;
  bool _holdStopFailed = false;
  // 짧게 보여 주고 평소 화면으로 돌아가는 타이머(보관 완료).
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
    _powerTimer = Timer.periodic(_powerInterval, (_) {
      _fetchPower();
      _fetchAir();
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
          title: '작은 팔 장치 상태를 볼 수 없어요',
          message: 'SimpleLay 본체와 연결되면 확인할 수 있어요.'),
      ConnectionItem(
          id: 'plug',
          state: 'unreachable',
          title: '가전 콘센트 장치 상태를 볼 수 없어요',
          message: 'SimpleLay 본체와 연결되면 확인할 수 있어요.'),
    ];
    if (!_connectionsLoaded) {
      return const [
        ConnectionItem(
            id: 'network',
            state: 'unreachable',
            title: '연결을 확인하고 있어요',
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
    if (!st.running && last != null &&
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

  /// 가전 줄의 '켜짐'(2026-10-16) — 서버가 최근 ThinQ 조회로 본 전원만. 평소 화면일 때만 묻는다.
  Future<void> _fetchPower() async {
    if (_phase != KioskPhase.idle) return;
    final on = await _api.thinqPowerOn();
    if (!mounted || _sameSet(on, _onIds)) return;
    setState(() => _onIds = on);
  }

  /// 평소 화면의 '실내 공기' 한 줄(2026-10-16) — 서버가 최근 ThinQ 조회로 본 센서 값만. 평소 화면일 때만 묻는다.
  /// 실패·모름이면 줄을 내린다(묵은 값을 붙들지 않는다 — 서버도 600초 넘은 값은 주지 않는다).
  Future<void> _fetchAir() async {
    if (_phase != KioskPhase.idle) return;
    final air = await _api.thinqAir();
    if (!mounted) return;
    if (air == null && _air == null) return;
    setState(() => _air = air);
  }

  /// ThinQ 가전 상세에서 확인을 거쳐 접수된 조작 — 다른 실행처럼 실행 화면이 job_id로 따라간다.
  /// 다시 시도는 두지 않는다(설정 변경은 상태를 다시 읽고 사람이 다시 고른다).
  void _onThinqAccepted(String jobId, String label) {
    if (!mounted || _phase != KioskPhase.manual) return;
    _toExecuting(label, applianceId: _manualAppliance?.id, jobId: jobId);
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
      _tts.speak('위험 신호음을 감지했어요. 안전한 곳으로 이동한 뒤 주변에 도움을 요청해 주세요.');
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
        await _pollEstopOnly();
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
      if (st.running && st.jobId != null) {
        _toExecuting(st.currentButton ?? _nameOf(st.applianceId),
            applianceId: st.applianceId, jobId: st.jobId);
        return;
      }
      // 버튼을 다 누른 뒤 가전이 돌아가는 중 — 동작 중 화면(정지 버튼 대기).
      // 제안보다 먼저 본다: 안내는 한 번에 하나다.
      if (_holdActive(st.holdState)) {
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
    if (jobId == null) return; // 접수 응답 전에는 다른 작업 상태를 사용하지 않는다.
    try {
      final st = await _api.status();
      if (!mounted || _phase != KioskPhase.executing ||
          _activeJobId != jobId) {
        return;
      }
      _lastStatusOk = DateTime.now();
      _trackStrip(st);
      _trackEstop(st);

      // ① 완료 판정 최우선 — 내 job 완료 직후 다른 클라이언트의 새 job이
      // 시작되면 running=true여도 last_job_id는 내 job이다. running을 먼저
      // 처리하면 그 완료를 영영 놓친다(추월 레이스).
      if (st.lastJobId != null && st.lastJobId == _activeJobId) {
        if (st.lastAutoRun?.jobId == jobId) {
          // 자동 실행(허용 규칙)은 완료 화면 대신 위 한 줄로 실제 결과를 알린다(C2).
          _seenLastJobId = jobId;
          _toIdle();
          _trackAutoRun(st);
          return;
        }
        _completeFromStatus(st, jobId);
        return;
      }

      if (st.running) {
        final mine = _activeJobId == null || st.jobId == _activeJobId;
        if (mine) {
          _foreignPolls = 0;
          setState(() {
            _executionMode = st.executionMode;
            _currentButton = st.currentButton ?? _currentButton;
            _currentAttempt = st.currentAttempt ?? _currentAttempt;
            _completedSteps = st.completedSteps ?? _completedSteps;
            _verificationConfidence =
                st.verificationConfidence ?? _verificationConfidence;
            _verificationDetail =
                st.verificationDetail ?? _verificationDetail;
            _execApplianceId = st.applianceId ?? _execApplianceId;
            // 서버가 단계 수를 줄 때만 진행을 채운다
            final total = st.totalSteps;
            if (total != null && total > 0) {
              _totalSteps = total;
              _execBarValue =
                  ((st.completedSteps ?? 0) / total).clamp(0.0, 0.95);
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
          _toDone(false, '실행 확인 불가',
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
        _toDone(false, '서버 응답 없음',
            reason: KioskFailureReason.serverLost);
      }
    }
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
      if (st.running && st.jobId != null && st.jobId != _activeJobId) {
        _toExecuting(st.currentButton ?? _nameOf(st.applianceId),
            applianceId: st.applianceId, jobId: st.jobId);
        return;
      }
      _catchMissedResult(st);
    } catch (_) {}
  }

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
    if (_health.speakGeneral) _tts.speak('자동 실행, $text'); // 조용한 시간·모름에는 소리 없이 한 줄만
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
    _stopFollowTimer = Timer.periodic(_stopFollowInterval, (timer) async {
      if (inFlight) return;
      if (!mounted || _activeJobId != jobId ||
          (_phase != KioskPhase.executing && _phase != KioskPhase.done) ||
          tries >= _stopFollowTries) {
        timer.cancel();
        return;
      }
      tries++;
      inFlight = true;
      try {
        final st = await _api.status();
        if (!mounted || _activeJobId != jobId || !timer.isActive) return;
        if (st.lastJobId != jobId) {
          timer.cancel(); // 그사이 다른 실행이 끝났다 — 이 job의 단계가 아니다
          return;
        }
        final level = st.stopLevelOf(jobId);
        if (level != null) {
          timer.cancel();
          setState(() {
            _doneStopLevel = level;
            _doneStopAckMs = st.stopAckMsOf(jobId);
          });
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
      if (st.running && st.jobId != null) {
        _holdReturnTimer?.cancel();
        _toExecuting(st.currentButton ?? _nameOf(st.applianceId),
            applianceId: st.applianceId, jobId: st.jobId);
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
            ? '작은 팔 장치에 문제가 생겼어요. 가전 전원을 직접 꺼 주세요.'
            : '작은 팔이 정지 버튼을 대신 눌렀지만 멈췄는지 확인하지 못했어요. 지금 가전의 정지 버튼을 직접 눌러 주세요.');
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

  void _toIdle() {
    _holdReturnTimer?.cancel();
    _holdReturnTimer = null;
    _countdownTimer?.cancel();
    setState(() {
      _phase = KioskPhase.idle;
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
      applianceId == null ? '' : (_findIn(_appliances, applianceId)?.name ?? '');

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
      _currentAppliance = appliance; // 실행 라우팅의 기준
    });
    _persistSettings();
    _fetchRoutines();
  }

  /// 내 가전의 루틴 → 카드(다가오면). 실행은 카드의 "시작"(승인) 뒤에만.
  Future<void> _onRoutine(KioskRoutine routine) async {
    try {
      final result = await _api.triggerRoutine(routine.id);
      if (!mounted || _phase != KioskPhase.manual) return;
      final card = result.suggestion;
      if (card != null) {
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
        content: Text('루틴 카드를 만들지 못했어요. 연결을 확인해 주세요.'),
      ));
    }
  }

  void _onManualApplianceSelected(ApplianceMap appliance) {
    setState(() {
      _manualAppliance = appliance;
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
    _countdownTimer?.cancel();
    setState(() {
      _phase = KioskPhase.manual;
      _manualAppliance =
          _appliances.length == 1 ? _appliances.single : null;
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
      _tts.speak(suggestion.isScenario
          ? '${suggestion.purpose} 화면에서 시작을 눌러 주세요.'
          : '${suggestion.purpose}, 지금 할까요? 화면에서 시작을 눌러 주세요.');
    }
    setState(() {
      _phase = KioskPhase.suggestion;
      _currentSuggestion = suggestion;
      _cdRemaining = _countdownSeconds;
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
            ? '$who — ${r.reasons.first}'
            : '$who — 아직 조작할 준비가 되지 않았어요';
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

  void _toExecuting(String title, {String? applianceId, String? jobId}) {
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
    _stopFollowTimer?.cancel();
    _doneOperationDetail = null;
    _doneRunSteps = const [];
    _activeJobId = jobId;
    _retryAction = null;
    _lastStatusOk = DateTime.now();
    _foreignPolls = 0;
    setState(() {
      _phase = KioskPhase.executing;
      _execTitle = title;
      _execApplianceId = applianceId;
      _lastButtons = null;
      _execBarValue = 0;
      _totalSteps = null;
      _currentButton = null;
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
    final lead = label.isEmpty ? '' : '$label, ';
    _tts.speak(
      // 화면과 같은 말. '완료되었습니다'는 조리·세탁이 끝났다고 들린다 --
      // 이 시스템이 끝낸 것은 버튼 조작이다.
      success
          ? '$lead${finishedMessage(kind: ResultKind.success, executionMode: _executionMode, route: _doneRoute, confirmation: _doneRawConfirmation, detail: _doneDetail, operationVerified: _doneOperationConfirmed == true && _doneOperationSource == 'real' && _executionMode != 'mock')}'
          : switch (reason) {
              KioskFailureReason.serverLost =>
                '실행 상태를 확인할 수 없어요. 가전 상태를 직접 확인해 주세요.',
              // 정지 단계만큼(2026-10-15) — 단계 보고가 늦으면 모르는 단계로 말한다(화면은 뒤에 고쳐진다).
              KioskFailureReason.stopped =>
                finishedMessage(kind: ResultKind.stopped, stopLevel: _doneStopLevel),
              KioskFailureReason.safetyStop =>
                '$lead${finishedMessage(kind: ResultKind.safetyStop, abortReason: _doneAbortReason)}',
              KioskFailureReason.unconfirmed =>
                '$lead${unconfirmedSentence()}',
              KioskFailureReason.receiptUnknown =>
                '$lead${unconfirmedSentence(receipt: 'unknown')}',
              KioskFailureReason.notExecuted =>
                '$lead명령이 실행되지 않았어요. 화면을 확인해 주세요.',
              KioskFailureReason.execution =>
                '$lead가전을 먼저 봐 주세요. 버튼이 눌렸는지 확인하지 못했어요.${_retryAction != null ? ' $kDontRetryIfOn.' : ''}',
            },
    );
    setState(() {
      _phase = KioskPhase.done;
      _doneSuccess = success;
      _doneLabel = label;
      _doneReason = success ? null : reason;
    });
    // 실패는 자동으로 사라지지 않는다 — 사용자가 다음 행동을 고를 때까지
    // 화면에 남아야 한다(고령 사용자가 이유도 모른 채 놓치는 것을 막는다).
    if (!success) return;
    Future.delayed(_doneReturnDuration, () {
      if (mounted && _phase == KioskPhase.done) _toIdle();
    });
  }

  Future<void> _onApprove({KioskSuggestion? suggestion}) async {
    if (_dismissingSuggestion) return;
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
    _toExecuting(label, applianceId: suggestion.applianceId);
    _retryAction = () => _onApprove(suggestion: suggestion);

    try {
      // job 모델: 즉시 접수 — 진행·완료는 _pollExecuting이 job_id 대조로 따라간다
      final accepted = await _api.approveSuggestion(suggestion.id);
      _activeJobId = accepted.jobId;
    } on KioskApiException catch (e) {
      if (!mounted || _phase != KioskPhase.executing) return;
      if (e.isApprovalChanged || e.statusCode == 412) {
        // 승인 재검사 실패: 서버가 카드를 내렸다. 실패 화면('다시 시도')으로
        // 보내면 옛 승인을 또 누르게 된다 — 처음 화면으로 돌아가 새 카드를 받는다.
        // 412(준비 안 됨)는 서버 문장이 이유를 말한다.
        final message = e.isApprovalChanged
            ? kApprovalChangedMessage
            : (e.detail.isNotEmpty ? e.detail : '가전이 아직 조작할 준비가 되지 않았어요.');
        _tts.speak(message);
        _toIdle();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        _poll();
        return;
      }
      _toDone(false, label,
          reason: KioskFailureReason.serverLost);
    } catch (_) {
      // 접수 자체가 실패(서버 다운·409 등) — 올 수 없는 완료를 기다리는 대신
      // 즉시 실패 화면으로 탈출한다.
      if (mounted && _phase == KioskPhase.executing) {
        _toDone(false, label,
            reason: KioskFailureReason.serverLost);
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
    _toExecuting(button.label, applianceId: _currentAppliance.id);
    _retryAction = () => _onManualExecute(button);
    try {
      final accepted = await _api.executeButtons(
        [button.label],
        applianceId: _currentAppliance.id,
      );
      _activeJobId = accepted.jobId;
    } catch (_) {
      // 접수 실패 — 즉시 실패 화면으로 탈출 (고착 방지)
      if (mounted && _phase == KioskPhase.executing) {
        _toDone(false, button.label,
            reason: KioskFailureReason.serverLost);
      }
    }
  }

  Future<void> _onStop() async {
    // 정지 "요청"만 보낸다 — 화면 전환은 폴링이 safety_stopped 완료를 받은 뒤.
    // 하드웨어가 멈추기 전에 '정지됨' 화면부터 띄우면 실제 상태와 어긋난다.
    try {
      await _api.stop();
    } catch (_) {
      // 정지 요청조차 실패 = 통신 문제 — 실행 화면 유지, 30초 탈출 타이머가
      // (_pollExecuting의 _statusLostTimeout) 결국 실패 화면으로 빼낸다.
    }
  }

  Future<void> _onSetDnd(int minutes) async {
    bool? persisted;
    try {
      persisted = await _api.setDnd(minutes);
    } catch (_) {}
    await _checkHealth();
    if (mounted) setState(() => _showDnd = false);
    _notSaved(persisted);
  }

  Future<void> _onClearDnd() async {
    bool? persisted;
    try {
      persisted = await _api.clearDnd();
    } catch (_) {}
    await _checkHealth();
    if (mounted) setState(() => _showDnd = false);
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
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(_largeText ? 1.22 : 1.0),
      ),
      child: KioskCanvas(child: _buildScaffold()),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      floatingActionButton: const bool.fromEnvironment('SIMPLELAY_ROUTINE_MOCK') && _phase == KioskPhase.idle && !_showSettings && !_showDnd && !_alert.active
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RoutineRehearsalScreen(request: _api.routineRequest),
              )),
              label: const Text('다가전 모의'), icon: const Icon(Icons.science_outlined),
            ) : null,
      backgroundColor: KioskColors.bg,
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
                      child: KioskEstopLayout(
                        banner: _autoNotice != null &&
                                (_phase == KioskPhase.idle || _phase == KioskPhase.done)
                            ? KioskAutoRunNotice(
                                text: _autoNotice!,
                                onClose: () => setState(() => _autoNotice = null),
                              )
                            : null,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _buildScreen(),
                        ),
                      ),
                    ),
                    if (_showDnd)
                      Positioned.fill(
                        child: DndOverlay(
                          dndUntil: _health.dndUntil,
                          dndScope: _health.dndScope,
                          quietSchedule: _health.quietSchedule,
                          onSet: _onSetDnd,
                          onClear: _onClearDnd,
                          onDismiss: () => setState(() => _showDnd = false),
                        ),
                      ),
                    if (_alert.active && !_alertAcknowledged)
                      Positioned.fill(
                        child: DangerAlertOverlay(
                          onAcknowledge: () => setState(() => _alertAcknowledged = true),
                        ),
                      ),
                    if (_openConnectionId != null && _phase == KioskPhase.idle)
                      Positioned.fill(child: _buildConnectionModal()),
                    if (_showSettings)
                      Positioned.fill(
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
                          countdownSeconds: _countdownSeconds,
                          onCountdownChanged: (seconds) {
                            setState(() => _countdownSeconds = seconds);
                            _persistSettings();
                          },
                          onDismiss: () => setState(() => _showSettings = false),
                          // 설정을 닫고 평소 화면 위 줄과 같은 방해 금지 선택을 연다.
                          onOpenDnd: () => setState(() {
                            _showSettings = false;
                            _showDnd = true;
                          }),
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

  Widget _buildConnectionModal() {
    final id = _openConnectionId;
    final item = _connectionItems.where((c) => c.id == id).firstOrNull ??
        ConnectionItem.hubUnreachable;
    return KioskConnectionModal(
      item: item,
      checking: _connectionsChecking,
      onRecheck: _recheckConnections,
      onClose: () => setState(() => _openConnectionId = null),
    );
  }

  Widget _buildScreen() {
    switch (_phase) {
      case KioskPhase.idle:
        return KioskIdleView(
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
          air: _air,
          dndUntil: _health.dndUntil,
          quietUntil: _health.quietScheduleActive ? _health.quietSchedule?.$2 : null,
          temperature: _sensorData?.mocked == false ? _sensorData?.temperature : null,
          humidity: _sensorData?.mocked == false ? _sensorData?.humidity : null,
          onSelectAppliance: _toMyAppliance,
          onOpenConnection: (item) =>
              setState(() => _openConnectionId = item.id),
          onDndGesture: () => setState(() => _showDnd = true),
          onSettingsGesture: () => setState(() => _showSettings = true),
        );
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
          onClose: _holdNeedsPerson(st) ? _toIdle : null,
          // 비상 멈춤이 걸려 있으면 제목이 위 띠와 같은 말을 한다(돌아가고 있다고 말하지 않는다).
          estopTitle: _estopLatched ? estopTitleFor(_estopDetail) : null,
        );
      case KioskPhase.manual:
        final manualAppliance = _manualAppliance;
        if (manualAppliance == null) {
          return KioskApplianceSelectView(
            key: const ValueKey('appliance-select'),
            appliances: _appliances,
            lastUsedId: _currentAppliance.id,
            onSelect: _onManualApplianceSelected,
            onCancel: _fromManual,
          );
        }
        return KioskManualView(
          key: const ValueKey('manual'),
          appliance: manualAppliance,
          onExecute: _onManualExecute,
          onCancel: _fromManual,
          routines: _routines
              ?.where((r) => r.involves(manualAppliance.id))
              .toList(),
          onRoutine: _onRoutine,
          thinqRead: () => _api.thinqStatus(manualAppliance.id),
          thinqSend: (action, args) => _api.thinqCommand(manualAppliance.id, action, args),
          onThinqAccepted: _onThinqAccepted,
        );
      case KioskPhase.suggestion:
        final suggestion = _currentSuggestion!;
        final targetId = suggestion.applianceId;
        return KioskSuggestionView(
          key: const ValueKey('suggestion'),
          suggestion: suggestion,
          // 제안 **자신의** 대상. 지금 고른 가전(_currentAppliance)으로 메우면
          // 화면과 실제로 눌릴 가전이 어긋난다.
          target: targetId == null ? null : _findIn(_appliances, targetId),
          cdRemaining: _cdRemaining,
          cdTotal: _countdownSeconds,
          scenarioName: _scenarioNames[suggestion.scenarioId],
          blockedWhy: suggestion.isScenario ? _scenarioBlockedWhy : null,
          onApprove: _onApprove,
          onReject: _onReject,
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
          currentAttempt: _currentAttempt,
          completedSteps: _completedSteps,
          totalSteps: _totalSteps,
          verificationConfidence: _verificationConfidence,
          verificationDetail: _verificationDetail,
          onStop: _onStop,
        );
      case KioskPhase.done:
        return KioskDoneView(
          executionMode: _executionMode,
          key: const ValueKey('done'),
          success: _doneSuccess,
          label: _doneLabel,
          target: _execApplianceId == null
              ? null
              : _findIn(_appliances, _execApplianceId!),
          reason: _doneReason,
          route: _doneRoute,
          confirmation: _doneConfirmation,
          resultConfirmation: _doneRawConfirmation,
          detail: _doneDetail,
          operationConfirmed: _doneOperationConfirmed,
          operationSource: _doneOperationSource,
          operationDetail: _doneOperationDetail,
          runSteps: _doneRunSteps,
          stopLevel: _doneStopLevel,
          stopAckMs: _doneStopAckMs,
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
          onDismiss: _toIdle,
        );
    }
  }
}
