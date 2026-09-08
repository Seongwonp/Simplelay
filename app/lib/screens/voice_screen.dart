import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/voice_provider.dart';
import '../services/ble_service.dart';
import '../services/rpi_api_service.dart';
import '../services/voice_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen>
    with WidgetsBindingObserver {
  /// 전송 중 재진입 잠금. 연타하거나 자동/수동 경로가 겹치면 같은 명령이
  /// 두 번 실행된다 -- 물리 버튼을 누르는 기기에서는 되돌릴 수 없다.
  bool _sending = false;

  // dispose()는 위젯이 이미 unmount되는 중이라 그 시점의 ref.read()는
  // "Cannot use ref after the widget was disposed"로 죽는다 — initState에서
  // (ref가 아직 유효할 때) 미리 읽어 필드에 캐시해두고 dispose에서는 이
  // 필드만 쓴다.
  late final VoiceService _voiceService;

  @override
  void initState() {
    super.initState();
    _voiceService = ref.read(voiceServiceProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 뒤로 가거나 화면이 꺼지면 마이크를 놓는다. 보이지 않는 화면이
    // 계속 듣고 있으면 안 된다.
    if (state != AppLifecycleState.resumed) _cancelSession();
  }

  /// 음성 세션을 끝내고 확인 대기 문장도 비운다.
  /// 화면을 떠났다가 돌아와 예전 문장을 실행하는 혼선을 막는다.
  /// 인식이 실패한 이유. 스낵바는 몇 초 뒤 사라지므로, 화면에도 남겨
  /// **다음에 무엇을 할 수 있는지**를 같이 보여준다. 안내가 사라지고 나면
  /// 사용자는 같은 시도를 반복하는 것 말고 할 게 없다.
  String? _recognitionError;

  void _fail(String message) {
    _notice(message);
    if (mounted) setState(() => _recognitionError = message);
  }

  void _clearFailure() {
    if (_recognitionError != null) setState(() => _recognitionError = null);
  }

  Future<void> _cancelSession() async {
    if (_voiceService.isListening) await _voiceService.stop();
    if (!mounted) return;
    ref.read(voiceListeningProvider.notifier).state = false;
    ref.read(voiceTextProvider.notifier).state = '';
  }

  /// 듣기만 끝낸다 -- 실행은 사용자가 인식 문장을 보고 고른다.
  Future<void> _finishListening() async {
    await _voiceService.stop();
    if (!mounted) return;
    ref.read(voiceListeningProvider.notifier).state = false;
    // 듣기는 끝났는데 남은 말이 없다 -- 실패와 다를 바 없는 상태다.
    if (ref.read(voiceTextProvider).trim().isEmpty) {
      setState(() => _recognitionError = '말을 알아듣지 못했어요.');
    }
  }

  Future<void> _restartListening() async {
    ref.read(voiceTextProvider.notifier).state = '';
    _clearFailure();
    await _toggle();
  }

  void _cancelPending() => ref.read(voiceTextProvider.notifier).state = '';

  Future<void> _toggle() async {
    final voice = _voiceService;
    if (voice.isListening) {
      await voice.stop();
      ref.read(voiceListeningProvider.notifier).state = false;
      return;
    }
    final available = await voice.initialize();
    if (!mounted) return;
    if (!available) {
      _fail('음성 인식을 사용할 수 없습니다. 권한을 확인하세요.');
      return;
    }
    _clearFailure();
    ref.read(voiceTextProvider.notifier).state = '';
    ref.read(voiceListeningProvider.notifier).state = true;
    try {
      await voice.listen(
        onText: (text) {
          if (!mounted) return;
          ref.read(voiceTextProvider.notifier).state = text;
        },
        onSilence: (text) {
          if (!mounted) return;
          // 5초 침묵은 "듣기 종료"일 뿐 "실행 동의"가 아니다. 생각하다
          // 잠깐 멈춘 것이 실행으로 해석되면, 물리 버튼을 대신 누르는
          // 기기에서는 되돌릴 수 없는 동작이 된다. 여기서는 멈추기만 하고
          // 실행 여부는 사용자가 인식 문장을 확인하고 고른다.
          ref.read(voiceListeningProvider.notifier).state = false;
          ref.read(voiceTextProvider.notifier).state = text;
        },
        onError: (errorId) {
          if (!mounted) return;
          // cancelOnError가 엔진 세션을 종료하므로 UI도 즉시 idle로 맞춘다.
          // 부분 인식 문자열은 재전송 오해를 막기 위해 비운다.
          ref.read(voiceListeningProvider.notifier).state = false;
          ref.read(voiceTextProvider.notifier).state = '';
          _fail(voiceErrorGuide(errorId));
        },
      );
    } catch (_) {
      if (!mounted) return;
      ref.read(voiceListeningProvider.notifier).state = false;
      _fail('음성 인식을 시작하지 못했어요. 다시 시도해주세요.');
    }
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;
    setState(() => _sending = true);
    final rpiApi = ref.read(rpiApiServiceProvider);
    final appliance = ref.read(selectedApplianceProvider);

    try {
      if (appliance.isCustom) {
        // 사용자 정의 가전은 서버 고정 규칙이 없어서 LLM으로 해석해야 하고,
        // BLE 릴레이(ESP32)는 의도 해석을 못 하므로 RPi5 HTTP 직통만 지원한다
        // (버튼 직접 실행 — manual_control_screen과 같은 제약).
        if (rpiApi == null) {
          _notice('사용자 정의 가전의 음성 명령은 RPi5 서버 연결이 필요해요. 설정에서 URL을 확인하세요.');
          return;
        }
        final accepted = await rpiApi.executeForAppliance(
          trimmed,
          appliance.buttons.map((b) => b.label).toList(),
          applianceId: appliance.id,
        );
        _trackJob(rpiApi, accepted.jobId, trimmed);
      } else if (rpiApi != null) {
        // RPi HTTP 직통 — 즉시 접수(job_id) 후 상태 화면에서 진행 확인
        final accepted = await rpiApi.execute(
          trimmed,
          source: 'voice',
          applianceId: appliance.id,
        );
        _trackJob(rpiApi, accepted.jobId, trimmed);
      } else {
        // BLE 폴백
        await ref
            .read(bleServiceProvider)
            .sendCommand(trimmed, source: 'voice');
        if (mounted) _notice('명령을 전송했습니다.');
      }
    } on RpiApiException catch (error) {
      if (mounted) {
        _notice(switch (error.statusCode) {
          422 => '이해하지 못한 명령이에요. 다시 말해주세요.',
          409 => '다른 작업이 실행 중이에요. 끝난 뒤 다시 시도해주세요.',
          503 => '음성 해석 기능이 서버에 설정되어 있지 않아요.',
          _ => '명령을 전달하지 못했어요. 연결을 확인해주세요.',
        });
      }
    } on TimeoutException {
      // 응답이 유실됐을 뿐 서버는 이미 접수했을 수 있다. 이걸 '미접수'로
      // 단정하고 BLE로 다시 보내면 같은 명령이 두 번 실행된다 -- 채널 간
      // 중복을 걸러낼 요청 ID가 아직 없으므로 자동 재전송하지 않는다.
      if (mounted) {
        _notice('요청이 접수됐는지 확인 중이에요. 실행 상태를 확인해주세요.');
      }
    } catch (_) {
      // 연결 자체가 성립하지 않은 실패(서버에 닿지도 못함). 서버가 살아서
      // 거절한 게 아니므로, BLE(ESP32 릴레이)가 연결돼 있으면 폴백 전송한다 —
      // "Wi-Fi가 끊겨도 동작"이 실제로 성립하는 지점. 사용자 정의 가전은
      // LLM 해석이 필요해 BLE 릴레이로는 처리 불가라 제외.
      final bleState = ref.read(bleConnectionProvider).valueOrNull;
      if (!appliance.isCustom && bleState == BleConnectionState.connected) {
        try {
          await ref
              .read(bleServiceProvider)
              .sendCommand(trimmed, source: 'voice');
          if (mounted) _notice('서버 응답이 없어 BLE로 전송했어요.');
          return;
        } catch (_) {
          // BLE마저 실패 — 아래 공통 안내로
        }
      }
      if (mounted) _notice('명령을 전달하지 못했어요. 연결을 확인해주세요.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // 접수된 job을 상태 화면에서 실시간으로 따라가게 하고 그 화면으로 이동한다.
  // 음성 경로는 서버가 해석한 버튼 시퀀스를 미리 모르므로 steps 없이 시작 —
  // 진행률·완료 판정은 /status 폴링이 채운다.
  void _trackJob(RpiApiService api, String jobId, String label) {
    ref.read(executionStatusProvider.notifier).beginHttpJob(
          api: api,
          jobId: jobId,
          label: label,
        );
    if (mounted) context.go('/status');
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceService.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = ref.watch(voiceTextProvider);
    final listening = ref.watch(voiceListeningProvider);
    final appliance = ref.watch(selectedApplianceProvider);

    // 탭을 떠나면 마이크를 놓는다. 탭 브랜치는 화면을 떠나도 위젯이 살아
    // 있어서(상태 보존), 여기서 정리하지 않으면 숨겨진 화면이 계속 듣는다.
    ref.listen<int>(currentTabIndexProvider, (_, next) {
      if (next != voiceTabIndex) _cancelSession();
    });

    // 내장 가전(전자레인지)만 실제로 매칭되는 규칙이 있어서 그 예시를 쓰고,
    // 사용자 정의 가전은 등록된 실제 버튼 라벨로 예시를 만든다 — 안 그러면
    // "우유 데워줘" 힌트가 우유 버튼도 없는 가전에서도 그대로 보이게 된다.
    final hintExample = appliance.isCustom && appliance.buttons.isNotEmpty
        ? '예: ${appliance.buttons.first.label} 해줘'
        : '예: 즉석밥 데워줘';

    return Scaffold(
      appBar: AppBar(title: const Text('음성 명령')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          children: [
            // 인식 문장이 길거나 글씨를 키우면 내용이 화면을 넘긴다.
            // 본문은 스크롤하고, 실행/취소는 아래에 고정해 항상 닿게 한다.
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 24),

                    // ── 웨이브 비주얼라이저 ────────────────────────────────────────
                    _WaveVisualizer(active: listening),
                    const SizedBox(height: 32),

                    // ── 마이크 버튼 ────────────────────────────────────────────────
                    _MicButton(
                      listening: listening,
                      onTap: _sending ? null : _toggle,
                    ),
                    const SizedBox(height: 28),

                    // ── 상태 텍스트 ────────────────────────────────────────────────
                    Text(
                      listening
                          ? '듣고 있어요…'
                          : text.trim().isEmpty
                              ? '마이크를 눌러 말해보세요'
                              : '이대로 실행할까요?',
                      style: AppText.title,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),

                    // ── 인식된 텍스트 라이브 표시 ──────────────────────────────────
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: text.isEmpty
                          ? (_recognitionError == null
                              ? Text(
                                  hintExample,
                                  key: const ValueKey('hint'),
                                  style: TextStyle(color: context.appMuted),
                                  textAlign: TextAlign.center,
                                )
                              : _FailureNote(
                                  key: const ValueKey('failure'),
                                  message: _recognitionError!,
                                ))
                          : Container(
                              key: const ValueKey('live'),
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color:
                                    context.appPrimary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color:
                                      context.appPrimary.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Text(
                                text,
                                style: AppText.title
                                    .copyWith(color: context.appPrimary),
                                textAlign: TextAlign.center,
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '말이 끝나면 내용을 확인한 뒤 실행해요.',
                      style: TextStyle(color: context.appMuted, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // ── 확인 후 실행 ───────────────────────────────────────────────
            // 듣기 종료와 실행 동의를 분리한다. 인식이 틀렸을 때 고치거나
            // 그만둘 자리가 없으면, 잘못 알아들은 문장이 그대로 물리 조작이 된다.
            if (listening)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _sending ? null : _finishListening,
                  child: const Text('말 끝났어요'),
                ),
              )
            else if (text.trim().isEmpty && _recognitionError != null) ...[
              // 실패한 자리에 두 경로를 함께 둔다. 안내만 남기면 사용자는
              // 같은 시도를 되풀이하게 된다 -- 홈에서 이미 같은 규칙을 쓴다.
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: OutlinedButton.icon(
                      onPressed: _sending ? null : () => context.go('/manual-control'),
                      icon: const Icon(Icons.grid_view_rounded, size: 20),
                      label: const Text('버튼으로 조작'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: FilledButton.icon(
                      onPressed: _sending ? null : _restartListening,
                      icon: const Icon(Icons.mic, size: 20),
                      label: const Text('다시 말하기'),
                    ),
                  ),
                ],
              ),
            ] else if (text.trim().isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _sending ? null : _restartListening,
                      child: const Text('다시 말하기'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _sending ? null : () => _send(text),
                      child: Text(_sending ? '보내는 중…' : '이대로 실행'),
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: _sending ? null : _cancelPending,
                child: const Text('취소'),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ── 인식 실패 안내 ────────────────────────────────────────────────────────

/// 스낵바가 사라진 뒤에도 "무슨 일이 있었는지"가 화면에 남게 한다.
class _FailureNote extends StatelessWidget {
  const _FailureNote({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: context.appWarning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.appWarning.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: context.appWarning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, textAlign: TextAlign.start),
            ),
          ],
        ),
      );
}

// ── 마이크 버튼 ───────────────────────────────────────────────────────────

class _MicButton extends StatelessWidget {
  const _MicButton({required this.listening, required this.onTap});
  final bool listening;
  final VoidCallback? onTap;

  @override
  // Semantics: 스크린리더 사용자에게 상태까지 포함해 버튼으로 읽힌다.
  // 햅틱: 듣기 시작/정지 전환을 손끝으로도 확인 (시각 비의존 채널).
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: listening ? '음성 인식 정지' : '음성 명령 시작',
        child: GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            onTap?.call();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            width: listening ? 100 : 84,
            height: listening ? 100 : 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: listening
                  ? context.appPrimary
                  : context.appPrimary.withValues(alpha: 0.15),
              boxShadow: listening
                  ? [
                      BoxShadow(
                        color: context.appPrimary.withValues(alpha: 0.35),
                        blurRadius: 32,
                        spreadRadius: 4,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              listening ? Icons.stop_rounded : Icons.mic_rounded,
              size: listening ? 44 : 38,
              color: listening ? Colors.black : context.appPrimary,
            ),
          ),
        ),
      );
}

// ── 웨이브 비주얼라이저 (5개 바) ─────────────────────────────────────────

class _WaveVisualizer extends StatelessWidget {
  const _WaveVisualizer({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(
              5,
              (i) => _WaveBar(
                    index: i,
                    active: active,
                  )),
        ),
      );
}

class _WaveBar extends StatefulWidget {
  const _WaveBar({required this.index, required this.active});
  final int index;
  final bool active;

  @override
  State<_WaveBar> createState() => _WaveBarState();
}

class _WaveBarState extends State<_WaveBar>
    with SingleTickerProviderStateMixin {
  // 바마다 높이 범위가 달라야 자연스러운 파형처럼 보임
  static const _minHeights = [10.0, 18.0, 28.0, 18.0, 10.0];
  static const _maxHeights = [24.0, 38.0, 56.0, 38.0, 24.0];
  static const _delays = [0, 100, 50, 150, 80];

  late final AnimationController _ctrl;
  late final Animation<double> _height;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 400 + widget.index * 60),
    );
    _height = Tween(
      begin: _minHeights[widget.index],
      end: _maxHeights[widget.index],
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));

    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(_WaveBar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_started) {
      _start();
    } else if (!widget.active && _started) {
      _stop();
    }
  }

  Future<void> _start() async {
    _started = true;
    await Future.delayed(Duration(milliseconds: _delays[widget.index]));
    // 대기 중 음성 오류/수동 정지로 active가 false가 될 수 있다. 예약된
    // 지연 콜백이 그 뒤 애니메이션을 되살리지 않도록 최신 상태를 재확인한다.
    if (mounted && _started && widget.active) _ctrl.repeat(reverse: true);
  }

  void _stop() {
    _started = false;
    _ctrl.animateTo(0, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Container(
            width: 7,
            height: _height.value,
            decoration: BoxDecoration(
              color: widget.active
                  ? context.appPrimary
                  : context.appPrimary.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
}
