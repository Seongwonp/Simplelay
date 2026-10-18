part of '../settings_screen.dart';

/// 안부 확인을 며칠 쉰다 — 집을 비운 것을 **아는** 날들.
///
/// 여행·입원처럼 조용한 것이 정상인 날에도 안부 신호는 그대로 울린다.
/// 보호자는 이미 알고 있는 일로 알림을 받고, 며칠 이어지면 정작 진짜 신호가
/// 왔을 때 무시하게 된다 — 안부 기능이 스스로를 무디게 만든다.
///
/// 방해 금지(제안 쪽)와 다른 자리에 둔 이유: 하나로 묶으면 방해 금지 30분이
/// 안부 확인까지 꺼버리거나, 여행 일주일이 제안까지 막는다.
/// 방해 금지 — 제안을 잠시 쉰다.
///
/// 홈 앱바의 아이콘에서 옮겨 왔다. 뜻을 추측해야 하는 그림이 여럿 붙어
/// 있으면 디지털에 익숙하지 않은 사용자에게는 그 줄 전체가 읽을 수 없는
/// 영역이 된다. 자주 쓰는 조작이 아니므로 설정이 맞는 자리다.
///
/// **안부 확인 쉬기와 다른 것이다** -- 아래 타일의 설명을 참고.
class _DndTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final until = ref.watch(dndProvider);
    final active = until != null && until.isAfter(DateTime.now());
    // 업데이트 전에 켠 잠시 쉬기를 이어받은 동안은 새 제안만 쉰다(2026-10-14 마감 2번).
    final carried = ref.watch(dndScopeProvider) == 'suggestions_only';
    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(active
            ? AppIcons.pauseActive
            : AppIcons.pause),
        title: const Text('잠시 쉬기'),
        // 어절 단위 줄바꿈·14pt(UI 평가 3차 10/17 — '쉬 / 어요'로 끊기고 12pt는 작았다).
        subtitle: _WordsText(
          // 잠시 쉬기도 조용한 시간과 같은 판정이다(2026-10-14) — 아직 시작하지 않은 자동 실행도 건너뛴다.
          // 켜져 있으면 끝나는 시각을 함께(2026-10-14 마감 확인 A5).
          !active
              ? '몇 시간 동안 묻지도, 자동으로 하지도 않아요'
              : carried
                  ? '${pauseEndClock(until)}까지 묻지만 않아요. 예전에 켠 설정이라 자동으로 하는 일은 그대로 해요'
                  : '${pauseEndClock(until)}까지 묻지도, 자동으로 하지도 않아요',
          style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
        ),
        // 테두리 버튼 — 글자만 있으면 누를 곳으로 보이지 않는다(UI 평가 10/17). 고령 사용자 기준 최소 터치 대상.
        trailing: OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => showDndSheet(context),
          child: Text(active ? '그만 쉬기' : '시간 고르기'),
        ),
      ),
    );
  }
}

/// 조용한 시간(2026-10-14, 사용자 승인 5번) — 매일 정해진 시간대. 서버에 저장되고 키오스크도 같은 상태를 보인다.
///
/// 실제 범위만 말한다: 서버 `scope` 문장(새 제안과 일반 안내 소리, 아직 시작하지 않은 자동 실행)과
/// '직접 실행·정지는 그대로예요'. 비상정지·실패 경보 소리는 바꾸지 않았다(정책 미정 — 사용자 확인 필요)라서
/// '모든 알림이 조용해진다'고 쓰지 않는다. 시간대는 줄을 누르면 시작·끝 시각을 차례로 고른다.
class _QuietHoursTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_QuietHoursTile> createState() => _QuietHoursTileState();
}

class _QuietHoursTileState extends ConsumerState<_QuietHoursTile> {
  bool _busy = false;

