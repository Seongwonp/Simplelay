import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
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
import '../theme/app_text.dart';

class SuggestionScreen extends ConsumerWidget {
  const SuggestionScreen({required this.sequenceId, super.key});

  final String sequenceId;

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
  }) async {
    final rpiApi = ref.read(rpiApiServiceProvider);
    if (suggestion.source == SuggestionSource.http && rpiApi != null) {
      try {
        await rpiApi.rejectSuggestion(suggestion.sequenceId, mute: mute);
      } on RpiApiException catch (error) {
        if (error.statusCode != 404) {
          if (context.mounted) {
            _notifyError(context, '거부를 전달하지 못했어요. 연결을 확인해주세요.');
          }
          return;
        }
      } catch (_) {
        if (context.mounted) {
          _notifyError(context, '거부를 전달하지 못했어요. 연결을 확인해주세요.');
        }
        return;
      }
    }
    await ref.read(suggestionProvider.notifier).respond(suggestion, false);
    if (!context.mounted) return;
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
        content: const Text('이 제안은 앞으로 표시하지 않아요.'),
        duration: const Duration(seconds: 6),
        action: api == null
            ? null
            : SnackBarAction(
                label: '되돌리기',
                onPressed: () async {
                  try {
                    await api.unmuteSuppression(purpose);
                    messenger.showSnackBar(
                      const SnackBar(content: Text('다시 표시할게요.')),
                    );
                  } catch (_) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('되돌리지 못했어요. 설정에서 해제할 수 있어요.'),
                      ),
                    );
                  }
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(suggestionProvider);
    final suggestion =
        items.where((s) => s.sequenceId == sequenceId).firstOrNull;

    if (suggestion == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('제안 확인')),
        body: const Center(child: Text('제안을 찾을 수 없습니다.')),
      );
    }

    // 제안이 대상을 알려주면 그 가전으로 그린다 -- 전역 선택값을 쓰면
    // 화면이 보여주는 버튼과 실제 눌릴 버튼이 어긋날 수 있다.
    final selected = ref.watch(selectedApplianceProvider);
    final all = ref.watch(allAppliancesProvider);
    final target = suggestion.applianceId == null
        ? null
        : all.where((a) => a.id == suggestion.applianceId).firstOrNull;

    // 대상을 명시했는데 그 가전을 모르겠다면, 현재 선택 가전으로 **바꿔
    // 그리지 않는다.** 예전에는 조용히 폴백해서, 지운 선풍기의 제안이
    // 전자레인지 지도를 달고 나오고 승인까지 눌리게 했다. 서버도 이제
    // 그 실행을 404로 거절하므로(R1), 화면이 승인 버튼을 내걸면 누를 수
    // 있는데 안 되는 버튼이 된다.
    if (suggestion.applianceId != null && target == null) {
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
    final appliance = target ?? selected;

    return Scaffold(
      appBar: AppBar(title: const Text('제안 확인')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        children: [
          // 큰 스파클 원을 없앴다. "AI 기능"이라는 표시일 뿐 무엇에 대한 제안인지는
          // 알려주지 않았고, 화면에서 가장 큰 자리를 장식이 차지하고 있었다.
          // 어느 가전인지는 아래 버튼맵의 가전 칩이 이미 말해준다.

          // ── 제목 ────────────────────────────────────────────────────────
          // label은 사용자가 예전에 했던 말 그대로다 -- 그대로 되물어본다.
          // 무엇을 조작할지부터 말한다 -- 여러 가전을 다루므로 대상이
          // 먼저 보여야 사용자가 맡길지 판단할 수 있다.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(appliance.icon, size: 18, color: context.appMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  appliance.name,
                  style: TextStyle(color: context.appMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${suggestion.label}, 지금 할까요?',
            textAlign: TextAlign.center,
            style: AppText.heading,
          ),
          // 왜 지금 이게 떴는지. 환경 제안은 서버가 준 근거, 패턴 제안은
          // 시간대·횟수로 만든 한 문장이다(데모는 비어 있다).
          if (suggestion.whyNow.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              suggestion.whyNow,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appMuted),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '이 순서로 버튼을 눌러요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appMuted),
          ),

          const SizedBox(height: 24),

          // ── 버튼맵 그리드 ────────────────────────────────────────────────
          _ButtonMapGrid(appliance: appliance, steps: suggestion.steps),

          const SizedBox(height: 28),

          // ── 단계 타임라인 ────────────────────────────────────────────────
          ...List.generate(suggestion.steps.length, (i) {
            final code = suggestion.steps[i];
            final isLast = i == suggestion.steps.length - 1;
            return _StepRow(
              index: i,
              code: code,
              isLast: isLast,
            );
          }),

          const SizedBox(height: 32),

          // ── 거부 / 승인 버튼 ─────────────────────────────────────────────
          Row(
            children: [
              // 폭 비율은 키오스크와 같게(3:4) -- 1:2로 두면 '이번만 넘기기'가
              // 기본 글씨에서도 단어 중간에서 줄바꿈된다. 문구는 두 화면이
              // 같아야 손버릇이 생기므로 폭을 넓히는 쪽으로 맞춘다.
              Expanded(
                flex: 3,
                child: OutlinedButton(
                  onPressed: () =>
                      _dismissSuggestion(context, ref, suggestion, mute: false),
                  child: const Text('이번만 넘기기'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: FilledButton.icon(
                  onPressed: () async {
                    final rpiApi = ref.read(rpiApiServiceProvider);
                    if (suggestion.source == SuggestionSource.http &&
                        rpiApi != null) {
                      try {
                        // HTTP: RPi에 승인 전송 — 즉시 job_id 접수, 이후 상태
                        // 화면이 /status 폴링으로 이 job의 진행·완료를 따라간다
                        final accepted = await rpiApi
                            .approveSuggestion(suggestion.sequenceId);
                        ref.read(executionStatusProvider.notifier).beginHttpJob(
                              api: rpiApi,
                              jobId: accepted.jobId,
                              label: suggestion.label,
                              steps: suggestion.steps,
                            );
                      } on RpiApiException catch (error) {
                        if (context.mounted) {
                          _notifyError(
                            context,
                            error.statusCode == 409
                                ? '다른 작업이 실행 중이에요. 끝난 뒤 다시 시도해주세요.'
                                : '실행 요청을 전달하지 못했어요. 연결을 확인해주세요.',
                          );
                        }
                        return;
                      } catch (_) {
                        if (context.mounted) {
                          _notifyError(
                              context, '실행 요청을 전달하지 못했어요. 연결을 확인해주세요.');
                        }
                        return;
                      }
                    }
                    // BLE 출처일 때만 respond()가 실제로 BLE 응답을 보낸다
                    // (HTTP 출처는 로컬 목록에서 제거만 함 — 위에서 이미 서버에 전달했으므로).
                    await ref
                        .read(suggestionProvider.notifier)
                        .respond(suggestion, true);
                    if (suggestion.source != SuggestionSource.http) {
                      // BLE 경로만 메시지 스트림 기반으로 추적한다. HTTP 경로는
                      // 위에서 beginHttpJob으로 실제 /status 폴링을 이미
                      // 시작했으므로 가짜 센서 주입이 끼면 안 된다.
                      ref
                          .read(executionStatusProvider.notifier)
                          .begin(suggestion);
                      // 가짜 센서·가짜 성공은 **명시적으로 켠 데모 세션**
                      // 에서만. kDebugMode에 걸어두면 실기기에 물린 디버그
                      // 빌드에서도 섞여, 실제로는 안 눌린 실행이 화면에서
                      // 성공으로 끝난다.
                      if (ref.read(demoModeProvider)) {
                        DemoService(ref.read(bleServiceProvider))
                            .runExecutionFlow();
                      }
                    }
                    if (context.mounted) context.go('/status');
                  },
                  icon: const Icon(Icons.play_arrow_rounded),
                  // '승인'은 결재 용어다. 사용자가 하는 일은 결재가 아니라
                  // "지금 시킬지" 정하는 것 -- 키오스크와 같은 문구를 쓴다.
                  label: const Text('지금 실행'),
                ),
              ),
            ],
          ),
          // 영구 억제를 실제로 지킬 수 있는 제안에만 내건다 -- BLE 경로는
          // '이번만 넘기기'와 같은 거절 메시지라 약속을 지킬 수 없다.
          if (suggestion.canMute) ...[
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: () =>
                    _dismissSuggestion(context, ref, suggestion, mute: true),
                icon: const Icon(Icons.notifications_off_outlined, size: 18),
                label: const Text('이 제안 다시 받지 않기'),
              ),
            ),
          ],
        ],
      ),
    );
  }
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
      appBar: AppBar(title: const Text('제안 확인')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.help_outline, size: 40, color: context.appWarning),
            const SizedBox(height: 12),
            Text(
              '대상 가전 정보를 확인해 주세요.',
              textAlign: TextAlign.center,
              style: AppText.heading,
            ),
            const SizedBox(height: 8),
            Text(
              "'${suggestion.label}' 제안이 가리키는 가전을 찾지 못했어요. "
              '다른 기기에서 지웠거나 아직 목록을 받지 못했을 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appMuted),
            ),
            const Spacer(),
            OutlinedButton(
              onPressed: onDismiss,
              child: const Text('이 제안 지우기'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/settings'),
              icon: const Icon(Icons.settings),
              label: const Text('가전 목록 확인'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 버튼맵 그리드 ─────────────────────────────────────────────────────────

class _ButtonMapGrid extends StatelessWidget {
  const _ButtonMapGrid({required this.appliance, required this.steps});

  final ApplianceMap appliance;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    // 시퀀스에서 각 버튼 ID가 몇 번째 순서인지 맵핑 (중복 시 첫 등장 순서)
    final stepOrder = <String, int>{};
    for (var i = 0; i < steps.length; i++) {
      stepOrder.putIfAbsent(steps[i], () => i + 1);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(appliance.icon, color: context.appPrimary, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${appliance.name}의 실제 버튼 배치',
                  style: context.appCaption),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: context.appOverlayFaint,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.appBorderFaint),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            children: List.generate(appliance.rows, (row) {
              return Padding(
                padding:
                    EdgeInsets.only(bottom: row < appliance.rows - 1 ? 8 : 0),
                child: Row(
                  children: List.generate(appliance.cols, (col) {
                    final btn = appliance.buttonAt(col, row);
                    final order = btn != null ? stepOrder[btn.id] : null;
                    final isInSequence = order != null;

                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                            right: col < appliance.cols - 1 ? 8 : 0),
                        child: btn == null
                            ? const SizedBox(height: 52)
                            : AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                height: 52,
                                decoration: BoxDecoration(
                                  color: isInSequence
                                      ? context.appPrimary
                                          .withValues(alpha: 0.2)
                                      : context.appOverlayFaint,
                                  borderRadius: BorderRadius.circular(8),
                                  // 순서에 든 버튼만 테두리를 준다. 나머지까지
                                  // 두르면 전부 눌러도 되는 버튼처럼 보이는데,
                                  // 이 지도는 읽는 그림이지 조작판이 아니다.
                                  border: isInSequence
                                      ? Border.all(
                                          color: context.appPrimary, width: 1.5)
                                      : null,
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Text(
                                      btn.label,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isInSequence
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                        color: isInSequence
                                            ? context.appPrimary
                                            : context.appOnSurfaceFaint,
                                      ),
                                    ),
                                    if (isInSequence)
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: Container(
                                          width: 20,
                                          height: 20,
                                          decoration: BoxDecoration(
                                            color: context.appPrimary,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Center(
                                            child: Text(
                                              '$order',
                                              style: TextStyle(
                                                // 9px는 고령 사용자에게 사실상
                                                // 안 보인다 — 배지째 키웠다
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                // 검정 고정이면 라이트 모드
                                                // (어두운 골드 위)에서 3.78:1
                                                color: context.appOnAccent,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                      ),
                    );
                  }),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// ── 단계 타임라인 행 ──────────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.code,
    required this.isLast,
  });
  final int index;
  final String code;
  final bool isLast;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 인덱스 + 연결선 ──────────────────────────────────────────────
          Column(
            children: [
              // 18% 틴트 위에 같은 강조색 숫자를 얹으면 라이트 모드에서
              // 4.23:1이다 -- 틴트를 옅게 해도 강조색 자신이 상한이라
              // 4.5를 못 넘는다. 순서 숫자는 이 화면에서 읽어야 하는
              // 정보이므로 면을 채우고 대비되는 글자를 얹는다(5.56:1).
              CircleAvatar(
                radius: 16,
                backgroundColor: context.appPrimary,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: context.appOnAccent,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 48,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: AppColors.borderSubtle,
                ),
            ],
          ),
          const SizedBox(width: 14),

          // ── 단계 카드 ─────────────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
              child: Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        _stepIcon(code),
                        color: context.appPrimary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(readableStep(code), style: AppText.body),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );

  IconData _stepIcon(String code) {
    if (code.contains('시작')) return Icons.play_circle_outline;
    if (code.contains('취소') || code.contains('정지')) {
      return Icons.cancel_outlined;
    }
    if (code.contains('해동')) return Icons.ac_unit;
    if (code.contains('시간')) return Icons.timer_outlined;
    if (code.contains('우유')) return Icons.local_drink_outlined;
    if (code.contains('즉석밥')) return Icons.rice_bowl;
    if (code.contains('냉동')) return Icons.kitchen;
    if (code.contains('라면')) return Icons.ramen_dining;
    return Icons.touch_app;
  }
}
