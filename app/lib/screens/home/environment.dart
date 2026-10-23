part of '../home_screen.dart';

class _SensorStrip extends StatelessWidget {
  const _SensorStrip({required this.reading});
  final SensorReading? reading;

  @override
  Widget build(BuildContext context) {
    if (reading?.mocked != false) return const SizedBox.shrink();
    final temp = reading?.temperature;
    final hum = reading?.humidity;
    if (temp == null && hum == null) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: reading != null ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (temp != null) ...[
            Icon(Icons.thermostat_outlined, size: 14, color: context.appMuted),
            const SizedBox(width: AppSpace.xs),
            Text(
              '${temp.toStringAsFixed(1)}°C',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
          if (temp != null && hum != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpace.sm),
              child: Text('·', style: TextStyle(color: context.appMuted)),
            ),
          if (hum != null) ...[
            Icon(Icons.water_drop_outlined, size: 14, color: context.appMuted),
            const SizedBox(width: AppSpace.xs),
            Text(
              '${hum.toStringAsFixed(0)}%',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// ── DND 활성 배너 ─────────────────────────────────────────────────────────

class _DndBanner extends StatelessWidget {
  const _DndBanner({required this.until, required this.onClear, this.carried = false});
  final DateTime until;
  final VoidCallback onClear;

  /// 업데이트 전에 켠 방해 금지를 이어받았다 — 새 제안만 쉰다.
  final bool carried;

  String get _remaining {
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return '끝났어요';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분 남았어요' : '$h시간 남았어요';
    }
    return '${diff.inMinutes + 1}분 남았어요';
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
        decoration: BoxDecoration(
          color: context.appWarning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.appWarning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(AppIcons.pauseActive, color: context.appWarning, size: 18),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                // 끝나는 시각을 함께 적는다(2026-10-14 마감 확인 A5) — 남은 시간만으로는 '언제까지'를 셈해야 한다.
                // 범위 문장을 늘 붙인다(문구 기준 §4 10/19) — '방해 금지'만으로는 제안만 멈추는 줄로 읽혔다.
                '방해 금지 켜짐. ${pauseEndClock(until)}까지, $_remaining. '
                '${carried ? kDndCarriedScopeText : kDndScopeText} $kDndKeepsText',
                style: TextStyle(color: context.appWarning, fontSize: AppFont.caption),
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: context.appWarning,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                minimumSize: const Size(48, 48),
              ),
              child: const Text('방해 금지 끄기', style: TextStyle(fontSize: AppFont.caption)),
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
        title: const Text('본체 주소'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '예: 192.168.0.10',
            helperText: '설치하는 분용이에요. 공유기 관리 화면에서 본체 주소를 찾아 주세요.',
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
      // 확인한 것은 /ping 응답뿐이다. 추론 계층이 켜졌는지, 가전이 물려
      // 있는지는 이 신호로 알 수 없다 -- 확인한 만큼만 말한다.
      // (온디바이스 추론 경계는 docs/inference-boundary.md)
      RpiConnectionState.keyRequired => (
          context.appWarning, Icons.key, '연결 비밀번호가 필요해요', '설정에서 연결 비밀번호를 넣어 주세요.'
        ),
      RpiConnectionState.connected => (
          context.appSuccess,
          Icons.wifi,
          '본체와 연결됨',
          '말이나 버튼으로 가전을 쓸 수 있어요',
        ),
      RpiConnectionState.checking => (
          context.appWarning,
          Icons.sync,
          '본체를 찾고 있어요…',
          '잠시만 기다려 주세요',
        ),
      RpiConnectionState.unreachable => (
          context.appDanger,
          Icons.wifi_off,
          '본체와 연결이 끊겼어요',
          '폰과 본체가 같은 와이파이인지 봐 주세요',
        ),
      RpiConnectionState.unconfigured => (
          context.appMuted,
          Icons.wifi_off,
          '본체 주소를 넣어 주세요',
          '설치하는 분이 설정에서 넣어 주세요',
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
        padding: const EdgeInsets.all(AppSpace.lg),
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
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('주소 입력', style: TextStyle(fontSize: AppFont.caption)),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(rpiConnectionProvider.notifier).check(),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  minimumSize: const Size(48, 48),
                ),
                child: const Text('다시 찾기', style: TextStyle(fontSize: AppFont.caption)),
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
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _StatusCardBody(
            icon: Icons.bluetooth_disabled,
            color: context.appMuted,
            iconBackground: Theme.of(context).colorScheme.surfaceContainerHigh,
            title: '블루투스 연결이 꺼져 있어요',
            subtitle: '켜 두면 와이파이가 끊겨도 가전을 쓸 수 있어요.',
            actions: [
              Consumer(
                builder: (_, ref, __) => TextButton(
                  onPressed: () => GoRouter.of(ref.context).go('/settings'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('설정에서 켜기', style: TextStyle(fontSize: AppFont.caption)),
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
        const SizedBox(width: AppSpace.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpace.xs),
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
        const SizedBox(height: AppSpace.xs),
        Wrap(spacing: AppSpace.xs, runSpacing: AppSpace.xs, children: actions),
      ],
    );
  }
}


/// 홈 가전 칸 순서 — 바로 쓸 수 있는 가전이 앞, 설정·연결이 남은 가전이 뒤(평가 17차 10/18: 본체 화면 가전 줄과 같은
/// 규칙). 같은 무리 안에서는 등록 순서. 본체 화면의 '확인 필요·동작 중' 앞당김은 홈 칸 띠가 말하므로 두지 않는다.
List<ApplianceMap> homeApplianceOrder(List<ApplianceMap> appliances) {
  bool later(ApplianceMap a) =>
      needsPanelMapping(a) || a.readiness == 'needs_setup' || a.readiness == 'disconnected';
  return [
    for (final a in appliances) if (!later(a)) a,
    for (final a in appliances) if (later(a)) a,
  ];
}
