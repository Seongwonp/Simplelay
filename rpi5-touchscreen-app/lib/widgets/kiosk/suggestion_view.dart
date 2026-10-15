import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/command_result.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_scroll_area.dart';
import 'kiosk_target_line.dart';
import 'route_badge.dart';

/// 승인 재검사 실패(409) 안내. 폰 앱과 같은 문장.
const kApprovalChangedMessage = '제안 내용이 바뀌어 다시 확인이 필요해요';

/// 제안 확인 화면.
///
/// 다가오면(UI 확정 2026-09-30 §3-2) — 제안 카드 **한 장**, 버튼은 "시작"과
/// "다음에" 두 개뿐이다. 억제·미루기·동작 바꾸기 같은 관리는 폰 앱의 루틴 탭에 둔다.
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
    this.scenarioName,
    this.blockedWhy,
  });

  final KioskSuggestion suggestion;

  /// 시나리오 이름(GET /scenarios). 모르면 null이고 질문만 보인다.
  final String? scenarioName;

  /// 시나리오 대상 중 준비 안 된 것이 있으면 그 이유(GET /readiness/{id}).
  final String? blockedWhy;

  /// 이 제안이 조작할 가전 -- **제안 자신의 appliance_id**로 찾은 것.
  /// 모르면 null이고, 지금 고른 가전으로 대신 채우지 않는다.
  final ApplianceMap? target;
  final int cdRemaining;

  /// 카운트다운 전체 길이(초) — 설정에서 바뀌므로 진행바가 이 값을 봐야
  /// 남은 시간과 바가 어긋나지 않는다.
  final int cdTotal;
  final VoidCallback onApprove;

  /// "다음에" — 이번만 넘긴다(억제하지 않는다).
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final target = this.target;
    // 대상을 모르는 제안은 실행을 내걸지 않는다(백로그 B10) — 서버도 대상
    // 없는 승인을 거절하므로, 눌리는 버튼을 세워 두면 눌렀는데 아무 일도
    // 안 일어나는 화면이 된다. 폰 제안 확인(D1)과 같은 규칙.
    // 시나리오 카드는 서버가 고정한 명령으로 승인한다(ThinQ 가전은 조작판 목록에
    // 없다). 막는 것은 준비 안 된 대상뿐이다.
    final scenario = suggestion.isScenario;
    final canExecute = scenario ? blockedWhy == null : target != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (target != null && !scenario) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: KioskTargetLine(appliance: target),
            ),
            const SizedBox(height: 10),
          ],
          // 사용자가 붙인 루틴 이름 — 메뉴는 사용자가 만든다(§1-1).
          if (suggestion.routineName != null &&
              suggestion.routineName!.isNotEmpty) ...[
            Text(
              '내 루틴 "${suggestion.routineName}"',
              style: const TextStyle(fontSize: 22, color: KioskColors.muted),
            ),
            const SizedBox(height: 6),
          ],
          if (scenario && scenarioName != null) ...[
            Text(
              '시나리오 · $scenarioName',
              style: const TextStyle(fontSize: 22, color: KioskColors.muted),
            ),
            const SizedBox(height: 6),
          ],
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 왼쪽: 무엇을 ─────────────────────────────────────────
                Expanded(
                  flex: 5,
                  // 큰 글씨에서 근거 줄이 아래로 넘치면 스크롤 막대가 보인다(2026-10-15).
                  child: KioskScrollArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 사용자가 예전에 했던 말 그대로가 purpose다 — 제품이
                        // 지어낸 문구가 아니라 본인의 표현이라 그대로 되물어보는
                        // 편이 알아듣기 쉽다.
                        // 질문은 따로 한 줄. 이어 쓰면 폭에 따라 '할까 / 요?'처럼
                        // 끊긴다 -- 한글은 글자 단위로 줄이 바뀐다.
                        Text(
                          // 시나리오 질문은 서버 문장이 이미 물음으로 끝난다.
                          scenario
                              ? '${suggestion.isDemo ? '[시연 데이터] ' : ''}${suggestion.purpose}'
                              : '${suggestion.isDemo ? '[시연 데이터] ' : ''}${suggestion.purpose},\n지금 할까요?',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                            color: Colors.white,
                          ),
                        ),
                        // 근거를 줄여도 잘리면 안 되는 제한(예: '조리 완료가 아닐 수 있어요')은 근거 밖
                        // 늘 보이는 줄로 뺀다. 모의 여부는 질문 줄의 '[시연 데이터]'가 늘 말한다(2026-10-14 추가 확인).
                        for (final caveat in kAlwaysShownCaveats)
                          if (suggestion.whyNow.contains(caveat)) ...[
                            const SizedBox(height: 8),
                            Text(
                              caveat,
                              key: const ValueKey('suggestion-caveat'),
                              style: const TextStyle(
                                  fontSize: 20, color: KioskColors.warning),
                            ),
                          ],
                        // 근거는 실제로 셀 수 있을 때만 말한다 -- 어느
                        // 시간대였는지까지 밝힌다. 판단의 주인공은 질문과 버튼이라 근거는
                        // 두 줄까지만(2026-10-14 UI 정리). 넘치면 '근거 전체 보기'로 펼친다. 낭독에는 전문이 간다.
                        if (suggestion.whyNow.isNotEmpty && !suggestion.userStarted) ...[
                          const SizedBox(height: 10),
                          _WhyText(
                            scenario
                                ? '근거: ${suggestion.whyNow}'
                                : suggestion.whyNow,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // ── 오른쪽(시나리오): 어느 가전을 어느 경로로 무엇을 ─────────
                if (scenario) ...[
                  const SizedBox(width: 28),
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // 버튼 누름만이면 '누를 버튼', ThinQ가 섞이면 '할 일'(폰과 같은 말, 2026-10-14).
                          suggestion.commands.every((c) => c.route == 'physical')
                              ? '누를 버튼'
                              : '할 일',
                          style: const TextStyle(
                              fontSize: 20, color: KioskColors.muted),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _CommandList(commands: suggestion.commands),
                        ),
                      ],
                    ),
                  ),
                ]
                // ── 오른쪽: 어떤 순서로 ─────────────────────────────────
                else if (suggestion.steps.isNotEmpty) ...[
                  const SizedBox(width: 28),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '작은 팔이 누를 순서',
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

          const SizedBox(height: 12),
          Row(
            children: [
              // 보조 동작이 왼쪽, 주요 실행이 오른쪽 — 폰 앱과 같은 규칙.
              // 높이를 고정하지 않고 **최소 높이**로 준다. 고정하면 큰 글씨
              // 모드에서 글자가 버튼 안에서 잘린다. 선택 버튼은 질문 다음으로 크게 — 순서·근거보다
              // 먼저 눈에 들어와야 한다(2026-10-14 UI 정리).
              Expanded(
                flex: 3,
                child: OutlinedButton(
                  key: const ValueKey('suggestion-later'),
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 72),
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: KioskColors.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  // 서버 동작은 이번만 거절(mute=false)이다 — 그 뜻 그대로(2026-10-15).
                  child: const Text(
                    '이번엔 안 할게요',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: ElevatedButton(
                  key: const ValueKey('suggestion-approve'),
                  onPressed: canExecute ? onApprove : null,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 72),
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
                    '시작',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // 카운트다운에서 정작 중요한 정보는 남은 초가 아니라 "가만히 두면
              // 아무 일도 없다"는 사실이다 — 자동으로 실행될까 봐 서두르지 않도록.
              Expanded(
                child: Text(
                  canExecute
                      // 남은 초는 이 화면에서 닫히는 시간이다 — 거절·실행을 보내지 않는다(2026-10-15).
                      ? '누르지 않으면 실행하지 않아요 · $cdRemaining초 뒤 닫혀요'
                      : scenario
                          ? '$blockedWhy · $cdRemaining초 뒤 닫혀요'
                          : '이 제안의 가전을 찾을 수 없어 실행할 수 없어요 · '
                              '$cdRemaining초 뒤 닫혀요',
                  style: TextStyle(
                      fontSize: 18,
                      color: canExecute || !scenario
                          ? KioskColors.muted
                          : KioskColors.danger),
                ),
              ),
            ],
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
    );
  }
}

/// 근거 두 줄 제한을 해도 화면에서 빠지면 안 되는 제한 문장 — 근거 밖 줄에 따로 보인다.
const kAlwaysShownCaveats = ['조리 완료가 아닐 수 있어요'];

/// 근거 — 두 줄까지 보이고, 넘치면 '근거 전체 보기'(48 이상)로 펼친다. 낭독은 늘 전문이다.
class _WhyText extends StatefulWidget {
  const _WhyText(this.text);
  final String text;

  @override
  State<_WhyText> createState() => _WhyTextState();
}

class _WhyTextState extends State<_WhyText> {
  bool _expanded = false;

  static const _style = TextStyle(fontSize: 20, color: KioskColors.muted);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: _style),
        maxLines: 2,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: widget.text,
            excludeSemantics: true,
            child: Text(
              widget.text,
              maxLines: _expanded ? null : 2,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: _style,
            ),
          ),
          if (overflows)
            TextButton(
              key: const ValueKey('suggestion-why-more'),
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                foregroundColor: KioskColors.muted,
                minimumSize: const Size(0, 48),
                padding: EdgeInsets.zero,
              ),
              child: Text(_expanded ? '근거 접기' : '근거 전체 보기',
                  style: const TextStyle(fontSize: 18)),
            ),
        ],
      );
    });
  }
}

