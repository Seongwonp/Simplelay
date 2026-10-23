part of '../home_screen.dart';

class _HomeRoutines extends ConsumerStatefulWidget {
  const _HomeRoutines({
    required this.hubConnected,
    required this.hasAppliances,
    required this.applianceNames,
    this.applianceIcons = const {},
    this.needsSetupIds = const {},
    this.featureFirst = true,
  });

  /// 가전 id → 아이콘. 루틴 타일 아이콘을 대상 가전 아이콘으로(평가 3차 10/18).
  final Map<String, IconData> applianceIcons;
  final bool featureFirst;

  /// 위치(버튼 자리)를 아직 맞추지 않은 가전 — 이 가전을 쓰는 루틴 타일은 설정으로 보낸다.
  final Set<String> needsSetupIds;

  final bool hubConnected;
  final bool hasAppliances;
  final Map<String, String> applianceNames;

  @override
  ConsumerState<_HomeRoutines> createState() => _HomeRoutinesState();
}

class _HomeRoutinesState extends ConsumerState<_HomeRoutines> {
  String? _runningId;
  String? _error;
  String? _errorFor;

  static const _maxTiles = 1;

  Future<void> _run(Routine r) async {
    final id = r.id!;
    if (_runningId != null) return;
    try {
      // 먼저 무엇을 하는지 묻는다(휴리스틱 평가 10/18) — 고르면 루틴 탭과 같은 승인 카드 경로.
      final error = await confirmAndRunRoutine(context, ref, r, onConfirmed: () {
        if (!mounted) return;
        setState(() {
          _runningId = id;
          _error = null;
        });
      });
      if (mounted && error != null) {
        setState(() {
          _error = error;
          _errorFor = id;
        });
      }
    } finally {
      if (mounted) setState(() => _runningId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(routinesProvider);
    return async.when(
      // 불러오는 중에는 자리를 비워 둔다 — '없음'으로 보이지 않게.
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        // 허브 주소가 없거나 허브에 닿지 않으면 위의 허브 안내가 이미 말한다.
        if (e is RoutinesUnavailable || !widget.hubConnected) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxl),
          child: Text('루틴을 불러오지 못했어요.',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        );
      },
      data: (routines) {
        if (routines.isEmpty) {
          // 0대면 가전 추가가 첫 과업이다 — 루틴 입구를 겹쳐 두지 않는다.
          if (!widget.hasAppliances) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: AppSpace.xxl),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('home-new-routine'),
                onPressed: () => context.push('/routine/edit'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 루틴 만들기'),
              ),
            ),
          );
        }
        bool needsSetup(Routine r) => r.applianceIds.any(widget.needsSetupIds.contains);
        final manual = [
          for (final r in routines)
            if (r.isRunCandidate && r.trigger.kind != RoutineTriggerKind.time) r,
        ];
        if (manual.isEmpty) {
          return Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            key: const Key('home-routines-more'),
            onPressed: () => context.push('/routines'),
            icon: const Icon(Icons.bookmark_outline), label: const Text('저장한 동작 전체'),
          ));
        }
        // 준비된 루틴이 먼저, 설정이 필요한 루틴은 뒤.
        final ordered = [
          ...manual.where((r) => !needsSetup(r)),
          ...manual.where(needsSetup),
        ];
        final shown = ordered.take(_maxTiles).toList();
        final busy = _runningId != null;
        final tiles = [
          for (final r in shown)
            _RoutineTile(
              routine: r,
              subtitle: routineSubtitle(r, widget.applianceNames),
              iconOf: widget.applianceIcons,
              running: _runningId == r.id,
              busy: busy,
              needsSetup: needsSetup(r),
              featured: widget.featureFirst && r == shown.first && !needsSetup(r),
              onTap: needsSetup(r)
                  // 설정이 필요한 가전으로 바로 간다(UI 평가 10/17).
                  ? () => context.push('/appliance/detail/'
                      '${r.applianceIds.firstWhere(widget.needsSetupIds.contains, orElse: () => r.applianceIds.first)}')
                  : () => _run(r),
            ),
        ];
        final errorRoutine = shown.where((r) => r.id == _errorFor).firstOrNull;
        return Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxl),
          child: Column(
            key: const Key('home-routines'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 제목과 '루틴 더 보기'는 한 줄에 다 들어갈 때만 나란히 — 큰 글씨에서는 버튼이 다음 줄로 간다
              // (평가 4차 10/18: 200%에서 '내 루/틴'으로 꺾였다).
              Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                const _SectionTitle('무엇을 할까요?'),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: TextButton(
                      key: const Key('home-routines-more'),
                      onPressed: () => context.push('/routines'),
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(child: Text('저장한 동작 전체', style: TextStyle(fontSize: AppFont.caption, color: context.appMuted))),
                        Icon(Icons.chevron_right, size: 20, color: context.appMuted),
                      ]),
                    ),
                  ),
              ]),
              // 줄 목록 — 가전 타일(카드)과 다른 모양(평가 5차 10/18).
              for (var i = 0; i < tiles.length; i++) ...[
                tiles[i],
                if (i + 1 < tiles.length) Divider(height: 1, color: context.appBorderFaint),
              ],
              if (errorRoutine != null && _error != null)
                _ErrorLine('${errorRoutine.name}: $_error'),
            ],
          ),
        );
      },
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Text(keepWordsTogether(text),
            style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
      );
}

