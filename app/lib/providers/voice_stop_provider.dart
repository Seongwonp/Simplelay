import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/execution_status.dart';
import '../services/voice_service.dart';
import 'estop_provider.dart';
import 'execution_status_provider.dart';
import 'rpi_api_provider.dart';
import 'voice_provider.dart';

/// 실행 중 '멈춰' 듣기에 쓰는 인식기 — 홈 '말로 조작하기'와 **같은 엔진**이다
/// (폰 음성 인식, 2026-10-07). 엔진이 하나라 두 쪽이 서로의 세션을 끊을 수 있고,
/// 그때는 [SpeechRecognizer.listen]의 `onInterrupted`로 안다. 시험은 이 provider를
/// 가짜 인식기로 바꾼다.
final speechRecognizerProvider =
    Provider<SpeechRecognizer>((ref) => ref.watch(voiceServiceProvider));

/// 정지로 받는 짧은 말. 공백·문장부호를 뺀 뒤 이 말들만으로 이루어져야 한다
/// ("멈춰 멈춰"는 되고 "전자레인지 멈춰 있어"·"그만 데워줘"는 안 된다).
/// 긴 문장 속 낱말을 받지 않는 것은 오인식 대비다 — 정지는 버튼이 본 수단이다.
const _stopWords = [
  '멈춰주세요', '멈춰줘요', '멈춰줘', '멈춰요', '멈춰라', '멈추어', '멈춰', '멈춤',
  '정지해주세요', '정지해줘', '정지해요', '정지해', '정지',
  '그만해주세요', '그만해줘', '그만해요', '그만해', '그만',
  '스톱', '스탑', 'stop',
];

final _ignored = RegExp(r'[\s.,!?~·…"]');

bool isStopPhrase(String text) {
  var rest = text.toLowerCase().replaceAll(_ignored, '');
  if (rest.isEmpty || rest.length > 16) return false;
  while (rest.isNotEmpty) {
    String? hit;
    for (final w in _stopWords) {
      if (rest.startsWith(w)) {
        hit = w;
        break; // 긴 말부터 적어 두었다
      }
    }
    if (hit == null) return false;
    rest = rest.substring(hit.length);
  }
  return true;
}

class VoiceStopState {
  const VoiceStopState({this.listening = false});

  /// 내 듣기 세션이 엔진에 열려 있다 — 화면에 "듣는 중"을 띄운다. 엔진이 세션을
  /// 끝내면(침묵·`done`·오류·남이 가져감) 바로 false가 된다.
  final bool listening;
}

