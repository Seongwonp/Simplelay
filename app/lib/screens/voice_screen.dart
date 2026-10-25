import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/command_result.dart';
import '../models/intent_proposal.dart';
import '../models/execution_status.dart';
import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/voice_provider.dart';
import '../providers/voice_stop_provider.dart' show isStopPhrase;
import '../services/rpi_api_service.dart';
import '../services/voice_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../models/appliance.dart';
import '../widgets/appliance_artwork.dart';
import '../widgets/demo_badge.dart';
import '../widgets/no_appliance_notice.dart';
import '../theme/app_tokens.dart';

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
  bool _thinking = false;
  int _intentGeneration = 0;
  int _sendSerial = 0;

  void _cancelIntent() {
    _intentGeneration++;
    if (mounted && _thinking) {
      _sendSerial++; // A late cancelled lookup must not unlock a newer submission.
      setState(() {
        _thinking = false;
        _sending = false;
      });
    }
  }

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

  /// 본체가 말을 못 알아듣고 준 '혹시 이것?' 후보·할 수 있는 일 목록(422, 2026-10-19 서버). 고르면 확인부터 다시 묻는다.
  NotUnderstoodHelp? _notUnderstood;

  void _fail(String message) {
    _notice(message);
    if (mounted) setState(() => _recognitionError = message);
  }

  void _clearFailure() {
    if (_recognitionError != null || _notUnderstood != null) {
      setState(() {
        _recognitionError = null;
        _notUnderstood = null;
      });
    }
  }

  /// 후보·할 수 있는 일을 고르면 그 문장을 확인 대기에 올린다 — **바로 실행하지 않는다**('이대로 실행할까요?'를 다시 묻는다).
  void _pickPurpose(String purpose) {
    setState(() {
      _notUnderstood = null;
      _recognitionError = null;
    });
    ref.read(voiceTextProvider.notifier).state = purpose;
  }

  Future<void> _cancelSession() async {
    _cancelIntent();
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
      setState(() => _recognitionError = '말을 알아듣지 못했어요. 다시 말해 주세요.');
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
      _fail('듣기를 시작하지 못했어요. 다시 해 주세요.');
    }
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;
    setState(() => _sending = true);
    final rpiApi = ref.read(rpiApiServiceProvider);
    if (isStopPhrase(trimmed)) {
      // 안전 보고 G7(2026-10-16): "멈춰"·"그만" 같은 정지어는 실행 명령이 아니다. 예전에는 /execute로 보내
      // 서버가 '취소' 버튼을 눌렀고, 서버를 고친 뒤에는 빈 job(`job_id: ""`)을 따라가 '실행 중'으로 머물다
      // '연결이 끊겨…'를 띄웠다. 정지 버튼과 같은 정지를 보낸다(판정은 실행 중 음성 정지와 같은 `isStopPhrase`).
      try {
        await _sendStop(rpiApi);
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    final appliance = ref.read(selectedApplianceProvider);
    if (appliance == null) {
      // 여기까지 오면 안 되지만(마이크가 막혀 있다), 상태가 그 사이 바뀔
      // 수 있다. 조작할 대상 없이 전송하지 않는다.
      setState(() => _sending = false);
      _notice('사용할 가전을 먼저 추가해 주세요.');
      return;
    }

    if (appliance.isCustom && rpiApi == null) {
      // 사용자 정의 가전은 서버 고정 규칙이 없어서 LLM으로 해석해야 하고,
      // BLE 릴레이(ESP32)는 의도 해석을 못 하므로 RPi5 HTTP 직통만 지원한다
      // (버튼 직접 실행 — manual_control_screen과 같은 제약).
      setState(() => _sending = false);
      _notice('말로 하려면 본체와 연결해야 해요. 설정에서 본체 연결을 봐 주세요.');
      return;
    }
    if (rpiApi != null) {
      await _sendToHub(rpiApi, appliance, trimmed);
      return;
    }
    try {
      if (appliance.isThinq) {
        // ThinQ 가전은 서버를 거쳐야 한다 -- BLE 릴레이(ESP32)는 누를 버튼이
        // 없는 가전을 조작할 수 없다.
        _notice('LG 가전은 본체와 연결돼야 쓸 수 있어요. 설정에서 연결을 봐 주세요.');
      } else {
        // BLE 폴백
        await ref
            .read(bleServiceProvider)
            .sendCommand(trimmed, source: 'voice');
        if (mounted) _notice('보냈어요.');
      }
    } catch (_) {
      if (mounted) _notice('블루투스로 보내지 못했어요. 연결을 봐 주세요.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 본체로 보낸다. 보내기 **전에** '보내는 중'으로 들어가 답을 기다리는 사이에도 정지 띠가 있다(검토 10/19).
  ///
  /// 본체가 답하지 않은 실패(시간 초과·연결 끊김·응답 해석 실패)는 **보내지 못했다는 뜻이 아니다** — 본체가 받아 이미
  /// 누르기 시작했을 수 있다(package:http로는 '닿지 못함'과 '보낸 뒤 답 없음'을 믿을 만하게 가르지 못한다). 예전에는 이때
  /// 블루투스로 같은 말을 또 보내 두 번 눌리거나 켠 것을 도로 끌 수 있었다. 이제 블루투스로 다시 보내지 않고 '모름'으로 두어
  /// 정지를 남긴다. 같은 요청을 가려낼 요청 번호가 본체에 생기기 전까지는 다시 보내지 않는다.
  Future<void> _sendToHub(
      RpiApiService rpiApi, ApplianceMap appliance, String text) async {
    final serial = ++_sendSerial;
    final execution = ref.read(executionStatusProvider.notifier);
    final requestId = execution.beginSubmitting(api: rpiApi, label: text);
    try {
      // RPi HTTP 직통 — 즉시 접수(job_id) 후 상태 화면에서 진행 확인
      final accepted = appliance.isCustom
          ? await rpiApi.executeForAppliance(
              text,
              appliance.buttons.map((b) => b.label).toList(),
              applianceId: appliance.id,
              clientRequestId: requestId,
            )
          : await rpiApi.execute(text,
              source: 'voice',
              applianceId: appliance.id,
              clientRequestId: requestId);
      if (accepted.stopped) execution.abandonSubmission(requestId);
      _trackOrShowStop(rpiApi, accepted, text, requestId);
    } on RpiApiException catch (error) {
      execution.abandonSubmission(requestId); // 본체가 답했다 — 받지 않았다
      final help = NotUnderstoodHelp.fromException(error);
      final unconfiguredLegacyParser = appliance.isCustom &&
          error.statusCode == 503 &&
          error.message.startsWith('no LLM client configured');
      if (help != null || error.statusCode == 422 || unconfiguredLegacyParser) {
        if (await _understandFallback(rpiApi, text)) return;
        if (!mounted) return;
      }
      if (help != null) {
        // 새 서버: 못 알아들은 말이면 이유·후보·할 수 있는 일을 화면에 남긴다(스낵바는 금방 사라진다).
        if (mounted) {
          setState(() => _notUnderstood = help);
          _cancelPending();
        }
        return;
      }
      if (error.statusCode == 422) {
        // 옛 서버의 못 알아들은 말도 화면에 남기고 그 말은 지운다 — '이대로 실행'에 그대로 두면 같은 말을 또 보낸다.
        if (mounted) {
          setState(() => _recognitionError = '무슨 말인지 몰랐어요. 다시 말해 주세요.');
          _cancelPending();
        }
        return;
      }
      if (mounted) {
        _notice(switch (error.statusCode) {
          409 => '다른 일을 하는 중이에요. 끝난 뒤 다시 해 주세요.',
          503 => '본체에서 말 알아듣기가 꺼져 있어요. 버튼으로 해 주세요.',
          // 412: 가전이 아직 조작할 준비가 안 됐다. 서버가 무엇이
          // 남았는지 말해주므로 일반 문구로 덮지 않는다 -- 덮으면
          // 사용자가 원인을 가전 고장 쪽에서 찾게 된다.
          412 => _readinessMessage(error),
          _ => '본체에 보내지 못했어요. 연결을 봐 주세요.',
        });
      }
    } catch (_) {
      // 본체가 받았는지 모른다 — 다시 보내지 않고(블루투스로도) 모름으로 두어 정지를 남긴다.
      execution.beginSubmissionUnknown(
          api: rpiApi, label: text, requestId: requestId, byRequest: true);
      if (mounted) {
        _notice('본체가 받았는지 확인하지 못했어요. 다시 보내기 전에 집에서 가전을 확인해야 해요.');
        context.push('/status');
      }
    } finally {
      if (mounted && serial == _sendSerial) setState(() => _sending = false);
    }
  }

  Future<bool> _understandFallback(RpiApiService api, String text) async {
    if (!mounted) return true;
    final generation = ++_intentGeneration;
    bool current() =>
        mounted &&
        generation == _intentGeneration &&
        identical(ref.read(rpiApiServiceProvider), api) &&
        (ModalRoute.of(context)?.isCurrent ?? false);
    setState(() => _thinking = true);
    IntentProposal? proposal;
    try {
      proposal = await api.understandIntent(text);
    } catch (_) {/* Keep the original not-understood explanation. */}
    if (!mounted || !current()) return true;
    setState(() => _thinking = false);
    if (proposal == null) return false;
    final selected = proposal;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(selected.question),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('아니요')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('네')),
              ],
            ));
    if (!current()) return true;
    _cancelPending();
    if (accepted != true) return true;
    await _executeProposal(api, selected, current);
    return true;
  }

  Future<void> _executeProposal(RpiApiService api, IntentProposal proposal,
      bool Function() current) async {
    String? cardId;
    // Routine triggering only creates a card. Check its fingerprint before the existing approval path.
    if (proposal.kind == 'routine') {
      try {
        final result = await api.triggerRoutine(proposal.routineId!);
        if (!current()) return;
        final cards = await api.suggestions();
        if (!current()) return;
        final card =
            cards.where((c) => c.id == result.suggestionId).firstOrNull;
        if (card == null ||
            card.scenarioId !=
                'routine:${proposal.routineId}@${proposal.fingerprint!.substring(0, 12)}') {
          _notice('동작 내용이 바뀌었어요. 다시 골라 주세요.');
          return;
        }
        cardId = card.id;
      } catch (_) {
        if (current()) _notice('동작을 불러오지 못했어요. 다시 골라 주세요.');
        return;
      }
    }
    if (!current()) return;
    final execution = ref.read(executionStatusProvider.notifier);
    final requestId =
        execution.beginSubmitting(api: api, label: proposal.label);
    try {
      final RpiJobAccepted result;
      switch (proposal.kind) {
        case 'buttons':
          result = await api.executeButtons(proposal.buttons,
              applianceId: proposal.applianceId, clientRequestId: requestId);
        case 'thinq':
          result = await api.thinqCommand(
              proposal.applianceId!, proposal.action!, proposal.args,
              clientRequestId: requestId);
        default:
          result =
              await api.approveSuggestion(cardId!, clientRequestId: requestId);
      }
      _trackOrShowStop(api, result, proposal.label, requestId);
    } on RpiApiException catch (error) {
      execution.abandonSubmission(requestId);
      if (mounted) {
        _notice(error.statusCode == 412
            ? _readinessMessage(error)
            : '지금은 실행하지 못했어요. 다시 확인해 주세요.');
      }
    } catch (_) {
      execution.beginSubmissionUnknown(
          api: api,
          label: proposal.label,
          requestId: requestId,
          byRequest: true);
      if (mounted) context.push('/status');
    }
  }

  /// 정지어를 정지로 보낸다(G7). 폰이 따라가는 실행이 있으면 화면 정지 버튼과 **같은 호출**(`emergencyStop`) —
  /// 그 실행의 정지 단계 문장이 상태 화면에 남는다. 따라가는 실행이 없으면 허브에 바로 `POST /stop`(실행 중 음성
  /// 정지와 같은 분기). 어느 쪽도 새 실행을 따라가지 않는다.
  Future<void> _sendStop(RpiApiService? rpiApi) async {
    _cancelPending();
    final phase = ref.read(executionStatusProvider).phase;
    final tracking = phase == ExecutionPhase.waiting ||
        phase == ExecutionPhase.running ||
        phase == ExecutionPhase.retrying ||
        phase == ExecutionPhase.unknown;
    if (tracking) {
      await ref.read(executionStatusProvider.notifier).emergencyStop();
      if (!mounted) return;
      final message = ref.read(executionStatusProvider).message;
      if (message != null && message.isNotEmpty) _notice(message);
      context.push('/status');
      return;
    }
    if (rpiApi == null) {
      // 허브 없이 BLE만 — 정지 버튼의 대체 경로와 같은 정지 프레임.
      final sent = await ref.read(bleServiceProvider).emergencyStop();
      if (mounted) {
        _notice(sent ? '멈추라고 보냈어요.' : '멈추라고 보내지 못했어요. 다시 말해 주세요.');
      }
      return;
    }
    try {
      final outcome = await rpiApi.stop();
      if (mounted) _notice(_stopNotice(outcome));
    } on TimeoutException {
      // 응답 시간 초과는 '보내지 못함'이 아니라 '전달 여부 모름'이다. 정지는 다시 보내도 안전하다.
      if (mounted) {
        _notice('멈추라고 보냈는데 답이 없어요. 멈추지 않았으면 다시 말해 주세요.');
      }
    } catch (_) {
      if (mounted) _notice('멈추라고 보내지 못했어요. 다시 말해 주세요.');
    }
  }

  /// 정지 결과 한 줄 — 서버가 알린 정지 단계까지만 말한다(정지 버튼과 같은 문장). 단계가 없으면 실행 중이었는지로 가른다.
  static String _stopNotice(StopOutcome? outcome) {
    if (outcome == null) return '멈추라고 보냈어요.';
    return stopLevelSentence(outcome.stopLevel, ackMs: outcome.ackMs) ??
        (outcome.wasRunning ? '멈추라고 보냈어요.' : '멈추라고 보냈어요. 하던 일은 없었어요.');
  }

  /// 접수 응답 처리. 서버가 발화를 정지어로 받아 정지했으면(`status: stopped`, G7 두 번째 방어) 정지 문구만 보이고
  /// 따라가지 않는다 — 그 응답의 `job_id`는 새 실행이 아니다(멈춘 실행이거나 빈 문자열). 멈춘 실행을 폰이 따라가고
  /// 있었다면 그 추적이 결과를 받는다.
  void _trackOrShowStop(RpiApiService api, RpiJobAccepted accepted,
      String label, String requestId) {
    if (accepted.stopped) {
      _cancelPending();
      if (mounted) _notice(_stopNotice(accepted.stop));
      return;
    }
    _trackJob(api, accepted.jobId, label, requestId);
  }

  // 접수된 job을 상태 화면에서 실시간으로 따라가게 하고 그 화면으로 이동한다.
  // 음성 경로는 서버가 해석한 버튼 시퀀스를 미리 모르므로 steps 없이 시작 —
  // 진행률·완료 판정은 /status 폴링이 채운다.
  void _trackJob(
      RpiApiService api, String jobId, String label, String requestId) {
    ref.read(executionStatusProvider.notifier).beginHttpJob(
          api: api,
          jobId: jobId,
          label: label,
          requestId: requestId,
        );
    if (mounted) context.push('/status');
  }

  /// 412(준비 안 됨) 안내 — 서버가 준 사유를 그대로 싣는다.
  static String _readinessMessage(RpiApiException error) {
    final detail = error.message.trim();
    return detail.isEmpty ? '이 가전은 아직 준비되지 않았어요.' : '아직 준비되지 않았어요. $detail';
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    _intentGeneration++;
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
    ref.listen(selectedApplianceProvider, (previous, next) {
      if (previous?.id != next?.id) _cancelIntent();
    });
    ref.listen(rpiApiServiceProvider, (previous, next) {
      if (!identical(previous, next)) _cancelIntent();
    });

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
        appBar: AppBar(title: const Text('말로 하기')),
        body: NoApplianceNotice(
          title: '사용할 가전을 먼저 추가해 주세요',
          body: '가전을 추가하면 여기서 말로 시킬 수 있어요.',
          onAdd: () => context.go('/'),
        ),
      );
    }

    // 음성 인식을 쓸 수 없는 기기. 마이크를 그려 두고 눌러도 안 되게 하지
    // 않는다 -- 무엇이 안 되는지와 대신 갈 길을 말한다.
    if (_voiceUnavailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('말로 하기')),
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
    // LG 가전은 누를 버튼이 없어서 종류 이름으로 말한다(본체 규칙: '공기청정기 켜줘'·'세탁 시작해줘',
    // 이름 없는 '켜 줘'는 받지 않는다 — 첫 사용자 검토 10/19).
    final hintExample = appliance.isThinq
        ? switch (appliance.category) {
            ApplianceCategory.washingMachine => '예: 세탁 시작해 줘',
            ApplianceCategory.other => '예: ${appliance.name} 켜 줘',
            final c => '예: ${c.label} 켜 줘',
          }
        : appliance.isCustom && appliance.buttons.isNotEmpty
            ? '예: ${appliance.buttons.first.label} 해줘'
            : '예: 즉석밥 데워줘';

    // 큰 글씨에서는 두 버튼을 나란히 두면 '다시 말하기'가 단어 중간에서
    // 꺾인다. 세로로 쌓고 주 행동을 위에 둔다(제안 화면과 같은 규칙).
    final stacked = MediaQuery.textScalerOf(context).scale(1) >= 1.5;

    return Scaffold(
      appBar: AppBar(title: const Text('말로 하기')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxxl),
        child: Column(
          children: [
            if (_thinking) ...[
              Semantics(liveRegion: true, child: const Text('생각하고 있어요…')),
              TextButton(
                  key: const Key('intent-cancel'),
                  onPressed: _cancelIntent,
                  child: const Text('취소')),
            ],
            // 인식 문장이 길거나 글씨를 키우면 내용이 화면을 넘긴다.
            // 본문은 스크롤하고, 실행/취소는 아래에 고정해 항상 닿게 한다.
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: AppSpace.md),

                    // ── 어느 가전에게 말하는가 ─────────────────────────────
                    // 여러 가전을 다루므로 말이 어디로 가는지 먼저 보여야
                    // 한다. 엉뚱한 가전에 대고 말한 뒤에 알면 늦다.
                    _TargetLine(appliance: appliance),
                    const SizedBox(height: AppSpace.xl),

                    // ── 웨이브 비주얼라이저 ────────────────────────────────────────
                    _WaveVisualizer(active: listening, level: _soundLevel),
                    const SizedBox(height: AppSpace.xxxl),

                    // ── 마이크 버튼 ────────────────────────────────────────────────
                    _MicButton(
                      listening: listening,
                      onTap: _sending ? null : _toggle,
                    ),
                    const SizedBox(height: AppSpace.xxxl),

                    // ── 상태 텍스트 ────────────────────────────────────────────────
                    Text(
                      listening
                          ? '듣고 있어요…'
                          : text.trim().isEmpty
                              ? '마이크를 눌러 말해보세요'
                              : '이대로 할까요?',
                      style: AppText.title,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpace.md),

                    // ── 인식된 텍스트 라이브 표시 ──────────────────────────────────
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: text.isEmpty
                          ? (_notUnderstood != null
                              ? _NotUnderstoodPanel(
                                  key: const ValueKey('not-understood'),
                                  help: _notUnderstood!,
                                  applianceName: appliance.displayName,
                                  onPick: _sending ? null : _pickPurpose,
                                )
                              : _recognitionError == null
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
                                  horizontal: AppSpace.lg,
                                  vertical: AppSpace.md),
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
                    const SizedBox(height: AppSpace.sm),
                    // 언제 듣기가 끝나는지 미리 말한다. 생각하다 멈춘 사이에
                    // 조용히 끝나 버리면, 사용자는 마이크가 고장 났다고 여긴다.
                    Text(
                      listening
                          ? '${VoiceService.silenceTimeout.inSeconds}초 동안 조용하면 듣기를 멈추고 물어봐요.'
                          : '말이 끝나면 한 번 물어본 뒤 해요.',
                      style: TextStyle(
                          color: context.appMuted, fontSize: AppFont.caption),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: AppSpace.xxl),
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
            else if (text.trim().isEmpty &&
                (_recognitionError != null || _notUnderstood != null)) ...[
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
                  label: const Text('버튼으로 하기'),
                ),
              ),
            ] else if (text.trim().isNotEmpty) ...[
              _ActionPair(
                stacked: stacked,
                primary: FilledButton(
                  onPressed: _sending ? null : () => _send(text),
                  child: Text(_sending ? '보내는 중…' : '이대로 하기'),
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
            const SizedBox(height: AppSpace.xxxl),
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
          children: [primary, const SizedBox(height: AppSpace.sm), secondary],
        )
      : Row(
          children: [
            Expanded(flex: 3, child: secondary),
            const SizedBox(width: AppSpace.md),
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
          ApplianceArtwork(category: appliance.category, size: 24),
          const SizedBox(width: AppSpace.sm),
          Flexible(
            child: Text(
              '${appliance.displayName}에게',
              style:
                  TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ),
          if (appliance.isDemo) ...[
            const SizedBox(width: AppSpace.sm),
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
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.xxxl, vertical: AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.mic_off_outlined, size: 52, color: context.appMuted),
              const SizedBox(height: AppSpace.xl),
              Text(
                '이 폰에서는 말로 하기를 쓸 수 없어요. 버튼으로 해 주세요',
                textAlign: TextAlign.center,
                style: AppText.title,
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                '마이크 권한이 꺼져 있거나 말 알아듣기 기능이 없어요.\n'
                '${appliance.displayName}은 버튼으로 그대로 쓸 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppFont.caption, color: context.appMuted),
              ),
              const SizedBox(height: AppSpace.xxl),
              FilledButton.icon(
                onPressed: onManual,
                icon: const Icon(Icons.touch_app, size: 20),
                label: const Text('버튼으로 하기'),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('권한을 켰어요. 다시 보기'),
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
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg, vertical: AppSpace.md),
        decoration: BoxDecoration(
          color: context.appWarning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.appWarning.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: context.appWarning, size: 20),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(message, textAlign: TextAlign.start),
            ),
          ],
        ),
      );
}

