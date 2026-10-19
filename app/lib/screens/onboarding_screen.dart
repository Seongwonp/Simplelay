import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

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

  /// 첫 화면의 할 일은 본체 연결이다 — '시작하기'는 연결 없이 홈으로만 가서, 처음 쓰는 사람은 연결한 줄 알았다
  /// (첫 사용 검토 10/19). 연결 화면에서 연결을 마치고 돌아오면 홈으로 간다. 못 했으면 이 화면에 남는다.
  Future<void> _pair() async {
    final paired = await context.push<bool>('/pair');
    if (paired == true && mounted) await _start();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: context.appBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxxl),
          child: Column(
            children: [
              // 본문은 스크롤 -- 글씨를 키우면 안내가 화면 밖으로 넘쳐,
              // 정작 글씨가 필요한 사용자가 내용을 잃는다.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: AppSpace.xxxl),

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
                      const SizedBox(height: AppSpace.xxxl),

                      // ── 타이틀 ─────────────────────────────────────────────────
                      Text(
                        '반가워요.\nSimpleLay예요',
                        textAlign: TextAlign.center,
                        style: AppText.heading.copyWith(
                          color: cs.onSurface,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      Text(
                        '가전을 등록하고 허락하면\n누름 장치가 버튼을 대신 눌러 줘요.',
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(color: context.appMuted),
                      ),

                      const SizedBox(height: AppSpace.xxxl),

                      // ── 특징 3가지 ──────────────────────────────────────────────
                      _FeatureRow(
                        icon: Icons.wifi_rounded,
                        title: '본체 연결',
                        body: '폰을 본체와 같은 와이파이에 연결해 주세요.',
                      ),
                      const SizedBox(height: AppSpace.xl),
                      _FeatureRow(
                        icon: Icons.lightbulb_outline_rounded,
                        title: '때맞춰 물어보기',
                        body: '자주 하는 일을 때맞춰\n할까요? 하고 물어봐요.',
                      ),
                      const SizedBox(height: AppSpace.xl),
                      _FeatureRow(
                        icon: AppIcons.routine,
                        title: '내 루틴',
                        body: '자주 누르는 순서를 저장하고\n루틴 화면에서 실행해요.',
                      ),

                      const SizedBox(height: AppSpace.xxxl),
                    ],
                  ),
                ),
              ),

              // ── 시작 버튼 ── 스크롤 밖에 고정해 항상 닿게 ──────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('onboarding-pair'),
                  onPressed: _loading ? null : _pair,
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
                          '본체 연결하기',
                          style: TextStyle(
                            fontSize: AppFont.caption,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              // 본체가 아직 없거나 설치하는 분이 나중에 연결할 때 — 홈의 연결 안내로 이어진다.
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  key: const Key('onboarding-later'),
                  onPressed: _loading ? null : _start,
                  style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: const Text('나중에 연결할게요'),
                ),
              ),

              const SizedBox(height: AppSpace.xl),
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
        const SizedBox(width: AppSpace.lg),
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
              const SizedBox(height: AppSpace.xs),
              Text(
                body,
                style: AppText.body.copyWith(
                  fontSize: AppFont.caption,
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
