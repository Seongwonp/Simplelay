import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/auto_rule.dart';
import '../models/command_result.dart';
import '../models/line_break.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
import '../providers/demo_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/demo_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../theme/app_text.dart';
import '../widgets/appliance_portrait.dart';
import '../widgets/auto_rule_confirm_sheet.dart';
import '../widgets/button_map_grid.dart';
import '../widgets/demo_badge.dart';
import '../widgets/route_badge.dart';
import '../theme/app_tokens.dart';

/// 제안 하나를 확인하고 맡길지 정하는 화면.
///
/// 읽는 순서가 곧 판단 순서다: **어느 가전을 → 무엇을 하려고 → 어떤 버튼을
/// 어떤 순서로** 누르는지. 그다음에야 맡길지 정할 수 있다. 그래서 대상
/// 가전이 질문보다 먼저 오고, 버튼 순서는 장식 없이 라벨과 번호만 남긴다.
/// 주 행동은 스크롤과 무관하게 아래에 고정한다 -- 6단계짜리 제안에서 실행
/// 버튼이 화면 밖으로 밀리면, 확인한 뒤 다시 찾아 내려가야 한다.
class SuggestionScreen extends ConsumerWidget {
  const SuggestionScreen({required this.sequenceId, super.key});

  final String sequenceId;

