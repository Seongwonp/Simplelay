import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/ble_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final suggestions = ref.watch(suggestionProvider);
    final connected = connection == BleConnectionState.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('SimpleLay')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: connected ? () => context.go('/voice') : null,
        backgroundColor: connected ? AppColors.primary : Colors.white12,
        foregroundColor: connected ? Colors.black : AppColors.onSurfaceMuted,
        icon: const Icon(Icons.mic_rounded),
        label: const Text('말하기'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _BleStatusCard(connected: connected),
          const SizedBox(height: 32),
          Text('대기 중인 제안', style: AppText.title),
          const SizedBox(height: 12),
          if (suggestions.isEmpty)
            _EmptySuggestions()
          else
            ...suggestions.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SlidingCard(
                  child: _SuggestionTile(
                    suggestion: s,
                    onTap: () => context.push('/suggestion/${s.sequenceId}'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── BLE 연결 상태 카드 ─────────────────────────────────────────────────────

class _BleStatusCard extends StatelessWidget {
  const _BleStatusCard({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: connected
            ? AppColors.primary.withValues(alpha: 0.10)
            : AppColors.surfaceLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: connected ? AppColors.primary.withValues(alpha: 0.4) : AppColors.borderSubtle,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected
                    ? AppColors.primary.withValues(alpha: 0.18)
                    : Colors.white12,
              ),
              child: Icon(
                connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: connected ? AppColors.primary : AppColors.onSurfaceMuted,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connected ? '기기 연결됨' : '기기 연결 필요',
                    style: AppText.title,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    connected
                        ? '명령을 보낼 준비가 되었습니다.'
                        : '설정에서 SimpleLay 기기를 연결하세요.',
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            if (!connected)
              Consumer(
                builder: (_, ref, __) => TextButton(
                  onPressed: () => GoRouter.of(ref.context).go('/settings'),
                  child: const Text('연결'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── 제안 카드 타일 ────────────────────────────────────────────────────────

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({required this.suggestion, required this.onTap});
  final dynamic suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.auto_awesome,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(suggestion.label, style: AppText.body),
                      const SizedBox(height: 2),
                      Text(
                        '${suggestion.steps.length}단계 동작',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.onSurfaceMuted),
              ],
            ),
          ),
        ),
      );
}

// ── 빈 상태 ───────────────────────────────────────────────────────────────

class _EmptySuggestions extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
          child: Column(
            children: [
              Icon(Icons.lightbulb_outline,
                  color: AppColors.onSurfaceMuted, size: 36),
              const SizedBox(height: 12),
              const Text('새로운 제안이 없습니다.',
                  style: TextStyle(color: AppColors.onSurfaceMuted)),
            ],
          ),
        ),
      );
}

// ── 슬라이딩 카드 애니메이션 ───────────────────────────────────────────────

class _SlidingCard extends StatefulWidget {
  const _SlidingCard({required this.child});
  final Widget child;

  @override
  State<_SlidingCard> createState() => _SlidingCardState();
}

class _SlidingCardState extends State<_SlidingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final Animation<Offset> _offset = Tween(
    begin: const Offset(0, 0.12),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart));
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _offset, child: widget.child),
      );
}