/// 실행 중 음성 '멈춰' 정지(9/30 결정, 2026-10-07 구현, 10/8 인계 5차 수리).
///
/// - **실행 중**일 때만 듣는다. 실행 중은 세 가지로 안다:
///   폰이 추적하는 실행(정지 줄이 보이는 단계: waiting·running·retrying·unknown),
///   서버 `/status.running`(키오스크·루틴이 시작한 실행 포함),
///   **정지 버튼 위 대기**(`hold_state == hovering_stop`). 서버 조회가 실패하면
///   뒤의 두 값은 꺼진 것으로 본다 — 모르는 채 마이크를 열어 두지 않는다.
/// - 정지 말이면 폰이 추적하는 실행에는 화면 정지 버튼과 **같은 호출**
///   (`ExecutionStatusNotifier.emergencyStop`)을, 그 밖(서버만 아는 실행·대기)에는
///   그 호출이 쓰는 같은 `POST /stop`을 부른다. 별도 정지 경로는 없다.
/// - 정지 요청은 한 실행(듣기 구간)에 **보낸 것이 확인되면** 한 번만 — 보내는 중
///   중복도, 보낸 뒤 반복도 무시한다. **보내지 못했으면**(HTTP 실패) 다시 듣고,
///   다시 말하면 다시 요청한다. 정지 버튼은 그대로 있다.
/// - 정지는 **최종 인식 결과**로만 한다. 부분 결과가 정지 말뿐이면
///   [partialStopDelay]만큼 다른 말이 이어지지 않을 때 보낸다("그만" 뒤에
///   "그만 데워줘"가 오면 보내지 않는다). 정지가 그만큼 늦어지는 것은 감수한다.
/// - "듣는 중" 표시는 엔진 세션이 열려 있는 동안만이다. 엔진이 스스로 끝나면
///   (`done`) 표시를 끄고 잠시 뒤 다시 연다.
/// - 인식 오류·권한 거부·엔진 없음은 조용히 넘어간다(화면 안내 없음).
/// - 이 듣기는 정지 말 말고는 아무것도 하지 않는다 — **음성으로 실행 시작 금지.**
class VoiceStopController extends StateNotifier<VoiceStopState>
    with WidgetsBindingObserver {
  VoiceStopController(this._ref) : super(const VoiceStopState()) {
    _recognizer = _ref.read(speechRecognizerProvider);
    _ref.listen<ExecutionStatus>(executionStatusProvider, (_, __) => _evaluate());
    _ref.listen<EstopState>(estopProvider, (_, __) => _evaluate());
    // 홈 '말로 조작하기'가 마이크를 쥐는 동안은 비켜 준다.
    _ref.listen<bool>(voiceListeningProvider, (_, __) => _evaluate());
    WidgetsBinding.instance.addObserver(this);
    _evaluate();
  }

  final Ref _ref;
  late final SpeechRecognizer _recognizer;

  /// 다시 듣기 사이 간격. 엔진이 침묵·오류로 세션을 끝낸 뒤 바로 다시 열면
  /// 엔진이 바쁘다고 거절하는 기기가 있다(추측 — 실기기에서 확인 필요).
  static const restartDelay = Duration(milliseconds: 400);
  static const errorRestartDelay = Duration(milliseconds: 1200);

  /// 정지 말뿐인 부분 결과 뒤 이만큼 다른 결과가 없으면 정지로 본다.
  /// 최종 결과가 먼저 오면 그쪽으로 바로 판정한다(추측 — 실기기에서 확인 필요).
  static const partialStopDelay = Duration(milliseconds: 1000);

  /// 연속 오류가 이만큼이면 이번 듣기 구간은 접는다(무한 재시도 방지).
  static const maxConsecutiveErrors = 5;

  bool _active = false; // 듣기 구간 안인가(실행 중·대기 중)
  bool _sent = false; // 이번 구간에서 정지를 보냈고 서버가 받았다
  bool _stopInFlight = false;
  bool _gaveUp = false; // 권한 거부·엔진 없음·오류 반복
  bool _paused = false; // 앱이 뒤로 갔다
  bool _starting = false;
  bool _sessionOpen = false; // 내 듣기 세션이 엔진에 열려 있다(여는 중 포함)
  bool _disposed = false;
  int _errors = 0;
  int _gen = 0; // 내 듣기 세션 세대 — 끝난 세션의 늦은 콜백을 버린다
  Timer? _restartTimer;
  Timer? _partialTimer; // 정지 말뿐인 부분 결과 뒤 조용함을 기다린다

  bool _phoneTracking() {
    final phase = _ref.read(executionStatusProvider).phase;
    return phase == ExecutionPhase.waiting ||
        phase == ExecutionPhase.running ||
        phase == ExecutionPhase.retrying ||
        phase == ExecutionPhase.unknown;
  }

  bool _hubActive() {
    final hub = _ref.read(estopProvider);
    return hub.hubRunning || hub.holdingAtStop;
  }

  bool get _otherHoldsMic => _ref.read(voiceListeningProvider);

  bool get _wanted =>
      !_disposed &&
      _active &&
      !_sent &&
      !_gaveUp &&
      !_paused &&
      !_stopInFlight &&
      !_otherHoldsMic;

  void _evaluate() {
    if (_disposed) return;
    final active = _phoneTracking() || _hubActive();
    if (active && !_active) {
      // 새 듣기 구간 — 지난 실행의 '보냄'·포기를 들고 오지 않는다.
      _sent = false;
      _gaveUp = false;
      _errors = 0;
    }
    _active = active;
    if (_wanted) {
      if (!_sessionOpen && _restartTimer == null) _start();
    } else {
      _release();
    }
  }

  Future<void> _start() async {
    if (_starting || _sessionOpen) return;
    _starting = true;
    try {
      final ok = await _recognizer.initialize();
      if (_disposed) return;
      if (!ok) {
        _gaveUp = true; // 권한 거부·엔진 없음 — 조용히
        return;
      }
      if (!_wanted) return;
      final gen = ++_gen;
      _sessionOpen = true;
      await _recognizer.listen(
        onText: (text) {
          if (gen != _gen) return;
          _errors = 0;
          _onPartial(text);
        },
        onFinal: (text) {
          if (gen != _gen) return;
          _partialTimer?.cancel();
          _partialTimer = null;
          if (isStopPhrase(text)) _onStopWord();
        },
        onSilence: (text) {
          if (gen != _gen) return;
          if (isStopPhrase(text)) _onStopWord();
          _sessionEnded(restartDelay);
        },
        onDone: () {
          if (gen != _gen) return;
          // 엔진이 스스로 끝냈다 — 최종 결과는 이미 onFinal로 왔다.
          _sessionEnded(restartDelay);
        },
        onError: (errorId) {
          if (gen != _gen) return;
          if (errorId == 'error_insufficient_permissions' ||
              ++_errors >= maxConsecutiveErrors) {
            _gaveUp = true;
          }
          _sessionEnded(errorRestartDelay);
        },
        onInterrupted: () {
          if (gen != _gen) return;
          _sessionEnded(restartDelay);
        },
      );
      // 세션이 실제로 열린 뒤에만 "듣는 중" — 여는 사이 끝났으면 띄우지 않는다.
      if (!_disposed && gen == _gen && _sessionOpen) {
        state = const VoiceStopState(listening: true);
      }
    } catch (_) {
      // 엔진 없음(플러그인 미등록 포함)·시작 실패 — 조용히 접는다.
      _gaveUp = true;
      _gen++;
      _sessionOpen = false;
      if (!_disposed) state = const VoiceStopState();
    } finally {
      _starting = false;
    }
  }

  /// 부분 결과(최종 포함 — 최종 판정은 onFinal이 한다). 정지 말뿐이면
  /// 짧게 기다리고, 다른 말이 이어지면 기다림을 버린다.
  void _onPartial(String text) {
    _partialTimer?.cancel();
    _partialTimer = null;
    if (!isStopPhrase(text)) return;
    final gen = _gen;
    _partialTimer = Timer(partialStopDelay, () {
      _partialTimer = null;
      if (gen != _gen) return;
      _onStopWord();
    });
  }

  void _sessionEnded(Duration delay) {
    _gen++;
    _sessionOpen = false;
    _partialTimer?.cancel();
    _partialTimer = null;
    if (_disposed) return;
    state = const VoiceStopState();
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      _evaluate();
    });
  }

  /// 내 세션을 닫는다. 다른 화면이 마이크를 쥔 동안에는 엔진을 건드리지 않는다.
  void _release() {
    _restartTimer?.cancel();
    _restartTimer = null;
    _partialTimer?.cancel();
    _partialTimer = null;
    if (!_sessionOpen) return;
    _gen++;
    _sessionOpen = false;
    state = const VoiceStopState();
    if (!_otherHoldsMic) {
      unawaited(_recognizer.cancel().catchError((_) {}));
    }
  }

  Future<void> _onStopWord() async {
    if (!_active || _sent || _stopInFlight) return;
    _stopInFlight = true;
    _release(); // 보내는 동안은 듣지 않는다
    try {
      final bool sent;
      if (_phoneTracking()) {
        // 화면 정지 버튼과 같은 호출. false면 보내지 못했다(문구는 그쪽이 띄운다).
        sent = await _ref.read(executionStatusProvider.notifier).emergencyStop();
      } else {
        // 폰이 추적하지 않는 실행(키오스크·루틴) 또는 정지 버튼 위 대기 —
        // 같은 POST /stop(대기면 서버가 정지 버튼 누름으로 넘긴다).
        final api = _ref.read(rpiApiServiceProvider);
        if (api == null) {
          sent = false;
        } else {
          await api.stop();
          sent = true;
        }
      }
      if (sent) _sent = true;
    } catch (_) {
      // 보내지 못했다 — 조용히. 정지 버튼은 그대로 있고, 다시 말해도 된다.
    } finally {
      _stopInFlight = false;
      _evaluate(); // 못 보냈으면 다시 듣는다
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 보이지 않는 앱이 듣고 있으면 안 된다.
    _paused = state != AppLifecycleState.resumed;
    _evaluate();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _restartTimer?.cancel();
    _partialTimer?.cancel();
    if (_sessionOpen) {
      _gen++;
      _sessionOpen = false;
      unawaited(_recognizer.cancel().catchError((_) {}));
    }
    super.dispose();
  }
}


final voiceStopProvider =
    StateNotifierProvider<VoiceStopController, VoiceStopState>(
  VoiceStopController.new,
);