  Future<void> _revise(BuildContext context, WidgetRef ref, Suggestion suggestion) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) return;
    try {
      final options = await api.revisionOptions(suggestion.sequenceId);
      if (!context.mounted) return;
      if (options.isEmpty) {
        _notifyError(context, '이 가전에는 바꿀 수 있는 다른 동작이 없어요.');
        return;
      }
      final purpose = await showDialog<String>(context: context, builder: (dialogContext) => SimpleDialog(
        title: const Text('이번 동작 바꾸기. 고르기만 하고 아직 하지 않아요'),
        children: options.entries.map((e) => SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, e.key),
          child: Text('${e.key}\n${e.value.join(' → ')}'),
        )).toList(),
      ));
      if (purpose == null || !context.mounted) return;
      final revised = await api.reviseSuggestion(suggestion.sequenceId, purpose);
      if (!context.mounted) return;
      ref.read(suggestionProvider.notifier).replaceHttp(suggestion.sequenceId, revised);
      context.replace('/suggestion/${revised.id}');
    } catch (_) {
      if (context.mounted) _notifyError(context, '동작을 바꾸지 못했어요. 홈에서 다시 열어 주세요.');
    }
  }

  static void _notifyError(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 거절 공통 -- "이번만 넘기기"(mute=false)와 "다시 추천 안 함"
  /// (mute=true)가 같은 경로를 쓰되 mute만 다르다. mute=true면 서버가
  /// 그 루틴을 억제 목록에 넣어 패턴이 다시 띄우지 않는다.
  static Future<void> _dismissSuggestion(
    BuildContext context,
    WidgetRef ref,
    Suggestion suggestion, {
    required bool mute,
    bool snooze = false,
  }) async {
    final rpiApi = ref.read(rpiApiServiceProvider);
    var paused = false;
    if (snooze && rpiApi == null) {
      _notifyError(context, '쉬기를 본체에 알리지 못했어요. 연결을 봐 주세요.');
      return;
    }
    if (suggestion.source == SuggestionSource.http && rpiApi != null) {
      try {
        if (snooze) {
          await rpiApi.snoozeSuggestion(suggestion.sequenceId);
          paused = true;
        } else {
          await rpiApi.rejectSuggestion(suggestion.sequenceId, mute: mute);
        }
      } on RpiApiException catch (error) {
        if (error.statusCode != 404) {
          if (context.mounted) {
            _notifyError(context, '고른 것을 본체에 알리지 못했어요. 연결을 봐 주세요.');
          }
          return;
        }
      } catch (_) {
        if (context.mounted) {
          _notifyError(context, '고른 것을 본체에 알리지 못했어요. 연결을 봐 주세요.');
        }
        return;
      }
    }
    await ref.read(suggestionProvider.notifier).respond(suggestion, false);
    if (!context.mounted) return;
    if (paused) {
      _notifyError(context, '30분 동안 이 일은 묻지 않을게요. 그 뒤에도 때가 맞을 때만 물어요.');
    }
    if (mute) {
      // 무엇이 바뀌었는지 말하고 물릴 길을 같이 준다 -- 설정 화면까지
      // 찾아 들어가야 되돌릴 수 있으면 되돌릴 수 있는 게 아니다.
      _notifyMuted(context, rpiApi, suggestion.label);
    }
    context.pop();
  }

  /// 억제 직후 안내 + 되돌리기. 되돌리기가 실패하면 조용히 넘어가지 않고
  /// 다시 알린다 -- 억제는 남았는데 풀렸다고 믿으면 더 나쁘다.
  static void _notifyMuted(
    BuildContext context,
    RpiApiService? api,
    String purpose,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('이 일은 앞으로 묻지 않을게요.'),
        duration: const Duration(seconds: 6),
        action: api == null
            ? null
            : SnackBarAction(
                label: '되돌리기',
                onPressed: () async {
                  try {
                    await api.unmuteSuppression(purpose);
                    messenger.showSnackBar(
                      const SnackBar(content: Text('다시 물어볼게요.')),
                    );
                  } catch (_) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('되돌리지 못했어요. 설정에서 다시 풀 수 있어요.'),
                      ),
                    );
                  }
                },
              ),
      ),
    );
  }

  /// 맡긴다. HTTP 출처는 서버 승인 → job 추적, BLE 출처는 응답 전송.
  static Future<void> _approve(
    BuildContext context,
    WidgetRef ref,
    Suggestion suggestion, {
    AutoRuleOffer? allow,
  }) async {
    final rpiApi = ref.read(rpiApiServiceProvider);
    if (suggestion.source == SuggestionSource.http && rpiApi != null) {
      final execution = ref.read(executionStatusProvider.notifier);
      // 아까 보낸 승인의 답을 기다리는 중 — 또 보내면 두 번 보내지고 늦은 답이 엇갈린다(검토 10/19).
      if (execution.admissionInFlight) {
        _notifyError(context, ExecutionStatusNotifier.waitAdmissionNotice);
        return;
      }
      // 승인 뒤의 이름은 질문(purpose)이 아니다 — 루틴·시나리오 이름.
      final label = suggestion.doneLabel(
        scenarioName: ref.read(scenarioNamesProvider).valueOrNull?[suggestion.scenarioId],
      );
      // 보내기 전에 '보내는 중'으로 — 답을 기다리는 사이에도 본체는 이미 시작했을 수 있어 정지 띠를 남긴다(검토 10/19).
      final requestId =
          execution.beginSubmitting(api: rpiApi, label: label, steps: suggestion.steps);
      try {
        // HTTP: RPi에 승인 전송 — 즉시 job_id 접수, 이후 상태 화면이
        // /status 폴링으로 이 job의 진행·완료를 따라간다. '다음부터 자동으로'(allow)면
        // 같은 승인에 확인 화면이 보여 준 허용 내용의 지문을 실어 규칙도 함께 저장한다.
        final accepted = allow == null
            ? await rpiApi.approveSuggestion(suggestion.sequenceId, clientRequestId: requestId)
            : await rpiApi.approveAndAllowSuggestion(
                suggestion.sequenceId, allow.fingerprint, clientRequestId: requestId);
        execution.beginHttpJob(
          api: rpiApi,
          jobId: accepted.jobId,
          label: label,
          steps: suggestion.steps,
          requestId: requestId,
        );
        // 이번 실행은 제출됐지만 자동 허용은 저장되지 않았다(허용 저장 사이 전체 정지 등, 3차 평가 H2) —
        // 실행 추적과 따로 서버 문장을 그대로 알린다. 규칙은 켜지지 않았다.
        final allowFailure = accepted.autoAllowFailure;
        if (allowFailure != null && context.mounted) _notifyError(context, allowFailure);
      } on RpiApiException catch (error) {
        execution.abandonSubmission(requestId); // 본체가 답했다 — 받지 않았다
        if (error.isApprovalChanged) {
          // 승인한 대상·경로·동작이 바뀌었거나 승인이 만료됐다. 서버는 카드를
          // 내렸다 -- 옛 카드를 다시 누르지 않게 지우고 새 목록을 받는다.
          if (context.mounted) {
            _notifyError(context, approvalChangedMessage);
          }
          await ref
              .read(suggestionProvider.notifier)
              .refreshAfterApprovalChanged(suggestion.sequenceId);
          if (context.mounted && context.canPop()) context.pop();
          return;
        }
        if (context.mounted) {
          _notifyError(
            context,
            switch (error.statusCode) {
              409 => '다른 일을 하는 중이에요. 끝난 뒤 다시 해 주세요.',
              // 412: 준비 안 된 가전. 기다린다고 되는 일이 아니므로
              // '잠시 후'라고 하지 않는다. 서버 문장(경로별 이유)이 있으면 그대로.
              412 => error.message.isNotEmpty && suggestion.isScenario
                  ? error.message
                  : '이 가전은 아직 준비가 안 됐어요. '
                      '설정에서 연결을 봐 주세요.',
              // 자동 실행으로 정할 수 없는 카드(물리 누름 등) — 서버 문장 그대로.
              422 when allow != null && error.message.isNotEmpty => error.message,
              _ => '본체에 보내지 못했어요. 연결을 봐 주세요.',
            },
          );
        }
        return;
      } catch (_) {
        // 보냈는데 답이 없다(시간 초과·연결 끊김) — 본체가 승인을 받아 이미 시작했을 수 있다(검토 10/19). '보내지 못했어요'라고
        // 하면 도는 실행을 멈출 길이 없었다. 모름으로 두고 정지를 남기며, 같은 승인을 다시 물어(이미 승인된 카드면 본체가 같은
        // 실행 번호를 준다) 또는 상태로 그 실행을 찾아 이어서 본다.
        execution.beginSubmissionUnknown(
          api: rpiApi,
          label: label,
          steps: suggestion.steps,
          requestId: requestId,
          // 승인에 요청 번호를 실었다 — 새 본체에는 그 번호로 접수한 실행을 묻는다. '다음부터 자동으로'도 번호를 싣지만(다시
          // 물으면 새 본체가 같은 실행을 준다) 그 번호를 조회에 남기지 않는 본체가 있어 조회로 '받지 않음'이라 단정하지 않는다.
          byRequest: allow == null,
          recoverJobId: () async => (allow == null
                  ? await rpiApi.approveSuggestion(suggestion.sequenceId, clientRequestId: requestId)
                  : await rpiApi.approveAndAllowSuggestion(
                      suggestion.sequenceId, allow.fingerprint, clientRequestId: requestId))
              .jobId,
        );
        if (context.mounted) context.pushReplacement('/status');
        return;
      }
    }
    // BLE 출처일 때만 respond()가 실제로 BLE 응답을 보낸다
    // (HTTP 출처는 로컬 목록에서 제거만 함 — 위에서 이미 서버에 전달했으므로).
    await ref.read(suggestionProvider.notifier).respond(suggestion, true);
    if (suggestion.source != SuggestionSource.http) {
      // BLE 경로만 메시지 스트림 기반으로 추적한다. HTTP 경로는 위에서
      // beginHttpJob으로 실제 /status 폴링을 이미 시작했으므로 가짜 센서
      // 주입이 끼면 안 된다.
      ref.read(executionStatusProvider.notifier).begin(suggestion);
      // 가짜 센서·가짜 성공은 **명시적으로 켠 데모 세션**에서만.
      // kDebugMode에 걸어두면 실기기에 물린 디버그 빌드에서도 섞여,
      // 실제로는 안 눌린 실행이 화면에서 성공으로 끝난다.
      if (ref.read(demoModeProvider)) {
        DemoService(ref.read(bleServiceProvider)).runExecutionFlow();
      }
    }
    // 승인 화면을 실행 상태 화면으로 **바꿔 끼운다.** 승인된 카드는 목록에서
    // 빠지므로, 그 위에 쌓으면 실행 상태 화면의 '확인'이 "제안을 찾을 수
    // 없어요." 빈 화면으로 돌아간다(2026-10-13 에뮬레이터). 바꿔 끼우면
    // '확인'·'닫기'는 실행을 시작한 곳(홈·루틴 목록·편집기)으로 간다.
    if (context.mounted) context.pushReplacement('/status');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(suggestionProvider);
    final suggestion =
        items.where((s) => s.sequenceId == sequenceId).firstOrNull;

    if (suggestion == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('할까요?')),
        body: const Center(child: Text('이 알림을 찾을 수 없어요.')),
      );
    }

    // 시나리오 카드는 서버가 확정한 명령(대상·경로·동작)을 그대로 보여 주고
    // 승인한다. ThinQ 가전은 폰의 가전 목록(버튼맵)에 없으므로 아래의 버튼맵
    // 규칙으로 그리면 '대상을 찾지 못함'이 된다.
    if (suggestion.isScenario) {
      return _ScenarioSuggestionScreen(
        suggestion: suggestion,
        onSkip: () =>
            _dismissSuggestion(context, ref, suggestion, mute: false),
        onMute: () => _dismissSuggestion(context, ref, suggestion, mute: true),
        onSnooze: suggestion.source == SuggestionSource.http &&
                !suggestion.isDemo &&
                suggestion.timeBand != '데모'
            ? () => _dismissSuggestion(context, ref, suggestion,
                mute: false, snooze: true)
            : null,
        onRevise: suggestion.source == SuggestionSource.http &&
                suggestion.timeBand != '환경'
            ? () => _revise(context, ref, suggestion)
            : null,
        onRun: () => _approve(context, ref, suggestion),
        // '다음부터도 자동으로' — 서버가 허용 내용을 준 카드(HTTP)만. 물리 누름 카드에는 없다.
        onAllow: switch (suggestion.autoRuleOffer) {
          final offer? when suggestion.source == SuggestionSource.http => () async {
              final ok = await showAutoRuleConfirmSheet(
                context,
                conditionText: offer.conditionText,
                actionText: offer.actionText,
                caveat: offer.caveat,
              );
              if (!ok || !context.mounted) return;
              await _approve(context, ref, suggestion, allow: offer);
            },
          _ => null,
        },
      );
    }

    // 제안이 조작할 **그 가전**으로 그린다. 전역 선택값을 쓰면 화면이
    // 보여주는 버튼과 실제 눌릴 버튼이 어긋난다.
    final installed = ref.watch(installedAppliancesProvider);
    final target = suggestion.applianceId == null
        ? null
        : installed.where((a) => a.id == suggestion.applianceId).firstOrNull;

    // 대상을 알 수 없으면 **현재 선택 가전으로 바꿔 그리지 않는다.**
    // 예전에는 조용히 폴백해서, 지운 선풍기의 제안이 전자레인지 지도를
    // 달고 나오고 승인까지 눌리게 했다. 서버도 그 실행을 404로 거절하므로
    // (R1), 화면이 승인 버튼을 내걸면 누를 수 있는데 안 되는 버튼이 된다.
    //
    // 대상을 아예 안 밝힌 제안(가전 없이 쌓인 옛 이력)도 같다 -- 무엇이
    // 눌릴지 그릴 수 없으면 그리지 않는다.
    if (target == null) {
      return _UnknownTargetScreen(
        suggestion: suggestion,
        onDismiss: () => _dismissSuggestion(
          context,
          ref,
          suggestion,
          mute: false,
        ),
      );
    }
    final appliance = target;

    // 준비 안 된 가전은 **여기서 먼저 막는다.** 서버도 412로 거절하지만,
    // 누를 수 있는 버튼을 두고 눌러 봐야 안 된다고 하면 사용자는 원인을
    // 가전 쪽에서 찾는다. 모르는 것(readinessKnown=false)은 막지 않는다 --
    // 서버가 죽었을 때 조작 수단이 통째로 사라지면 안 된다.
    final blocked = appliance.readinessKnown && !appliance.canExecute;
    final blockedWhy = !blocked
        ? null
        : appliance.readinessReasons.firstOrNull ??
            (appliance.readiness == 'disconnected'
                ? '아직 연결되지 않았어요'
                : '아직 준비가 안 됐어요');

    final more = _moreActions(
      canMute: suggestion.canMute,
      onMute: () => _dismissSuggestion(context, ref, suggestion, mute: true),
      onRevise: suggestion.source == SuggestionSource.http && suggestion.timeBand != '환경'
          ? () => _revise(context, ref, suggestion) : null,
      onSnooze: suggestion.source == SuggestionSource.http && !suggestion.isDemo
          && suggestion.timeBand != '데모'
          ? () => _dismissSuggestion(context, ref, suggestion, mute: false, snooze: true)
          : null,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('할까요?'),
        actions: [if (more.isNotEmpty) _MoreButton(actions: more)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.xxl),
        children: [
          // ── 어느 가전인가 ────────────────────────────────────────────────
          // 여러 가전을 다루므로 대상이 질문보다 먼저 보여야 맡길지 판단할
          // 수 있다. 사진이 있으면 사진, 없으면 종류별 실루엣.
          _TargetHeader(appliance: appliance, stepCount: suggestion.steps.length),

          const SizedBox(height: AppSpace.xl),

          // ── 무엇을 ──────────────────────────────────────────────────────
          // label은 사용자가 예전에 했던 말 그대로다 -- 그대로 되물어본다.
          // 잘라내지 않는다. 긴 말은 줄바꿈해서 다 보여준다.
          if (suggestion.isDemo) const Text('연습용으로 만든 알림이에요', style: AppText.body),
          // 낱말 중간에서 꺾이지 않게('할까|요' 방지, 평가 5차 10/18). 읽을 때는 원문.
          Text(keepWordsTogether('${suggestion.label}, 지금 할까요?'),
              semanticsLabel: '${suggestion.label}, 지금 할까요?', style: AppText.heading),
          // 왜 지금 이게 떴는지. 환경 제안은 서버가 준 근거, 패턴 제안은
          // 시간대·횟수로 만든 한 문장이다(데모는 비어 있다).
          if (suggestion.whyNow.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              keepWordsTogether(suggestion.whyNow),
              semanticsLabel: suggestion.whyNow,
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],

          const SizedBox(height: AppSpace.xxxl),

          // ── 어떤 버튼을, 어떤 순서로 ────────────────────────────────────
          // 단계를 카드 하나하나로 감싸지 않는다. 라벨과 번호가 가장
          // 선명해야 하는데, 카드 테두리·아이콘이 그보다 먼저 보였다.
          Text('누를 순서', style: AppText.title),
          const SizedBox(height: AppSpace.sm),
          _StepList(appliance: appliance, steps: suggestion.steps),

          const SizedBox(height: AppSpace.xxxl),

          // ── 실제 배치에서 어디인가 ──────────────────────────────────────
          // 순서 목록이 주 정보고, 지도는 그것을 실제 버튼판 위에서 다시
          // 확인하는 보조다. 그래서 아래에 두고, 필요할 때 펼친다(2026-10-14 UI 정리).
          _ButtonMapSection(appliance: appliance, steps: suggestion.steps),
        ],
      ),
      // 주 행동은 스크롤과 무관하게 항상 손 닿는 자리에 — 실행·다음에 둘만.
      // 쉬기·동작 바꾸기·다시 받지 않기는 위의 '더 보기'에 둔다(2026-10-14 UI 정리).
      bottomNavigationBar: _ActionBar(
        appliance: appliance,
        stepCount: suggestion.steps.length,
        blockedWhy: blockedWhy,
        onSkip: () => _dismissSuggestion(context, ref, suggestion, mute: false),
        onRun: blocked ? null : () => _approve(context, ref, suggestion),
      ),
    );
  }
}

