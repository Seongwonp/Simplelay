import 'package:flutter/material.dart';

import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';

/// 휴대폰에서 말한 내용의 확인 질문(2026-10-26) — 폰과 같은 질문을 키오스크에도 띄운다. 먼저 고른 쪽만 정해진다.
///
/// 모양은 직접 고른 저장 동작 확인 카드와 같다(질문 + '아니요 | 네'). 질문은 본체 문장 그대로.
/// [onApprove]가 null이면 키오스크에 그 동작을 보낼 길이 없다 — '네' 없이 휴대폰에서 정해 달라고만 말한다.
class KioskVoiceProposalView extends StatelessWidget {
  const KioskVoiceProposalView({
    super.key,
    required this.proposal,
    required this.onReject,
    this.onApprove,
    this.busy = false,
    this.heardText,
  });

  final KioskIntentProposal proposal;
  final VoidCallback onReject;
  final VoidCallback? onApprove;

  /// 본체에 정하는 중 — 두 번 누르지 않게 단추를 잠근다.
  final bool busy;
  final String? heardText;

  static const caption = '휴대폰에서 말한 내용';
  static const phoneOnly = '휴대폰에서 정해 주세요';

  @override
  Widget build(BuildContext context) {
    final canApprove = onApprove != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(KioskSpace.xl, KioskSpace.sm, KioskSpace.xl, KioskSizes.actionsBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.smartphone, color: KioskColors.muted, size: 22),
            const SizedBox(width: 8),
            Text(heardText == null ? caption : '본체에서 말한 내용',
                key: const ValueKey('voice-proposal-caption'),
                style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted)),
          ]),
          if (heardText != null && heardText!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('들은 말: $heardText', key: const ValueKey('voice-heard-text'),
                style: TextStyle(fontSize: KioskType.body, color: KioskColors.ink)),
          ],
          const SizedBox(height: KioskSpace.sm),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: KioskText(
                proposal.question,
                textKey: const ValueKey('voice-proposal-question'),
                phrases: true,
                style: TextStyle(
                    fontSize: KioskType.key, fontWeight: FontWeight.w700, height: 1.25, color: KioskColors.ink),
              ),
            ),
          ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: Semantics(
                    button: true,
                    label: '아니요. 이번에는 하지 않아요',
                    excludeSemantics: true,
                    child: OutlinedButton(
                      key: const ValueKey('voice-proposal-no'),
                      onPressed: busy ? null : onReject,
                      style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.muted).copyWith(
                        minimumSize: const WidgetStatePropertyAll(Size(0, KioskSizes.primaryButton)),
                        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
                      ),
                      child: const KioskText('아니요',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: canApprove
                      ? Semantics(
                          button: true,
                          enabled: !busy,
                          label: '네. ${proposal.label}',
                          excludeSemantics: true,
                          child: ElevatedButton(
                            key: const ValueKey('voice-proposal-yes'),
                            onPressed: busy ? null : onApprove,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(0, KioskSizes.primaryButton),
                              backgroundColor: KioskColors.primary,
                              foregroundColor: KioskColors.onAccent,
                              disabledBackgroundColor: KioskColors.border,
                              disabledForegroundColor: KioskColors.muted,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('네',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w800)),
                          ),
                        )
                      : Center(
                          child: KioskText(phoneOnly,
                              textKey: const ValueKey('voice-proposal-phone-only'),
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: KioskType.body, color: KioskColors.ink)),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          KioskText(
            canApprove ? "'네'를 누르기 전에는 아무것도 하지 않아요" : '여기서는 이 일을 보낼 수 없어요',
            style: TextStyle(fontSize: KioskType.body, height: 1.25, color: KioskColors.ink),
          ),
        ],
      ),
    );
  }
}