/// 눌릴 버튼을 번호와 라벨로. 서버가 준 **실제 버튼 라벨**만 쓴다 --
/// 버튼 id 같은 내부 값은 화면에 나오지 않는다.
class _StepList extends StatelessWidget {
  const _StepList({required this.steps});

  final List<String> steps;

  static Widget _number(int n) => Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        // 순서 번호는 정보다. 강조색은 주 행동('지금 실행') 몫으로 남긴다.
        decoration: const BoxDecoration(
          color: KioskColors.success,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$n',
          style: const TextStyle(
            fontSize: 15,
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
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
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
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// 시나리오의 확정 명령 — 번호 · 서버가 쓴 문장(가전·동작) · 경로 배지.
class _CommandList extends StatelessWidget {
  const _CommandList({required this.commands});

  final List<KioskSuggestionCommand> commands;

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: commands.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final c = commands[i];
          final summary = c.summary.isNotEmpty
              ? c.summary
              : '가전과 동작을 폰에서 확인해 주세요';
          // 버튼 누름(physical)은 칩 없이 — routeLabel이 null을 주지만 '경로를 모름'이 아니다(10/14 회귀 수리).
          final path = c.route == 'physical'
              ? null
              : (routeLabel(c.route) ?? '경로 확인 필요');
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StepList._number(i + 1),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                    if (path != null) ...[
                      const SizedBox(height: 4),
                      KioskRouteBadge(label: path),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      );
}
