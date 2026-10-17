part of '../settings_screen.dart';

// ── 설정 탭 첫 묶음(UI 확정 §2) ──────────────────────────────────────────────

/// 행 여러 개를 한 묶음으로. 카드 더미가 되지 않게 얇은 테두리 하나만 쓴다.
class _NavGroup extends StatelessWidget {
  const _NavGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1)
                Divider(height: 1, color: context.appBorderFaint),
            ],
          ],
        ),
      );
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => ListTile(
        minVerticalPadding: 12,
        leading: Icon(icon, color: context.appPrimary),
        title: Text(title),
        // 어절 단위 줄바꿈('키오스크에서/는' 방지, UI 평가 10/17). 낭독은 원문.
        subtitle: Text(keepWordsTogether(subtitle),
            semanticsLabel: subtitle,
            style: TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                    color: AppColors.onAccent,
                    fontSize: AppFont.caption,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: onTap,
      );
}

// ── LG ThinQ 연결 ─────────────────────────────────────────────────────────

class _ThinqScreen extends ConsumerWidget {
  const _ThinqScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(rpiApiServiceProvider);
    final async = ref.watch(thinqOverviewProvider);
    final overview = async.valueOrNull;
    // 확인 중·확인 실패를 '계정이 연결되지 않았다'로 말하지 않는다(외부 검토 M3, 10/15).
    // 그 말은 허브가 ThinQ를 껐다고 답했을 때(404)만.
    final String headline;
    if (api == null || async.hasError) {
      headline = 'LG 가전이 연결됐는지 몰라요. 본체 연결을 봐 주세요.';
    } else if (!async.hasValue) {
      headline = '연결을 알아보는 중이에요.';
    } else if (overview == null) {
      headline = '본체에 LG 계정이 아직 연결되지 않았어요. 설치하는 분이 연결해요.';
    } else if (overview.appliances.isEmpty) {
      headline = '아직 추가한 LG 가전이 없어요. 아래에서 쓸 가전을 추가해 주세요.';
    } else {
      headline = '본체에 연결된 LG 가전이에요. '
          '가전 화면에서 지금 상태를 보고 바꿀 수 있어요. 루틴에도 넣을 수 있어요.';
    }
    return Scaffold(
      appBar: AppBar(title: const Text('LG 가전 연결')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          Text(
            headline,
            key: const Key('thinq-link-headline'),
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          const _ThinqApplianceList(),
          // 계정에서 찾은 가전 — 사용자가 '추가'를 눌러야 위 목록·홈에 들어온다(2026-10-13).
          const ThinqDiscoveredSection(),
        ],
      ),
    );
  }
}

// ── 음성으로 멈추기 ───────────────────────────────────────────────────────

/// 음성 정지는 **아직 허브에 들어가지 않았다**(실행 계획 §3-3, 통신 확인 뒤
/// 착수). 켜는 스위치를 두면 되지도 않는 기능을 된다고 말하게 되므로,
/// 어떻게 동작할 것인지와 지금 상태만 적는다.
// ── 글자 크기 ─────────────────────────────────────────────────────────────

/// 앱 안에 따로 글자 크기 설정을 두지 않는다 -- 휴대폰 설정 하나로 모든 앱이
/// 같이 커지는 편이 헷갈리지 않는다. 200%까지 화면이 넘치지 않는지 확인한다.
class _TextSizeScreen extends StatelessWidget {
  const _TextSizeScreen();

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(100).round();
    return Scaffold(
      appBar: AppBar(title: const Text('글자 크기')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          Text('지금 글자 크기: $scale%',
              style: const TextStyle(fontSize: AppFont.body, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpace.sm),
          Text(
            '휴대폰 설정 → 디스플레이 → 글자 크기에서 바꾸면 이 앱도 함께 커져요. '
            '200%까지 화면이 잘리지 않게 만들었어요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
        ],
      ),
    );
  }
}
