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
        subtitle: Text('실행 결과를 소리로 읽어줍니다',
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
        title: Text(isLight ? '라이트 모드' : '다크 모드'),
        subtitle: Text(isLight ? '밝은 화면' : '어두운 화면'),
        value: isLight,
        onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
      ),
    );
  }
}
