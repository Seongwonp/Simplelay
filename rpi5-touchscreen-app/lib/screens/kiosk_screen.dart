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
const _execBarFillDuration = KioskTimings.execBarFill;
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
  DateTime _now = DateTime.now();
  bool _showDnd = false;
  AlertState _alert = AlertState.inactive;
  bool _alertAcknowledged = false;

  KioskSuggestion? _currentSuggestion;
  int _cdRemaining = KioskTimings.countdownSeconds;
  int _countdownSeconds = KioskTimings.countdownSeconds;
  Timer? _countdownTimer;

  String _execTitle = '';
  double _execBarValue = 0;
  Timer? _execFillTimer;
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
    _execFillTimer?.cancel();
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
      _tts.speak('위험 신호음이 감지되었습니다. 안전한 곳으로 이동한 뒤 주변에 도움을 요청해 주세요.');
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
      if (st.running && st.jobId != null) {
        _activeJobId = st.jobId;
        _toExecuting(st.currentButton ?? '실행');
        return;
      }
    } catch (_) {}
    try {
      final list = await _api.suggestions();
      if (list.isNotEmpty && _phase == KioskPhase.idle) {
        _toSuggestion(list.first);
      }
    } catch (_) {}
  }

  Future<void> _pollExecuting() async {
    try {
      final st = await _api.status();
      _lastStatusOk = DateTime.now();
      if (!mounted) return;

      // ① 완료 판정 최우선 — 내 job 완료 직후 다른 클라이언트의 새 job이
      // 시작되면 running=true여도 last_job_id는 내 job이다. running을 먼저
      // 처리하면 그 완료를 영영 놓친다(추월 레이스).
      if (st.lastJobId != null && st.lastJobId == _activeJobId) {
        _finishExecuting(
          success: st.lastStatus == 'succeeded',
          buttons: st.lastButtons ?? const [],
        );
        return;
      }

      if (st.running) {
        final mine = _activeJobId == null || st.jobId == _activeJobId;
        if (mine) {
          _foreignPolls = 0;
          setState(() {
            _currentButton = st.currentButton ?? _currentButton;
            _currentAttempt = st.currentAttempt ?? _currentAttempt;
            _completedSteps = st.completedSteps ?? _completedSteps;
            _verificationConfidence =
                st.verificationConfidence ?? _verificationConfidence;
            _verificationDetail =
                st.verificationDetail ?? _verificationDetail;
            // 실제 진행 데이터가 있으면 9초짜리 가짜 채움 대신 진짜 진행률로
            final total = st.totalSteps;
            if (total != null && total > 0) {
              _execFillTimer?.cancel();
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
          _execFillTimer?.cancel();
          _toDone(false, '실행 확인 불가',
              reason: KioskFailureReason.serverLost);
        }
      }
    } catch (_) {
      // 연속 실패가 길어지면 서버 유실로 판정하고 실행 화면에서 탈출
      final since = _lastStatusOk;
      if (since != null &&
          DateTime.now().difference(since) > _statusLostTimeout) {
        _execFillTimer?.cancel();
        _toDone(false, '서버 응답 없음',
            reason: KioskFailureReason.serverLost);
      }
    }
  }

  void _toIdle() {
    _countdownTimer?.cancel();
    _execFillTimer?.cancel();
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
    if (!mounted || list.isEmpty) return;
    setState(() {
      _appliances = list;
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
    _execFillTimer?.cancel();
    setState(() {
      _phase = KioskPhase.manual;
      _manualAppliance =
          _appliances.length == 1 ? _appliances.single : null;
      _currentSuggestion = null;
      _showDnd = false;
    });
  }

  void _toSuggestion(KioskSuggestion suggestion) {
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

  void _toExecuting(String title) {
    _lastStatusOk = DateTime.now();
    _foreignPolls = 0;
    setState(() {
      _phase = KioskPhase.executing;
      _execTitle = title;
      _lastButtons = null;
      _execBarValue = 0;
      _currentButton = null;
      _currentAttempt = null;
      _completedSteps = null;
      _verificationConfidence = null;
      _verificationDetail = null;
    });
    _startExecFakeFill();
  }

  void _startExecFakeFill() {
    const stepMs = 150;
    var elapsedMs = 0;
    _execFillTimer?.cancel();
    _execFillTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      elapsedMs += stepMs;
      final frac =
          (elapsedMs / _execBarFillDuration.inMilliseconds).clamp(0.0, 1.0) *
          0.85;
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _execBarValue = frac);
      if (elapsedMs >= _execBarFillDuration.inMilliseconds) timer.cancel();
    });
  }

  void _finishExecuting({
    required bool success,
    required List<KioskButtonResult> buttons,
  }) {
    // 지연 도착한 approve/execute 응답이 이미 끝난(정지·완료된) 실행을
    // 되살려 idle 화면을 완료 화면으로 점프시키는 것을 막는다 —
    // _toDone과 동일한 phase 가드.
    if (_phase != KioskPhase.executing) return;
    _execFillTimer?.cancel();
    setState(() {
      _lastButtons = buttons;
      _execBarValue = 1.0;
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) _toDone(success, _execTitle);
    });
  }

  void _toDone(
    bool success,
    String label, {
    KioskFailureReason reason = KioskFailureReason.execution,
  }) {
    // 실행 결과 음성 안내. '서버 응답 없음'은 라벨이 아니라 오류 상황이라
    // 문장을 따로 쓴다 ("서버 응답 없음 실패했습니다"는 어색).
    _tts.speak(
      success
          ? '$label 완료되었습니다.'
          : label == '서버 응답 없음'
              ? '서버 응답이 없습니다. 연결을 확인해 주세요.'
              : '$label 실패했습니다. 화면을 확인해 주세요.',
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
    suggestion ??= _currentSuggestion;
    if (suggestion == null) return;
    _countdownTimer?.cancel();
    setState(() => _currentSuggestion = null);
    _toExecuting(suggestion.purpose);
    _retryAction = () => _onApprove(suggestion: suggestion);

    try {
      // job 모델: 즉시 접수 — 진행·완료는 _pollExecuting이 job_id 대조로 따라간다
      final accepted = await _api.approveSuggestion(suggestion.id);
      _activeJobId = accepted.jobId;
    } catch (_) {
      // 접수 자체가 실패(서버 다운·409 등) — 올 수 없는 완료를 기다리는 대신
      // 즉시 실패 화면으로 탈출한다.
      _execFillTimer?.cancel();
      if (mounted && _phase == KioskPhase.executing) {
        _toDone(false, suggestion.purpose,
            reason: KioskFailureReason.serverLost);
      }
    }
  }

  Future<void> _onReject() => _dismissSuggestion(mute: false);

  // "다시 추천 안 함" -- 이 루틴을 서버 억제 목록에 넣어 패턴이 다시
  // 띄우지 않게 한다(단순 dismiss와 다름).
  Future<void> _onRejectMute() => _dismissSuggestion(mute: true);

  Future<void> _dismissSuggestion({required bool mute}) async {
    final suggestion = _currentSuggestion;
    _countdownTimer?.cancel();
    _toIdle();
    if (suggestion != null) {
      try {
        await _api.rejectSuggestion(suggestion.id, mute: mute);
      } catch (_) {}
    }
  }

  Future<void> _onManualExecute(ApplianceButton button) async {
    _toExecuting(button.label);
    _retryAction = () => _onManualExecute(button);
    try {
      final accepted = await _api.executeButtons(
        [button.label],
        applianceId: _currentAppliance.id,
      );
      _activeJobId = accepted.jobId;
    } catch (_) {
      // 접수 실패 — 즉시 실패 화면으로 탈출 (고착 방지)
      _execFillTimer?.cancel();
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
          dndUntil: _health.dndUntil,
          temperature: _sensorData?.temperature,
          humidity: _sensorData?.humidity,
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
        return KioskSuggestionView(
          key: const ValueKey('suggestion'),
          suggestion: suggestion,
          cdRemaining: _cdRemaining,
          cdTotal: _countdownSeconds,
          onApprove: _onApprove,
          onReject: _onReject,
          onRejectMute: _onRejectMute,
        );
      case KioskPhase.executing:
        return KioskExecutingView(
          key: const ValueKey('executing'),
          title: _execTitle,
          lastButtons: _lastButtons,
          currentButton: _currentButton,
          currentAttempt: _currentAttempt,
          completedSteps: _completedSteps,
          verificationConfidence: _verificationConfidence,
          verificationDetail: _verificationDetail,
          onStop: _onStop,
        );
      case KioskPhase.done:
        return KioskDoneView(
          key: const ValueKey('done'),
          success: _doneSuccess,
          label: _doneLabel,
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