// ── 대상 가전 머리 ────────────────────────────────────────────────────────

class _TargetHeader extends StatelessWidget {
  const _TargetHeader({required this.appliance, required this.stepCount});

  final ApplianceMap appliance;
  final int stepCount;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppliancePortrait(appliance: appliance, size: 64, borderRadius: 12),
          const SizedBox(width: AppSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(appliance.displayName, style: AppText.title),
                    ),
                    if (appliance.isDemo) ...[
                      const SizedBox(width: AppSpace.sm),
                      const DemoBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  keepWordsTogether('누름 장치가 버튼 $stepCount개를 차례로 눌러요'),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                ),
              ],
            ),
          ),
        ],
      );
}

// ── 누를 순서 ─────────────────────────────────────────────────────────────

/// 번호와 라벨만. 아이콘을 문자열에서 추측해 붙이지 않는다 -- '시작'에
/// 재생 아이콘을 붙이는 식은 맞을 때도 있지만 틀릴 때 아무도 모른다.
class _StepList extends StatelessWidget {
  const _StepList({required this.appliance, required this.steps});

  final ApplianceMap appliance;
  final List<String> steps;

  /// **그 가전의** 버튼 라벨. 등록된 버튼이면 사용자가 붙인 이름 그대로,
  /// 아니면(내장 가전 코드) 전역 표. 아래 지도와 같은 단어를 쓴다.
  String _label(String code) => appliance.buttons.any((b) => b.id == code)
      ? appliance.labelFor(code)
      : readableStep(code);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
              child: Row(
                children: [
                  // 18% 틴트 위에 같은 강조색 숫자를 얹으면 라이트 모드에서
                  // 4.23:1이다. 순서 숫자는 읽어야 하는 정보이므로 면을
                  // 채우고 대비되는 글자를 얹는다(5.56:1).
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: context.appInk,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: context.appOnAccent,
                        fontWeight: FontWeight.w700,
                        fontSize: AppFont.caption,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.lg),
                  Expanded(
                    child: Text(
                      _label(steps[i]),
                      style: const TextStyle(
                        fontSize: AppFont.cardTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i < steps.length - 1)
              Divider(height: 1, color: context.appBorderFaint),
          ],
        ],
      );
}

