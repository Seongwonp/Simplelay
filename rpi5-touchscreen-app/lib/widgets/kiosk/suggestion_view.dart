import 'package:flutter/material.dart';

import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';

/// 제안 확인 화면.
///
/// 여기서 사용자가 판단해야 하는 것은 "AI가 뭘 제안했나"가 아니라 **"내 가전의 어떤
/// 버튼을 대신 눌러줄 것인가, 그걸 맡길 것인가"**다. 그래서 화면 순서를
/// 무엇을 → 어떤 순서로 → 할까 말까 로 맞춘다.
///
/// 예전에는 'AI 제안' 라벨과 '승인/거부'라는 결재 용어가 먼저 읽혔고, 정작 눌릴
/// 버튼 순서는 화면에 없었다. 제품의 차별점이 가장 잘 드러나는 화면인데 그게 빠져
/// 있었다.
class KioskSuggestionView extends StatelessWidget {
  const KioskSuggestionView({
    super.key,
    required this.suggestion,
    required this.cdRemaining,
    required this.cdTotal,
    required this.onApprove,
    required this.onReject,
    required this.onRejectMute,
  });

  final KioskSuggestion suggestion;
  final int cdRemaining;

  /// 카운트다운 전체 길이(초) — 설정에서 바뀌므로 진행바가 이 값을 봐야
  /// 남은 시간과 바가 어긋나지 않는다.
  final int cdTotal;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  /// "다시 추천 안 함" -- 이번만 넘기기(onReject)와 달리 그 루틴을
  /// 아예 억제한다.
  final VoidCallback onRejectMute;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 사용자가 예전에 했던 말 그대로가 purpose다 — 제품이 지어낸 문구가
            // 아니라 본인의 표현이라 그대로 되물어보는 편이 알아듣기 쉽다.
            Text(
              '${suggestion.purpose}, 지금 할까요?',
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1.25,
                color: Colors.white,
              ),
            ),

            // 근거는 실제로 셀 수 있을 때만 말한다
            if (suggestion.reason.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                suggestion.reason,
                style: const TextStyle(fontSize: 22, color: KioskColors.muted),
              ),
            ] else if (suggestion.occurrences > 0) ...[
              const SizedBox(height: 10),
              Text(
                '이 시간대에 ${suggestion.occurrences}번 하셨어요.',
                style: const TextStyle(fontSize: 22, color: KioskColors.muted),
              ),
            ],

            if (suggestion.steps.isNotEmpty) ...[
              const SizedBox(height: 22),
              const Text(
                '이 순서로 버튼을 눌러요',
                style: TextStyle(fontSize: 22, color: KioskColors.muted),
              ),
              const SizedBox(height: 10),
              _StepSequence(steps: suggestion.steps),
            ],

            const SizedBox(height: 16),
            Row(
              children: [
                // 보조 동작이 왼쪽, 주요 실행이 오른쪽 — 폰 앱과 같은 규칙.
                // 예전에는 키오스크만 실행이 왼쪽이라 두 화면의 손버릇이 달랐다.
                // 높이를 고정하지 않고 **최소 높이**로 준다. 고정하면 큰 글씨
                // 모드에서 글자가 버튼 안에서 잘린다 -- 그건 RenderFlex 오버플로가
                // 아니라서 레이아웃 테스트가 잡지 못했고, 실제 렌더 이미지를 보고서야
                // 드러났다.
                Expanded(
                  flex: 3,
                  child: OutlinedButton(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 64),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: KioskColors.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      '이번만 넘기기',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: ElevatedButton(
                    onPressed: onApprove,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 64),
                      backgroundColor: KioskColors.primary,
                      foregroundColor: KioskColors.onAccent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      '지금 실행',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: onRejectMute,
                style: TextButton.styleFrom(
                  foregroundColor: KioskColors.muted,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.notifications_off_outlined, size: 16),
                label: const Text(
                  '이 제안 다시 받지 않기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // 카운트다운에서 정작 중요한 정보는 남은 초가 아니라 "가만히 두면
            // 아무 일도 없다"는 사실이다 — 자동으로 실행될까 봐 서두르지 않도록.
            Text(
              '누르지 않으면 실행하지 않아요 · $cdRemaining초',
              style: const TextStyle(fontSize: 18, color: KioskColors.muted),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: cdTotal > 0 ? cdRemaining / cdTotal : 0,
                minHeight: 2,
                backgroundColor: KioskColors.border,
                valueColor: AlwaysStoppedAnimation(
                  KioskColors.muted.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 눌릴 버튼을 순서대로. 세로 목록이 읽기는 쉽지만 800x480에 큰 글씨까지 겹치면
/// 넘치므로, 순서가 드러나는 가로 배치로 접는다.
class _StepSequence extends StatelessWidget {
  const _StepSequence({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            const Icon(Icons.arrow_forward_rounded,
                size: 18, color: KioskColors.muted),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: KioskColors.surface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: KioskColors.border),
            ),
            child: Text(
              steps[i],
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
