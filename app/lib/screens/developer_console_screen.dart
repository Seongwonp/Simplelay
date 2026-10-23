import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appliance.dart';
import '../models/command_result.dart'
    show stopLevelConfirmed, stopLevelSentence;
import '../providers/appliance_provider.dart';
import '../providers/dev_api_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/dev_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 개발자 도구 (Phase 2, 2026-10-10 실물 경로) — 기본 모의, 서버가 켜면 실제 장치.
///
/// 설치·보정 준비에 필요한 것만 둔다: 대상 가전, 이동 패드, 서버 상태,
/// 정지, 기록. 방향 버튼은 한 번 누를 때 한 번만 이동하며 서버의 허용 목록을 따른다.
///
/// 지키는 것:
/// - 화면 맨 위에 '모의' 또는 '실제 장치' 표시가 늘 보인다. 근거는 서버 응답
///   (`mock`·`motion_target`)뿐이다. 서버가 모의가 아닌데 실제 장치라고 명시하지
///   않으면(옛 서버) 조작을 전부 잠근다.
/// - 실제 장치는 한 번 누를 때 한 번만 움직인다(누르고 있어도 반복하지 않는다).
///   Z는 솔레노이드라 조그가 없고 누르기로만 움직인다.
/// - 세션이 열려 있는 동안 heartbeat를 보내고, 화면을 떠나거나 앱이
///   백그라운드로 가면 세션을 끝낸다(서버도 heartbeat가 끊기면 스스로 멈춘다).
/// - 정지를 확인하지 못한 결과를 완료처럼 표시하지 않는다.
class DeveloperConsoleScreen extends ConsumerStatefulWidget {
  const DeveloperConsoleScreen({super.key});

  @override
  ConsumerState<DeveloperConsoleScreen> createState() =>
      _DeveloperConsoleScreenState();
}

