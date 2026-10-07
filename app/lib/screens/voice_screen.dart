import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/appliance_provider.dart';
import '../providers/demo_provider.dart';
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
import '../models/appliance.dart';
import '../widgets/demo_badge.dart';
import '../widgets/no_appliance_notice.dart';

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

  /// 엔진이 알려준 **실제** 입력 음량. null이면 아직 한 번도 받지
  /// 못했다 -- 음량을 주지 않는 플랫폼도 있다. 그때는 파형을 흔들지
  /// 않는다(모르는 것을 그럴듯하게 그리지 않는다).
  ///
  /// setState가 아니라 ValueNotifier인 이유: 음량은 말하는 내내 초당
  /// 십수 번 온다. 그때마다 화면 전체를 다시 그리면 **정작 말하고 있는
  /// 순간에** 화면이 버벅인다. 다시 그릴 것은 막대 다섯 개뿐이다.
  final ValueNotifier<double?> _soundLevel = ValueNotifier(null);

  /// 이 기기에서 음성 인식 자체를 쓸 수 없다(권한 거부·엔진 없음).
  ///
  /// 한 번 못 알아들은 것과 다르다. 그때는 '다시 말하기'가 답이지만,
  /// 여기서는 아무리 다시 말해도 소용없다 -- 다른 길(버튼)을 먼저 내민다.
  bool _voiceUnavailable = false;

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
    // 엔진은 실행 중 '멈춰' 듣기와 같이 쓴다 — 그쪽이 쥐고 있을 때 누른 마이크는
    // '끄기'가 아니라 '시작'이다(이 화면이 듣는 중일 때만 끈다).
    if (voice.isListening && ref.read(voiceListeningProvider)) {
      await voice.stop();
      ref.read(voiceListeningProvider.notifier).state = false;
      return;
    }
    final available = await voice.initialize();
    if (!mounted) return;
    if (!available) {
      setState(() => _voiceUnavailable = true);
      return;
    }
    if (_voiceUnavailable) setState(() => _voiceUnavailable = false);
    _clearFailure();
    _soundLevel.value = null; // 지난 세션의 음량이 새 세션에 남지 않게
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
        onSoundLevel: (level) {
          if (!mounted) return;
          _soundLevel.value = level;
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
    if (appliance == null) {
      // 여기까지 오면 안 되지만(마이크가 막혀 있다), 상태가 그 사이 바뀔
      // 수 있다. 조작할 대상 없이 전송하지 않는다.
      setState(() => _sending = false);
      _notice('사용할 가전을 먼저 추가해 주세요.');
      return;
    }

    try {
      if (appliance.isCustom) {
        // 사용자 정의 가전은 서버 고정 규칙이 없어서 LLM으로 해석해야 하고,
        // BLE 릴레이(ESP32)는 의도 해석을 못 하므로 RPi5 HTTP 직통만 지원한다
        // (버튼 직접 실행 — manual_control_screen과 같은 제약).
        if (rpiApi == null) {
          _notice('음성으로 실행하려면 허브에 연결해 주세요. 설정에서 허브 주소를 확인해 주세요.');
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
      } else if (appliance.isThinq) {
        // ThinQ 가전은 서버를 거쳐야 한다 -- BLE 릴레이(ESP32)는 누를 버튼이
        // 없는 가전을 조작할 수 없다.
        _notice('ThinQ 가전은 기기 연결이 필요해요. 설정에서 연결을 확인하세요.');
      } else {
        // BLE 폴백
        await ref
            .read(bleServiceProvider)
            .sendCommand(trimmed, source: 'voice');
        if (mounted) _notice('명령을 보냈어요.');
      }
    } on RpiApiException catch (error) {
      if (mounted) {
        _notice(switch (error.statusCode) {
          422 => '이해하지 못한 명령이에요. 다시 말해주세요.',
          409 => '다른 작업이 실행 중이에요. 끝난 뒤 다시 시도해주세요.',
          503 => '음성 해석 기능이 서버에 설정되어 있지 않아요.',
          // 412: 가전이 아직 조작할 준비가 안 됐다. 서버가 무엇이
          // 남았는지 말해주므로 일반 문구로 덮지 않는다 -- 덮으면
          // 사용자가 원인을 가전 고장 쪽에서 찾게 된다.
          412 => _readinessMessage(error),
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
      // 모의 실행 중에는 BLE 폴백도 막는다 -- 여기로 새면 "실제 조작이
      // 아닙니다" 화면 아래에서 실기기가 진짜로 움직인다.
      //
      // 서버가 "준비 안 됐다"고 말한 가전도 막는다. BLE는 ESP32로 바로
      // 나가 **서버 게이트를 거치지 않으므로**, 여기서 안 막으면 준비
      // 안 된 기기가 실제로 움직인다(F1 마감 감사).
      if (!appliance.isCustom &&
          bleState == BleConnectionState.connected &&
          appliance.mayDispatchWithoutServer &&
          !ref.read(demoModeProvider)) {
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
    if (mounted) context.push('/status');
  }

  /// 412(준비 안 됨) 안내 — 서버가 준 사유를 그대로 싣는다.
  static String _readinessMessage(RpiApiException error) {
    final detail = error.message.trim();
    return detail.isEmpty
        ? '이 가전은 아직 조작할 준비가 되지 않았어요.'
        : '아직 조작할 준비가 되지 않았어요 — $detail';
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceService.cancel();
    _soundLevel.dispose();
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

    // 조작할 가전이 없으면 **마이크를 내주지 않는다.**
    //
    // 말하게 두고 전송 단계에서 실패시키면, 사용자는 자기 발음이 문제라고
    // 생각하게 된다. 무엇이 없는지와 어디로 가면 되는지를 먼저 말한다.
    // "가전 없음"은 예외가 아니라 정상 제품 상태다 -- 처음 설치한 사람은
    // 반드시 여기를 지난다.
    if (appliance == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('음성 명령')),
        body: NoApplianceNotice(
          title: '사용할 가전을 먼저 추가해 주세요',
          body: '조작할 가전이 있어야 말로 시킬 수 있어요.\n가전을 추가하면 바로 여기서 쓸 수 있어요.',
          onAdd: () => context.go('/'),
        ),
      );
    }

    // 음성 인식을 쓸 수 없는 기기. 마이크를 그려 두고 눌러도 안 되게 하지
    // 않는다 -- 무엇이 안 되는지와 대신 갈 길을 말한다.
    if (_voiceUnavailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('음성 명령')),
        body: _VoiceUnavailableNotice(
          appliance: appliance,
          onManual: () => context.go('/manual-control'),
          onRetry: _toggle,
        ),
      );
    }

    // 내장 가전(전자레인지)만 실제로 매칭되는 규칙이 있어서 그 예시를 쓰고,
    // 사용자 정의 가전은 등록된 실제 버튼 라벨로 예시를 만든다 — 안 그러면
    // "즉석밥 데워줘" 힌트가 즉석밥 버튼도 없는 가전에서도 그대로 보이게 된다.
    final hintExample = appliance.isCustom && appliance.buttons.isNotEmpty
        ? '예: ${appliance.buttons.first.label} 해줘'
        : '예: 즉석밥 데워줘';

    // 큰 글씨에서는 두 버튼을 나란히 두면 '다시 말하기'가 단어 중간에서
    // 꺾인다. 세로로 쌓고 주 행동을 위에 둔다(제안 화면과 같은 규칙).
    final stacked = MediaQuery.textScalerOf(context).scale(1) >= 1.5;

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
                    const SizedBox(height: 12),

                    // ── 어느 가전에게 말하는가 ─────────────────────────────
                    // 여러 가전을 다루므로 말이 어디로 가는지 먼저 보여야
                    // 한다. 엉뚱한 가전에 대고 말한 뒤에 알면 늦다.
                    _TargetLine(appliance: appliance),
                    const SizedBox(height: 20),

                    // ── 웨이브 비주얼라이저 ────────────────────────────────────────
                    _WaveVisualizer(active: listening, level: _soundLevel),
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
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: context.appOutline,
                                ),
                              ),
                              child: Text(
                                text,
                                style: AppText.title
                                    .copyWith(color: context.appInk),
                                textAlign: TextAlign.center,
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    // 언제 듣기가 끝나는지 미리 말한다. 생각하다 멈춘 사이에
                    // 조용히 끝나 버리면, 사용자는 마이크가 고장 났다고 여긴다.
                    Text(
                      listening
                          ? '${VoiceService.silenceTimeout.inSeconds}초 동안 조용하면 듣기를 멈추고 확인을 물어요.'
                          : '말이 끝나면 내용을 확인한 뒤 실행해요.',
                      style: TextStyle(color: context.appMuted, fontSize: 14),
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
              _ActionPair(
                stacked: stacked,
                primary: FilledButton.icon(
                  onPressed: _sending ? null : _restartListening,
                  icon: const Icon(Icons.mic, size: 20),
                  label: const Text('다시 말하기'),
                ),
                secondary: OutlinedButton.icon(
                  onPressed:
                      _sending ? null : () => context.go('/manual-control'),
                  icon: const Icon(Icons.grid_view_rounded, size: 20),
                  label: const Text('버튼으로 조작'),
                ),
              ),
            ] else if (text.trim().isNotEmpty) ...[
              _ActionPair(
                stacked: stacked,
                primary: FilledButton(
                  onPressed: _sending ? null : () => _send(text),
                  child: Text(_sending ? '보내는 중…' : '이대로 실행'),
                ),
                secondary: OutlinedButton(
                  onPressed: _sending ? null : _restartListening,
                  child: const Text('다시 말하기'),
                ),
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

// ── 주/부 행동 한 쌍 ──────────────────────────────────────────────────────

/// 보통은 나란히(부 3 : 주 4), 큰 글씨에서는 주 행동을 위에 두고 세로로.
class _ActionPair extends StatelessWidget {
  const _ActionPair({
    required this.stacked,
    required this.primary,
    required this.secondary,
  });

  final bool stacked;
  final Widget primary;
  final Widget secondary;

  @override
  Widget build(BuildContext context) => stacked
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [primary, const SizedBox(height: 8), secondary],
        )
      : Row(
          children: [
            Expanded(flex: 3, child: secondary),
            const SizedBox(width: 12),
            Expanded(flex: 4, child: primary),
          ],
        );
}

// ── 어느 가전에게 ────────────────────────────────────────────────────────

class _TargetLine extends StatelessWidget {
  const _TargetLine({required this.appliance});

  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(appliance.icon, size: 18, color: context.appMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${appliance.displayName}에게',
              style: TextStyle(fontSize: 16, color: context.appMuted),
            ),
          ),
          if (appliance.isDemo) ...[
            const SizedBox(width: 8),
            const DemoBadge(),
          ],
        ],
      );
}

