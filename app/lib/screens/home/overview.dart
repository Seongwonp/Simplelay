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
                label: '자동 실행, 묻지 않고 해요',
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
