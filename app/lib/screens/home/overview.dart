part of '../home_screen.dart';

/// 홈 구획 제목(카드 제목 단계 20).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.sm),
        child: Semantics(header: true, child: Text(text, style: AppText.title)),
      );
}

/// 홈 '확인이 필요해요'의 안 본 알림 줄 — 이름은 하나, '안 본 알림 N건'(설정 줄·설정 탭 접근성 이름과 같은 말).
///
/// 평가 11·12차(10/18)에 종류 말('자동으로 한 일·루틴 안내 알림 4건, 아직 안 봤어요')을 붙였더니 평가 13차(10/18)에서
/// 분류 나열 말투에 어절 중간에서 끊겼고, 문제가 아닌 알림도 경고처럼 읽혔다. 그래서 종류는 **봐야 할 것이 섞였을 때만**
/// 가장 무거운 것 하나를 짧은 말로 붙인다('안 본 알림 3건, 못 한 일이 있어요'). 자동으로 한 일·루틴 안내뿐이면 건수만.
///
/// 평가 15차(10/18): '안 본 알림 7건, 못 한 일이 있어요'는 한 줄에 두 가지를 말하면서 **무엇을** 못 했는지는
/// 없었다 → 봐야 할 것이 있으면 그 갈래만 한 줄('못 한 일 1건: 공기청정기 바람 중간으로 하기' — 가장 최근 것의
/// 이름, 기록이 아는 말만), 나머지 알림은 따로 '안 본 알림 6건'([CareAttentionLines.rest]). 봐야 할 것이 없으면
/// 중립 한 줄 '안 본 알림 N건'만.
typedef CareAttentionLines = ({String? look, String? rest});

CareAttentionLines careAttentionLines(List<RpiCareEvent> unread) {
  if (unread.isEmpty) return (look: null, rest: null);
  final group = _careLookGroup(unread);
  if (group == null) return (look: null, rest: '안 본 알림 ${unread.length}건');
  final (word, kinds) = group;
  final hits = [for (final e in unread) if (kinds.contains(e.kind)) e]
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  final what = careEventWhat(hits.first);
  // 평가 16차(10/18): '못 한 일 3건: 공기청정기 바람 세기 중'은 끝 '중'이 '진행 중'처럼 읽혔고 기록('바람 중간으로 하기 ·
  // 3번 못 했어요')과 이름·단위가 달랐다 → 기록과 같은 행동 이름, 횟수는 '번'으로 끝 괄호에. 이름이 서로 다른 일이
  // 섞였으면 가장 최근 것의 이름과 '외 N번'(한 이름에 다른 일의 횟수를 붙이지 않는다).
  final String look;
  if (what == null) {
    look = '$word ${hits.length}번';
  } else {
    final same = hits.where((e) => careEventWhat(e) == what).length;
    final others = hits.length - same;
    // 평가 17차(10/18): 끝 괄호 '(3번)'이 혼자 다음 줄로 갔다 → 여러 번이면 '공기청정기 바람 중간으로 하기 · 3번 못
    // 했어요'처럼 횟수와 결과를 문장 끝에 붙인다(기록 칩 '3번 못 했어요'와 같은 말).
    final verb = switch (word) { '못 한 일' => '못 했어요', '멈춘 일' => '멈췄어요', _ => null };
    if (same > 1 && verb != null) {
      look = '$what · $same번 $verb${others > 0 ? ', 다른 일 $others번' : ''}';
    } else {
      look = '$word: $what${same > 1 ? ' $same번' : ''}${others > 0 ? ' 외 $others번' : ''}';
    }
  }
  return (
    look: look,
    // 휴리스틱 평가(10/18): '그 밖에 안 본 알림 4건'(홈)과 '안 본 알림 7건'(설정)이 달라 헷갈렸다 → 홈·설정 같은 수 하나
    // (전체 안 본 수). 위 실패 경고로 따로 보인 것도 이 수에 들어 있다.
    rest: '안 본 알림 ${unread.length}건',
  );
}

/// 홈·접근성에서 쓰는 한 문장(두 줄을 이은 것).
String careAttentionText(List<RpiCareEvent> unread) {
  final l = careAttentionLines(unread);
  return [if (l.look != null) l.look!, if (l.rest != null) l.rest!].join(', ');
}