// ── 하단 고정 행동 ────────────────────────────────────────────────────────

/// 실행 직전 **대상과 단계 수를 한 번 더** 말하고, 선택지는 둘만 둔다:
/// 지금 실행(채움) > 다음에(외곽선). 관리 선택지는 위의 '더 보기'(2026-10-14 UI 정리).
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.appliance,
    required this.stepCount,
    required this.blockedWhy,
    required this.onSkip,
    required this.onRun,
  });

  final ApplianceMap appliance;
  final int stepCount;

  /// 실행할 수 없는 이유. null이면 실행할 수 있다.
  final String? blockedWhy;
  final VoidCallback onSkip;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final skip = OutlinedButton(
      onPressed: onSkip,
      // 키오스크와 같은 말(UI 평가 10/17) — '이번만 넘긴다'는 뜻이 버튼에 드러난다.
      child: const Text('이번엔 안 할게요'),
    );
    final run = FilledButton.icon(
      onPressed: onRun,
      icon: const Icon(Icons.play_arrow_rounded),
      // '승인'은 결재 용어다. 사용자가 하는 일은 결재가 아니라 "지금
      // 시킬지" 정하는 것 -- 키오스크와 같은 문구를 쓴다.
      label: const Text('지금 하기'),
    );
    // 큰 글씨에서는 두 버튼을 나란히 두면 '다음에'가 단어 중간에서
    // 줄바꿈된다. 세로로 쌓고 주 행동을 위에 둔다. 안내 줄은 뺀다(위 머리가 같은 말을 한다).

    return Material(
      key: const Key('suggestion-action-bar'),
      color: context.appBackground,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.sm),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.appBorderFaint)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (blockedWhy != null)
                // 막힌 이유를 버튼 바로 위에서 말한다. 비활성 버튼만 두면
                // 사용자는 왜 안 눌리는지 가전 쪽에서 찾는다.
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: context.appDanger),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          '$blockedWhy. 설정에서 연결을 봐 주세요',
                          style: TextStyle(
                              fontSize: AppFont.caption, color: context.appDanger),
                        ),
                      ),
                    ],
                  ),
                )
              else
                // 실행 직전에 대상과 버튼 수를 한 번 더 말한다.
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Text(
                    '${appliance.displayName}, 버튼 $stepCount개',
                    style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                  ),
                ),
              // 늘 세로로, 주 행동이 위 — 나란히 두면 좁은 폰에서 '이번엔 안 할게 / 요'로 끊겼다(UI 평가 10/17).
              run,
              const SizedBox(height: AppSpace.sm),
              skip,
            ],
          ),
        ),
      ),
    );
  }
}


