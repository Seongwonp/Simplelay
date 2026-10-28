part of '../settings_screen.dart';

// 음성 안내 토글

class _VoiceGuideTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(voiceGuideProvider);
    return _SettingCard(
      child: SwitchListTile(
        // 다른 설정 줄과 같은 아이콘 열(평가 15차 10/18: 화면·소리 줄만 아이콘이 왼쪽으로 붙어 있었다).
        contentPadding: const EdgeInsets.symmetric(horizontal: kSettingsRowInset),
        secondary: const Icon(Icons.record_voice_over),
        title: const Text('음성 안내'),
        subtitle: Text(keepWordsTogether('실행 결과를 소리로 알려 줘요'),
            style: TextStyle(color: context.appMuted, fontSize: AppFont.caption)),
        value: enabled,
        onChanged: (v) => ref.read(voiceGuideProvider.notifier).set(v),
      ),
    );
  }
}

// 테마 토글

class _ThemeToggleTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLight = ref.watch(themeModeProvider) == ThemeMode.light;
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: kSettingsRowInset),
        // 평가 14차(10/18): 꺼져 있을 때 해 아이콘이라 '어두운 화면'과 어긋났다 → 켜짐·꺼짐과 상관없이 같은 대비 아이콘.
        secondary: const Icon(Icons.contrast),
        // 제목은 고정 — 켜고 끌 때마다 제목이 바뀌면 스위치가 무엇을 뜻하는지 헷갈린다(2026-10-14 UX).
        title: const Text('어두운 화면'),
        value: !isLight,
        onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
      ),
    );
  }
}
