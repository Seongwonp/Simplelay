import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/learning_stats_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final suggestions = ref.watch(suggestionProvider);
    final connected = connection == BleConnectionState.connected;
    final statusColor = connected ? AppColors.success : AppColors.primary;
    // 사용자 정의 가전은 의도 해석 규칙이 없어서 음성 명령 대신 버튼을 직접
    // 탭해서 실행하는 화면으로 보낸다 (manual_control_screen.dart).
    final isCustomAppliance = ref.watch(selectedApplianceProvider).isCustom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SimpleLay'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Chip(
                avatar: Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  size: 16,
                  color: statusColor,
                ),
                label: Text(
                  connected ? '연결됨' : '미연결',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: statusColor),
                ),
                backgroundColor: statusColor.withValues(alpha: 0.12),
                side: BorderSide(color: statusColor, width: 0.5),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: isCustomAppliance
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/manual-control'),
              backgroundColor: context.appPrimary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              icon: const Icon(Icons.touch_app),
              label: const Text('버튼으로 조작'),
            )
          : FloatingActionButton.extended(
              onPressed: connected ? () => context.go('/voice') : null,
              backgroundColor: connected
                  ? context.appPrimary
                  : Theme.of(context).colorScheme.surfaceContainerHigh,
              foregroundColor: connected
                  ? Theme.of(context).colorScheme.onPrimary
                  : context.appMuted,
              icon: const Icon(Icons.mic_rounded),
              label: const Text('말하기'),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _BleStatusCard(connected: connected),
          const SizedBox(height: 16),
          LearningStatsCard(suggestions: suggestions),
          const SizedBox(height: 28),
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
            ? context.appPrimary.withValues(alpha: 0.10)
            : context.appSurfaceLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: connected
              ? context.appPrimary.withValues(alpha: 0.4)
              : context.appBorderSubtle,
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
                    ? context.appPrimary.withValues(alpha: 0.18)
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
              ),
              child: Icon(
                connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: connected ? context.appPrimary : context.appMuted,
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
                    color: context.appPrimary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.auto_awesome,
                    color: context.appPrimary,
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
                Icon(Icons.chevron_right, color: context.appMuted),
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