/// '더 보기' 안의 관리 선택지 하나.
typedef _MoreAction = ({String label, IconData icon, VoidCallback onTap});

/// 관리 선택지(30분 쉬기·이번 동작 바꾸기·다시 받지 않기). 실행·다음에와 한꺼번에 늘어놓으면 다섯 갈래가 되어
/// 무엇이 주 행동인지 흐려졌다(2026-10-14 외부 UI 의견) — 아래 고정 영역에서 빼 '더 보기'에 둔다.
/// 자동 실행 허용('다음부터도 자동으로')은 여기에 넣지 않는다 — 실행과 같은 무게의 결정이라 고정 영역에 남는다.
List<_MoreAction> _moreActions({
  required bool canMute,
  required VoidCallback onMute,
  VoidCallback? onSnooze,
  VoidCallback? onRevise,
}) =>
    [
      if (onSnooze != null)
        (label: '30분 동안 묻지 않기', icon: Icons.snooze, onTap: onSnooze),
      if (onRevise != null)
        (label: '이번 동작 바꾸기', icon: Icons.edit_outlined, onTap: onRevise),
      // 영구 억제를 실제로 지킬 수 있는 제안에만 내건다 -- BLE 경로는 '다음에'와 같은 거절 메시지라
      // 약속을 지킬 수 없다.
      if (canMute)
        (label: '이 일은 다시 묻지 않기', icon: Icons.notifications_off_outlined, onTap: onMute),
    ];

