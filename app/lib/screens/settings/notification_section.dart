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
    return _SettingCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(active
            ? Icons.do_not_disturb_on
            : Icons.do_not_disturb_on_outlined),
        title: const Text('제안 잠시 쉬기'),
        subtitle: Text(
          active ? '지금은 제안을 보내지 않아요' : '몇 시간 동안 제안을 멈춰요',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        trailing: TextButton(
          // 고령 사용자 기준 최소 터치 대상.
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => showDndSheet(context),
          child: Text(active ? '지금 받기' : '시간 고르기'),
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
      helpText: '언제까지 쉴까요?',
    );
    if (picked == null) return;
    final ok =
        await ref.read(wellnessPauseProvider.notifier).pauseUntil(picked);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('설정을 전달하지 못했어요. 연결을 확인해 주세요.')),
      );
    }
  }

  Future<void> _clear() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await ref.read(wellnessPauseProvider.notifier).clear()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('설정을 전달하지 못했어요. 연결을 확인해 주세요.')),
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
          paused ? Icons.notifications_paused : Icons.favorite_outline,
        ),
        title: const Text('안부 확인 쉬기'),
        subtitle: Text(
          paused
              ? '${_ymd(until)}까지 쉬어요. 실행 실패·위험 신호음은 그대로 알려드려요.'
              : '여행처럼 집을 비우는 날 켜세요. 조용한 게 정상인 날 알림이 오지 않아요.',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        trailing: TextButton(
          // 고령 사용자 기준 최소 터치 대상.
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: paused ? _clear : _pick,
          child: Text(paused ? '지금 켜기' : '쉬기'),
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
          return _SuppressionNote(
            text: _noServer ? '기기와 연결되면 여기에 표시돼요.' : '다시 추천 안 하는 항목이 없어요.',
          );
        }
        return Column(
          children: [
            for (final purpose in items)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
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
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          if (leading != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: context.appMuted),
              child: leading!,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(text, style: TextStyle(color: context.appMuted)),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('다시 불러오기')),
        ],
      ),
    );
  }
}