/// 알림 한 건이 **무엇에 대한** 것인지 — 서버가 적은 목적 문장(행동 이름으로), 없으면 알림 문장의 따옴표 속 이름
/// (본체 요약 '공기청정기 바람 세기 중'도 기록과 같은 행동 이름 '공기청정기 바람 중간으로 하기'로). 둘 다 없으면 null.
String? careEventWhat(RpiCareEvent e) {
  final purpose = e.purpose?.trim() ?? '';
  if (purpose.isNotEmpty) return purposeActionName(purpose);
  final quoted = RegExp(r"'([^']+)'").firstMatch(e.message);
  final label = quoted?.group(1)?.trim();
  return (label == null || label.isEmpty) ? null : summaryActionName(label);
}

/// 안 본 알림 가운데 사람이 봐야 할 것(위험 소리·실패·정지·루틴 멈춤·안부 신호)이 있는가 — 경고색은 이때만.
bool careNeedsLook(List<RpiCareEvent> unread) => _careLookGroup(unread) != null;

/// 봐야 할 갈래 가운데 가장 무거운 것 하나 — (짧은 이름, 그 갈래의 종류들). 없으면 null(자동으로 한 일·루틴 안내·모르는 종류).
(String, Set<String>)? _careLookGroup(List<RpiCareEvent> unread) {
  const order = [
    ('위험 소리', {'danger_sound'}),
    ('못 한 일', {'execution_failed', 'appliance_done_undelivered'}),
    ('멈춘 일', {'emergency_stop'}),
    ('멈춘 루틴', {'routine_stopped'}),
    ('안부 신호', {'quiet_routine'}),
  ];
  final kinds = {for (final e in unread) e.kind};
  for (final g in order) {
    if (kinds.any(g.$2.contains)) return g;
  }
  return null;
}

// ── 지금 우리 집 ─────────────────────────────────────────────────────────────

/// 맨 위 요약 한 장 — 공기 · 다음 예정(큰 시각과 자동 배지).
///
/// 가전 전원은 여기서 말하지 않는다 — 가전 타일 띠('켜져 있어요')가 말한다(평가 11차 10/18: '공기청정기 켜짐'과
/// 타일 '켜져 있어요'가 겹치고 명사형·문장형이 섞였다).
///
/// **아는 것만 말한다.** 공기 등급은 본체가 최근에 읽은 값일 때만(모르면 그 칸을 비운다),
/// 둘 다 모르면 카드 자체가 없다. 공기 '좋음'도 초록으로 칠하지 않는다(초록은 실제 확인 결과 전용).
class _HomeNow extends ConsumerWidget {
  const _HomeNow();

