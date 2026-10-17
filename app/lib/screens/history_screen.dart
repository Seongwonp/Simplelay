import '../models/clock_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/command_result.dart';
import '../models/display_status.dart';
import '../models/line_break.dart';
import '../providers/appliance_provider.dart';
import '../providers/clock_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_icons.dart';
import '../widgets/status_badge.dart';
import '../theme/app_tokens.dart';

/// 실행 기록 — 공감지능(패턴 학습)의 근거 데이터와 폐루프의 회복 기록
/// ("재시도 N회 후 성공")을 사용자에게 그대로 보여준다.
final historyProvider =
    FutureProvider.autoDispose<List<RpiHistoryEntry>>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  // 허브에 닿지 않으면 조회하지 못한 것이다 — '기록 없음'으로 말하지 않는다.
  if (api == null) throw StateError('hub not connected');
  return api.history();
});

/// 날짜별 로그가 아니라 **무엇을 했고 결과가 어땠는지**가 먼저다.
///
/// 읽는 순서(2026-10-18): 날짜(구획 제목, 눌렸는지 모르는 일 수) → 행 두 줄(무엇을 · 시각·누가)
/// + 왼쪽 출처 아이콘 + 오른쪽 결과 배지. 결과 문장·모의 여부·다음 행동·버튼별 결과는 눌러서 펼친다.
/// 한 건은 카드가 아니라 행이다.
/// 문구는 `models/display_status.dart`가 정한다 — 목적을 추정하지 않고, 데이터가
/// 아는 수준까지만 말한다.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(historyProvider);
    final now = ref.watch(nowProvider)();
    final installed = ref.watch(installedAppliancesProvider);

    return Scaffold(
      // 탭 제목은 홈('우리 집')과 같은 굵은 큰 제목(UI 평가 10/17).
      appBar: AppBar(title: Text('기록', style: AppText.heading)),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(historyProvider.future),
        child: historyAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _Message(
            icon: Icons.wifi_off,
            text: '기록을 불러오지 못했어요.\n연결을 보고 아래로 당겨 새로 봐 주세요.',
          ),
          data: (entries) => entries.isEmpty
              ? _Message(
                  icon: Icons.history,
                  text: '아직 기록이 없어요.\n가전을 쓰면 여기에 남아요.',
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.xxxl),
                  children: [
                    for (final section in _groupByDay(entries, now)) ...[
                      const SizedBox(height: AppSpace.lg),
                      Text(section.label, style: AppText.title),
                      // 눌렸는지 모르는 일은 행마다가 아니라 날짜 머리에 한 번(2차 평가 10/18).
                      if (unknownPressCount(section.entries) case final n when n > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Row(children: [
                            Icon(Icons.help_outline, size: 20, color: context.appWarning),
                            const SizedBox(width: AppSpace.sm),
                            Expanded(
                              child: Text('눌렸는지 모르는 일 $n건. 가전을 봐 주세요',
                                  style: TextStyle(
                                      fontSize: AppFont.caption,
                                      fontWeight: FontWeight.w600,
                                      color: context.appWarning)),
                            ),
                          ]),
                        ),
                      const SizedBox(height: AppSpace.xs),
                      for (var i = 0; i < section.entries.length; i++) ...[
                        // jobId가 다르면 같은 시각이라도 다른 행이다(합치지 않는다).
                        _HistoryRow(
                          key: ValueKey('history-${section.entries[i].jobId}'),
                          entry: section.entries[i],
                          // 실행할 때의 이름이 먼저다 — 나중에 이름·모드가 바뀌어도 그때 이름(결함 ②).
                          applianceName: section.entries[i].applianceName ??
                              _applianceName(
                                  installed, section.entries[i].applianceId),
                        ),
                        if (i < section.entries.length - 1)
                          Divider(height: 1, color: context.appBorderFaint),
                      ],
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  /// 기록이 가리키는 가전 이름. 모르면 null -- 지어내지 않는다(지웠거나,
  /// 이 열이 생기기 전 기록이다).
  static String? _applianceName(List installed, String? id) {
    if (id == null) return null;
    for (final a in installed) {
      if (a.id == id) return a.displayName as String;
    }
    return null;
  }
}

class _DaySection {
  const _DaySection(this.label, this.entries);
  final String label;
  final List<RpiHistoryEntry> entries;
}

/// 서버가 최신순으로 준 목록을 날짜 구획으로 나눈다. 순서는 그대로다.
List<_DaySection> _groupByDay(List<RpiHistoryEntry> entries, DateTime now) {
  final sections = <_DaySection>[];
  for (final e in entries) {
    final label = _dayLabel(e.finishedAt, now);
    if (sections.isNotEmpty && sections.last.label == label) {
      sections.last.entries.add(e);
    } else {
      sections.add(_DaySection(label, [e]));
    }
  }
  return sections;
}

String _dayLabel(DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '오늘';
  if (diff == 1) return '어제';
  return '${t.month}월 ${t.day}일';
}

/// 기록 줄 시각 — '오후 10:04'(폰의 다른 시각과 같은 꼴, 평가 8차 10/18).
String _hm(DateTime t) => ampmOf(t);

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // RefreshIndicator가 빈 화면에서도 동작하도록 스크롤 가능 영역 유지
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 40, color: context.appMuted),
                  const SizedBox(height: AppSpace.md),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.appMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 어느 단계까지 갔는지 — 성공 / 확인하지 못함 / 시도 횟수.
///
/// 폐루프는 버튼마다 눌림을 확인하고 필요하면 다시 누른다. 실패했을 때
/// **어디서** 멈췄는지는 그 기록에 이미 들어 있는데 화면이 버리고 있었다.
/// 가전 앞에서 무엇을 이어서 해야 하는지가 여기서 갈린다.
class _StepBreakdown extends StatelessWidget {
  const _StepBreakdown({required this.buttons, this.notPressed = false});

  final List<RpiHistoryButton> buttons;

  /// 모션 장치가 걸려 멈춘 실행(abortReason) — 실패한 단계는 누르지 못한 것이다.
  /// "확인 못 함"(눌렀을 수도 있음)으로 말하지 않는다(2026-10-14 UX).
  final bool notPressed;

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in buttons)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs),
            child: Row(
              children: [
                Icon(
                  b.success
                      ? Icons.check_circle_outline
                      : notPressed
                          ? Icons.remove_circle_outline
                          : Icons.help_outline,
                  size: 18,
                  color: b.success ? context.appSuccess : context.appWarning,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    b.button,
                    style: TextStyle(
                      fontSize: AppFont.caption,
                      color: b.success ? null : context.appMuted,
                    ),
                  ),
                ),
                Text(
                  // '눌렀지만 확인 못 함'과 '아예 못 누름'을 화면이
                  // 구분할 재료는 없다 -- 확인 여부까지만 말한다.
                  b.success
                      ? (b.attempts > 1 ? '${b.attempts}번 만에 눌렸어요' : '눌렸어요')
                      : notPressed
                          ? '누르지 않았어요'
                          : '눌렸는지 몰라요',
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// ThinQ 기록의 수신 수준 한 줄(접수됨·받았는지 확인이 필요해요 등). 물리 기록은
/// 결과 문장이 이미 확인 수준을 말하므로 따로 적지 않는다("물리 버튼"·"확인 근거
/// 없음" 같은 시스템 용어를 앞에 내지 않는다).
String? _thinqReceiptLine(RpiHistoryEntry e, ResultKind kind) {
  if (e.route != 'thinq') return null;
  // 모의는 결과 문장("연습 · ○○에 보내지 않았어요")이 이미 다 말한다 — 접수 줄을 겹치지 않는다.
  if (e.executionMode == 'mock') return null;
  // 이미 목표값이면 위 결과 문장이 다 말한다 — 같은 뜻을 두 줄로 쓰지 않는다(UI 평가 10/17).
  if (e.confirmation == 'already_at_target') return 'LG 가전';
  final label = confirmationLabel(
    route: e.route,
    receipt: e.receipt,
    confirmation: e.confirmation,
    kind: kind,
    executionMode: e.executionMode,
  );
  return label ?? 'LG 가전';
}

/// 결과 배지 — 됐어요 · 봐 주세요 · 멈췄어요 · 스스로 멈췄어요 · 못 했어요 · 연습(평가 5차 넷 → 7차 멈춤 둘을 가름).
///
/// **초록 '됐어요'는 상태를 다시 읽거나 누름을 확인했을 때만**이다. 보고·접수만 받은 것, 됐는지 모르는 것은
/// '봐 주세요'(가전을 직접 보라는 뜻) — 예전 '받았어요'는 됐다는 말로 읽혀 확인 수준을 높여 보였다.
/// 멈춘 것은 손 아이콘 + '멈췄어요'(멈춰 달라고 해서)·'스스로 멈췄어요'(본체가 안전 때문에), 색은 같은 주의 색.
/// 자세한 사정은 펼친 결과 문장이 말한다.
/// 이미 그 설정이라 보내지 않은 것(already_at_target)은 본체가 **상태를 읽어** 본 것이라 실제 실행에서만 '됐어요'.
({String label, IconData icon, BadgeTone tone}) historyBadgeOf(RpiHistoryEntry e) {
  const check = (label: '봐 주세요', icon: Icons.help_outline, tone: BadgeTone.attention);
  final kind = resultKindOf(outcome: e.outcome, status: e.status);
  if (e.executionMode == 'mock') {
    return (label: '연습', icon: Icons.science_outlined, tone: BadgeTone.neutral);
  }
  switch (kind) {
    // 멈춘 기록은 '봐 주세요'와 글자를 가른다(평가 7차 10/18: ?와 ✋에 같은 '봐 주세요'가 붙어 무엇이 다른지 몰랐다).
    // 색은 그대로 주의 — 멈춘 것도 가전을 사람이 봐야 한다. 말은 결과 한 단어([resultWord])와 같다.
    case ResultKind.stopped:
    case ResultKind.safetyStop:
      return (label: resultWord(kind), icon: Icons.front_hand_outlined, tone: check.tone);
    case ResultKind.failed:
      return (label: '못 했어요', icon: Icons.cancel_outlined, tone: BadgeTone.danger);
    case ResultKind.unconfirmed:
      return check;
    case ResultKind.success:
      break;
  }
  final real = e.executionMode == 'real';
  final confirmed = e.route == 'thinq'
      ? (e.confirmation == 'state_confirmed' ||
          e.confirmation == 'state_confirmed_unknown_before' ||
          e.confirmation == 'already_at_target')
      : (e.confirmation == 'operation_confirmed' || e.confirmation == 'press_confirmed');
  if (real && confirmed) {
    // '됐어요'는 기호도 하나(평가 6차 10/18: 같은 '됐어요'에 ✓와 ⓘ가 섞였다). 이미 그 설정이라 보내지 않은 것도
    // 원하던 상태를 **읽어서** 본 것이라 같은 ✓ — 보내지 않았다는 차이는 펼친 결과 문장('이미 그 설정이라 …')이 말한다.
    return (label: '됐어요', icon: Icons.check_circle, tone: BadgeTone.confirmed);
  }
  // 보고·접수만 받았다 — 됐는지는 확인하지 못했다.
  return check;
}

/// 날짜 구획 안에서 눌렸는지 모르는 버튼 기록 수(2차 평가 10/18 — 행마다 말하지 않고 머리에 한 번).
int unknownPressCount(List<RpiHistoryEntry> entries) => entries
    .where((e) =>
        e.route != 'thinq' &&
        e.executionMode != 'mock' &&
        resultKindOf(outcome: e.outcome, status: e.status) == ResultKind.unconfirmed)
    .length;

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    super.key,
    required this.entry,
    required this.applianceName,
  });

  final RpiHistoryEntry entry;

  /// 어느 가전이었는지. 모르면 null이고 말하지 않는다.
  final String? applianceName;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

