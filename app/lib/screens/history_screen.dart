import '../models/clock_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
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

/// 기록 묶음은 바로 앞 회차와 이 간격 안일 때만(평가 15차 10/18).
const kHistoryRunGap = Duration(minutes: 10);

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
                      // 평가 14차(10/18): 연달아 같은 일·같은 결과는 한 줄로 묶는다('3번 못 했어요') — 펼치면 각 회차.
                      // 날짜 구획 안에서 바로 이어질 때만(사이에 다른 일이 있으면 따로), 결과·이유·출처까지 같을 때만.
                      ..._rows(context, _runsOf(section.entries, installed), installed),
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

  static List<Widget> _rows(BuildContext context, List<List<RpiHistoryEntry>> runs, List installed) => [
        for (final (i, run) in runs.indexed) ...[
          _HistoryRow(
            key: ValueKey('history-${run.first.jobId}'),
            entries: run,
            applianceName: _nameOf(installed, run.first),
            applianceIcon: _applianceIcon(installed, run.first.applianceId),
          ),
          if (i < runs.length - 1) Divider(height: 1, color: context.appBorderFaint),
        ],
      ];

  /// 실행할 때의 이름이 먼저다 — 나중에 이름·모드가 바뀌어도 그때 이름(결함 ②).
  static String? _nameOf(List installed, RpiHistoryEntry e) =>
      e.applianceName ?? _applianceName(installed, e.applianceId);

  /// 바로 이어진 같은 일·같은 결과를 한 묶음으로. 순서는 서버 순서(최신 먼저) 그대로.
  static List<List<RpiHistoryEntry>> _runsOf(List<RpiHistoryEntry> entries, List installed) {
    final runs = <List<RpiHistoryEntry>>[];
    String? lastKey;
    for (final e in entries) {
      final key = historyRunKey(e, applianceName: _nameOf(installed, e));
      // 평가 15차(10/18): '켜기 · 2번'이 '오전 10:51~오후 12:59'로 두 시간에 걸쳐 묶였다 → 바로 앞 회차와
      // [kHistoryRunGap] 안일 때만 같은 묶음(따로 한 일이 한 번에 한 것처럼 읽히지 않게).
      if (runs.isNotEmpty &&
          key == lastKey &&
          runs.last.last.finishedAt.difference(e.finishedAt).abs() <= kHistoryRunGap) {
        runs.last.add(e);
      } else {
        runs.add([e]);
      }
      lastKey = key;
    }
    return runs;
  }

  /// 기록이 가리키는 가전의 아이콘(종류에서). 모르면 null.
  static IconData? _applianceIcon(List installed, String? id) {
    if (id == null) return null;
    for (final a in installed) {
      if (a.id == id) return a.icon as IconData;
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

/// 실패 기록의 이유 한 줄(평가 14차 10/18: '못 했어요'가 세 번 이어져도 왜인지 없었다). **기록에 있는 말만** —
/// 본체가 남긴 결과 문장(`detail`)의 첫 문장, 그것이 없으면 작은 팔 기록은 결과 문장(보내지 못함·다시 눌러도 모름 같은
/// 데이터가 아는 사정). LG 가전 기록에 문장이 없으면 null — '가전이 하지 않았어요'는 배지와 같은 말이라 붙이지 않는다.
String? historyFailReason(RpiHistoryEntry e, {String? applianceName}) {
  if (e.executionMode == 'mock') return null;
  if (resultKindOf(outcome: e.outcome, status: e.status) != ResultKind.failed) return null;
  final first = _detailParts(e.detail).$1;
  if (first != null) return plainFailReason(first, historyTitle(e, applianceName: applianceName));
  if (e.route == 'thinq') return null;
  return historyResult(e, applianceName: applianceName).sentence;
}

/// 본체 거절 문장의 첫 문장 → 쉬운 말(평가 15차 10/18: '가전의 지금 모드에서는 이 명령을 받을 수 없어요'의 '모드'·'명령').
///
/// **근거가 있는 만큼만** 말한다 — '꺼져 있어'는 본체가 꺼짐 거절 코드로 적었을 때만 쓰고(바람 세기 일이면 '꺼져 있을
/// 땐 바람 세기를 바꿀 수 없어요'), 모드·상태 거절은 꺼졌다고 하지 않고 '지금은 가전이 바꿀 수 없는 상태였어요'.
/// 모르는 문장은 그대로 둔다(지어내지 않는다).
String plainFailReason(String first, String title) {
  final t = first.trim();
  if (t.contains('꺼져 있어 이 명령을')) {
    return title.contains('바람') ? '꺼져 있을 땐 바람 세기를 바꿀 수 없어요' : '가전이 꺼져 있어서 못 했어요';
  }
  if (t.contains('지금 모드에서는 이 명령을') || t.contains('지금은 이 명령을')) {
    return '지금은 가전이 바꿀 수 없는 상태였어요';
  }
  if (t == '가전이 이 명령을 받지 않았어요') return '가전이 받지 않았어요';
  return t;
}

/// 본체 결과 문장 → (첫 문장(마침표 뺌), 나머지). 비었으면 (null, null).
(String?, String?) _detailParts(String detail) {
  final d = detail.trim();
  if (d.isEmpty) return (null, null);
  final m = RegExp(r'^(.+?)[.。](?:\s+(.*))?$', dotAll: true).firstMatch(d);
  if (m == null) return (d, null);
  final rest = m.group(2)?.trim();
  return (m.group(1)!.trim(), (rest == null || rest.isEmpty) ? null : rest);
}

/// 묶음 열쇠 — 같은 일(제목)·같은 결과(배지)·같은 출처·같은 가전·같은 이유·같은 실제/연습일 때만 한 줄로 묶는다.
String historyRunKey(RpiHistoryEntry e, {String? applianceName}) => [
      historyTitle(e, applianceName: applianceName),
      historyBadgeOf(e).label,
      historySourceLabel(e),
      historyOrigin(e, applianceName: applianceName) ?? '',
      applianceName ?? '',
      e.executionMode,
      historyFailReason(e, applianceName: applianceName) ?? '',
      historyResult(e, applianceName: applianceName).sentence,
    ].join('\u0000');

/// '됐어요' 기록이 **무엇을 확인했는지** 짧게(평가 14차 10/18: 성공 줄이 '됐어요' 한 마디로 끝나 무엇이 됐는지 몰랐다).
///
/// 기록의 확인 수준(`confirmation`)에서만 말한다 — 초록 '됐어요'가 아닌 기록(보고·접수만, 모름, 연습)은 null.
/// - LG 가전 상태를 다시 읽음(state_confirmed·state_confirmed_unknown_before): 행동 이름이 켜기/끄기면 '켜짐 확인'/'꺼짐 확인',
///   그 밖은 '바뀐 상태 확인'. 루틴 기록은 이름이 한 일을 다 말하지 않을 수 있어 '상태 확인'.
/// - 이미 그 설정이라 보내지 않음(already_at_target): '이미 그 상태'.
/// - 작은 팔: 전기를 쓰기 시작함(operation_confirmed) '동작 확인', 눌림 확인(press_confirmed) '눌림 확인'.
String? historyConfirmedPhrase(RpiHistoryEntry e, {String? applianceName}) {
  if (historyBadgeOf(e).tone != BadgeTone.confirmed) return null;
  if (e.route == 'thinq') {
    switch (e.confirmation) {
      case 'already_at_target':
        return '이미 그 상태';
      case 'state_confirmed':
      case 'state_confirmed_unknown_before':
        if (!historyIsLgAppliance(e)) return '상태 확인';
        final title = historyTitle(e, applianceName: applianceName);
        if (title.endsWith(' 켜기')) return '켜짐 확인';
        if (title.endsWith(' 끄기')) return '꺼짐 확인';
        return '바뀐 상태 확인';
    }
    return null;
  }
  return switch (e.confirmation) {
    'operation_confirmed' => '동작 확인',
    'press_confirmed' => '눌림 확인',
    _ => null,
  };
}

/// 묶음의 시각 — 한 번이면 '오후 1:00', 여럿이면 '오후 12:59~1:00'(같은 오전/오후는 한 번만).
String _runTime(List<RpiHistoryEntry> entries) {
  final newest = _hm(entries.first.finishedAt);
  if (entries.length == 1) return newest;
  final oldest = _hm(entries.last.finishedAt);
  if (oldest == newest) return newest;
  final p1 = oldest.split(' ');
  final p2 = newest.split(' ');
  if (p1.length == 2 && p2.length == 2 && p1.first == p2.first) return '$oldest~${p2.last}';
  return '$oldest~$newest';
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    super.key,
    required this.entries,
    required this.applianceName,
    this.applianceIcon,
  });

  /// 한 줄에 묶인 기록(최신 먼저, 하나 이상). 같은 일·같은 결과가 연달아 있을 때만 여럿이다.
  final List<RpiHistoryEntry> entries;

  /// 가전 종류 아이콘. LG 가전 기록의 왼쪽 아이콘에 쓴다. 모르면 null.
  final IconData? applianceIcon;

  /// 어느 가전이었는지. 모르면 null이고 말하지 않는다.
  final String? applianceName;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

/// 기록 한 줄 — 두 줄(무엇을 · 언제·누가) + 왼쪽 출처 아이콘 + 오른쪽 결과.
/// 결과 문장·다음 할 일·버튼별 결과는 눌러서 펼친다(2026-10-18). 묶음이면 펼친 칸에 회차마다.
///
/// 평가 14차(10/18): 모든 줄이 같은 짜임(회색 원 + 배지 칩)이라 위계가 없었다 — 회색 원을 빼고, 됐어요·연습은 칩 없이
/// 작은 기호·글자로 조용히. 볼 것(못 했어요·봐 주세요·멈췄어요)만 칩으로 눈에 띄게.
class _HistoryRowState extends State<_HistoryRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final entry = entries.first;
    final count = entries.length;
    final applianceName = widget.applianceName;
    final result = historyResult(entry, applianceName: applianceName);
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
    // 제목·루틴 이름이 이미 가전 이름을 말하면 시각 줄에서 되풀이하지 않는다. 'LG 가전' 같은 출처는 묶음에 한 번.
    final timeLine = [
      _runTime(entries),
      // 루틴은 어떻게 시작했는지까지('루틴 · 물어보고'·'루틴 · 자동으로', 평가 7차 10/18).
      historySourceLabel(entry),
      if (origin != null) origin,
      if (name != null && !title.contains(name) && !(origin ?? '').contains(name)) name,
    ].join(' · ');
    final muted = context.appCaption;
    // 이유 한 줄 — '봐 주세요'는 결과 문장(평가 10차 10/18), '못 했어요'는 기록에 있는 이유(평가 14차 10/18).
    final look = badge.label == '봐 주세요';
    final reason = look ? result.sentence : historyFailReason(entry, applianceName: applianceName);
    final reasonColor = look ? context.appWarning : context.appInk;

    final label = count > 1 ? '$count번 ${badge.label}' : badge.label;
    // 됐어요·연습은 칩 없이 작은 기호·글자. 볼 것만 칩.
    final quiet = badge.tone == BadgeTone.confirmed || badge.tone == BadgeTone.neutral;
    // 됐어요는 무엇을 확인했는지 짧게('켜짐 확인') — 기록의 확인 수준에서만([historyConfirmedPhrase]).
    final confirmed = historyConfirmedPhrase(entry, applianceName: applianceName);
    final quietLabel = confirmed == null ? label : (count > 1 ? '$confirmed · $count번' : confirmed);
    final Widget badgeWidget = quiet
        ? _QuietResult(
            key: Key('history-result-${entry.jobId}'),
            icon: badge.icon,
            label: quietLabel,
            semanticLabel: confirmed == null ? label : '${badge.label}, $quietLabel',
            color: badge.tone == BadgeTone.confirmed ? context.appConfirmed : context.appMuted)
        : StatusBadge(key: Key('history-result-${entry.jobId}'), icon: badge.icon, label: label, tone: badge.tone);

    // 큰 글씨에서는 결과를 제목 아래로 — 오른쪽에 두면 제목이 한 글자씩 꺾인다.
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 왼쪽 = 누가(직접·루틴·자동). 회색 원 없이 아이콘만(평가 14차 10/18).
        // 사람이 시작한 LG 가전 기록은 손 대신 가전 아이콘(평가 12차 10/18), LG 가전 자동 실행도(평가 13차).
        // 큰 글씨에서는 아이콘도 글자 배율을 따라(평가 15차 10/18, 상한 있음).
        SizedBox(
          width: textScaledIcon(context, AppSpace.xxxl),
          height: textScaledIcon(context, AppSpace.xxl + AppSpace.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(
                historyIsLgAppliance(entry)
                    ? (widget.applianceIcon ?? ApplianceCategory.other.icon)
                    : AppIcons.source(source),
                key: Key('history-icon-${entry.jobId}'),
                size: textScaledIcon(context, 22),
                color: context.appMuted),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 행동 이름의 짧은 끝 낱말('하기')은 앞 낱말과 함께 꺾인다(평가 14차 10/18). 낭독은 원문.
              Text(keepActionNameTogether(title),
                  key: Key('history-title-${entry.jobId}'),
                  semanticsLabel: title,
                  style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w600)),
              // 낱말 중간에서 꺾이지 않게('전자레인/지' 방지). 가운뎃점은 앞 낱말에 붙여 줄 머리에 오지 않게
              // (평가 13차 10/18: '사람이 직접 / · 전자레인지'). 낭독은 원문.
              Text(keepPhrasesTogether(timeLine, wholeParts: !big),
                  key: Key('history-time-${entry.jobId}'), semanticsLabel: timeLine, style: muted),
              if (reason != null)
                Text(keepPhrasesTogether(reason),
                    key: Key('history-reason-${entry.jobId}'),
                    semanticsLabel: reason,
                    style: muted.copyWith(fontWeight: FontWeight.w600, color: reasonColor)),
              if (big) ...[const SizedBox(height: AppSpace.xs), badgeWidget],
            ],
          ),
        ),
        if (!big) ...[const SizedBox(width: AppSpace.sm), badgeWidget],
      ],
    );

    // '버튼판에서 직접 누르기'는 물리 경로의 끝이 안 좋았던 실행만, 묶음이어도 한 번.
    final kind = result.kind;
    final breakdown = kind != ResultKind.success && kind != ResultKind.unconfirmed && entry.route != 'thinq';

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
              padding: const EdgeInsets.only(left: AppSpace.xxxl + AppSpace.sm, bottom: AppSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (count == 1)
                    ..._details(context, entry, reasonShown: reason != null)
                  else
                    // 묶음은 회차마다 시각과 그 회차의 결과 — 출처('LG 가전')는 위 한 번으로 끝낸다.
                    for (final e in entries)
                      Padding(
                        key: Key('history-sub-${e.jobId}'),
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_hm(e.finishedAt),
                                style: muted.copyWith(fontWeight: FontWeight.w700, color: context.appInk)),
                            ..._details(context, e, reasonShown: reason != null, inRun: true),
                          ],
                        ),
                      ),
                  if (breakdown)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/manual-control'),
                        icon: const Icon(Icons.grid_view_rounded, size: 18),
                        label: const Text('버튼판에서 직접 누르기'),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 펼친 칸 — 결과 문장·연습 줄·접수 줄·다음 할 일·본체 문장·재시도·버튼별 결과. [reasonShown]이면 위 이유 줄이
  /// 이미 말한 것(결과 문장, 또는 본체 문장의 첫 문장)은 되풀이하지 않는다.
  List<Widget> _details(BuildContext context, RpiHistoryEntry entry,
      {required bool reasonShown, bool inRun = false}) {
    final applianceName = widget.applianceName;
    final result = historyResult(entry, applianceName: applianceName);
    final kind = result.kind;
    final succeeded = kind == ResultKind.success;
    final breakdown = !succeeded && kind != ResultKind.unconfirmed && entry.route != 'thinq';
    // 접수 줄이 출처 말('LG 가전')뿐이면 위 시각 줄이 이미 말했다 — 묶음 회차마다·LG 가전 줄에서 되풀이하지 않는다(평가 14차).
    final rawReceipt = _thinqReceiptLine(entry, kind);
    final receipt = rawReceipt == 'LG 가전' && (inRun || historyIsLgAppliance(entry)) ? null : rawReceipt;
    final muted = context.appCaption;
    final failReason = historyFailReason(entry, applianceName: applianceName);
    final (detailFirst, detailRest) = _detailParts(entry.detail);
    final look = historyBadgeOf(entry).label == '봐 주세요';
    // 이유 줄이 결과 문장이면 결과 문장을, 본체 문장의 첫 문장이면 그 첫 문장을 빼고 나머지만.
    final sentenceShown = reasonShown && (look || failReason == result.sentence);
    final detailFirstShown = detailFirst == null
        ? null
        : plainFailReason(detailFirst, historyTitle(entry, applianceName: applianceName));
    final detailShown = reasonShown && !look && failReason != null && failReason == detailFirstShown;
    final detailText = detailShown ? detailRest : (entry.detail.isEmpty ? null : entry.detail);
    return [
      if (!sentenceShown)
        Text(
          result.sentence,
          style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w600),
        ),
      if (result.mockNote case final note?) Text(note, style: muted),
      if (receipt != null) Text(receipt, style: muted),
      if (result.next case final next?) ...[
        const SizedBox(height: AppSpace.xs),
        Text(next, style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w600)),
      ],
      // 연습(모의) 기록은 위 한 줄이 이미 말한다 — 서버 설명을 겹치면 어긋난다(10/14).
      if (detailText != null && !succeeded && entry.executionMode != 'mock') Text(detailText, style: muted),
      if (entry.retryCount > 0 && succeeded) ...[
        const SizedBox(height: AppSpace.xs),
        // 폐루프의 핵심 증거 — 실패를 스스로 재시도로 회복했다. '됐어요'라 하지 않는다 — 다시 누른 사실만.
        Row(children: [
          Icon(Icons.refresh, size: 16, color: context.appMuted),
          const SizedBox(width: AppSpace.xs),
          Text('${entry.retryCount}번 더 눌러 마쳤어요', style: muted.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ],
      // 끝이 안 좋았던 실행만 버튼별 결과.
      if (breakdown) ...[
        const SizedBox(height: AppSpace.sm),
        _StepBreakdown(buttons: entry.buttons, notPressed: entry.abortReason != null),
      ],
    ];
  }
}

/// 조용한 결과 표시 — 칩(면·테두리) 없이 작은 기호 + 글자(평가 14차 10/18: 됐어요가 줄마다 초록 칩이라 볼 것이 묻혔다).
class _QuietResult extends StatelessWidget {
  const _QuietResult(
      {super.key, required this.icon, required this.label, required this.color, this.semanticLabel});
  final IconData icon;
  final String label;
  final String? semanticLabel;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.xs),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpace.xs),
          // 큰 글씨에서 칸보다 길면 낱말 단위로 꺾는다(넘치지 않게).
          Flexible(
            child: Text(keepWordsTogether(label),
                semanticsLabel: semanticLabel ?? label,
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          ),
        ]),
      );
}