// ── 못 알아들었을 때 ─────────────────────────────────────────────────────

/// 본체가 준 이유 한 줄, '혹시 이것인가요?' 후보, 이 가전이 할 수 있는 일. 버튼은 모두 **확인으로** 간다 — 실행 아님.
class _NotUnderstoodPanel extends StatelessWidget {
  const _NotUnderstoodPanel({
    required this.help,
    required this.applianceName,
    required this.onPick,
    super.key,
  });

  final NotUnderstoodHelp help;
  final String applianceName;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) {
    final suggestion = help.suggestion;
    final pick = onPick;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FailureNote(
          message: help.detail.trim().isEmpty ? '무슨 말인지 몰랐어요.' : help.detail,
        ),
        if (suggestion != null) ...[
          const SizedBox(height: AppSpace.md),
          FilledButton.tonal(
            onPressed: pick == null ? null : () => pick(suggestion.purpose),
            child: Text('혹시 이것인가요? ${suggestion.label}',
                textAlign: TextAlign.center),
          ),
        ],
        if (help.choices.isNotEmpty) ...[
          const SizedBox(height: AppSpace.lg),
          Text(
            '$applianceName${_subjectParticle(applianceName)} 할 수 있는 일이에요',
            style: AppText.body.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final choice in help.choices)
                OutlinedButton(
                  onPressed: pick == null ? null : () => pick(choice.purpose),
                  child: Text(choice.label),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '이렇게 말해 보세요: ${help.choices.first.purpose}',
            style:
                TextStyle(color: context.appMuted, fontSize: AppFont.caption),
          ),
        ],
      ],
    );
  }
}

/// '이'/'가' — 끝 글자 받침을 본다. 한글이 아니면 '가'.
String _subjectParticle(String word) {
  if (word.isEmpty) return '가';
  final c = word.runes.last;
  if (c < 0xAC00 || c > 0xD7A3) return '가';
  return (c - 0xAC00) % 28 == 0 ? '가' : '이';
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
        label: listening ? '듣기 끝내기' : '말하기 시작',
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
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
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
