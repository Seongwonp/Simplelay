import '../models/clock_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/command_result.dart';
import '../models/execution_status.dart';
import '../models/display_status.dart'
    show applianceDisplayLine, isPracticeAppliance, pressDeviceHosts, pressUnavailableNotice;
import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/appliance_sync_provider.dart';
import '../providers/clock_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/panel_photo_view.dart' show applianceImageOverride;
import '../theme/app_text.dart';
import '../widgets/appliance_panel.dart';
import '../widgets/demo_badge.dart';
import '../widgets/route_badge.dart';
import '../widgets/row_menu.dart';
import '../widgets/thinq_state_card.dart';
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
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Text('이 가전을 찾을 수 없어요. 홈에서 다시 골라 주세요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        ),
      );
    }
    final a = appliance;
    // 준비 판정은 서버 항목에서 읽는다 — 이 폰이 저장한 정의는 판정을 들고 있지 않아, 누를 장치가 없는 가전도
    // '누를까요?'를 물은 뒤에야 거절됐다(검토 10/19). 홈 타일과 같은 근거다.
    final catalog = ref.watch(serverApplianceCatalogProvider);
    final source = catalog.readinessFor(a) ?? a;
    final pressNotice =
        pressUnavailableNotice(a, source, pressHosts: pressDeviceHosts(catalog.appliances));
    final routines = ref.watch(routinesProvider).valueOrNull ?? const <Routine>[];
    final mine = routines.where((r) => r.applianceIds.contains(a.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // 연습 가전은 '연습 세탁기'(접근성 감사 10/18, 홈·본체와 같은 표기).
            Flexible(child: Text(applianceDisplayLine(a))),
            if (a.isDemo) ...[const SizedBox(width: AppSpace.sm), const DemoBadge()],
            // 연습 가전에는 'LG 가전'을 쓰지 않는다(출시 검토 10/18).
            if (a.isThinq && !isPracticeAppliance(a)) ...[
              const SizedBox(width: AppSpace.sm),
              const RouteBadge(label: 'LG 가전'),
            ],
          ],
        ),
        // 지우기는 이 화면 위 ⋮ 한 곳(평가 7차 10/18) — 설정의 가전 줄은 모두 > 하나라 줄마다 ⋮와 >가 섞이지 않는다.
        // 지울 수 있는 것은 사용자가 등록한 가전만(LG 가전은 LG 앱에서 관리).
        actions: [
          if (a.isCustom && !a.isThinq)
            RowMenu(
              menuKey: Key('appliance-menu-${a.id}'),
              semanticLabel: '${a.name} 더 보기',
              items: [
                RowMenuItem(
                  key: Key('appliance-delete-${a.id}'),
                  label: '지우기',
                  icon: Icons.delete_outline,
                  danger: true,
                  onSelected: () => _confirmRemove(context, ref, a),
                ),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xxxl),
        children: [
          _ReadinessLine(appliance: source, notice: pressNotice),
          const SizedBox(height: AppSpace.md),
          if (a.isThinq) ...[
            Text(
              'LG 가전이라 누를 버튼이 없어요. 아래에서 바로 바꾸거나 말이나 루틴으로 맡겨 주세요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
            const SizedBox(height: AppSpace.md),
            ThinqStateCard(applianceId: a.id, applianceName: a.displayName),
          ] else ...[
            Text(
              a.panelMapping != null
                  ? '사진 속 버튼을 누르면 누름 장치가 대신 눌러요. 빨간 원은 정지, 점선은 기다리는 자리예요.'
                  : '버튼을 누르면 누름 장치가 대신 눌러요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
            const SizedBox(height: AppSpace.md),
            AppliancePanel(
              appliance: a,
              imageOverride: applianceImageOverride,
              onButton: (b) => _confirmPress(context, ref, a, b, source: source, notice: pressNotice),
            ),
          ],
          const SizedBox(height: AppSpace.xl),

          // ── 내 루틴 ───────────────────────────────────────────────────────
          _Card(
            // 큰 글씨에서는 버튼을 아래 줄로 — 한 줄이면 버튼 글자가 넘친다.
            child: Flex(
              mainAxisSize: MainAxisSize.min,
              direction: MediaQuery.textScalerOf(context).scale(1) > 1.3
                  ? Axis.vertical
                  : Axis.horizontal,
              crossAxisAlignment: MediaQuery.textScalerOf(context).scale(1) > 1.3
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                _slot(
                  MediaQuery.textScalerOf(context).scale(1) <= 1.3,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 0개면 숫자와 빈 문장을 겹치지 않고 한 줄로(2026-10-14 UX).
                      Text(mine.isEmpty ? '아직 루틴이 없어요' : '내 루틴 ${mine.length}개',
                          style: const TextStyle(
                              fontSize: AppFont.body, fontWeight: FontWeight.w700)),
                      if (mine.isNotEmpty) ...[
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          mine.map((r) => r.name).join(', '),
                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                        ),
                      ],
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
                    label: const Text('누르는 순서 저장'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.md),

          // ── 오늘 사용 ─────────────────────────────────────────────────────
          _TodayUse(applianceId: a.id, thinq: a.isThinq),

          if (!a.isThinq) ...[
            const SizedBox(height: AppSpace.sm),
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

  /// 가전 지우기 — 확인을 한 번 더 받는다(설정의 가전 줄에서 옮김, 평가 7차 10/18).
  static Future<void> _confirmRemove(BuildContext context, WidgetRef ref, ApplianceMap appliance) async {
    // async gap 전에 캡처 — 다이얼로그가 닫힌 뒤의 context 사용을 피한다
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("'${appliance.name}' 삭제"),
        content: const Text('등록한 버튼 배치와 사진이 함께 삭제돼요. 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            // 전경색을 명시하지 않으면 라이트 모드에서 흰 글자(3.63:1)가 된다
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: AppColors.onAccent,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // 폰 삭제는 무조건 성립하고(사용자가 지시한 일이다), 서버 전송이 실패하면 그 사실이 삭제 대기열에 남아
    // 다음 동기화가 다시 보낸다(R3).
    final result = await ref.read(applianceSyncProvider.notifier).deleteAppliance(appliance.id);
    if (result.failed > 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('폰에서는 지웠어요. 본체에는 다음에 맞출 때 다시 시도할게요.')),
      );
    }
    // 지운 가전의 상세에 머물지 않는다.
    if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
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
    ApplianceButton b, {
    required ApplianceMap source,
    String? notice,
  }) async {
    if (source.readinessKnown && !source.canExecute) {
      _snack(
        context,
        notice ?? source.readinessReasons.firstOrNull ?? '아직 이 가전은 준비가 안 됐어요.',
      );
      return;
    }
    // 아까 보낸 같은 버튼이 눌렸는지 모르면 다시 누를지부터 묻는다(그 확인이 누르기 확인을 대신한다).
    final repeat = await _confirmRepeatIfUnknown(context, ref, b);
    if (repeat == false || !context.mounted) return;
    final ok = repeat ?? await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("'${b.label}' 버튼을 누를까요?"),
        content: Text(
          "누름 장치가 ${a.displayName}의 '${b.label}' 버튼을 대신 눌러요. "
          '누른 뒤 결과를 보여 드려요.',
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
      _snack(context, '본체와 연결되면 누를 수 있어요.');
      return;
    }
    final execution = ref.read(executionStatusProvider.notifier);
    // 보내기 전에 '보내는 중'으로 — 답을 기다리는 사이에도 정지 띠가 있다(검토 10/19).
    final requestId = execution.beginSubmitting(api: api, label: b.label, steps: [b.label]);
    try {
      final accepted = await api.executeButtons([b.label], applianceId: a.id);
      // 공용 실행 상태에 등록한다 -- 이 화면을 떠나도 정지 수단이 남는다.
      execution.beginHttpJob(
        api: api,
        jobId: accepted.jobId,
        label: b.label,
        steps: [b.label],
        requestId: requestId,
      );
      if (context.mounted) context.push('/status');
    } on RpiApiException catch (e) {
      execution.abandonSubmission(requestId); // 본체가 답했다 — 받지 않았다
      if (!context.mounted) return;
      _snack(
        context,
        switch (e.statusCode) {
          409 => '다른 일을 하는 중이에요. 끝난 뒤 다시 눌러 주세요.',
          412 => e.message,
          _ => '누르라고 보내지 못했어요. 연결을 봐 주세요.',
        },
      );
    } catch (_) {
      // 보냈는데 답이 없다(시간 초과·연결 끊김) — 본체가 받아 이미 눌렀을 수 있다(검토 10/19, 수동 조작 화면과 같은 규칙).
      // '보내지 못했어요'라고 하면 정지 없이 같은 버튼을 또 눌러, 켜기·끄기 버튼이면 도로 꺼질 수 있었다.
      execution.beginSubmissionUnknown(
        api: api,
        label: b.label,
        steps: [b.label],
        requestId: requestId,
      );
      if (!context.mounted) return;
      _snack(context, manualPressUnknownSentence(b.label));
      context.push('/status');
    }
  }

  /// 아까 이 버튼을 보냈는데 눌렸는지 모른다(보내는 중·접수 답을 못 받음) — 다시 누를지 묻는다. 다시 누르면 true, 그만두면
  /// false, 모르는 버튼이 아니면 null(평소 누르기 확인으로).
  static Future<bool?> _confirmRepeatIfUnknown(
    BuildContext context,
    WidgetRef ref,
    ApplianceButton b,
  ) async {
    final status = ref.read(executionStatusProvider);
    final unresolved = status.phase == ExecutionPhase.waiting ||
        (status.phase == ExecutionPhase.unknown &&
            (status.sequenceId?.startsWith('unsent-') ?? false));
    if (!unresolved || status.label != b.label) return null;
    final again = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('다시 누를까요?'),
        content: Text("아까 누른 '${b.label}' 버튼은 눌렸는지 아직 몰라요. 다시 누르면 두 번 눌릴 수 있어요. "
            '가전을 보고 안 눌렸을 때만 다시 눌러 주세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('그만두기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('다시 누르기'),
          ),
        ],
      ),
    );
    return again ?? false;
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// 지금 맡길 수 있는가 한 줄. **모르는 것을 준비됐다고 말하지 않는다** --
/// 서버가 준비 상태를 알려 준 경우에만 못 쓴다고 단정한다.
class _ReadinessLine extends StatelessWidget {
  const _ReadinessLine({required this.appliance, this.notice});
  final ApplianceMap appliance;

  /// 누를 장치가 없을 때의 쉬운 안내와 다음 할 일([pressUnavailableNotice]). 있으면 서버 이유 대신 이것.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    if (!(a.readinessKnown && !a.canExecute)) return const SizedBox.shrink();
    final why = notice ??
        a.readinessReasons.firstOrNull ??
        (a.readiness == 'disconnected' ? '아직 연결되지 않았어요' : '아직 준비가 안 됐어요');
    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: context.appWarning),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(why,
              style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
        ),
      ],
    );
  }
}

/// 오늘 이 가전으로 한 일. 서버 기록에서 온다 -- 기록이 없으면 지어내지 않는다.
class _TodayUse extends ConsumerWidget {
  const _TodayUse({required this.applianceId, this.thinq = false});
  final String applianceId;

  /// ThinQ 가전이면 목적 없는 기록을 '버튼 직접 누름'이라 하지 않는다(누를 버튼이 없다).
  final bool thinq;

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
              style: TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.xs),
          if (today.isEmpty)
            Text('오늘은 아직 사용하지 않았어요',
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))
          else
            for (final e in today)
              Text(
                '${_hm(e.finishedAt)} ${_what(e)}, ${_result(e)}',
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
              ),
        ],
      ),
    );
  }

  /// 무엇을 했는가. 목적(말·제안·루틴)이 있으면 그것. 없으면 ThinQ 기록은 허브가 남긴
  /// 결과 문장('강풍으로 바꿨어요' 같은 것)을, 그것도 없으면 'ThinQ 직접 조작'.
  String _what(RpiHistoryEntry e) {
    final purpose = e.purpose;
    if (purpose != null && purpose.isNotEmpty) return purpose;
    if (thinq || e.route == 'thinq') {
      final detail = e.detail.trim();
      if (detail.isEmpty) return '직접 바꿈';
      return detail.endsWith('.') ? detail.substring(0, detail.length - 1) : detail;
    }
    return '직접 누름';
  }

  static String _hm(DateTime t) => ampmOf(t);

  /// 결과는 기록 탭과 같은 규칙(서버 판정)으로만. 모의 실행은 모의라고 적는다 --
  /// 모의 성공을 실제 성공처럼 말하지 않는다.
  static String _result(RpiHistoryEntry e) {
    final word = resultWord(resultKindOf(outcome: e.outcome, status: e.status));
    return e.executionMode == 'mock' ? '연습, $word' : word;
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: context.appSurfaceLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: DefaultTextStyle.merge(style: AppText.body, child: child),
      );
}

/// 가로 줄에서는 남은 폭을 채우고(Expanded), 세로로 쌓을 때는 그대로 둔다.
Widget _slot(bool expand, Widget child) => expand ? Expanded(child: child) : child;