  Future<void> _save(Map<String, Object> change) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null || _busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final saved = await api.setQuietHours(change);
      if (saved?.persisted == false) {
        messenger.showSnackBar(const SnackBar(content: Text(kSettingNotSavedNotice)));
      }
    } on RpiApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.message.isNotEmpty ? e.message : '설정을 본체에 보내지 못했어요. 연결을 봐 주세요.')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('설정을 본체에 보내지 못했어요. 연결을 봐 주세요.')));
    } finally {
      if (mounted) setState(() => _busy = false);
      ref.invalidate(quietHoursProvider);
    }
  }

  static TimeOfDay _parse(String hhmm) {
    final parts = hhmm.split(':');
    return TimeOfDay(hour: int.tryParse(parts.first) ?? 22, minute: int.tryParse(parts.last) ?? 0);
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickRange(QuietHoursStatus s) async {
    final start = await showTimePicker(
        context: context, initialTime: _parse(s.start), helpText: '조용한 시간 시작');
    if (start == null || !mounted) return;
    final end = await showTimePicker(
        context: context, initialTime: _parse(s.end), helpText: '조용한 시간 끝');
    if (end == null || !mounted) return;
    await _save({'start': _fmt(start), 'end': _fmt(end)});
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(rpiApiServiceProvider) != null;
    final s = ref.watch(quietHoursProvider).valueOrNull;
    final rules = ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[];
    final skip = s == null ? null : quietSkipLine(s, rules);
    final muted = TextStyle(color: context.appMuted, fontSize: AppFont.caption);
    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(s?.active == true && s?.reason == 'schedule'
            ? AppIcons.quietHoursActive
            : AppIcons.quietHours),
        title: const Text('조용한 시간'),
        subtitle: s == null
            ? Text(connected ? '설정을 불러오지 못했어요.' : '본체와 연결되면 설정할 수 있어요.', style: muted)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _WordsText(s.summary, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                  // 겹치는 자동 실행을 이름으로(UI 평가 6차 10/17) — 켜는 순간 소리 없이 건너뛰지 않게.
                  // 범위 설명보다 먼저(7차: 가장 중요한 경고가 맨 끝이었다).
                  if (skip != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                      // 앰버는 실제로 건너뛸 때(켜짐)만, 켜면 건너뛸 미리 알림은 회색 — 루틴 탭 규칙 카드와 같은 색 규칙
                      // (UI 평가 8차 10/17).
                      child: _WordsText(skip,
                          style: TextStyle(
                              fontSize: AppFont.caption,
                              color: s.enabled ? context.appWarning : context.appMuted,
                              fontWeight: FontWeight.w600)),
                    ),
                  _WordsText(
                    '${s.scope ?? '묻는 알림과 안내 소리만 쉬어요.'} 직접 하기와 정지는 그대로예요.',
                    style: muted,
                  ),
                ],
              ),
        onTap: s == null || _busy ? null : () => _pickRange(s),
        trailing: SizedBox(
          key: const Key('quiet-hours-switch'),
          height: 48,
          child: Switch(
            value: s?.enabled ?? false,
            onChanged: s == null || _busy ? null : (v) => _save({'enabled': v}),
          ),
        ),
      ),
    );
  }
}

class _WellnessPauseTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WellnessPauseTile> createState() => _WellnessPauseTileState();
}

class _WellnessPauseTileState extends ConsumerState<_WellnessPauseTile> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(wellnessPauseProvider.notifier).refresh();
    });
  }

  Future<void> _pick() async {
    final messenger = ScaffoldMessenger.of(context);
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: today.add(const Duration(days: 3)),
      firstDate: today,
      // 무기한을 두지 않는 것과 같은 이유로 상한도 둔다 — 꺼둔 것을 잊으면
      // 안부 기능이 있는 채로 없는 것과 같아진다.
      lastDate: today.add(const Duration(days: 90)),
      helpText: '언제까지 집을 비우나요?',
    );
    if (picked == null) return;
    final ok =
        await ref.read(wellnessPauseProvider.notifier).pauseUntil(picked);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('설정을 본체에 보내지 못했어요. 연결을 봐 주세요.')),
      );
    }
  }

  Future<void> _clear() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await ref.read(wellnessPauseProvider.notifier).clear()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('설정을 본체에 보내지 못했어요. 연결을 봐 주세요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final until = ref.watch(wellnessPauseProvider);
    final paused = until != null;
    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          paused ? Icons.notifications_paused : Icons.luggage_outlined,
        ),
        // 이름은 하는 일 그대로 '집 비우는 날'(평가 3차 10/18 — '안부 확인 쉬기'는 무엇을 쉬는지 어려웠다).
        title: const Text(kAwayTitle),
        subtitle: _WordsText(
          paused
              ? '${_ymd(until)}까지 집을 비워요. 안부 알림만 쉬고, 실패나 위험 신호음은 그대로 알려 드려요.'
              : '여행처럼 집을 비우는 날 켜세요. 집이 조용해도 안부 알림이 오지 않아요.',
          style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
        ),
        // 테두리 버튼 — 글자만 있으면 누를 곳으로 보이지 않는다(UI 평가 10/17). 고령 사용자 기준 최소 터치 대상.
        trailing: OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: paused ? _clear : _pick,
          child: Text(paused ? '지금 끝내기' : '날짜 정하기'),
        ),
      ),
    );
  }

  static String _ymd(DateTime t) => '${t.month}월 ${t.day}일';
}

