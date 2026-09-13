import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appliance.dart';
import '../providers/appliance_provider.dart';
import '../providers/dev_api_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/dev_api_service.dart';
import '../theme/app_colors.dart';

/// 개발자 도구 (Phase 2) — **모의 제어 전용** 최소 화면.
///
/// 설치·보정 준비에 필요한 것만 둔다: 대상 가전, 서버 상태, 제한된 명령,
/// 정지, 기록. 조이스틱·자유 입력 콘솔은 없다 -- 명령은 버튼으로만 만들고
/// 서버의 허용 목록을 그대로 따른다.
///
/// 지키는 것:
/// - 화면 어디에서나 "모의 제어 — 실제로 움직이지 않음"이 보인다. 서버가
///   모의가 아니라고 답하면 조작을 전부 잠근다.
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
  String? _sessionId;
  String? _secret;
  String? _sessionApplianceId;
  String? _targetId;
  String? _pressButtonId;
  String? _message;
  bool _messageIsProblem = false;
  bool _busy = false;
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
                ? '정지를 확인했어요'
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
      if (!started.state.mock ||
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
      _say('세션을 열었어요 — 모의 제어라 실제로 움직이지 않아요');
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
          !state.mock ||
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
    try {
      final result = await api.command(
        id,
        secret,
        applianceId: appliance,
        text: text,
        requestId: requestId,
      );
      if (!_current(epoch, api) || _sessionId != id) return;
      _stateRead++;
      setState(() => _state = result.state);
      final sensor = result.sensor;
      _say(
        sensor == null
            ? "'${result.normalized ?? text}' 명령을 모의 어댑터가 받았어요"
            : '센서(모의): ${sensor.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)}').join(' · ')}',
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
    if (result.state.phase == 'fault') {
      _say('정지를 확인하지 못했어요 — 기기가 잠겼습니다. 다시 정지를 눌러 확인해 주세요.', problem: true);
    } else if (result.state.phase == 'stopping') {
      _say('정지 요청을 확인했어요. 남은 동작을 정리하고 있어요.');
      _scheduleSettlePoll();
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
        'real_adapter_not_allowed' => '모의 제어 서버가 아니에요 — 이 화면에서는 조작할 수 없어요',
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
        'duplicate_request' => '같은 요청이 이미 처리됐어요',
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
    final notMock = state != null && !state.mock;
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
        _hasSession &&
        !_busy &&
        state?.phase == 'active';

    return Scaffold(
      appBar: AppBar(title: const Text('개발자 도구')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _MockBanner(notMock: notMock),
          const SizedBox(height: 16),
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
              const SizedBox(height: 10),
              Text(
                _message!,
                style: TextStyle(
                  fontSize: 15,
                  color: _messageIsProblem ? context.appDanger : null,
                  fontWeight:
                      _messageIsProblem ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
            const SizedBox(height: 20),
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
            const SizedBox(height: 12),
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
                const SizedBox(width: 12),
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
            const SizedBox(height: 24),
            _Label('명령'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CommandButton(
                    '상태', canCommand ? () => _command('status') : null),
                _CommandButton('홈', canCommand ? () => _command('home') : null),
                _CommandButton(
                    '센서 읽기', canCommand ? () => _command('sensor read') : null),
              ],
            ),
            const SizedBox(height: 12),
            _Label('한 번 누를 때 1mm 이동'),
            for (final axis in const ['x', 'y', 'z'])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Text(axis.toUpperCase(),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                    Expanded(
                      child: _CommandButton('$axis −',
                          canCommand ? () => _command('jog $axis - 1') : null),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _CommandButton('$axis +',
                          canCommand ? () => _command('jog $axis + 1') : null),
                    ),
                  ],
                ),
              ),
            if (target != null && target.buttons.isNotEmpty) ...[
              const SizedBox(height: 12),
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
                  const SizedBox(width: 8),
                  _CommandButton(
                    '누르기',
                    canCommand && _pressButtonId != null
                        ? () => _command('press $_pressButtonId')
                        : null,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            _StopButton(onStop: _stop),
            const SizedBox(height: 24),
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
                  style: TextStyle(color: context.appMuted, fontSize: 13))
            else
              for (final line in _log)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    '${_hms(line.at)}  ${line.event}  ${line.detail}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: context.appOnSurfaceSoft,
                    ),
                  ),
                ),
            const SizedBox(height: 12),
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

class _MockBanner extends StatelessWidget {
  const _MockBanner({required this.notMock});

  final bool notMock;

  @override
  Widget build(BuildContext context) {
    final color = notMock ? context.appDanger : context.appWarning;
    return Semantics(
      container: true,
      liveRegion: notMock,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color, width: 2),
        ),
        child: Row(
          children: [
            Icon(notMock ? Icons.block : Icons.science_outlined,
                color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notMock ? '모의 제어 서버가 아니에요' : '모의 제어 — 실제로 움직이지 않음',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    notMock
                        ? '이 화면은 모의 제어만 지원합니다. 조작을 모두 잠갔어요.'
                        : '서버의 모의 어댑터에만 명령이 갑니다. 설치·보정 준비용입니다.',
                    style: TextStyle(fontSize: 13, color: context.appMuted),
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
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 18,
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
        padding: const EdgeInsets.only(bottom: 6),
        child:
            Text(text, style: TextStyle(color: context.appMuted, fontSize: 13)),
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
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
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
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          '서버의 SIMPLELAY_DEV_TOKEN과 같은 값입니다. 일반 API 키와 다릅니다.',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
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
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: onSave,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          child: const Text('토큰 저장'),
        ),
      ],
    );
  }
}
