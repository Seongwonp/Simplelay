import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _loading = false;

  Future<void> _start() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: context.appBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ── 아이콘 ─────────────────────────────────────────────────
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: context.appPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: context.appPrimary.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(
                  Icons.home_max_outlined,
                  size: 36,
                  color: context.appPrimary,
                ),
              ),
              const SizedBox(height: 28),

              // ── 타이틀 ─────────────────────────────────────────────────
              Text(
                'SimpleLay에 오신 것을\n환영합니다',
                textAlign: TextAlign.center,
                style: AppText.heading.copyWith(
                  color: cs.onSurface,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'AI가 상황을 인식하고 가전을 대신 조작합니다',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: context.appMuted),
              ),

              const Spacer(flex: 2),

              // ── 특징 3가지 ──────────────────────────────────────────────
              _FeatureRow(
                icon: Icons.wifi_rounded,
                title: '자동 연결',
                body: 'RPi5와 같은 WiFi에 연결하면\nsimplelay.local로 자동 접속됩니다',
              ),
              const SizedBox(height: 20),
              _FeatureRow(
                icon: Icons.lightbulb_outline_rounded,
                title: 'AI 제안',
                body: '상황을 감지하면 가전 조작 제안이\n화면에 나타납니다',
              ),
              const SizedBox(height: 20),
              _FeatureRow(
                icon: Icons.do_not_disturb_on_outlined,
                title: '방해 금지',
                body: '홈 화면 우측 상단 버튼으로\n제안을 잠시 멈출 수 있습니다',
              ),

              const Spacer(flex: 3),

              // ── 시작 버튼 ───────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _loading ? null : _start,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.appPrimary,
                    foregroundColor: isDark
                        ? AppColors.background
                        : AppColors.backgroundLight,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.background,
                          ),
                        )
                      : const Text(
                          '시작하기',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: context.appPrimary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: context.appPrimary),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: AppText.body.copyWith(
                  fontSize: 13,
                  color: context.appMuted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
