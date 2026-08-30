import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items      = ref.watch(suggestionProvider);
    final appliance  = ref.watch(selectedApplianceProvider);
    final suggestion = items.where((s) => s.sequenceId == sequenceId).firstOrNull;

    if (suggestion == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('제안 확인')),
        body: const Center(child: Text('제안을 찾을 수 없습니다.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('제안 확인')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        children: [
          // ── 헤더 아이콘 ─────────────────────────────────────────────────
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: context.appPrimary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.auto_awesome,
                color: context.appPrimary,
                size: 36,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── 제목 ────────────────────────────────────────────────────────
          Text(
            suggestion.label,
            textAlign: TextAlign.center,
            style: AppText.heading,
          ),
          const SizedBox(height: 6),
          Text(
            '아래 순서대로 버튼을 누를까요?',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appMuted),
          ),

          const SizedBox(height: 24),

          // ── 버튼맵 그리드 ────────────────────────────────────────────────
          _ButtonMapGrid(appliance: appliance, steps: suggestion.steps),

          const SizedBox(height: 28),

          // ── 단계 타임라인 ────────────────────────────────────────────────
          ...List.generate(suggestion.steps.length, (i) {
            final code   = suggestion.steps[i];
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
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final rpiApi = ref.read(rpiApiServiceProvider);
                    if (suggestion.source == SuggestionSource.http && rpiApi != null) {
                      try {
                        // HTTP: RPi에 직접 거부 전송
                        await rpiApi.rejectSuggestion(suggestion.sequenceId);
                      } on RpiApiException catch (error) {
                        // 서버에 이미 없는 제안(404)이면 로컬 제거만 하면 되므로
                        // 계속 진행 — 그 외 에러는 사용자에게 알리고 중단.
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
                    // BLE 출처일 때만 respond()가 실제로 BLE 응답을 보낸다
                    // (HTTP 출처는 로컬 목록에서 제거만 함 — 위에서 이미 서버에 전달했으므로).
                    await ref
                        .read(suggestionProvider.notifier)
                        .respond(suggestion, false);
                    if (context.mounted) context.pop();
                  },
                  child: const Text('거부'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () async {
                    final rpiApi = ref.read(rpiApiServiceProvider);
                    if (suggestion.source == SuggestionSource.http && rpiApi != null) {
                      try {
                        // HTTP: RPi에 승인 전송 — 즉시 job_id 접수, 이후 상태
                        // 화면이 /status 폴링으로 이 job의 진행·완료를 따라간다
                        final accepted =
                            await rpiApi.approveSuggestion(suggestion.sequenceId);
                        ref
                            .read(executionStatusProvider.notifier)
                            .beginHttpJob(
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
                          _notifyError(context, '실행 요청을 전달하지 못했어요. 연결을 확인해주세요.');
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
                      // BLE 경로만 메시지 스트림 기반 추적 + 디버그 데모 주입.
                      // HTTP 경로는 위에서 beginHttpJob으로 실제 /status 폴링을
                      // 이미 시작했으므로 가짜 센서 주입이 끼면 안 된다(실패를
                      // 성공처럼 보이게 만들 수 있음).
                      ref
                          .read(executionStatusProvider.notifier)
                          .begin(suggestion);
                      if (kDebugMode) {
                        DemoService(ref.read(bleServiceProvider))
                            .runExecutionFlow();
                      }
                    }
                    if (context.mounted) context.go('/status');
                  },
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('승인하고 실행'),
                ),
              ),
            ],
          ),
        ],
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
            Text(appliance.name, style: context.appCaption),
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
                padding: EdgeInsets.only(
                    bottom: row < appliance.rows - 1 ? 8 : 0),
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
                                      ? context.appPrimary.withValues(alpha: 0.2)
                                      : context.appOverlayFaint,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isInSequence
                                        ? context.appPrimary
                                        : context.appBorderFaint,
                                    width: isInSequence ? 1.5 : 0.5,
                                  ),
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Text(
                                      btn.label,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 12,
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
                                              style: const TextStyle(
                                                // 9px는 고령 사용자에게 사실상
                                                // 안 보인다 — 배지째 키웠다
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black,
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
              CircleAvatar(
                radius: 16,
                backgroundColor: context.appPrimary.withValues(alpha: 0.18),
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: context.appPrimary,
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
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
    if (code.contains('시작'))  return Icons.play_circle_outline;
    if (code.contains('취소') || code.contains('정지')) return Icons.cancel_outlined;
    if (code.contains('해동'))  return Icons.ac_unit;
    if (code.contains('시간'))  return Icons.timer_outlined;
    if (code.contains('우유'))  return Icons.local_drink_outlined;
    return Icons.touch_app;
  }
}
