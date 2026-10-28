part of '../settings_screen.dart';

// 개발자 화면(설정 맨 아래 항목, 2026-10-18까지는 다섯 번째 탭)
//
// 서버 `SIMPLELAY_DEV_MODE`가 켜졌을 때만 설정에 항목이 보인다(UI 확정 §2, 실행 계획
// §3-8). 개발자 콘솔(모의 조그·원점·정지), 데모 모드와 제안 시뮬레이션이
// 여기 있다. 탭을 숨기는 것은 접근 제한이 아니다 -- 서버가 개발자 모드·개발자
// 토큰으로 따로 막는다.

class DeveloperTabScreen extends ConsumerWidget {
  const DeveloperTabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devMode = ref.watch(developerModeProvider);
    final show = ref.watch(showDeveloperTabProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('개발자')),
      body: !show
          ? Padding(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Text('허브의 개발자 모드가 꺼져 있어요.',
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpace.xl),
              children: [
                Text(
                  devMode
                      ? '허브 개발자 모드가 켜져 있어요. 시연 날에는 끄고 제품 화면만 보여 주세요.'
                      : '허브 개발자 모드는 꺼져 있고, 이 폰의 데모 모드가 켜져 있어서 보여요.',
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
                ),
                const SizedBox(height: AppSpace.lg),
                _SectionHeader(title: '도구'),
                const SizedBox(height: AppSpace.xs),
                _DeveloperToolsTile(),
                const SizedBox(height: AppSpace.xxl),
                // 가전마다 버튼을 눌러 줄 장치(노드) 등록 — 설정에서 옮겨 왔다(2026-10-14 UX).
                _SectionHeader(title: '누름 장치'),
                const SizedBox(height: AppSpace.sm),
                _NodeSection(),
                const SizedBox(height: AppSpace.xxl),
                _SectionHeader(title: '데모'),
                const SizedBox(height: AppSpace.md),
                _DemoModeTile(),
                const SizedBox(height: AppSpace.sm),
                _DemoSection(),
              ],
            ),
    );
  }
}