/// 앱바의 '더 보기' — 누르면 아래에서 관리 선택지 목록이 올라온다. 고른 뒤 목록을 먼저 닫고 실행한다
/// (거절은 이 화면을 닫으므로, 목록이 열린 채 실행하면 목록만 닫힌다).
///
/// 낭독 이름은 무엇을 더 보는지 말한다('제안 옵션 더 보기', 화면 글자는 '더 보기'). 목록을 닫으면 초점을
/// 이 버튼으로 되돌린다 — 스위치·키보드로 다루는 사용자가 화면 처음으로 튕기지 않게(2026-10-14 추가 확인).
class _MoreButton extends StatefulWidget {
  const _MoreButton({required this.actions});

  final List<_MoreAction> actions;

  @override
  State<_MoreButton> createState() => _MoreButtonState();
}

class _MoreButtonState extends State<_MoreButton> {
  final _focus = FocusNode(debugLabel: 'suggestion-more');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  List<_MoreAction> get actions => widget.actions;

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<VoidCallback>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final a in actions)
                ListTile(
                  minTileHeight: 56,
                  leading: Icon(a.icon),
                  title: Text(a.label),
                  onTap: () => Navigator.of(sheetContext).pop(a.onTap),
                ),
            ],
          ),
        ),
      ),
    );
    // 고르지 않고 닫았으면 초점을 이 버튼으로 되돌린다. 골랐으면 그 동작이 화면을 바꿀 수 있어 그대로 둔다.
    if (picked == null) {
      if (mounted) _focus.requestFocus();
      return;
    }
    picked();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: AppSpace.xs),
        child: Semantics(
          label: '더 보기',
          button: true,
          container: true,
          excludeSemantics: true,
          onTap: () => _open(context),
          child: TextButton.icon(
            key: const Key('suggestion-more'),
            focusNode: _focus,
            onPressed: () => _open(context),
            icon: const Icon(Icons.more_horiz),
            label: const Text('더 보기'),
          ),
        ),
      );
}

/// 실제 버튼 배치(지도) — 순서 목록을 버튼판 위에서 다시 확인하는 보조라 접어 둔다(2026-10-14 UI 정리).
/// 제목은 늘 보여 무엇을 펼치는지 안다.
class _ButtonMapSection extends StatelessWidget {
  const _ButtonMapSection({required this.appliance, required this.steps});

  final ApplianceMap appliance;
  final List<String> steps;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        key: const Key('suggestion-button-map'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.sm),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(keepWordsTogether('${appliance.displayName}의 실제 버튼 배치'),
            semanticsLabel: '${appliance.displayName}의 실제 버튼 배치', style: AppText.title),
        children: [ButtonMapGrid(appliance: appliance, steps: steps)],
      );
}

