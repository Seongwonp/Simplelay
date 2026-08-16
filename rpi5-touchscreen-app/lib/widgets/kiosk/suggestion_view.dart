import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';

const int _kCountdownSeconds = 10;

class KioskSuggestionView extends StatelessWidget {
  const KioskSuggestionView({
    super.key,
    required this.appliance,
    required this.suggestion,
    required this.cdRemaining,
    required this.onApprove,
    required this.onReject,
  });

  final ApplianceMap appliance;
  final KioskSuggestion suggestion;
  final int cdRemaining;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 400,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                  decoration: BoxDecoration(
                    color: KioskColors.primary.withValues(alpha: 0.1),
                    border: Border.all(
                      color: KioskColors.primary.withValues(alpha: 0.28),
                    ),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: const Text(
                    '✦  AI 제안',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.06,
                      color: KioskColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  suggestion.purpose,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 14, color: KioskColors.muted),
                    children: [
                      const TextSpan(text: '최근 '),
                      TextSpan(
                        text: '${suggestion.occurrences}',
                        style: const TextStyle(
                          color: KioskColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const TextSpan(text: '회 같은 시간대에 반복 감지'),
                    ],
                  ),
                ),
                const Spacer(),
                // 승인 버튼 — glow 효과
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: KioskColors.success.withValues(alpha: 0.28),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 68,
                    child: ElevatedButton.icon(
                      onPressed: onApprove,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KioskColors.success,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.check, size: 22),
                      label: const Text(
                        '승인하고 실행',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: OutlinedButton(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KioskColors.muted,
                      side: const BorderSide(color: KioskColors.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('거부'),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '$cdRemaining초',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: KioskColors.warning,
                      ),
                    ),
                    const Text(
                      ' 후 자동 닫힘',
                      style: TextStyle(fontSize: 13, color: KioskColors.muted),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: cdRemaining / _kCountdownSeconds,
                          minHeight: 4,
                          backgroundColor: KioskColors.border,
                          valueColor:
                              const AlwaysStoppedAnimation(KioskColors.warning),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${appliance.name} 버튼 배치',
                  style: const TextStyle(fontSize: 12, color: KioskColors.muted),
                ),
                const SizedBox(height: 10),
                // /suggestions가 주는 steps는 미리보기 — 실제 실행은 승인 시점에
                // 다시 해석되므로 최종 순서와 다를 수 있다(드물게).
                Expanded(
                  child: _ButtonGrid(
                    appliance: appliance,
                    highlightLabels: suggestion.steps,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({required this.appliance, required this.highlightLabels});

  final ApplianceMap appliance;
  final List<String> highlightLabels;

  @override
  Widget build(BuildContext context) {
    // 백엔드는 버튼을 라벨 문자열로 돌려주므로 id가 아닌 label로 매칭한다.
    final orderMap = <String, int>{};
    for (var i = 0; i < highlightLabels.length; i++) {
      orderMap.putIfAbsent(highlightLabels[i], () => i + 1);
    }

    return Column(
      children: List.generate(appliance.rows, (row) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: row < appliance.rows - 1 ? 7 : 0),
            child: Row(
              children: List.generate(appliance.cols, (col) {
                final btn = appliance.buttonAt(col, row);
                final order = btn != null ? orderMap[btn.label] : null;
                final isHighlighted = order != null;
                return Expanded(
                  child: Padding(
                    padding:
                        EdgeInsets.only(right: col < appliance.cols - 1 ? 7 : 0),
                    child: btn == null
                        ? const SizedBox.shrink()
                        : Container(
                            decoration: BoxDecoration(
                              color: isHighlighted
                                  ? KioskColors.primary.withValues(alpha: 0.14)
                                  : KioskColors.surface,
                              border: Border.all(
                                color: isHighlighted
                                    ? KioskColors.primary
                                    : KioskColors.border,
                                width: isHighlighted ? 1.5 : 1,
                              ),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Text(
                                  btn.label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isHighlighted
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                    color: isHighlighted
                                        ? KioskColors.primary
                                        : Colors.white.withValues(alpha: 0.45),
                                  ),
                                ),
                                if (isHighlighted)
                                  Positioned(
                                    top: 4,
                                    right: 5,
                                    child: Container(
                                      width: 16,
                                      height: 16,
                                      alignment: Alignment.center,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: KioskColors.primary,
                                      ),
                                      child: Text(
                                        '$order',
                                        style: const TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                );
              }),
            ),
          ),
        );
      }),
    );
  }
}
