part of '../home_screen.dart';

class _NoApplianceStage extends StatelessWidget {
  const _NoApplianceStage({required this.onAdd, this.note});

  final VoidCallback onAdd;
  final String? note;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('아직 등록한 가전이 없어요', style: AppText.title),
          const SizedBox(height: AppSpace.sm),
          Text(
            '버튼판 사진을 찍고 버튼 자리를 알려 주면\n여기서 가전을 쓸 수 있어요.',
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
          ),
          if (note case final note?) ...[
            const SizedBox(height: AppSpace.sm),
            Text(note, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          ],
          const SizedBox(height: AppSpace.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 20),
            label: const Text('가전 추가'),
          ),
        ],
      );
}

// ── 연결 상세 (접힘) ──────────────────────────────────────────────────────

/// 서버·BLE 사정을 한 줄로 접어 둔다.
///
/// **문제가 있으면 펼친 채로 연다.** 접어두는 것은 "지금은 신경 쓰지 않아도
/// 된다"는 뜻인데, 연결이 끊긴 상태에서 그러면 복구 동선이 화면에서
/// 사라진다 -- 가장 도움이 필요한 순간에.
class _ConnectionDetails extends StatefulWidget {
  const _ConnectionDetails({
    required this.rpiState,
    required this.bleConnected,
  });

  final RpiConnectionState rpiState;
  final bool bleConnected;

  @override
  State<_ConnectionDetails> createState() => _ConnectionDetailsState();
}

class _ConnectionDetailsState extends State<_ConnectionDetails> {
  bool _open = false;

  /// 닿지 않는다고 **확인된** 경우만. 확인 중(checking·unconfigured)은 아니다.
  bool get _serverDown => widget.rpiState == RpiConnectionState.unreachable;

  /// 허브에 닿으면 예비 연결이 꺼져도 말하지 않는다(2026-10-14 UX) — 조작은 되고,
  /// 사용자가 그걸로 할 판단이 없다. 허브 연결에 문제가 있을 때만 줄을 둔다.
  bool get _hasProblem => _serverDown;

  @override
  Widget build(BuildContext context) {
    // 문제가 없으면 이 줄 자체를 두지 않는다. 잘 되고 있는 것을 알리는
    // 줄은 화면을 관리 도구로 되돌릴 뿐, 사용자가 그걸로 할 판단이 없다.
    if (!_hasProblem) return const SizedBox.shrink();

    // 둘 다 끊긴 것과 예비 연결로 버티는 것은 문장을 나눈다 -- 조작은 되는데
    // "연결 설정이 필요해요"라고만 하면 무엇이 안 되는지 알 수 없다.
    final (String label, Color color, IconData icon) = widget.bleConnected
            ? ('알림과 기록을 못 받고 있어요', context.appWarning,
                Icons.wifi_tethering_error)
            : ('연결 설정이 필요해요', context.appDanger,
                Icons.wifi_tethering_error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              // 고령 사용자 기준 최소 터치 대상을 줄 전체로 준다.
              padding: const EdgeInsets.symmetric(vertical: AppSpace.lg, horizontal: AppSpace.xs),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      // 기술 용어를 여기 쓰지 않는다. `RPi 서버`·주소 입력·
                      // 재시도는 눌렀을 때만 나온다.
                      keepWordsTogether(label),
                      style: TextStyle(
                        fontSize: AppFont.caption,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  Text(
                    _open ? '접기' : '확인하기',
                    style: TextStyle(
                      fontSize: AppFont.caption,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: color),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: AppSpace.xs),
          // 닿는 기기를 "연결됐어요" 카드로 다시 말하지 않는다.
          if (_serverDown) _RpiStatusCard(state: widget.rpiState),
          // 예비 연결은 **꺼져 있을 때만** 말한다.
          if (!widget.bleConnected) ...[
            if (_serverDown) const SizedBox(height: AppSpace.md),
            _BleStatusCard(connected: widget.bleConnected),
          ],
        ],
      ],
    );
  }
}

// ── 온습도 스트립 ──────────────────────────────────────────────────────────