// ── 대상 가전을 모를 때 ───────────────────────────────────────────────────

/// 제안이 가리키는 가전을 목록에서 찾지 못했을 때.
///
/// 대개 다른 기기에서 그 가전을 지웠거나, 아직 가전 목록을 받지 못한
/// 상태다. 어느 쪽이든 **무엇이 눌릴지 화면이 말할 수 없으므로** 실행
/// 버튼을 내걸지 않는다.
class _UnknownTargetScreen extends StatelessWidget {
  const _UnknownTargetScreen({
    required this.suggestion,
    required this.onDismiss,
  });

  final Suggestion suggestion;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('할까요?')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.xxl, AppSpace.xxxl, AppSpace.xxl, AppSpace.xxxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.help_outline, size: 40, color: context.appWarning),
            const SizedBox(height: AppSpace.md),
            Text(
              '어느 가전인지 몰라요.',
              textAlign: TextAlign.center,
              style: AppText.heading,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              "'${suggestion.label}'의 가전을 찾지 못했어요. "
              '지워졌거나 이 폰이 목록을 아직 못 받았을 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appMuted),
            ),
            const Spacer(),
            OutlinedButton(
              onPressed: onDismiss,
              child: const Text('이 알림 지우기'),
            ),
            const SizedBox(height: AppSpace.md),
            FilledButton.icon(
              onPressed: () => context.go('/settings'),
              icon: const Icon(Icons.settings),
              label: const Text('가전 목록 보기'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 시나리오 카드 ─────────────────────────────────────────────────────────

/// 승인 재검사 실패(409) 안내. 키오스크와 같은 문장.
const approvalChangedMessage = '내용이 바뀌었어요. 다시 보고 허락해 주세요';

/// GET /scenarios의 이름 표. 실패·옛 서버는 빈 맵 -- 이름 없이 질문만 보인다.
final scenarioNamesProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return const {};
  return api.scenarioNames();
});

/// GET /readiness/{id} — 명령 대상 하나의 경로별 준비 상태. null은 **모름**이다
/// (막지 않는다 -- 서버가 실행 직전에 다시 검사하고 412로 거절한다).
final commandReadinessProvider = FutureProvider.autoDispose
    .family<RpiReadiness?, String>((ref, applianceId) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return null;
  return api.readiness(applianceId);
});

/// 시나리오 제안 확인 — 어느 가전을, 어느 경로로, 무엇을 할지 **서버가 고정한
/// 문장 그대로** 보여 준다. 승인은 이 명령들에만 묶인다(재해석 없음).
class _ScenarioSuggestionScreen extends ConsumerWidget {
  const _ScenarioSuggestionScreen({
    required this.suggestion,
    required this.onSkip,
    required this.onMute,
    required this.onRun,
    this.onSnooze,
    this.onRevise,
    this.onAllow,
  });

  final Suggestion suggestion;
  final VoidCallback onSkip;
  final VoidCallback onMute;
  final VoidCallback onRun;
  final VoidCallback? onSnooze;
  final VoidCallback? onRevise;

  /// '다음부터도 자동으로'(확인 시트 → 허용하고 이번에도 실행). null이면 버튼이 없다.
  final VoidCallback? onAllow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(scenarioNamesProvider).valueOrNull ?? const {};
    final name = names[suggestion.scenarioId];
    // 사용자가 루틴을 직접 실행했으면 제안이 아니다 — 근거·제안 쉬기·다시 받지 않기를 두지 않는다(2026-10-14 UX).
    final userStarted = suggestion.userStarted;
    final canMute = suggestion.canMute && !userStarted;
    final onSnooze = userStarted ? null : this.onSnooze;
    final allPhysical =
        suggestion.commands.every((c) => c.route == 'physical');

    // 준비 상태는 물리 제안과 같은 자리(실행 버튼 바로 위)에서 말한다.
    String? blockedWhy;
    final readiness = <String, RpiReadiness?>{};
    for (final c in suggestion.commands) {
      final r = ref.watch(commandReadinessProvider(c.targetId)).valueOrNull;
      readiness[c.targetId] = r;
      if (blockedWhy == null && r != null && !r.canExecute) {
        final who = c.summary.isNotEmpty ? c.summary : c.targetId;
        blockedWhy = r.reasons.isNotEmpty
            ? '$who. ${r.reasons.first}'
            : '$who. 아직 준비가 안 됐어요';
      }
    }

