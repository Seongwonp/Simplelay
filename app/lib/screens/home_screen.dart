import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/ble_service.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/dnd_bottom_sheet.dart';

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
          // 실행 기록 (공감지능 근거 + 폐루프 재시도 기록)
          IconButton(
            onPressed: () => context.push('/history'),
            icon: const Icon(Icons.history),
            tooltip: '실행 기록',
          ),
          // DND 토글 버튼
          IconButton(
            onPressed: () => showDndSheet(context),
            icon: Icon(
              dndActive
                  ? Icons.do_not_disturb_on
                  : Icons.do_not_disturb_on_outlined,
              color: dndActive ? context.appWarning : null,
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
          : Builder(builder: (context) {
              // 음성 명령은 RPi HTTP 직통으로도 가능하다 — BLE에만 묶어두면
              // "RPi 연결됨" 카드 옆에서 FAB만 죽어 있는 모순이 생긴다.
              final canSpeak = connected || rpiOnline;
              return FloatingActionButton.extended(
                onPressed: canSpeak ? () => context.go('/voice') : null,
                backgroundColor: canSpeak
                    ? context.appPrimary
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                foregroundColor: canSpeak
                    ? Theme.of(context).colorScheme.onPrimary
                    : context.appMuted,
                icon: const Icon(Icons.mic_rounded),
                label: const Text('말하기'),
              );
            }),
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
              until: dndUntil,
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

          // 학습 통계 카드(AI가 N개 패턴을 발견했습니다 + KPI 3칸)는 없앴다.
          // 제품이 자기가 똑똑하다고 광고하는 자리였고, 사용자가 그걸로 할 수 있는
          // 판단이 없었다. 게다가 '총 동작 N회'로 표시하던 값은 실제로는 대기 중인
          // 제안들의 단계 수 합계라, 라벨과 뜻이 아예 달랐다.
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
            Icon(Icons.thermostat_outlined,
                size: 14, color: context.appMuted),
            const SizedBox(width: 4),
            Text(
              '${temp.toStringAsFixed(1)}°C',
              style: TextStyle(
                  fontSize: 13, color: context.appMuted),
            ),
          ],
          if (temp != null && hum != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('·',
                  style: TextStyle(color: context.appMuted)),
            ),
          if (hum != null) ...[
            Icon(Icons.water_drop_outlined,
                size: 14, color: context.appMuted),
            const SizedBox(width: 4),
            Text(
              '${hum.toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: 13, color: context.appMuted),
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
          color: context.appWarning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: context.appWarning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.do_not_disturb_on,
                color: context.appWarning, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '방해 금지 중 · $_remaining',
                style: TextStyle(
                    color: context.appWarning, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: context.appWarning,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 48),
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
          context.appSuccess,
          Icons.wifi,
          'RPi 서버 연결됨',
          'AI 추론 · 제안 · 실행 준비 완료',
        ),
      RpiConnectionState.checking => (
          context.appWarning,
          Icons.sync,
          '연결 확인 중…',
          'simplelay.local 에 접속 중입니다',
        ),
      RpiConnectionState.unreachable => (
          context.appDanger,
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
        child: _StatusCardBody(
          icon: icon,
          color: color,
          title: title,
          subtitle: subtitle,
          actions: [
            if (state == RpiConnectionState.unreachable ||
                state == RpiConnectionState.unconfigured) ...[
              TextButton(
                onPressed: () => _promptForAddress(context, ref),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('주소 입력', style: TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(rpiConnectionProvider.notifier).check(),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(48, 48),
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
          child: _StatusCardBody(
            icon: Icons.bluetooth_disabled,
            color: context.appMuted,
            iconBackground: Theme.of(context).colorScheme.surfaceContainerHigh,
            title: '예비 연결이 꺼져 있어요',
            subtitle: '연결해 두면 서버가 안 될 때도 조작할 수 있어요.',
            actions: [
              Consumer(
                builder: (_, ref, __) => TextButton(
                  onPressed: () => GoRouter.of(ref.context).go('/settings'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('연결', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      );
}

/// 상태 카드의 공통 본문 — 아이콘 · 제목/설명 · 동작 버튼.
///
/// **큰 글씨에서 가로 배치가 무너진다.** 아이콘·텍스트·버튼을 한 줄에 두면 200%
/// 확대에서 버튼들이 폭을 다 가져가고 Expanded 텍스트가 한 글자씩 세로로 쪼개졌다
/// ("RPi 서버 미설정"이 여섯 줄이 됐다). 오버플로가 아니라 **압축**이라 레이아웃
/// 테스트가 잡지 못했고, 실제 렌더 이미지를 보고서야 드러났다.
///
/// 그래서 확대 배율이 커지면 버튼을 아래로 내린다. 보통 크기에서는 지금처럼 한 줄로
/// 둔다 -- 늘 세로로 쌓으면 평소 화면이 불필요하게 길어진다.
class _StatusCardBody extends StatelessWidget {
  const _StatusCardBody({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.actions,
    this.iconBackground,
  });

  final IconData icon;
  final Color color;
  final Color? iconBackground;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // 1.0을 넣으면 유효 배율이 그대로 나온다. 배율이 커지면 접는다.
    // 버튼이 둘이면 보통 크기에서도 접는다 -- 나란히 두면 설명이 어중간하게
    // 접혀서("서버 주 / 소를 입력하세요") 읽는 리듬이 끊긴다.
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) > 1.3 || actions.length > 1;

    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: iconBackground ?? color.withValues(alpha: 0.15),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: context.appCaption),
            ],
          ),
        ),
        if (!stacked) ...actions,
      ],
    );

    if (!stacked || actions.isEmpty) return head;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head,
        const SizedBox(height: 4),
        Wrap(spacing: 4, runSpacing: 4, children: actions),
      ],
    );
  }
}

// ── 연결 상태 chip (AppBar) ───────────────────────────────────────────────

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.connected, required this.rpiOnline});
  final bool connected;
  final bool rpiOnline;

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = rpiOnline
        ? (context.appSuccess, '연결됨')
        : connected
            ? (context.appWarning, 'BLE만')
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
                  // 스파클(Icons.auto_awesome)은 "AI 기능"이라는 표시일 뿐
                  // 무엇에 대한 제안인지는 알려주지 않았다. 어느 가전인지가
                  // 사용자에게 훨씬 쓸모 있는 정보다.
                  child: Icon(_applianceIconFor(suggestion),
                      color: context.appPrimary, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // label은 사용자가 예전에 했던 말 그대로다 -- 제품이
                      // 지어낸 문구가 아니라 본인 표현이라 그대로 되물어본다.
                      Text('${suggestion.label}, 지금 할까요?',
                          style: AppText.body),
                      const SizedBox(height: 2),
                      Text(_stepPreview(suggestion), style: context.appCaption),
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

// 제안이 어느 가전의 것인지는 버튼 코드 앞자리로 알 수 있다(AC-01, BT-05...).
// 등록된 가전 목록에서 그 코드를 가진 가전을 찾아 아이콘을 쓴다 -- 못 찾으면
// 일반 가전 아이콘으로 떨어진다(추측해서 틀린 아이콘을 보여주지 않는다).
IconData _applianceIconFor(Suggestion suggestion) {
  if (suggestion.steps.isEmpty) return Icons.devices_other_rounded;
  final first = suggestion.steps.first;
  for (final appliance in kAppliances) {
    if (appliance.buttons.any((b) => b.id == first || b.label == first)) {
      return appliance.icon;
    }
  }
  return Icons.devices_other_rounded;
}

/// 눌릴 버튼을 그대로 보여준다. "3단계 동작"은 몇 번 움직이는지만 알려줄 뿐,
/// **무엇을 누르는지**는 알려주지 않았다 -- 맡길지 판단하려면 그쪽이 필요하다.
String _stepPreview(Suggestion suggestion) {
  if (suggestion.steps.isEmpty) return '누를 버튼을 확인하려면 눌러 보세요';
  return suggestion.steps.map(readableStep).join(' → ');
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
                color: dndActive ? context.appWarning : context.appMuted,
                size: 36,
              ),
              const SizedBox(height: 12),
              Text(
                dndActive ? '방해 금지 모드 중' : '지금 확인할 제안이 없어요.',
                style: TextStyle(color: context.appMuted),
              ),
              if (dndActive) ...[
                const SizedBox(height: 4),
                Text(
                  '제안을 잠시 보내지 않아요.',
                  style: TextStyle(
                      color: context.appMuted, fontSize: 12),
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