// ── 음성 인식을 쓸 수 없는 기기 ──────────────────────────────────────────

/// 권한이 꺼져 있거나 엔진이 없다. '다시 말하기'는 답이 아니다 -- 버튼
/// 조작이라는 다른 길을 먼저 내밀고, 권한을 고친 뒤 돌아올 길을 둔다.
class _VoiceUnavailableNotice extends StatelessWidget {
  const _VoiceUnavailableNotice({
    required this.appliance,
    required this.onManual,
    required this.onRetry,
  });

  final ApplianceMap appliance;
  final VoidCallback onManual;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.mic_off_outlined, size: 52, color: context.appMuted),
              const SizedBox(height: 18),
              Text(
                '이 기기에서 음성 인식을 쓸 수 없어요',
                textAlign: TextAlign.center,
                style: AppText.title,
              ),
              const SizedBox(height: 8),
              Text(
                '마이크 권한이 꺼져 있거나 음성 인식 기능이 없어요.\n'
                '${appliance.displayName}은 버튼으로 그대로 조작할 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: context.appMuted),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onManual,
                icon: const Icon(Icons.touch_app, size: 20),
                label: const Text('버튼으로 조작'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('권한을 고쳤어요 — 다시 확인'),
              ),
            ],
          ),
        ),
      );
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

