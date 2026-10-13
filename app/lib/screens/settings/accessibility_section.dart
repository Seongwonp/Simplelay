part of '../settings_screen.dart';

// ── 음성 안내 토글 ─────────────────────────────────────────────────────────

class _VoiceGuideTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(voiceGuideProvider);
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.record_voice_over),
        title: const Text('음성 안내'),
        subtitle: Text('실행 결과를 소리로 알려 줘요',
            style: TextStyle(color: context.appMuted, fontSize: 12)),
        value: enabled,
        onChanged: (v) => ref.read(voiceGuideProvider.notifier).set(v),
      ),
    );
  }
}

// ── 테마 토글 ─────────────────────────────────────────────────────────────

class _ThemeToggleTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLight = ref.watch(themeModeProvider) == ThemeMode.light;
    return _SettingCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(isLight ? Icons.light_mode : Icons.dark_mode),
        // 제목은 고정 — 켜고 끌 때마다 제목이 바뀌면 스위치가 무엇을 뜻하는지 헷갈린다(2026-10-14 UX).
        title: const Text('어두운 화면'),
        value: !isLight,
        onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
      ),
    );
  }
}