/// 루틴 한 줄 — 아이콘 · 이름 · 무엇을 · 오른쪽 '지금 하기 >' 표시(설정이 필요하면 같은 꼴의 '설정하기 >').
///
/// 평가 5차(10/18): 가전 타일과 같은 흰 카드 2열이라 가전인지 루틴인지 모양으로 갈리지 않았다 — 루틴은 카드가 아닌
/// 줄 목록으로 둔다. 누르면 승인 카드만 만든다(설정이 필요하면 그 가전으로). 가전은 승인 화면에서 허락해야 움직인다.
class _RoutineTile extends StatelessWidget {
  const _RoutineTile({
    required this.routine,
    required this.subtitle,
    required this.running,
    required this.busy,
    required this.needsSetup,
    required this.onTap,
    this.iconOf = const {},
    this.featured = false,
  });

  final Routine routine;
  final String subtitle;
  final Map<String, IconData> iconOf;
  final bool running;
  final bool busy;
  final bool needsSetup;
  final bool featured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = routine;
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final Widget trailing = running
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        // 설정이 남았으면 같은 꼴의 '설정하기 >' — 무엇이 남았는지는 '확인이 필요해요' 한 곳에서(평가 3차 10/18).
        // 평가 11차(10/18): 글자 단추와 회색 '설정 필요' 칩이 섞여 있었다 — 루틴 탭 줄과 같은 글자 단추.
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Text(keepWordsTogether(needsSetup ? kSetupActionLabel : '지금 하기'),
                style: TextStyle(
                    fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appInk)),
            Icon(Icons.chevron_right, size: 20, color: context.appMuted),
          ]);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(keepWordsTogether(r.name),
            style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
        // 낱말·묶음 중간에서 꺾이지 않게("1단 / 계" 2026-10-14, "LG / 가전 설정" 평가 4차 10/18).
        Text(keepPhrasesTogether(subtitle, wholeParts: !big),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: context.appCaption),
      ],
    );
    if (featured) {
      return _FeaturedAction(
        routine: r, subtitle: subtitle, running: running, busy: busy, onTap: onTap, iconOf: iconOf,
      );
    }
    return Semantics(
      // 화면 글자는 이름뿐이어도 읽을 때는 무엇을 하는지 말한다.
      label: needsSetup ? '${r.name} 가전 설정하기' : '${r.name} 실행하기',
      container: true,
      button: true,
      enabled: needsSetup || !busy,
      excludeSemantics: true,
      child: InkWell(
        key: Key('home-routine-tile-${r.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: needsSetup || !busy ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.sm, horizontal: AppSpace.xs),
            child: big
                // 큰 글씨: 오른쪽 표시를 이름 아래로 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      _RoutineDot(routine: r, iconOf: iconOf, muted: needsSetup),
                      const SizedBox(width: AppSpace.md),
                      Expanded(child: info),
                    ]),
                    const SizedBox(height: AppSpace.xs),
                    trailing,
                  ])
                : Row(children: [
                    _RoutineDot(routine: r, iconOf: iconOf, muted: needsSetup),
                    const SizedBox(width: AppSpace.md),
                    Expanded(child: info),
                    const SizedBox(width: AppSpace.sm),
                    trailing,
                  ]),
          ),
        ),
      ),
    );
  }
}

/// 루틴 줄 왼쪽의 둥근 아이콘 자리(대상 가전 아이콘). 강조색은 쓰지 않는다 — 주 행동 색이 아니다.
class _RoutineDot extends StatelessWidget {
  const _RoutineDot({required this.routine, required this.iconOf, required this.muted});
  final Routine routine;
  final Map<String, IconData> iconOf;
  final bool muted;

  @override
  Widget build(BuildContext context) => Container(
        width: AppSpace.xxxl + AppSpace.sm,
        height: AppSpace.xxxl + AppSpace.sm,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: context.appOverlayFaint, shape: BoxShape.circle),
        child: RoutineIcon(routine: routine, iconOf: iconOf, color: muted ? context.appMuted : context.appInk),
      );
}

// ── 머리 ──────────────────────────────────────────────────────────────────

/// 제목 "우리 집"과 허브 연결 칩. 칩은 색만이 아니라 글자로 말한다.