// ── 듣는 중 표시 (5개 바) ────────────────────────────────────────────────

/// 마이크가 **실제로 듣고 있는 크기**를 보여준다.
///
/// 예전에는 정해진 반복 애니메이션이었다. 마이크가 아무것도 못 듣고 있어도
/// 똑같이 춤을 춰서, 인식이 안 될 때 사용자가 "더 크게 말할지 / 마이크가
/// 죽었는지"를 판단할 근거를 화면이 지워버렸다. 잘 듣고 있다는 인상만
/// 남기고 사실은 아무것도 알려주지 않는 표시였다.
class _WaveVisualizer extends StatelessWidget {
  const _WaveVisualizer({required this.active, required this.level});

  final bool active;

  /// 엔진이 준 음량. 값이 null이면 아직(또는 영영) 값이 없다는 뜻이다.
  final ValueListenable<double?> level;

  // 바마다 높이 범위가 달라야 자연스러운 파형처럼 보임
  static const _minHeights = [10.0, 18.0, 28.0, 18.0, 10.0];
  static const _maxHeights = [24.0, 38.0, 56.0, 38.0, 24.0];

  /// 0~1로 정규화. 음량 단위는 플랫폼마다 달라서(안드로이드는 RMS, iOS는
  /// dB) **상대적인 크기**로만 쓴다 -- 정확한 수치인 척하지 않는다.
  /// 값이 없으면 0: 바가 최소 높이로 가만히 있어 "듣는 중이지만 아무 소리도
  /// 안 들어온다"를 그대로 보여준다.
  double _scale(double? value) {
    if (!active || value == null) return 0;
    return (value / 10).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double?>(
        valueListenable: level,
        builder: (context, value, __) => _bars(context, _scale(value)),
      );

  Widget _bars(BuildContext context, double scale) {
    return SizedBox(
      height: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(5, (i) {
          return Padding(
            // 테스트가 막대 하나를 집어 높이를 재기 위한 열쇠.
            key: ValueKey('wave-bar-$i'),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              // 음량은 띄엄띄엄 오므로 사이를 짧게 이어 붙인다. 없는 움직임을
              // 만들지는 않는다 -- 값이 안 오면 높이가 그대로 머문다.
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: 7,
              height:
                  _minHeights[i] + (_maxHeights[i] - _minHeights[i]) * scale,
              decoration: BoxDecoration(
                color: active
                    ? context.appPrimary
                    : context.appMuted.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        }),
      ),
    );
  }
}
