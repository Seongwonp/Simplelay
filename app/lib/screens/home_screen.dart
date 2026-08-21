import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/dnd_bottom_sheet.dart';
import '../widgets/learning_stats_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(bleConnectionProvider).valueOrNull ??
        BleConnectionState.disconnected;
    final rpiState   = ref.watch(rpiConnectionProvider);
    final suggestions = ref.watch(suggestionProvider);
    final dndUntil   = ref.watch(dndProvider);
    final sensorAsync = ref.watch(sensorProvider);

    final connected   = connection == BleConnectionState.connected;
    final rpiOnline   = rpiState == RpiConnectionState.connected;
    final dndActive   = dndUntil != null && dndUntil.isAfter(DateTime.now());

    // 사용자 정의 가전은 의도 해석 규칙이 없어서 수동 버튼 화면으로 이동
    final isCustomAppliance = ref.watch(selectedApplianceProvider).isCustom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SimpleLay'),
        actions: [
          // DND 토글 버튼
          IconButton(
            onPressed: () => showDndSheet(context),
            icon: Icon(
              dndActive
                  ? Icons.do_not_disturb_on
                  : Icons.do_not_disturb_on_outlined,
              color: dndActive ? AppColors.warning : null,
            ),
            tooltip: dndActive ? '방해 금지 활성' : '방해 금지',
          ),
          // 연결 상태 chip
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _ConnectionChip(connected: connected, rpiOnline: rpiOnline),
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
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          // ── 온습도 스트립 ────────────────────────────────────────────────
          sensorAsync.when(
            data: (reading) => _SensorStrip(reading: reading),
            loading: () => const _SensorStrip(reading: null),
            error: (_, __) => const SizedBox.shrink(),
          ),

          // ── DND 배너 ─────────────────────────────────────────────────────
          if (dndActive) ...[
            const SizedBox(height: 12),
            _DndBanner(
              until: dndUntil!,
              onClear: () => ref.read(dndProvider.notifier).clear(),
            ),
          ],

          // ── RPi 연결 상태 카드 ────────────────────────────────────────────
          const SizedBox(height: 12),
          _RpiStatusCard(state: rpiState),

          // ── BLE 연결 상태 카드 (미연결 시만) ─────────────────────────────
          if (!connected) ...[
            const SizedBox(height: 12),
            _BleStatusCard(connected: connected),
          ],

          const SizedBox(height: 16),
          LearningStatsCard(suggestions: suggestions),
          const SizedBox(height: 28),
          Text('대기 중인 제안', style: AppText.title),
          const SizedBox(height: 12),
          if (suggestions.isEmpty)
            _EmptySuggestions(dndActive: dndActive)
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

// ── 온습도 스트립 ──────────────────────────────────────────────────────────

class _SensorStrip extends StatelessWidget {
  const _SensorStrip({required this.reading});
  final SensorReading? reading;

  @override
  Widget build(BuildContext context) {
    final temp = reading?.temperature;
    final hum  = reading?.humidity;
    if (temp == null && hum == null) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: reading != null ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (temp != null) ...[
            const Icon(Icons.thermostat_outlined,
                size: 14, color: AppColors.onSurfaceMuted),
            const SizedBox(width: 4),
            Text(
              '${temp.toStringAsFixed(1)}°C',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.onSurfaceMuted),
            ),
          ],
          if (temp != null && hum != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('·',
                  style: TextStyle(color: AppColors.onSurfaceMuted)),
            ),
          if (hum != null) ...[
            const Icon(Icons.water_drop_outlined,
                size: 14, color: AppColors.onSurfaceMuted),
            const SizedBox(width: 4),
            Text(
              '${hum.toStringAsFixed(0)}%',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.onSurfaceMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// ── DND 활성 배너 ─────────────────────────────────────────────────────────

class _DndBanner extends StatelessWidget {
  const _DndBanner({required this.until, required this.onClear});
  final DateTime until;
  final VoidCallback onClear;

  String get _remaining {
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return '해제됨';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분 남음' : '$h시간 남음';
    }
    return '${diff.inMinutes + 1}분 남음';
  }

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.do_not_disturb_on,
                color: AppColors.warning, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '방해 금지 중 · $_remaining',
                style: const TextStyle(
                    color: AppColors.warning, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.warning,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('해제', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
}

// ── RPi 연결 상태 카드 ────────────────────────────────────────────────────

class _RpiStatusCard extends ConsumerWidget {
  const _RpiStatusCard({required this.state});
  final RpiConnectionState state;

  // simplelay.local(mDNS)이 안 풀리는 Android 폰을 위한 최후 동선 —
  // IP만 쳐도 normalizeRpiUrl이 http://·:8000을 채워서 저장한다.
  Future<void> _promptForAddress(BuildContext context, WidgetRef ref) async {
    final controller =
        TextEditingController(text: ref.read(rpiUrlProvider) ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('RPi 서버 주소'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '예: 192.168.0.10',
            helperText: 'RPi5 화면이나 공유기 관리 페이지에서 IP를 확인할 수 있어요.',
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    // save가 정규화 + 저장하고, rpiUrlProvider listen이 연결 확인을 트리거한다
    await ref.read(rpiUrlProvider.notifier).save(result);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (Color color, IconData icon, String title, String subtitle) =
        switch (state) {
      RpiConnectionState.connected => (
          AppColors.success,
          Icons.wifi,
          'RPi 서버 연결됨',
          'AI 추론 · 제안 · 실행 준비 완료',
        ),
      RpiConnectionState.checking => (
          AppColors.warning,
          Icons.sync,
          '연결 확인 중…',
          'simplelay.local 에 접속 중입니다',
        ),
      RpiConnectionState.unreachable => (
          AppColors.danger,
          Icons.wifi_off,
          'RPi 서버에 연결할 수 없음',
          '같은 Wi-Fi인지 확인하거나 주소를 직접 입력하세요',
        ),
      RpiConnectionState.unconfigured => (
          context.appMuted,
          Icons.wifi_off,
          'RPi 서버 미설정',
          '설정에서 서버 주소를 입력하세요',
        ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppText.body
                          .copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: AppText.caption),
                ],
              ),
            ),
            if (state == RpiConnectionState.unreachable ||
                state == RpiConnectionState.unconfigured) ...[
              TextButton(
                onPressed: () => _promptForAddress(context, ref),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('주소 입력', style: TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(rpiConnectionProvider.notifier).check(),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('재시도', style: TextStyle(fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── BLE 연결 상태 카드 (미연결 시만 표시) ─────────────────────────────────

class _BleStatusCard extends StatelessWidget {
  const _BleStatusCard({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: context.appSurfaceLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.appBorderSubtle),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                ),
                child: Icon(Icons.bluetooth_disabled,
                    color: context.appMuted, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('BLE 기기 미연결', style: AppText.body),
                    const SizedBox(height: 2),
                    Text('설정에서 SimpleLay 기기를 연결하세요',
                        style: AppText.caption),
                  ],
                ),
              ),
              Consumer(
                builder: (_, ref, __) => TextButton(
                  onPressed: () => GoRouter.of(ref.context).go('/settings'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('연결', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      );
}

// ── 연결 상태 chip (AppBar) ───────────────────────────────────────────────

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.connected, required this.rpiOnline});
  final bool connected;
  final bool rpiOnline;

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = rpiOnline
        ? (AppColors.success, '연결됨')
        : connected
            ? (AppColors.warning, 'BLE만')
            : (context.appMuted, '미연결');

    return Chip(
      avatar: Icon(
        rpiOnline ? Icons.wifi : Icons.wifi_off,
        size: 14,
        color: color,
      ),
      label: Text(label,
          style: TextStyle(fontSize: 11, color: color)),
      backgroundColor: color.withValues(alpha: 0.10),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
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
                  child: Icon(Icons.auto_awesome,
                      color: context.appPrimary, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(suggestion.label, style: AppText.body),
                      const SizedBox(height: 2),
                      Text('${suggestion.steps.length}단계 동작',
                          style: AppText.caption),
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

// ── 빈 제안 상태 ──────────────────────────────────────────────────────────

class _EmptySuggestions extends StatelessWidget {
  const _EmptySuggestions({required this.dndActive});
  final bool dndActive;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
          child: Column(
            children: [
              Icon(
                dndActive
                    ? Icons.do_not_disturb_on_outlined
                    : Icons.lightbulb_outline,
                color: dndActive ? AppColors.warning : AppColors.onSurfaceMuted,
                size: 36,
              ),
              const SizedBox(height: 12),
              Text(
                dndActive ? '방해 금지 모드 중' : '새로운 제안이 없습니다.',
                style: const TextStyle(color: AppColors.onSurfaceMuted),
              ),
              if (dndActive) ...[
                const SizedBox(height: 4),
                const Text(
                  'AI 제안이 일시적으로 꺼져 있습니다.',
                  style: TextStyle(
                      color: AppColors.onSurfaceMuted, fontSize: 12),
                ),
              ],
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
