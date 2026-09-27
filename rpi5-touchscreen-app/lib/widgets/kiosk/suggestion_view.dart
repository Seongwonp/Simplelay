import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_target_line.dart';

/// 제안 확인 화면.
///
/// 여기서 사용자가 판단해야 하는 것은 "AI가 뭘 제안했나"가 아니라 **"내 가전의 어떤
/// 버튼을 대신 눌러줄 것인가, 그걸 맡길 것인가"**다. 그래서 읽는 순서를
/// 어느 가전을 → 무엇을(왼쪽, 크게) → 어떤 순서로(오른쪽) → 할까 말까(아래) 로 둔다.
///
/// 예전에는 'AI 제안' 라벨과 '승인/거부'라는 결재 용어가 먼저 읽혔고, 정작 눌릴
/// 버튼 순서는 화면에 없었다. 제품의 차별점이 가장 잘 드러나는 화면인데 그게 빠져
/// 있었다.
class KioskSuggestionView extends StatelessWidget {
  const KioskSuggestionView({
    super.key,
    required this.suggestion,
    this.target,
    required this.cdRemaining,
    required this.cdTotal,
    required this.onApprove,
    required this.onReject,
    required this.onRejectMute,
    this.onSnooze,
    this.onRevise,
  });

  final KioskSuggestion suggestion;

  /// 이 제안이 조작할 가전 -- **제안 자신의 appliance_id**로 찾은 것.
  /// 모르면 null이고, 지금 고른 가전으로 대신 채우지 않는다.
  final ApplianceMap? target;
  final int cdRemaining;

  /// 카운트다운 전체 길이(초) — 설정에서 바뀌므로 진행바가 이 값을 봐야
  /// 남은 시간과 바가 어긋나지 않는다.
  final int cdTotal;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  /// "다시 추천 안 함" -- 이번만 넘기기(onReject)와 달리 그 루틴을
  /// 아예 억제한다.
  final VoidCallback onRejectMute;
  final VoidCallback? onSnooze;
  final VoidCallback? onRevise;

  @override
  Widget build(BuildContext context) {
    final target = this.target;
    // 대상을 모르는 제안은 실행을 내걸지 않는다(백로그 B10) — 서버도 대상
    // 없는 승인을 거절하므로, 눌리는 버튼을 세워 두면 눌렀는데 아무 일도
    // 안 일어나는 화면이 된다. 폰 제안 확인(D1)과 같은 규칙.
    final canExecute = target != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (target != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: KioskTargetLine(appliance: target),
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 왼쪽: 무엇을 ─────────────────────────────────────────
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 사용자가 예전에 했던 말 그대로가 purpose다 — 제품이
                        // 지어낸 문구가 아니라 본인의 표현이라 그대로 되물어보는
                        // 편이 알아듣기 쉽다.
                        // 질문은 따로 한 줄. 이어 쓰면 폭에 따라 '할까 / 요?'처럼
                        // 끊긴다 -- 한글은 글자 단위로 줄이 바뀐다.
                        Text(
                          '${suggestion.isDemo ? '[시연 데이터] ' : ''}${suggestion.purpose},\n지금 할까요?',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                            color: Colors.white,
                          ),
                        ),
                        // 근거는 실제로 셀 수 있을 때만 말한다 -- 어느
                        // 시간대였는지까지 밝힌다.
                        if (suggestion.whyNow.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            suggestion.whyNow,
                            style: const TextStyle(
                              fontSize: 22,
                              color: KioskColors.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // ── 오른쪽: 어떤 순서로 ─────────────────────────────────
                if (suggestion.steps.isNotEmpty) ...[
                  const SizedBox(width: 28),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '누를 순서',
                          style:
                              TextStyle(fontSize: 20, color: KioskColors.muted),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _StepList(steps: suggestion.steps),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          if (onRevise != null && suggestion.timeBand != '환경')
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(
              onPressed: onRevise,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('이번 동작 바꾸기'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            )),
          if (onSnooze != null && !suggestion.isDemo && suggestion.timeBand != '데모')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onSnooze,
                icon: const Icon(Icons.snooze),
                label: const Text('이 제안 30분 쉬기 · 이후 상황에 따라 다시 물어요'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              // 보조 동작이 왼쪽, 주요 실행이 오른쪽 — 폰 앱과 같은 규칙.
              // 높이를 고정하지 않고 **최소 높이**로 준다. 고정하면 큰 글씨
              // 모드에서 글자가 버튼 안에서 잘린다.
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
                  onPressed: canExecute ? onApprove : null,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 64),
                    backgroundColor: KioskColors.primary,
                    foregroundColor: KioskColors.onAccent,
                    // 비활성이어도 글자는 읽혀야 한다 — 왜 못 누르는지는
                    // 아래 안내문이 말한다.
                    disabledBackgroundColor: KioskColors.border,
                    disabledForegroundColor: KioskColors.muted,
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

          Row(
            children: [
              // 카운트다운에서 정작 중요한 정보는 남은 초가 아니라 "가만히 두면
              // 아무 일도 없다"는 사실이다 — 자동으로 실행될까 봐 서두르지 않도록.
              Expanded(
                child: Text(
                  canExecute
                      ? '누르지 않으면 실행하지 않아요 · $cdRemaining초'
                      : '이 제안의 가전을 찾을 수 없어 실행할 수 없어요 · '
                          '$cdRemaining초',
                  style:
                      const TextStyle(fontSize: 18, color: KioskColors.muted),
                ),
              ),
              TextButton.icon(
                onPressed: onRejectMute,
                style: TextButton.styleFrom(
                  foregroundColor: KioskColors.muted,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  // 작은 글자여도 누르는 자리는 최소 터치 크기를 지킨다.
                  minimumSize: const Size(48, 48),
                ),
                icon: const Icon(Icons.notifications_off_outlined, size: 18),
                label: const Text(
                  '이 제안 다시 받지 않기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
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
    );
  }
}

/// 눌릴 버튼을 번호와 라벨로. 서버가 준 **실제 버튼 라벨**만 쓴다 --
/// 버튼 id 같은 내부 값은 화면에 나오지 않는다.
class _StepList extends StatelessWidget {
  const _StepList({required this.steps});

  final List<String> steps;

  static Widget _number(int n) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        // 순서 번호는 정보다. 보라는 주 행동('지금 실행') 몫으로 남긴다.
        decoration: const BoxDecoration(
          color: KioskColors.success,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$n',
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: KioskColors.onAccent,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // 네 단계까지는 세로로 한 줄씩 -- 가장 읽기 쉽다. 그보다 길면 세로
    // 목록이 칸을 넘어 뒤쪽 단계가 잘리는데, 잘렸다는 표시도 없어 사용자는
    // 순서가 거기서 끝난 줄 안다. 그때는 번호를 붙인 채 옆으로 흘려 전부 보인다.
    if (steps.length > 4) {
      return SingleChildScrollView(
        child: Wrap(
          spacing: 14,
          runSpacing: 10,
          children: [
            for (var i = 0; i < steps.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _number(i + 1),
                  const SizedBox(width: 8),
                  Text(
                    steps[i],
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: steps.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => Row(
        children: [
          _number(i + 1),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              steps[i],
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