  static const _airWords = {
    'GOOD': '좋음',
    'NORMAL': '보통',
    'BAD': '나쁨',
    'VERY_BAD': '매우 나쁨',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grade = ref.watch(thinqAirProvider).valueOrNull;
    final next = ref.watch(nextRoutineProvider).valueOrNull;
    final air = grade == null ? null : _airWords[grade];
    final facts = <Widget>[
      if (air != null)
        _Fact(
          icon: Icons.air,
          text: '공기 $air',
          color: grade == 'BAD' || grade == 'VERY_BAD' ? context.appWarning : null,
        ),
    ];
    if (facts.isEmpty && next == null) return const SizedBox.shrink();

    // 평가 14차(10/18): 옅은 회색 면이 '확인이 필요해요' 카드와 같아 주인공이 약했다 → 면 없이 큰 제목과 큰 글자로
    // 위계를 준다(이 화면의 첫 구역). 간격은 한 단계씩 좁힌다(평가 6차 10/18: 첫 화면에 가전 두 줄이 보이게).
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Container(
        key: const Key('home-now'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text('지금 우리 집',
                    style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Wrap(spacing: AppSpace.lg, runSpacing: AppSpace.sm, children: facts),
              ],
              if (next != null) ...[
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.md),
                  Divider(height: 1, color: context.appBorderFaint),
                ],
                const SizedBox(height: AppSpace.md),
                _NextUp(next: next),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 24, color: color ?? context.appMuted),
          const SizedBox(width: AppSpace.sm),
          // 핵심 한 줄은 크게(정보 피라미드, 평가 5차 10/18).
          Flexible(
            child: Text(keepWordsTogether(text),
                semanticsLabel: text,
                style: TextStyle(
                    fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      );
}

/// 다음 예정 — 큰 시각(32) · 무엇을 · 언제 · 자동/물어보고 배지.
class _NextUp extends StatelessWidget {
  const _NextUp({required this.next});
  final RoutineNextRun next;

  @override
  Widget build(BuildContext context) {
    final n = next;
    // 큰 시각 바로 옆이라 '매일 22:00'의 시각은 되풀이하지 않는다(평가 6차 10/18) — 큰 시각과 **같을 때만** 뺀다
    // (다르면 시간대가 어긋난 것이라 그대로 둔다, 2차 평가 10/18).
    final repeat = withAmPm(n.when.contains(n.clock) ? n.when.replaceAll(n.clock, '').trim() : n.when);
    final when = [
      if (n.dayLabel.isNotEmpty) n.dayLabel,
      if (repeat.isNotEmpty) repeat,
    ].join(' · ');
    // 루틴 탭 다음 실행 줄과 같은 말(평가 4차 10/18: 여기는 '자동', 루틴 탭은 '자동 실행'이었다).
    // 한 번 건너뛴 회차(2026-10-18)는 본체 말 '오늘은 건너뛰어요' — 중립색(초록·실패 색 아님), '자동으로 해요'는 함께 말하지 않는다.
    final badge = n.quietSkip
        ? StatusBadge(icon: AppIcons.quietHours, label: n.modeText)
        : n.skipped
            ? StatusBadge(key: const Key('home-next-skipped'), icon: AppIcons.skipOnce, label: n.skipText)
        // 평가 14차(10/18): 칩 '자동으로 해요'와 루틴 줄 '자동'·탭 '자동으로 하기'가 섞였다 → 루틴 줄과 같은 짧은 '자동'(칩 아님).
        : n.auto
            ? Semantics(
                label: '자동 루틴, 묻지 않고 해요',
                excludeSemantics: true,
                child: Text('자동',
                    key: const Key('home-next-auto'),
                    style: TextStyle(
                        fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appPrimary)),
              )
            : n.mode == RoutineMode.notify.value || n.modeLabel == RoutineMode.notify.label
                ? StatusBadge(icon: AppIcons.notify, label: n.modeText)
                : const StatusBadge(icon: Icons.front_hand_outlined, label: '물어보고 해요');
    // 오전/오후 표기(평가 7차 10/18) — 루틴 목록의 '매일 오전 7:00'과 같은 꼴. 큰 숫자는 '7:00', 그 위에 작은 '오전'.
    final ampm = ampmClock(n.clock);
    final split = ampm.indexOf(' ');
    final clock = Semantics(
      label: ampm,
      excludeSemantics: true,
      child: Column(
        key: const Key('home-next-clock'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (split > 0)
            Text(ampm.substring(0, split),
                style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appMuted)),
          Text(
            split > 0 ? ampm.substring(split + 1) : ampm,
            style: TextStyle(
              fontSize: AppFont.number,
              fontWeight: FontWeight.w700,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: context.appInk,
            ),
          ),
        ],
      ),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(keepWordsTogether(n.name), semanticsLabel: n.name, style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpace.xs),
        // 언제와 배지를 한 줄에 — 좁으면 배지가 아래로 내려간다.
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (when.isNotEmpty)
              Text(keepPhrasesTogether(when, wholeParts: MediaQuery.textScalerOf(context).scale(1) <= 1.3),
                  semanticsLabel: when, style: context.appCaption),
            badge,
          ],
        ),
        // '오늘은 건너뛰기' / '되돌리기' — 이 회차 한 번만(본체가 단추 말을 줄 때만, 조용한 시간 회차는 없음).
        if (n.canSkip) ...[
          const SizedBox(height: AppSpace.xs),
          SkipNextControl(next: n),
        ],
      ],
    );
    // 큰 글씨에서는 시각을 위에, 설명을 아래에 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [clock, const SizedBox(height: AppSpace.xs), info],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        clock,
        const SizedBox(width: AppSpace.lg),
        Expanded(child: info),
      ],
    );
  }
}

// ── 실패 경고 · 해야 할 일 · 안 본 알림 ─────────────────────────────────────────

/// 홈 맨 위 **실패 경고**(휴리스틱 평가 10/18 — 실패 경고·일반 알림·설정 남음이 '확인이 필요해요' 한 상자에 같은 무게로
/// 섞였다). 가장 무거운 것 하나와 할 일 단추 하나만 — 있을 때만.
///
/// - 지난 일을 못 했으면(failed) '지난 일을 못 했어요 · 결과 보기', 됐는지 모르면(unconfirmed) '지난 일이 됐는지 확인하지 못했어요 · 결과 보기'.
///   됐다고 말하지 않는다 — 상태 화면에서 무엇이 확인됐는지 본다.
/// - 안 본 알림에 못 한 일이 있으면 '공기청정기 바람 중간으로 하기 · 3번 못 했어요 · 기록 보기'(못 한 일만 거른 기록으로).
///   위험 소리·멈춘 일 같은 다른 볼 것은 '알림 보기'(보호자 알림함).