class _DeveloperConsoleScreenState extends ConsumerState<DeveloperConsoleScreen>
    with WidgetsBindingObserver {
  // 폰 콘솔이 세션을 열 때 밝히는 노드 이름. 노드-가전 대응 검증은 실물
  // 노드 프로토콜이 정해지는 하드웨어 주차의 몫이다.
  static const _nodeId = 'phone-console';

  final _tokenController = TextEditingController();

  DevApiService? _api;
  DevState? _state;

  /// 방향 패드 한 번의 이동량(mm). 서버 상한(max_jog_mm)을 넘는 값은 고를 수 없다.
  double _jogStep = 1;
  String? _sessionId;
  String? _secret;
  String? _sessionApplianceId;
  String? _targetId;
  String? _pressButtonId;
  String? _message;
  bool _messageIsProblem = false;
  bool _busy = false;

  /// 마지막 정지 응답의 확인 단계(2026-10-13). 정리(stopping) 뒤 '멈춤'을 말할 때 쓴다.
  String? _lastStopLevel;
  int? _lastStopAckMs;

  /// 정리가 끝나 유휴가 된 뒤의 문장 — 실물이면 마지막 정지 단계까지만 말한다.
  String _settledSentence(DevState state) {
    final sentence =
        stopLevelSentence(_lastStopLevel, ackMs: _lastStopAckMs, detail: true);
    if (sentence != null) return sentence;
    // 모의는 종전 문장, 실물인데 단계를 모르면 '보냄'까지만.
    return state.isReal ? stopLevelSentence('sent')! : '정지를 확인했어요';
  }

  Timer? _heartbeat;
  bool _beatInFlight = false;
  int _epoch = 0;
  int _stateRead = 0;
  bool _visible = true;
  Timer? _settlePoll;
  int _settleAttempts = 0;
  int _requestSeq = 0;
  List<DevLogLine> _log = const [];

  bool get _hasSession => _sessionId != null && _secret != null;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _visible = lifecycle != AppLifecycleState.hidden &&
        lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.detached;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshState());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 화면을 떠나면 세션을 끝낸다. 기다릴 수 없으니 보내기만 한다 --
    // 전달이 실패해도 서버는 heartbeat가 끊겨 스스로 멈춘다.
    final api = _api;
    final id = _sessionId;
    final secret = _secret;
    _invalidate();
    if (api != null && id != null && secret != null) {
      unawaited(api.end(id, secret).then<void>((_) {}, onError: (_) {}));
    }
    _tokenController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_visible) break;
        _visible = false;
        if (_hasSession) {
          _endSession(backgrounded: true);
        } else {
          _invalidate(); // 시작 응답을 기다리는 중에도 무효화한다.
        }
      case AppLifecycleState.resumed:
        _visible = true;
        _refreshState();
      case AppLifecycleState.inactive:
        // 알림창을 내리는 정도로는 세션을 끊지 않는다. 진짜로 화면에서
        // 사라지면(hidden) 그때 끝낸다.
        break;
    }
  }

  // ── 동작 ───────────────────────────────────────────────────────────────

  // 서버의 세션 ID와 별개인 UI 세대. 정지/이탈/연결 변경 뒤 도착한
  // 성공·실패·finally 모두 현재 화면을 변경하지 못한다.
  void _invalidate() {
    _epoch++;
    _stateRead++;
    _heartbeat?.cancel();
    _settlePoll?.cancel();
    _settleAttempts = 0;
    _beatInFlight = false;
    _busy = false;
    _sessionId = null;
    _secret = null;
    _sessionApplianceId = null;
    _state = null;
  }

  bool _current(int epoch, DevApiService api) =>
      mounted && epoch == _epoch && identical(api, _api);

  void _retire(DevApiService api, String id, String secret) {
    // 반드시 세션을 만든 서버로 보낸다. 전역 stop으로 새 세션을 건드리지 않는다.
    unawaited(api.end(id, secret).then<void>((_) {}, onError: (_) {}));
  }

  void _say(String message, {bool problem = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsProblem = problem;
    });
  }

  Future<void> _refreshState({bool settling = false}) async {
    final api = _api;
    if (!mounted || api == null || !_visible || _busy) return;
    final epoch = _epoch;
    final read = ++_stateRead;
    try {
      final state = await api.state();
      if (!_current(epoch, api) || read != _stateRead) return;
      setState(() => _state = state);
      if (state.phase == 'stopping') {
        _say('정지 요청을 확인했어요. 남은 동작을 정리하고 있어요.');
        _scheduleSettlePoll();
      } else if (settling) {
        _settlePoll?.cancel();
        _say(
            state.phase == 'idle'
                ? _settledSentence(state)
                : state.phase == 'fault'
                    ? '정지를 확인하지 못해 새 조작을 막았어요. 다시 정지를 눌러 주세요.'
                    : '서버 상태가 바뀌었어요. 현재 상태를 확인해 주세요.',
            problem: state.phase != 'idle');
      }
    } on DevApiException catch (e) {
      if (!_current(epoch, api) || read != _stateRead) return;
      setState(() => _state = null);
      _say(_describe(e), problem: true);
      if (settling) _scheduleSettlePoll();
    }
  }

  void _scheduleSettlePoll() {
    _settlePoll?.cancel();
    if (!_visible) return;
    if (_settleAttempts++ >= 20) {
      _say('정리 완료를 아직 확인하지 못했어요. 상태 새로고침 또는 정지를 눌러 주세요.', problem: true);
      return;
    }
    final epoch = _epoch;
    _settlePoll = Timer(const Duration(milliseconds: 500), () {
      if (mounted && epoch == _epoch && _visible) {
        _refreshState(settling: true);
      }
    });
  }

  Future<void> _start() async {
    final api = _api;
    final target = _targetId;
    if (api == null || target == null || _hasSession || _busy || !_visible) {
      return;
    }
    _invalidate();
    final epoch = _epoch;
    setState(() => _busy = true);
    try {
      final started = await api.start(target, nodeId: _nodeId);
      if (!_current(epoch, api) || !_visible) {
        _retire(api, started.sessionId, started.sessionSecret);
        return;
      }
      if (!(started.state.mock || started.state.isReal) ||
          !started.state.heartbeatTtlS.isFinite ||
          started.state.heartbeatTtlS <= 0 ||
          started.state.phase != 'active' ||
          started.state.session?.sessionId != started.sessionId) {
        _retire(api, started.sessionId, started.sessionSecret);
        setState(() => _state = started.state);
        _say('세션 시작 상태를 확인하지 못했어요. 상태를 다시 확인해 주세요.', problem: true);
        return;
      }
      setState(() {
        _sessionId = started.sessionId;
        _secret = started.sessionSecret;
        _sessionApplianceId = target;
        _state = started.state;
      });
      _startHeartbeat(started.state.heartbeatTtlS);
      _say(started.state.isReal
          ? '세션을 열었어요 — 실제 장치가 움직여요. 정지 버튼에 손을 두세요.'
          : '세션을 열었어요 — 모의 제어라 실제로 움직이지 않아요');
    } on DevApiException catch (e) {
      if (!_current(epoch, api)) return;
      _say(_describe(e), problem: true);
    } finally {
      if (_current(epoch, api)) setState(() => _busy = false);
    }
  }

  void _startHeartbeat(double ttlS) {
    _heartbeat?.cancel();
    // 지연 시 유지 요청을 쌓지 않는다. 한 번의 확인 실패부터 조작을 닫고 종료한다.
    final ms = (ttlS * 1000 / 3).round().clamp(1, 1000);
    _heartbeat = Timer.periodic(Duration(milliseconds: ms), (_) => _beat());
  }

  Future<void> _beat() async {
    final api = _api;
    final id = _sessionId;
    final secret = _secret;
    if (api == null ||
        id == null ||
        secret == null ||
        _beatInFlight ||
        !_visible) {
      return;
    }
    final epoch = _epoch;
    final read = _stateRead;
    _beatInFlight = true;
    try {
      final state =
          await api.heartbeat(id, secret, ttlS: _state?.heartbeatTtlS ?? 2);
      if (!_current(epoch, api) || _sessionId != id) return;
      if (state.phase != 'active' ||
          !(state.mock || state.isReal) ||
          state.session?.sessionId != id) {
        unawaited(_endSession());
        return;
      }
      if (!_busy && read == _stateRead) setState(() => _state = state);
    } on DevApiException catch (e) {
      if (!_current(epoch, api) || _sessionId != id) return;
      if (e.code == 'session_expired') {
        _invalidate();
        _say('세션이 끝났어요 — 정지 상태를 다시 확인해 주세요', problem: true);
        unawaited(_refreshState());
        return;
      }
      // 실패 뒤에는 heartbeat를 재개하지 않는다. 서버 watchdog과 별개로
      // 세션 종료도 시도하며, 응답이 없다는 이유로 정지를 확정하지 않는다.
      unawaited(_endSession());
      _say('연결 유지를 확인하지 못했어요 — 조작을 막고 세션을 끝내고 있어요', problem: true);
    } finally {
      if (_current(epoch, api)) _beatInFlight = false;
    }
  }

  Future<void> _command(String text) async {
    final api = _api;
    final id = _sessionId;
    final secret = _secret;
    final appliance = _sessionApplianceId;
    if (api == null ||
        id == null ||
        secret == null ||
        appliance == null ||
        _busy) {
      return;
    }
    final epoch = _epoch;
    _stateRead++;
    setState(() => _busy = true);
    // 재전송이 두 번 실행되지 않게 요청마다 id를 붙인다(서버가 중복을 거절).
    final requestId =
        'p${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_requestSeq++}';
    final real = _state?.isReal ?? false;
    try {
      final result = await api.command(
        id,
        secret,
        applianceId: appliance,
        text: text,
        requestId: requestId,
        // 실제 장치는 동작이 끝나야 답한다.
        timeout: real ? const Duration(seconds: 30) : null,
      );
      if (!_current(epoch, api) || _sessionId != id) return;
      _stateRead++;
      setState(() => _state = result.state);
      final sensor = result.sensor;
      final where = result.state.isReal ? '실제 장치' : '모의';
      final partialJog = result.state.isReal && sensor?['reached'] == 0;
      final position = sensor == null
          ? ''
          : sensor.entries
              .where((e) => e.key != 'reached')
              .map((e) => '${e.key} ${e.value.toStringAsFixed(1)}')
              .join(' · ');
      _say(
        partialJog
            ? '목표까지 가지 못하고 멈췄어요. 현재 위치: $position'
            : sensor == null
                ? (result.state.isReal
                    ? "'${result.normalized ?? text}' 동작을 실제 장치가 마쳤어요"
                    : "'${result.normalized ?? text}' 명령을 모의 어댑터가 받았어요")
                : '${result.state.isReal ? '위치' : '센서'}($where): $position',
      );
    } on DevApiException catch (e) {
      if (!_current(epoch, api) || _sessionId != id) return;
      if (e.code == 'session_expired') {
        _invalidate();
      }
      _say(_describe(e), problem: true);
      setState(() {
        _busy = false;
        _state = null;
      });
      unawaited(_refreshState());
    } finally {
      if (_current(epoch, api)) setState(() => _busy = false);
    }
  }

  /// 정지는 세션·진행 중 요청과 무관하게 언제나 보낸다.
  Future<void> _stop() async {
    final api = _api;
    if (api == null) return;
    _invalidate();
    final epoch = _epoch;
    setState(() => _busy = true);
    try {
      final result = await api.stop();
      if (!_current(epoch, api)) return;
      _showStopResult(result);
    } on DevApiException catch (e) {
      if (!_current(epoch, api)) return;
      _say(
        e.isNetwork
            ? '정지 응답을 확인하지 못했어요 — 정지되지 않았을 수 있습니다. 다시 정지를 눌러 주세요.'
            : _describe(e),
        problem: true,
      );
    } finally {
      if (_current(epoch, api)) setState(() => _busy = false);
    }
  }

  void _showStopResult(DevStopResult result, {bool backgrounded = false}) {
    setState(() => _state = result.state);
    _lastStopLevel = result.stopLevel;
    _lastStopAckMs = result.ackMs;
    // 실물 정지의 확인 단계(2026-10-13): 보냄(sent)은 확인이라고 말하지 않는다.
    final stopSentence =
        stopLevelSentence(result.stopLevel, ackMs: result.ackMs, detail: true);
    if (result.state.phase == 'fault') {
      _say('정지를 확인하지 못했어요 — 기기가 잠겼습니다. 다시 정지를 눌러 확인해 주세요.', problem: true);
    } else if (result.state.phase == 'stopping') {
      _say('정지 요청을 확인했어요. 남은 동작을 정리하고 있어요.');
      _scheduleSettlePoll();
    } else if (stopSentence != null && result.state.phase == 'idle') {
      _say(backgrounded ? '앱이 화면에서 사라져 세션을 끝냈어요 — $stopSentence' : stopSentence,
          problem: !stopLevelConfirmed(result.stopLevel));
    } else if (result.confirmed && result.state.phase == 'idle') {
      _say(backgrounded ? '앱이 화면에서 사라져 세션을 끝냈어요' : '정지를 확인했어요');
    } else {
      _say('정지 완료를 확인하지 못했어요. 현재 상태를 확인하고 다시 정지를 눌러 주세요.', problem: true);
    }
  }

  Future<void> _endSession({bool backgrounded = false}) async {
    final api = _api;
    final id = _sessionId;
    final secret = _secret;
    if (api == null || id == null || secret == null) return;
    _invalidate();
    final epoch = _epoch;
    setState(() => _busy = true);
    try {
      final result = await api.end(id, secret);
      if (!_current(epoch, api)) return;
      _showStopResult(result, backgrounded: backgrounded);
    } on DevApiException catch (e) {
      if (!_current(epoch, api)) return;
      _say(
        e.code == 'session_expired'
            ? '세션이 이미 끝나 있었어요'
            : '세션 종료 응답을 확인하지 못했어요 — 정지 상태를 다시 확인해 주세요.',
        problem: e.code != 'session_expired',
      );
    } finally {
      if (_current(epoch, api)) setState(() => _busy = false);
    }
  }

  Future<void> _loadLog() async {
    final api = _api;
    if (api == null) return;
    final epoch = _epoch;
    try {
      final lines = await api.log();
      if (!_current(epoch, api)) return;
      setState(() => _log = lines);
    } on DevApiException catch (e) {
      if (!_current(epoch, api)) return;
      _say(_describe(e), problem: true);
    }
  }

  String _describe(DevApiException e) => switch (e.code) {
        'network' => '서버 응답을 확인하지 못했어요',
        'dev_mode_disabled' => '서버에서 개발자 모드가 꺼져 있어요',
        'dev_token_not_configured' => '서버에 개발자 토큰이 설정되지 않았어요',
        'dev_token_required' || 'dev_token_invalid' => '개발자 토큰이 맞지 않아요',
        'auth_rate_limited' => '토큰 확인 실패가 너무 많아요 — 1분 뒤 다시 시도해 주세요',
        'real_adapter_not_allowed' => '서버에서 실제 장치 조작이 켜져 있지 않아요',
        'not_homed' => '위치 기준이 확인되지 않아 이동할 수 없어요',
        'step_too_large' => '한 번에 움직일 수 있는 거리를 넘었어요',
        'estop_latched' => '비상정지가 걸려 있어요 — 풀고 확인한 뒤 다시 시도해 주세요',
        'link_down' || 'act_link_unavailable' => 'RPi4와 연결돼 있지 않아요',
        'motion_mock' => 'RPi4가 모의 모션이라 실제 장치를 움직일 수 없어요',
        'dev_protocol_unsupported' => 'RPi4가 개발자 조작을 모르는 판이에요 — 같은 판으로 배포해 주세요',
        'dev_busy' => '이전 동작이 아직 끝나지 않았어요',
        'session_expired' => '세션이 끝났어요 — 새로 시작해 주세요',
        'not_session_owner' => '다른 기기가 연 세션이에요',
        'session_conflict' => '다른 기기가 이미 세션을 열어 두었어요',
        'session_starting' => '다른 세션의 시작을 처리 중이에요 — 잠시 후 다시 시도해 주세요',
        'request_capacity_reached' => '요청 기록 한도예요 — 세션을 끝내고 새로 시작해 주세요',
        'execution_busy' => '일반 실행이 진행 중이에요 — 끝난 뒤에 시작할 수 있어요',
        'stopping' ||
        'stopped' ||
        'stop_race' =>
          '정지를 정리하는 중이에요 — 잠시 후 다시 시도해 주세요',
        'fault' ||
        'stop_unconfirmed' =>
          '정지가 확인되지 않아 기기가 잠겨 있어요 — 정지를 눌러 확인해 주세요',
        'rate_limited' => '요청이 너무 잦아요 — 잠시 후 다시 시도해 주세요',
        'duplicate_request' => '같은 요청이 이미 처리되었어요',
        'shutting_down' => '서버가 종료 중이에요',
        'unknown_appliance' => '서버에 등록되지 않은 가전이에요',
        _ => e.message,
      };

  // ── 화면 ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(devApiServiceProvider);
    if (!identical(_api, api)) {
      final oldApi = _api;
      final oldId = _sessionId;
      final oldSecret = _secret;
      _invalidate();
      if (oldApi != null && oldId != null && oldSecret != null) {
        _retire(oldApi, oldId, oldSecret);
      }
      _api = api;
      _message = null;
      _log = const [];
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshState());
    }
    final installed = ref.watch(installedAppliancesProvider);
    if (_targetId == null || !installed.any((a) => a.id == _targetId)) {
      _targetId = installed.isEmpty ? null : installed.first.id;
    }
    ApplianceMap? target;
    for (final a in installed) {
      if (a.id == (_sessionApplianceId ?? _targetId)) target = a;
    }
    if (target == null || !target.buttons.any((b) => b.id == _pressButtonId)) {
      _pressButtonId = null;
    }

    final state = _state;
    final real = state != null && state.isReal;
    final maxJog = state?.maxJogMm ?? 1;
    final jogSteps = [
      for (final v in const [1.0, 2.0, 5.0])
        if (v <= maxJog) v,
    ];
    if (jogSteps.isEmpty) jogSteps.add(1.0);
    final jogStep = jogSteps.contains(_jogStep) ? _jogStep : jogSteps.first;
    // 모의도 아니고 실제 장치라고 명시하지도 않은 서버(옛 서버)는 조작하지 않는다.
    final notMock = state != null && !state.mock && !real;
    final canStart = api != null &&
        _visible &&
        state != null &&
        !notMock &&
        !_hasSession &&
        !_busy &&
        target != null &&
        state.phase == 'idle';
    final canCommand = api != null &&
        _visible &&
        target != null &&
        !notMock &&
        // 실제 장치인데 서버가 지금 보낼 수 없다고 하면(링크·비상정지 등) 조작을 막는다. 정지는 늘 열려 있다.
        !(real && state.realMotionReady == false) &&
        _hasSession &&
        !_busy &&
        state?.phase == 'active';

    return Scaffold(
      appBar: AppBar(title: const Text('개발자 도구')),
      // 이동 패드를 보기 위해 스크롤해도 정지 버튼은 항상 같은 자리에 둔다.
      bottomNavigationBar: api == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.sm),
                child: _StopButton(onStop: _stop),
              ),
            ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          _MotionBadge(state: state),
          const SizedBox(height: AppSpace.lg),
          if (api == null)
            _TokenSetup(
              controller: _tokenController,
              hasServerUrl: (ref.watch(rpiUrlProvider) ?? '').isNotEmpty,
              onSave: () async {
                await ref
                    .read(devTokenProvider.notifier)
                    .save(_tokenController.text);
                _tokenController.clear();
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _refreshState());
              },
            )
          else ...[
            _PhaseLine(state: state),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      _settleAttempts = 0;
                      _refreshState(settling: _state?.phase == 'stopping');
                    },
              child: const Text('상태 새로고침'),
            ),
            if (_message != null) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                _message!,
                style: TextStyle(
                  fontSize: AppFont.caption,
                  color: _messageIsProblem ? context.appDanger : null,
                  fontWeight:
                      _messageIsProblem ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
            const SizedBox(height: AppSpace.xl),
            _Label('대상 가전'),
            if (installed.isEmpty)
              Text('등록된 가전이 없어요', style: TextStyle(color: context.appMuted))
            else
              DropdownButton<String>(
                isExpanded: true,
                value: installed
                        .any((a) => a.id == (_sessionApplianceId ?? _targetId))
                    ? (_sessionApplianceId ?? _targetId)
                    : null,
                // 세션이 열려 있는 동안에는 대상을 바꾸지 않는다 -- 서버도
                // 매 명령마다 대상을 다시 확인한다.
                onChanged: _hasSession || _busy
                    ? null
                    : (id) => setState(() {
                          _targetId = id;
                          _pressButtonId = null;
                        }),
                items: [
                  for (final a in installed)
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
              ),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: canStart ? _start : null,
                    style:
                        FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                    child: const Text('세션 시작'),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _hasSession ? () => _endSession() : null,
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 52)),
                    child: const Text('세션 끝내기'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                _CommandButton(
                    '상태', canCommand ? () => _command('status') : null),
                _CommandButton(
                    '센서 읽기', canCommand ? () => _command('sensor read') : null),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            _Label('방향 이동'),
            const SizedBox(height: AppSpace.sm),
            _Label(real
                ? '방향을 누를 때마다 ${_MotionBadge._mm(jogStep)}mm 이동 — 한 번에 한 번만 움직여요 (Z는 누르기로만)'
                : '방향을 누를 때마다 ${_MotionBadge._mm(jogStep)}mm 이동'),
            if (jogSteps.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: SegmentedButton<double>(
                  key: const ValueKey('dev-jog-step'),
                  segments: [
                    for (final v in jogSteps)
                      ButtonSegment(
                          value: v, label: Text('${_MotionBadge._mm(v)}mm')),
                  ],
                  selected: {jogStep},
                  onSelectionChanged:
                      _busy ? null : (s) => setState(() => _jogStep = s.first),
                ),
              ),
            _JogPad(
              step: _MotionBadge._mm(jogStep),
              onJog: canCommand
                  ? (axis, sign) =>
                      _command('jog $axis $sign ${_MotionBadge._mm(jogStep)}')
                  : null,
            ),
            if (!_hasSession)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Text('세션 시작을 누르면 방향 버튼이 켜져요.',
                    style: TextStyle(color: context.appMuted)),
              ),
            if (!real)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 32,
                      child: Text('Z',
                          style: TextStyle(
                              fontSize: AppFont.body,
                              fontWeight: FontWeight.w700)),
                    ),
                    Expanded(
                      child: _CommandButton(
                          'z −',
                          canCommand
                              ? () => _command(
                                  'jog z - ${_MotionBadge._mm(jogStep)}')
                              : null),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: _CommandButton(
                          'z +',
                          canCommand
                              ? () => _command(
                                  'jog z + ${_MotionBadge._mm(jogStep)}')
                              : null),
                    ),
                  ],
                ),
              ),
            if (target != null && target.buttons.isNotEmpty) ...[
              const SizedBox(height: AppSpace.md),
              _Label('버튼 누르기 (보정이 끝난 가전만)'),
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _pressButtonId,
                      hint: const Text('버튼 고르기'),
                      onChanged: (id) => setState(() => _pressButtonId = id),
                      items: [
                        for (final b in target.buttons)
                          DropdownMenuItem(
                            value: b.id,
                            child: Text('${b.label} (${b.id})'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _CommandButton(
                    '누르기',
                    canCommand && _pressButtonId != null
                        ? () => _command('press $_pressButtonId')
                        : null,
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.xxl),
            Row(
              children: [
                Expanded(child: _Label('기록')),
                TextButton(
                  onPressed: _loadLog,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('기록 새로고침'),
                ),
              ],
            ),
            if (_log.isEmpty)
              Text('기록을 불러오지 않았어요',
                  style: TextStyle(
                      color: context.appMuted, fontSize: AppFont.caption))
            else
              for (final line in _log)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                  child: Text(
                    '${_hms(line.at)}  ${line.event}  ${line.detail}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: AppFont.caption,
                      color: context.appOnSurfaceSoft,
                    ),
                  ),
                ),
            const SizedBox(height: AppSpace.md),
            TextButton(
              onPressed: _hasSession || _busy
                  ? null
                  : () => ref.read(devTokenProvider.notifier).clear(),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child:
                  Text('개발자 토큰 지우기', style: TextStyle(color: context.appMuted)),
            ),
          ],
        ],
      ),
    );
  }

  static String _hms(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

// ── 조각 ───────────────────────────────────────────────────────────────────

/// '모의' / '실제 장치' 표시. 근거는 서버 응답뿐이고, 색만으로 말하지 않는다
/// -- 글자 배지·아이콘·문장을 함께 둔다.
class _MotionBadge extends StatelessWidget {
  const _MotionBadge({required this.state});

  final DevState? state;

  static String _mm(double v) => v.toStringAsFixed(v % 1 == 0 ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    final s = state;
    final real = s != null && s.isReal;
    final unsupported = s != null && !s.mock && !real;
    final realBlocked = real && s.realMotionReady == false;
    final color = real || unsupported ? context.appDanger : context.appWarning;
    final (String badge, IconData icon, String title, String body) = real
        ? (
            '실제 장치',
            Icons.precision_manufacturing_outlined,
            '실제 장치 — 기계가 움직여요',
            realBlocked
                ? '지금은 움직일 수 없어요: ${s.realMotionReason ?? '이유를 확인하지 못했어요'}'
                : 'RPi4를 거쳐 모션 보드로 명령이 가요. 한 번에 ${_mm(s.maxJogMm)}mm까지 움직여요. 정지 버튼에 손을 두세요.',
          )
        : unsupported
            ? (
                '확인 필요',
                Icons.block,
                '모의 제어 서버가 아니에요',
                '서버가 실제 장치라고 알리지 않았어요. 조작을 모두 잠갔어요.',
              )
            : (
                '모의',
                Icons.science_outlined,
                '모의 제어 — 실제로 움직이지 않음',
                '서버의 모의 어댑터에만 명령이 갑니다. 설치·보정 준비용입니다.',
              );
    return Semantics(
      container: true,
      liveRegion: real || unsupported,
      label: '개발자 도구 대상: $badge',
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color, width: real ? 3 : 2),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    key: const ValueKey('dev-motion-badge'),
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.md, vertical: AppSpace.xs),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        fontSize: AppFont.caption,
                        fontWeight: FontWeight.w800,
                        color: AppColors.onAccent,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    title,
                    style: const TextStyle(
                        fontSize: AppFont.body, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    body,
                    style: TextStyle(
                      fontSize: AppFont.caption,
                      color: realBlocked ? context.appDanger : context.appMuted,
                      fontWeight:
                          realBlocked ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 국면은 색만으로 말하지 않는다 -- 모양과 문장을 함께 둔다.
class _PhaseLine extends StatelessWidget {
  const _PhaseLine({required this.state});

  final DevState? state;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text, Color? color) = switch (state?.phase) {
      null => (Icons.help_outline, '상태 확인 전', null),
      'idle' => (Icons.radio_button_unchecked, '대기 — 세션 없음', null),
      'active' => (Icons.radio_button_checked, '세션 진행 중', null),
      'stopping' => (
          Icons.hourglass_top,
          '정지 정리 중 — 새 조작 불가',
          context.appWarning
        ),
      'fault' => (Icons.warning_amber, '정지 미확인 — 기기 잠김', context.appDanger),
      'execution_busy' => (
          Icons.play_circle_outline,
          '일반 실행 중 — 개발자 조작 불가',
          context.appWarning
        ),
      final other => (Icons.help_outline, '알 수 없는 상태: $other', null),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppFont.body,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.sm),
        child: Text(text,
            style:
                TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
      );
}

/// 상하좌우 방향 패드. 누를 때마다 한 번만 보낸다(누르고 있어도 반복하지 않는다).
/// 위 = y+, 아래 = y−, 왼쪽 = x−, 오른쪽 = x+ (갠트리 실제 방향은 기구 확인 전).
class _JogPad extends StatelessWidget {
  const _JogPad({required this.step, required this.onJog});

  final String step;
  final void Function(String axis, String sign)? onJog;

  Widget _dir(String label, IconData icon, String axis, String sign) =>
      SizedBox(
        width: 104,
        height: 64,
        child: OutlinedButton.icon(
          onPressed: onJog == null ? null : () => onJog!(axis, sign),
          icon: Icon(icon),
          label: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          key: const ValueKey('dev-jog-pad'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _dir('y +', Icons.arrow_upward, 'y', '+'),
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dir('x −', Icons.arrow_back, 'x', '-'),
                SizedBox(
                  width: 72,
                  child: Text('${step}mm',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                _dir('x +', Icons.arrow_forward, 'x', '+'),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            _dir('y −', Icons.arrow_downward, 'y', '-'),
          ],
        ),
      );
}

class _CommandButton extends StatelessWidget {
  const _CommandButton(this.label, this.onPressed);

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
        child: Text(label),
      );
}

/// 정지 기호·두꺼운 외곽선·격리된 자리 -- 실행 상태 화면의 긴급 정지와
/// 같은 모양 규칙. 세션이 없어도 항상 누를 수 있다.
class _StopButton extends StatelessWidget {
  const _StopButton({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 64,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: AppColors.onAccent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: Theme.of(context).colorScheme.onSurface,
                width: 3,
              ),
            ),
          ),
          onPressed: onStop,
          icon: const Icon(Icons.stop, size: 28),
          label: const Text(
            '정지',
            style: TextStyle(
                fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700),
          ),
        ),
      );
}

class _TokenSetup extends StatelessWidget {
  const _TokenSetup({
    required this.controller,
    required this.hasServerUrl,
    required this.onSave,
  });

  final TextEditingController controller;
  final bool hasServerUrl;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    if (!hasServerUrl) {
      return Text('설정의 고급 설정에서 서버 주소를 먼저 저장해 주세요',
          style: TextStyle(color: context.appMuted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('개발자 토큰',
            style: TextStyle(
                fontSize: AppFont.caption, fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpace.xs),
        Text(
          '서버의 SIMPLELAY_DEV_TOKEN과 같은 값입니다. 일반 API 키와 다릅니다.',
          style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
        ),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '개발자 토큰 입력',
            isDense: true,
          ),
          onSubmitted: (_) => onSave(),
        ),
        const SizedBox(height: AppSpace.sm),
        FilledButton.tonal(
          onPressed: onSave,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          child: const Text('토큰 저장'),
        ),
      ],
    );
  }
}
