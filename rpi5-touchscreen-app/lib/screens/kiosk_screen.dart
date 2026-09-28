import 'package:routine_rehearsal/routine_rehearsal.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../services/kiosk_api_service.dart';
import '../services/kiosk_event_stream.dart';
import '../services/kiosk_settings_store.dart';
import '../services/kiosk_tts_service.dart';
import '../theme/kiosk_colors.dart';
import '../widgets/kiosk/appliance_select_view.dart';
import '../widgets/kiosk/danger_alert_overlay.dart';
import '../widgets/kiosk/dnd_overlay.dart';
import '../widgets/kiosk/done_view.dart';
import '../widgets/kiosk/executing_view.dart';
import '../widgets/kiosk/idle_view.dart';
import '../widgets/kiosk/kiosk_canvas.dart';
import '../widgets/kiosk/kiosk_phase.dart';
import '../widgets/kiosk/kiosk_timings.dart';
import '../widgets/kiosk/manual_view.dart';
import '../widgets/kiosk/suggestion_view.dart';
import '../widgets/kiosk/settings_overlay.dart';
import '../widgets/kiosk/top_progress_bar.dart';

const _pollInterval = Duration(milliseconds: 2000);
const _healthInterval = Duration(seconds: 10);
const _sensorInterval = Duration(seconds: 60);
const _alertInterval = Duration(seconds: 3);
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
  // 실패 화면의 '다시 시도'가 무엇을 다시 할지 — 실행을 시작한 쪽이 심는다.
  Future<void> Function()? _retryAction;

  Timer? _pollTimer;
  Timer? _healthTimer;
  Timer? _clockTimer;
  Timer? _sensorTimer;
  Timer? _alertTimer;

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
    _fetchAlert();
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    _healthTimer = Timer.periodic(_healthInterval, (_) => _checkHealth());
    _sensorTimer = Timer.periodic(_sensorInterval, (_) {
      _fetchSensors();
      _fetchAppliances(); // 가전 목록도 같은 주기로 — 폰 등록이 1분 안에 반영
    });
    _alertTimer = Timer.periodic(_alertInterval, (_) => _fetchAlert());
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
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    _healthTimer?.cancel();
    _clockTimer?.cancel();
    _sensorTimer?.cancel();
    _alertTimer?.cancel();
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
      if (st.running && st.jobId != null) {
        _toExecuting(st.currentButton ?? '실행',
            applianceId: st.applianceId, jobId: st.jobId);
        return;
      }
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

  Future<void> _pollSuggestion() async {
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

      // ① 완료 판정 최우선 — 내 job 완료 직후 다른 클라이언트의 새 job이
      // 시작되면 running=true여도 last_job_id는 내 job이다. running을 먼저
      // 처리하면 그 완료를 영영 놓친다(추월 레이스).
      if (st.lastJobId != null && st.lastJobId == _activeJobId) {
        _executionMode = st.lastExecutionMode;
        _finishExecuting(
          success: st.lastStatus == 'succeeded',
          buttons: st.lastButtons ?? const [],
          reason: st.lastStatus == 'safety_stopped'
              ? KioskFailureReason.stopped : KioskFailureReason.execution,
        );
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

  void _toIdle() {
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
          _manualAppliance = null; // 선택 화면으로 — 삭제 안내는 목록 부재로 자명
        }
      }
    });
  }

  void _toManual() {
    if (_phase != KioskPhase.idle) return;
    // 서버에 연결돼 있지 않으면 조작 화면으로 보내지 않는다. 대기 화면이 이미
    // "기기 연결이 필요해요"라고 말하는데, 눌렀더니 전자레인지 버튼판이 뜨면
    // "연결도 안 됐는데 왜 조작이 되지?"라는 모순이 된다 -- 실제로 연결 없이는
    // 버튼도 못 누른다. 대기 화면의 안내가 그대로 이유가 된다.
    if (!_health.ok) return;
    setState(() {
      _phase = KioskPhase.manual;
      // 가전이 하나뿐이면 물을 것 없이 바로 조작판. 여럿이면 선택부터 —
      // 키오스크는 공간의 가전들을 다루는 허브라 "어느 가전인지"는
      // 조작하려는 순간에 묻는 것이 자연스럽다(설정 속 칩이던 시절엔
      // 고령 사용자가 가전을 바꿀 방법을 사실상 찾을 수 없었다).
      _manualAppliance =
          _appliances.length == 1 ? _appliances.single : null;
    });
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

  /// 실패 화면의 '버튼으로 조작' — 자동 실행을 포기하고 사람이 직접 누르는
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
    _tts.speak('${suggestion.purpose}, 지금 할까요? 화면에서 지금 실행을 눌러 주세요.');
    setState(() {
      _phase = KioskPhase.suggestion;
      _currentSuggestion = suggestion;
      _cdRemaining = _countdownSeconds;
    });
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

  void _toExecuting(String title, {String? applianceId, String? jobId}) {
    _executionMode = 'unknown';
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
    _tts.speak(
      // 화면과 같은 말. '완료되었습니다'는 조리·세탁이 끝났다고 들린다 --
      // 이 시스템이 끝낸 것은 버튼 조작이다.
      success
          ? (_executionMode == 'mock' ? '$label, 모의 버튼 조작을 마쳤어요. 실제 조작은 하지 않았어요.'
              : _executionMode == 'real' ? '$label, 버튼 조작을 마쳤어요.'
              : '$label, 실행기가 완료를 보고했어요. 실제 조작 여부는 확인하지 못했어요.')
          : reason == KioskFailureReason.serverLost
              ? '실행 상태를 확인할 수 없어요. 가전 상태를 직접 확인해 주세요.'
              : reason == KioskFailureReason.stopped
                  ? '실행을 멈췄어요. 장치가 완전히 멈췄는지 확인해 주세요.'
                  : '$label, 실행하지 못했어요. 화면을 확인해 주세요.',
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
    if (targetId == null || _findIn(_appliances, targetId) == null) return;
    _countdownTimer?.cancel();
    setState(() => _currentSuggestion = null);
    _toExecuting(suggestion.purpose, applianceId: suggestion.applianceId);
    _retryAction = () => _onApprove(suggestion: suggestion);

    try {
      // job 모델: 즉시 접수 — 진행·완료는 _pollExecuting이 job_id 대조로 따라간다
      final accepted = await _api.approveSuggestion(suggestion.id);
      _activeJobId = accepted.jobId;
    } catch (_) {
      // 접수 자체가 실패(서버 다운·409 등) — 올 수 없는 완료를 기다리는 대신
      // 즉시 실패 화면으로 탈출한다.
      if (mounted && _phase == KioskPhase.executing) {
        _toDone(false, suggestion.purpose,
            reason: KioskFailureReason.serverLost);
      }
    }
  }

  Future<void> _onReject() => _dismissSuggestion(mute: false);

  Future<void> _onRevise() async {
    final old = _currentSuggestion;
    if (old == null || _dismissingSuggestion) return;
    _dismissingSuggestion = true;
    try {
      final options = await _api.revisionOptions(old.id);
      if (!mounted || _phase != KioskPhase.suggestion || _currentSuggestion?.id != old.id) return;
      if (options.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('바꿀 수 있는 등록 동작이 없어요.')));
        return;
      }
      final purpose = await showDialog<String>(context: context, builder: (dialogContext) => SimpleDialog(
        title: const Text('이번 동작 바꾸기 · 아직 실행하지 않아요'),
        children: options.entries.map((e) => SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, e.key),
          child: Text('${e.key}\n${e.value.join(' → ')}'),
        )).toList(),
      ));
      if (purpose == null || !mounted || _phase != KioskPhase.suggestion || _currentSuggestion?.id != old.id) return;
      final revised = await _api.reviseSuggestion(old.id, purpose);
      if (mounted && _phase == KioskPhase.suggestion && _currentSuggestion?.id == old.id) {
        _toSuggestion(revised);
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('동작을 바꾸지 못했어요. 최신 제안을 확인해 주세요.')));
    } finally {
      _dismissingSuggestion = false;
    }
  }

  // "다시 추천 안 함" -- 이 루틴을 서버 억제 목록에 넣어 패턴이 다시
  // 띄우지 않게 한다(단순 dismiss와 다름).
  Future<void> _onRejectMute() => _dismissSuggestion(mute: true);

  Future<void> _dismissSuggestion({required bool mute, bool snooze = false}) async {
    final suggestion = _currentSuggestion;
    if (suggestion == null || _dismissingSuggestion) return;
    _dismissingSuggestion = true;
    _countdownTimer?.cancel();
    try {
      if (snooze) {
        await _api.snoozeSuggestion(suggestion.id);
      } else {
        await _api.rejectSuggestion(suggestion.id, mute: mute);
      }
      if (mounted && _phase == KioskPhase.suggestion &&
          _currentSuggestion?.id == suggestion.id) {
        _toIdle();
        if (snooze) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('30분간 이 제안을 쉬어요. 자동 실행하지 않아요.'),
          ));
        }
      }
    } catch (_) {
      if (mounted && _phase == KioskPhase.suggestion &&
          _currentSuggestion?.id == suggestion.id) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('넘기기를 전달하지 못했어요. 연결을 확인하고 다시 눌러주세요.'),
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
    try {
      await _api.setDnd(minutes);
    } catch (_) {}
    await _checkHealth();
    if (mounted) setState(() => _showDnd = false);
  }

  Future<void> _onClearDnd() async {
    try {
      await _api.clearDnd();
    } catch (_) {}
    await _checkHealth();
    if (mounted) setState(() => _showDnd = false);
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
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScreen() {
    switch (_phase) {
      case KioskPhase.idle:
        return KioskIdleView(
          key: const ValueKey('idle'),
          now: _now,
          connected: _health.ok,
          actuatorReady: _health.actuatorReady,
          // 서버 목록에서 확인된 가전일 때만 이름을 말한다.
          appliance: _appliancesFromServer
              ? _findIn(_appliances, _currentAppliance.id)
              : null,
          dndUntil: _health.dndUntil,
          temperature: _sensorData?.mocked == false ? _sensorData?.temperature : null,
          humidity: _sensorData?.mocked == false ? _sensorData?.humidity : null,
          onTap: _toManual,
          onLongPress: () => setState(() => _showDnd = true),
          onSettingsGesture: () => setState(() => _showSettings = true),
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
          onApprove: _onApprove,
          onReject: _onReject,
          onRejectMute: _onRejectMute,
          onSnooze: () => _dismissSuggestion(mute: false, snooze: true),
          onRevise: _onRevise,
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
          // 서버 연결이 끊긴 경우엔 '다시 시도'가 또 실패할 가능성이 높다 —
          // 그때는 수동 조작(사람이 직접 누르기)을 앞세운다.
          onRetry: _doneReason == KioskFailureReason.serverLost
              ? null
              : _onRetryFailed,
          onManual: _onManualFromFailure,
          onDismiss: _toIdle,
        );
    }
  }
}