/// 다시 추천 안 하는 루틴 목록 -- 개별 해제(다시 받기) 가능.
class _SuppressionSection extends ConsumerStatefulWidget {
  const _SuppressionSection();

  @override
  ConsumerState<_SuppressionSection> createState() =>
      _SuppressionSectionState();
}

class _SuppressionSectionState extends ConsumerState<_SuppressionSection> {
  Future<List<String>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 서버가 없으면 '조회 실패'가 아니라 '해당 없음'이다 -- 억제 목록은
  /// 서버가 들고 있으므로, 연결이 없을 때는 물어볼 곳 자체가 없다.
  bool _noServer = false;

  void _reload() {
    final api = ref.read(rpiApiServiceProvider);
    setState(() {
      _noServer = api == null;
      _future = api?.suppressions() ?? Future<List<String>>.value(const []);
    });
  }

  Future<void> _unmute(String purpose) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api != null) {
      try {
        await api.unmuteSuppression(purpose);
      } catch (_) {}
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snapshot) {
        // '아직 못 불러왔다'와 '못 불러왔다'와 '없다'는 서로 다른 상태다.
        // 셋을 빈 목록 하나로 뭉개면, 조회가 실패한 화면이 "억제한 게 없다"고
        // 단언한다 -- 사용자가 방금 내린 제안이 사라진 것처럼 보인다.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _SuppressionNote(
            text: '불러오는 중이에요.',
            leading: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError && !_noServer) {
          return _SuppressionNote(
            text: '목록을 불러오지 못했어요.',
            leading: Icon(Icons.error_outline, size: 18),
            onRetry: _reload,
          );
        }
        final items = snapshot.data ?? const <String>[];
        if (items.isEmpty) {
          // 비었으면 아무것도 두지 않는다(2026-10-14 UX) — 연결 전 안내만 남긴다.
          if (!_noServer) return const SizedBox.shrink();
          return const _SuppressionNote(text: '본체와 연결되면 여기에 나와요.');
        }
        return Column(
          children: [
            for (final purpose in items)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(purpose),
                trailing: TextButton(
                  onPressed: () => _unmute(purpose),
                  child: const Text('다시 받기'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 억제 목록의 '목록 아닌 상태'(불러오는 중·실패·없음)를 같은 모양으로 그린다.
/// Colors.grey는 크림 배경 위 2.38:1이라 보조 텍스트 토큰을 쓴다(7.4:1 이상).
class _SuppressionNote extends StatelessWidget {
  const _SuppressionNote({required this.text, this.leading, this.onRetry});

  final String text;
  final Widget? leading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm, horizontal: AppSpace.xs),
      child: Row(
        children: [
          if (leading != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: context.appMuted),
              child: leading!,
            ),
            const SizedBox(width: AppSpace.md),
          ],
          Expanded(
            child: Text(keepWordsTogether(text), semanticsLabel: text, style: TextStyle(color: context.appMuted)),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('다시 불러오기')),
        ],
      ),
    );
  }
}

/// 설정 부제 — 어절 단위로만 줄을 바꾸고(낱말 안 결합 문자), 화면 읽기에는 원문을 준다(UI 평가 3차 10/17).
class _WordsText extends StatelessWidget {
  const _WordsText(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      Text(keepWordsTogether(text), semanticsLabel: text, style: style);
}
