import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';

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
            padding: const EdgeInsets.fromLTRB(12, 16, 24, 8),
            child: Row(
              children: [
                // 뒤로가기: 16px 아이콘 단독 히트박스는 고령 사용자가 맞추기
                // 어렵다 — 패딩 포함 48px 이상으로 확대 + 눌림 잉크 피드백
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: onCancel,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Icon(
                        Icons.arrow_back_ios_new,
                        color: KioskColors.muted,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(appliance.icon, color: KioskColors.muted, size: 16),
                const SizedBox(width: 8),
                Text(
                  appliance.name,
                  style: const TextStyle(
                    fontSize: 20,
                    color: KioskColors.muted,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: _ButtonGrid(
                appliance: appliance,
                onExecute: onExecute,
              ),
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
  final void Function(ApplianceButton) onExecute;

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
                  ? const SizedBox(width: 88, height: 60)
                  : _ButtonCell(
                      button: btn,
                      onTap: () => onExecute(btn),
                    ),
            );
          }),
        );
      }),
    );
  }
}

class _ButtonCell extends StatelessWidget {
  const _ButtonCell({required this.button, required this.onTap});

  final ApplianceButton button;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // InkWell 잉크 피드백 — "눌렸는지 모름"이 실제 물리 버튼을 누르는 앱에선
    // 오조작(연타)으로 이어진다. Material 트리가 없는 화면이라 transparency로 공급.
    return Container(
      width: 88,
      height: 60,
      decoration: BoxDecoration(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: KioskColors.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          splashColor: KioskColors.primary.withValues(alpha: 0.25),
          highlightColor: KioskColors.primary.withValues(alpha: 0.12),
          child: Center(
            child: Text(
              button.label,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFFFAF7F2),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
