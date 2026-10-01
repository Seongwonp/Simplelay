import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/command_result.dart';
import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/clock_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../widgets/panel_photo_view.dart' show applianceImageOverride;
import '../theme/app_text.dart';
import '../widgets/appliance_panel.dart';
import '../widgets/demo_badge.dart';
import '../widgets/route_badge.dart';
import 'history_screen.dart' show historyProvider;

/// 가전 상세 — 등록 사진 위 버튼(UI 확정 §2).
///
/// **사진 속 버튼을 눌러도 곧바로 누르지 않는다.** 무엇을 누를지 한 번 더
/// 묻고, 승인하면 허브가 대신 누른다. 결과는 실행 상태 화면이 확인 근거와
/// 함께 말한다 -- 여기서 '됐어요'라고 먼저 말하지 않는다.
class ApplianceDetailScreen extends ConsumerWidget {
  const ApplianceDetailScreen({super.key, required this.applianceId});

  final String applianceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliance = ref
        .watch(installedAppliancesProvider)
        .where((a) => a.id == applianceId)
        .firstOrNull;
    if (appliance == null) {
      // 지워졌거나 서버 주소가 바뀌어 사라졌다. 빈 판을 그리지 않는다.
      return Scaffold(
        appBar: AppBar(),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('이 가전을 찾을 수 없어요. 홈에서 다시 골라 주세요.',
              style: TextStyle(fontSize: 16, color: context.appMuted)),
        ),
      );
    }
    final a = appliance;
    final routines = ref.watch(routinesProvider).valueOrNull ?? const <Routine>[];
    final mine = routines.where((r) => r.applianceIds.contains(a.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(child: Text(a.displayName)),
            if (a.isDemo) ...[const SizedBox(width: 8), const DemoBadge()],
            if (a.isThinq) ...[
              const SizedBox(width: 8),
              const RouteBadge(label: 'ThinQ'),
            ],
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          _ReadinessLine(appliance: a),
          const SizedBox(height: 12),
          if (a.isThinq)
            Text(
              '누를 버튼이 없는 ThinQ 가전이에요. 말로 맡기거나 루틴으로 만들어 주세요.',
              style: TextStyle(fontSize: 16, color: context.appMuted),
            )
          else ...[
            Text(
              a.panelMapping != null
                  ? '사진 속 버튼을 누르면 허브가 대신 눌러요. 빨간 원은 정지, 점선은 쉬는 자리예요.'
                  : '버튼을 누르면 허브가 대신 눌러요. 사진으로 등록하면 사진 위에 버튼이 보여요.',
              style: TextStyle(fontSize: 15, color: context.appMuted),
            ),
            const SizedBox(height: 10),
            AppliancePanel(
              appliance: a,
              imageOverride: applianceImageOverride,
              onButton: (b) => _confirmPress(context, ref, a, b),
            ),
          ],
          const SizedBox(height: 20),

          // ── 내 루틴 ───────────────────────────────────────────────────────
          _Card(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('내 루틴 ${mine.length}개',
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        mine.isEmpty
                            ? '이 가전으로 만든 루틴이 없어요'
                            : mine.map((r) => r.name).join(' · '),
                        style: TextStyle(fontSize: 14, color: context.appMuted),
                      ),
                    ],
                  ),
                ),
                if (!a.isThinq)
                  OutlinedButton.icon(
                    // 앱 테마의 버튼은 화면 폭을 채운다(Size.fromHeight). 줄 안에서는
                    // 폭을 내용에 맞춘다 -- 안 그러면 무한 폭 제약으로 무너진다.
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () => _record(context, ref, a),
                    icon: const Icon(Icons.radio_button_checked, size: 18),
                    label: const Text('루틴 녹화'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 오늘 사용 ─────────────────────────────────────────────────────
          _TodayUse(applianceId: a.id),

          if (!a.isThinq) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  ref.read(selectedApplianceProvider.notifier).select(a);
                  context.push('/manual-control');
                },
                icon: const Icon(Icons.grid_view, size: 18),
                label: const Text('버튼판으로 하나씩 누르기'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 녹화 → 편집기. 녹화 화면은 순서(버튼 id)만 돌려주고, 저장은 편집기에서.
  static Future<void> _record(
      BuildContext context, WidgetRef ref, ApplianceMap a) async {
    final buttons = await context.push<List<String>>('/routine/record/${a.id}');
    if (buttons == null || buttons.isEmpty || !context.mounted) return;
    await context.push(
      '/routine/edit',
      extra: Routine(
        name: '${a.name} 루틴',
        steps: [RoutineStep.press(a.id, buttons)],
      ),
    );
  }

  /// 사진 속 버튼 하나를 허브가 대신 누른다 — **확인을 거친다.**
  static Future<void> _confirmPress(
    BuildContext context,
    WidgetRef ref,
    ApplianceMap a,
    ApplianceButton b,
  ) async {
    if (a.readinessKnown && !a.canExecute) {
      _snack(
        context,
        a.readinessReasons.firstOrNull ?? '아직 이 가전을 맡길 수 없어요.',
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("'${b.label}' 버튼을 누를까요?"),
        content: Text(
          "허브가 ${a.displayName}의 '${b.label}' 버튼을 대신 눌러요. "
          '누른 뒤 결과는 실행 상태 화면에서 확인해요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('누르기'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) {
      _snack(context, '허브에 연결되면 누를 수 있어요.');
      return;
    }
    try {
      final accepted = await api.executeButtons([b.label], applianceId: a.id);
      // 공용 실행 상태에 등록한다 -- 이 화면을 떠나도 정지 수단이 남는다.
      ref.read(executionStatusProvider.notifier).beginHttpJob(
            api: api,
            jobId: accepted.jobId,
            label: b.label,
            steps: [b.label],
          );
      if (context.mounted) context.push('/status');
    } on RpiApiException catch (e) {
      if (!context.mounted) return;
      _snack(
        context,
        switch (e.statusCode) {
          409 => '다른 작업이 실행 중이에요. 끝난 뒤 다시 눌러 주세요.',
          412 => e.message,
          _ => '누르기를 보내지 못했어요. 연결을 확인해 주세요.',
        },
      );
    } catch (_) {
      if (context.mounted) _snack(context, '누르기를 보내지 못했어요. 연결을 확인해 주세요.');
    }
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// 지금 맡길 수 있는가 한 줄. **모르는 것을 준비됐다고 말하지 않는다** --
/// 서버가 준비 상태를 알려 준 경우에만 못 쓴다고 단정한다.
class _ReadinessLine extends StatelessWidget {
  const _ReadinessLine({required this.appliance});
  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    if (!(a.readinessKnown && !a.canExecute)) return const SizedBox.shrink();
    final why = a.readinessReasons.firstOrNull ??
        (a.readiness == 'disconnected' ? '아직 연결되지 않았어요' : '아직 준비가 끝나지 않았어요');
    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: context.appWarning),
        const SizedBox(width: 6),
        Expanded(
          child: Text(why,
              style: TextStyle(fontSize: 15, color: context.appWarning)),
        ),
      ],
    );
  }
}

/// 오늘 이 가전으로 한 일. 서버 기록에서 온다 -- 기록이 없으면 지어내지 않는다.
class _TodayUse extends ConsumerWidget {
  const _TodayUse({required this.applianceId});
  final String applianceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider)();
    final entries = ref.watch(historyProvider).valueOrNull ?? const [];
    final today = entries
        .where((e) =>
            e.applianceId == applianceId &&
            e.finishedAt.year == now.year &&
            e.finishedAt.month == now.month &&
            e.finishedAt.day == now.day)
        .take(3)
        .toList();
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('오늘 사용',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          if (today.isEmpty)
            Text('오늘은 아직 사용하지 않았어요',
                style: TextStyle(fontSize: 14, color: context.appMuted))
          else
            for (final e in today)
              Text(
                '${_hm(e.finishedAt)} ${e.purpose ?? '버튼 직접 누름'} · ${_result(e)}',
                style: TextStyle(fontSize: 14, color: context.appMuted),
              ),
        ],
      ),
    );
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 결과는 기록 탭과 같은 규칙(서버 판정)으로만. 모의 실행은 모의라고 적는다 --
  /// 모의 성공을 실제 성공처럼 말하지 않는다.
  static String _result(RpiHistoryEntry e) {
    final word = resultWord(resultKindOf(outcome: e.outcome, status: e.status));
    return e.executionMode == 'mock' ? '$word(모의)' : word;
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.appSurfaceLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: DefaultTextStyle.merge(style: AppText.body, child: child),
      );
}