    final more = _moreActions(
      canMute: canMute,
      onMute: onMute,
      onSnooze: onSnooze,
      onRevise: onRevise,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(userStarted ? '이대로 할까요?' : '할까요?'),
        actions: [if (more.isNotEmpty) _MoreButton(actions: more)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.xxl),
        children: [
          if (suggestion.isDemo)
            const Text('연습용으로 만든 알림이에요', style: AppText.body),
          if (name != null)
            Text(
              name,
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          const SizedBox(height: AppSpace.xs),
          // 서버의 질문 문장 그대로(예: "공기청정기 강풍으로 바꿀까요?").
          Text(suggestion.label, style: AppText.heading),
          if (suggestion.whyNow.isNotEmpty && !userStarted) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              '이유: ${suggestion.whyNow}',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
          const SizedBox(height: AppSpace.xxl),
          Text(allPhysical ? '누를 버튼' : '할 일', style: AppText.title),
          const SizedBox(height: AppSpace.sm),
          for (var i = 0; i < suggestion.commands.length; i++)
            _CommandRow(
              index: i,
              command: suggestion.commands[i],
              readiness: readiness[suggestion.commands[i].targetId],
            ),
          // 안심 문장("승인하면 위 내용 그대로만…"·"누르지 않으면 실행하지 않아요")은 뺐다 — 버튼이 이미 말한다.
          // 쉬기·동작 바꾸기·다시 받지 않기는 위의 '더 보기'(2026-10-14 UI 정리).
        ],
      ),
      bottomNavigationBar: _ScenarioActionBar(
        blockedWhy: blockedWhy,
        onSkip: onSkip,
        onRun: blockedWhy == null ? onRun : null,
        hasAllow: onAllow != null,
        onAllow: blockedWhy == null ? onAllow : null,
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({
    required this.index,
    required this.command,
    required this.readiness,
  });

  final int index;
  final SuggestionCommand command;
  final RpiReadiness? readiness;

  @override
  Widget build(BuildContext context) {
    // 물리 경로는 칩이 없다(routeLabel null, 2026-10-14 UX). ThinQ만 칩을 단다.
    final path = routeLabel(command.route);
    final summary = command.summary.isNotEmpty
        ? command.summary
        : '${command.targetId} ${command.action ?? command.buttons.join(' → ')}';
    final r = readiness;
    return Semantics(
      label: path == null ? '${index + 1}번. $summary' : '${index + 1}번. $summary. $path',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: context.appInk,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: context.appOnAccent,
                    fontWeight: FontWeight.w700,
                    fontSize: AppFont.caption,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary,
                      style: const TextStyle(
                          fontSize: AppFont.cardTitle, fontWeight: FontWeight.w600),
                    ),
                    if (path != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      RouteBadge(label: path),
                    ],
                    if (r != null && !r.canExecute) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        r.reasons.isNotEmpty
                            ? r.reasons.join(', ')
                            : '아직 준비가 안 됐어요',
                        style:
                            TextStyle(fontSize: AppFont.caption, color: context.appDanger),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScenarioActionBar extends StatelessWidget {
  const _ScenarioActionBar({
    required this.blockedWhy,
    required this.onSkip,
    required this.onRun,
    this.hasAllow = false,
    this.onAllow,
  });

  final String? blockedWhy;
  final VoidCallback onSkip;
  final VoidCallback? onRun;

  /// 자동 실행을 고를 수 있는 카드(v4 가열 종료 감지 → 공기청정기). 그러면 세 갈래:
  /// [이번만 실행] [다음부터도 자동으로] [안 할래요]. [onAllow]가 null이면(준비 안 됨) 누를 수 없다.
  final bool hasAllow;
  final VoidCallback? onAllow;

  @override
  Widget build(BuildContext context) {
    final skip = OutlinedButton(
      onPressed: onSkip,
      // 키오스크와 같은 말(UI 평가 10/17).
      child: const Text('이번엔 안 할게요'),
    );
    final run = FilledButton.icon(
      onPressed: onRun,
      icon: const Icon(Icons.play_arrow_rounded),
      label: Text(hasAllow ? '이번만 하기' : '지금 하기'),
    );
    // 세 갈래는 늘 세로로 — 위계: 이번만 실행(채움) > 다음부터도 자동으로(외곽선·아이콘) > 안 할래요(외곽선).
    // 자동 허용은 채움·톤으로 두지 않는다 — 실행과 같은 무게면 떠미는 버튼으로 읽힌다(외부 평가 10/16 p05).
    final why = blockedWhy;
    return Material(
      key: const Key('suggestion-action-bar'),
      color: context.appBackground,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.sm),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.appBorderFaint)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (why != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: context.appDanger),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          why,
                          style: TextStyle(
                              fontSize: AppFont.caption, color: context.appDanger),
                        ),
                      ),
                    ],
                  ),
                ),
              // 늘 세로로(위와 같은 이유, UI 평가 10/17).
              run,
              if (hasAllow) ...[
                const SizedBox(height: AppSpace.sm),
                OutlinedButton.icon(
                  key: const Key('suggestion-allow-auto'),
                  onPressed: onAllow,
                  icon: const Icon(AppIcons.auto),
                  label: const Text('다음부터도 자동으로'),
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              skip,
            ],
          ),
        ),
      ),
    );
  }
}
