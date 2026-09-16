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

    return Scaffold(
      backgroundColor: context.appBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              // 본문은 스크롤 -- 글씨를 키우면 안내가 화면 밖으로 넘쳐,
              // 정작 글씨가 필요한 사용자가 내용을 잃는다.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 32),

                      // ── 아이콘 ─────────────────────────────────────────────────
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: context.appBorderSubtle),
                        ),
                        child: Icon(
                          Icons.home_max_outlined,
                          size: 36,
                          color: context.appInk,
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
                        '복잡한 가전 버튼을 더 쉽게 조작하세요.\n말하거나 화면에서 고르면 대신 눌러드려요.',
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(color: context.appMuted),
                      ),

                      const SizedBox(height: 32),

                      // ── 특징 3가지 ──────────────────────────────────────────────
                      _FeatureRow(
                        icon: Icons.wifi_rounded,
                        title: '자동 연결',
                        body: 'RPi5와 같은 WiFi에 연결하면\nsimplelay.local로 자동 접속돼요',
                      ),
                      const SizedBox(height: 20),
                      _FeatureRow(
                        icon: Icons.lightbulb_outline_rounded,
                        title: '사용 습관 제안',
                        body: '상황을 감지하면 가전 조작 제안이\n화면에 나타납니다',
                      ),
                      const SizedBox(height: 20),
                      _FeatureRow(
                        icon: Icons.do_not_disturb_on_outlined,
                        title: '방해 금지',
                        body: '홈 화면 우측 상단 버튼으로\n제안을 잠시 멈출 수 있어요',
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),

              // ── 시작 버튼 ── 스크롤 밖에 고정해 항상 닿게 ──────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading ? null : _start,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 52),
                    backgroundColor: context.appPrimary,
                    foregroundColor: context.appOnAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _loading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            // 버튼 면 위에 도는 표시 -- 글자와 같은 색이어야
                            // 한다. 다크 배경색 고정이면 라이트 모드의
                            // 어두운 골드 버튼 위에서 사라진다.
                            color: context.appOnAccent,
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
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: context.appInk),
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
