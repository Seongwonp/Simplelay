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
        subtitle: Text(subtitle,
            style: TextStyle(color: context.appMuted, fontSize: 14)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                    color: AppColors.onAccent,
                    fontSize: 12,
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
    final overview = ref.watch(thinqOverviewProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('LG ThinQ 연결')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            overview == null
                ? '아직 ThinQ 계정이 허브에 연결되지 않았어요. 연결은 허브에서 설정해요.'
                : '허브에 연결된 ThinQ 가전이에요. 누를 버튼이 없어 목적(말)과 루틴으로 맡겨요.',
            style: TextStyle(fontSize: 16, color: context.appMuted),
          ),
          const _ThinqApplianceList(),
        ],
      ),
    );
  }
}

// ── 음성으로 멈추기 ───────────────────────────────────────────────────────

/// 음성 정지는 **아직 허브에 들어가지 않았다**(실행 계획 §3-3, 통신 확인 뒤
/// 착수). 켜는 스위치를 두면 되지도 않는 기능을 된다고 말하게 되므로,
/// 어떻게 동작할 것인지와 지금 상태만 적는다.
class _VoiceStopScreen extends StatelessWidget {
  const _VoiceStopScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('음성으로 멈추기')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('동작 중에만 "멈춰"를 들어요',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              '허브가 버튼을 누르는 동안과 정지 버튼 위에서 기다리는 동안에만 마이크를 열어요. '
              '"멈춰·정지·그만"을 들으면 정지 버튼을 눌러요. 다시 시작은 화면에서만 할 수 있어요.',
              style: TextStyle(fontSize: 16, color: context.appMuted),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: context.appWarning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '아직 준비 중이에요. 지금은 화면의 정지 버튼이나 허브의 비상정지 버튼을 써 주세요.',
                    style: TextStyle(fontSize: 16, color: context.appWarning),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

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
        padding: const EdgeInsets.all(20),
        children: [
          Text('지금 글자 크기: $scale%',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            '휴대폰 설정 → 디스플레이 → 글자 크기에서 바꾸면 이 앱도 함께 커져요. '
            '200%까지 화면이 잘리지 않게 만들었어요.',
            style: TextStyle(fontSize: 16, color: context.appMuted),
          ),
        ],
      ),
    );
  }
}