/// 기록 한 건 — 두 줄(무엇을 · 언제·누가) + 왼쪽 출처 아이콘 + 오른쪽 결과 배지.
/// 결과 문장·다음 할 일·버튼별 결과는 눌러서 펼친다(2026-10-18).
class _HistoryRowState extends State<_HistoryRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final applianceName = widget.applianceName;
    final result = historyResult(entry, applianceName: applianceName);
    final kind = result.kind;
    final succeeded = kind == ResultKind.success;
    // 버튼 단계·'버튼판에서 직접 누르기'는 물리 경로의 이야기다. ThinQ 기록과
    // 확인 못 함(실패 아님)은 펼치지 않는다.
    final breakdown = !succeeded &&
        kind != ResultKind.unconfirmed &&
        entry.route != 'thinq';
    final badge = historyBadgeOf(entry);
    final title = historyTitle(entry, applianceName: applianceName);
    final rawName = applianceName;
    // 모의 기록은 '연습' 배지·한 줄이 말한다 — 이름의 "(모의)"를 되풀이하지 않는다(표시만).
    final name = rawName != null && entry.executionMode == 'mock'
        ? withoutMockMark(rawName)
        : rawName;
    final source = historySource(entry);
    // 루틴·자동 규칙 이름은 부제로(평가 3차 10/18) — 제목은 한 일(행동 이름) 하나의 규칙.
    final origin = historyOrigin(entry, applianceName: applianceName);
    // 제목·루틴 이름이 이미 가전 이름을 말하면 시각 줄에서 되풀이하지 않는다.
    final timeLine = [
      _hm(entry.finishedAt),
      // 루틴은 어떻게 시작했는지까지('루틴 · 허락하고 실행'·'루틴 · 자동으로', 평가 7차 10/18).
      historySourceLabel(entry),
      if (origin != null) origin,
      if (name != null && !title.contains(name) && !(origin ?? '').contains(name)) name,
    ].join(' · ');
    final receipt = _thinqReceiptLine(entry, kind);
    final muted = context.appCaption;

    // 큰 글씨에서는 배지를 제목 아래로 — 오른쪽에 두면 제목이 한 글자씩 꺾인다.
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final badgeWidget = StatusBadge(icon: badge.icon, label: badge.label, tone: badge.tone);
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 왼쪽 = 누가(직접·루틴·자동).
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            shape: BoxShape.circle,
          ),
          child: Icon(AppIcons.source(source), size: 20, color: context.appMuted),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w600)),
              // 낱말 중간에서 꺾이지 않게('전자레인/지' 방지). 낭독은 원문.
              Text(keepWordsTogether(timeLine), semanticsLabel: timeLine, style: muted),
              if (big) ...[const SizedBox(height: AppSpace.xs), badgeWidget],
            ],
          ),
        ),
        if (!big) ...[const SizedBox(width: AppSpace.sm), badgeWidget],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              key: Key('history-tap-${entry.jobId}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                child: head,
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.only(
                  left: 40 + AppSpace.md, bottom: AppSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.sentence,
                    style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w600),
                  ),
                  if (result.mockNote case final note?) Text(note, style: muted),
                  if (receipt != null) Text(receipt, style: muted),
                  if (result.next case final next?) ...[
                    const SizedBox(height: AppSpace.xs),
                    Text(next,
                        style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w600)),
                  ],
                  // 연습(모의) 기록은 위 한 줄이 이미 말한다 — 서버 설명을 겹치면 어긋난다(10/14).
                  if (entry.detail.isNotEmpty && !succeeded && entry.executionMode != 'mock')
                    Text(entry.detail, style: muted),
                  if (entry.retryCount > 0 && succeeded) ...[
                    const SizedBox(height: AppSpace.xs),
                    // 폐루프의 핵심 증거 — 실패를 스스로 재시도로 회복했다. '됐어요'라 하지 않는다 — 다시 누른 사실만.
                    Row(children: [
                      Icon(Icons.refresh, size: 16, color: context.appMuted),
                      const SizedBox(width: AppSpace.xs),
                      Text('${entry.retryCount}번 더 눌러 마쳤어요',
                          style: muted.copyWith(fontWeight: FontWeight.w600)),
                    ]),
                  ],
                  // 끝이 안 좋았던 실행만 버튼별 결과와 다음 길을 둔다.
                  if (breakdown) ...[
                    const SizedBox(height: AppSpace.sm),
                    _StepBreakdown(
                        buttons: entry.buttons, notPressed: entry.abortReason != null),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/manual-control'),
                        icon: const Icon(Icons.grid_view_rounded, size: 18),
                        label: const Text('버튼판에서 직접 누르기'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
