import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';

/// 수동 조작 — 조작판을 직접 눌러 버튼 하나씩 맡긴다.
///
/// 멀리서도 **어느 가전의 판인지**가 먼저 읽혀야 한다. 예전에는 가전 이름이
/// 20px 회색이고 버튼 글자가 14px이라, 한 걸음만 떨어져도 무엇을 누르는지
/// 알기 어려웠다. 버튼에는 등록된 라벨만 쓴다 -- 내부 버튼 id는 나오지 않는다.
class KioskManualView extends StatelessWidget {
  const KioskManualView({
    super.key,
    required this.appliance,
    required this.onExecute,
    required this.onCancel,
  });

  final ApplianceMap appliance;
  final void Function(ApplianceButton button) onExecute;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: KioskColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 24, 6),
            child: Row(
              children: [
                // 뒤로가기: 아이콘 단독 히트박스는 고령 사용자가 맞추기
                // 어렵다 — 패딩 포함 52px + 눌림 잉크 피드백
                Semantics(
                  button: true,
                  label: '대기 화면으로 돌아가기',
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: onCancel,
                      borderRadius: BorderRadius.circular(12),
                      child: const SizedBox(
                        width: 52,
                        height: 52,
                        child: Icon(
                          Icons.arrow_back_ios_new,
                          color: KioskColors.muted,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(appliance.icon, color: KioskColors.muted, size: 30),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    appliance.name,
                    style: const TextStyle(
                      fontSize: 30,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // 아직 맡길 수 없는 가전이면 여기서 먼저 말한다. 눌러 보고
          // 실패로 알게 되면, 서버가 막은 것을 가전 고장으로 오해한다.
          if (!appliance.canExecute) _NotReadyNotice(appliance: appliance),
          Expanded(
            // 큰 글씨·준비 안 됨 안내가 겹쳐도 판이 화면 밖으로 넘치지 않게.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(
                child: _ButtonGrid(
                  appliance: appliance,
                  // 준비 안 된 가전은 탭 자체를 막는다(서버도 412로 거절 —
                  // 이중 방어). 누를 수 있는데 안 되는 버튼은 두지 않는다.
                  onExecute: appliance.canExecute ? onExecute : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 준비가 끝나지 않은 가전임을 큰 글씨로 알린다.
///
/// 상태 이름만 말하지 않고 **무엇이 남았는지**를 함께 낸다 — 폰과 같은
/// 문장을 쓴다(한 서버에서 나온 값이다).
class _NotReadyNotice extends StatelessWidget {
  const _NotReadyNotice({required this.appliance});

  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) {
    final disconnected = appliance.readiness == 'disconnected';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: KioskColors.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            disconnected ? Icons.link_off : Icons.build_outlined,
            color: KioskColors.warning,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  disconnected ? '아직 연결되지 않았어요' : '아직 준비가 끝나지 않았어요',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (appliance.readinessReasons.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    appliance.readinessReasons.join(' · '),
                    style: const TextStyle(
                      fontSize: 18,
                      color: KioskColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({required this.appliance, required this.onExecute});

  final ApplianceMap appliance;

  /// null이면 이 가전은 아직 맡길 수 없다.
  final void Function(ApplianceButton)? onExecute;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(appliance.rows, (row) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(appliance.cols, (col) {
            final btn = appliance.buttonAt(col, row);
            return Padding(
              padding: const EdgeInsets.all(5),
              child: btn == null
                  ? const SizedBox(width: _cellWidth, height: _cellHeight)
                  : _ButtonCell(
                      button: btn,
                      onTap: onExecute == null
                          ? null
                          : () => onExecute!(btn),
                    ),
            );
          }),
        );
      }),
    );
  }
}

// 멀리서 읽히는 크기. 4열(인덕션)·4행(전자레인지)이 800x480에 들어가는 상한.
const double _cellWidth = 124;
const double _cellHeight = 66;

class _ButtonCell extends StatelessWidget {
  const _ButtonCell({required this.button, required this.onTap});

  final ApplianceButton button;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // InkWell 잉크 피드백 — "눌렸는지 모름"이 실제 물리 버튼을 누르는 앱에선
    // 오조작(연타)으로 이어진다. Material 트리가 없는 화면이라 transparency로 공급.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '${button.label} 버튼 누르기',
      excludeSemantics: true,
      child: Container(
        width: _cellWidth,
        height: _cellHeight,
        decoration: BoxDecoration(
          color: KioskColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: KioskColors.border),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            splashColor: KioskColors.primary.withValues(alpha: 0.25),
            highlightColor: KioskColors.primary.withValues(alpha: 0.12),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  button.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    height: 1.15,
                    // 못 누르는 버튼은 그렇게 보여야 한다 — 색만 같으면
                    // 눌리지 않는 이유를 가전 쪽에서 찾게 된다.
                    color: onTap == null
                        ? const Color(0xFFFAF7F2).withValues(alpha: 0.35)
                        : const Color(0xFFFAF7F2),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
