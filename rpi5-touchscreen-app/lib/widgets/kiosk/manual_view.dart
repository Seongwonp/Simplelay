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
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: onCancel,
                  child: const Icon(
                    Icons.arrow_back_ios_new,
                    color: KioskColors.muted,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 14),
                Icon(appliance.icon, color: KioskColors.muted, size: 16),
                const SizedBox(width: 8),
                Text(
                  appliance.name,
                  style: const TextStyle(
                    fontSize: 15,
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 88,
        height: 60,
        decoration: BoxDecoration(
          color: KioskColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: KioskColors.border),
        ),
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
    );
  }
}
