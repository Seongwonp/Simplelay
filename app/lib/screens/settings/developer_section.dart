part of '../settings_screen.dart';

// 고급 설정을 펼쳤을 때만 보이는 구획. 일반 사용자 설정과 섞지 않는다.
// 앞으로 들어갈 개발자 도구(조이스틱·구조화 명령 콘솔·로그)는 이 파일에
// 붙는다 -- 진입은 설정 화면의 '고급 설정' 아래 같은 자리다.

// ── 데모 모드 토글 ─────────────────────────────────────────────────────────

/// 가짜 센서·가짜 결과를 화면에 주입해도 되는 상태를 켜고 끈다.
///
/// 예전에는 `kDebugMode`가 이 역할을 했는데, 그러면 실기기에 물린 디버그
/// 빌드에서도 가짜 센서가 섞여 **안 눌린 실행이 성공으로 끝난다.**
class _DemoModeTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(demoModeProvider);
    // 실행 중에는 잠근다. 모드를 갈아타면 실행 경로(실제 서버 / 모의)가
    // 통째로 바뀌는데, 그 순간 진행 중이던 작업은 추적을 잃는다.
    final phase = ref.watch(executionStatusProvider).phase;
    final busy = phase == ExecutionPhase.running ||
        phase == ExecutionPhase.retrying ||
        phase == ExecutionPhase.waiting;
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.science_outlined),
        title: const Text('데모 모드'),
        subtitle: Text(
          busy
              ? '실행이 끝난 뒤에 바꿀 수 있어요'
              : on
                  ? '실행이 서버로 나가지 않습니다 — 실제 조작이 아닙니다'
                  : '리허설용. 켜면 실행이 서버로 나가지 않습니다',
          style: TextStyle(color: context.appMuted, fontSize: 12),
        ),
        value: on,
        onChanged:
            busy ? null : (v) => ref.read(demoModeProvider.notifier).set(v),
      ),
    );
  }
}

// ── 데모 섹션 ─────────────────────────────────────────────────────────────

class _DemoSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () {
              DemoService(ref.read(bleServiceProvider)).injectSuggestion();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('데모 제안 주입 완료')),
              );
            },
            icon: const Icon(Icons.science_outlined),
            label: const Text('제안 시뮬레이션'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              ref.read(bleServiceProvider).simulateDisconnected();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('연결 해제 시뮬레이션')),
              );
            },
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('연결 해제'),
          ),
        ],
      );
}
