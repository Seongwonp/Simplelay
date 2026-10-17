part of '../settings_screen.dart';

// ── 섹션 헤더 ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  // 11px 대문자 라벨은 개발자 도구의 문법이다. 홈·제안·실행 상태와 같은
  // 구획 제목을 쓴다.
  Widget build(BuildContext context) => Text(title, style: AppText.title);
}

// ── 공통 카드 컨테이너 ────────────────────────────────────────────────────

/// 설정 항목 한 줄. 이름은 예전 그대로지만 더는 카드가 아니다.
///
/// 항목마다 둥근 카드를 두면 모든 설정의 깊이가 같아 보이고, 화면이
/// 카드 더미가 된다. 행과 구분선이면 충분하다.
class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: child,
          ),
          Divider(height: 1, color: context.appBorderFaint),
        ],
      );
}
