import 'package:flutter/material.dart';

import '../../models/action_name.dart';
import '../../models/appliance.dart';
import '../../models/command_result.dart';
import '../../models/josa.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_scroll_area.dart';
import 'kiosk_target_line.dart';
import 'kiosk_text.dart';
import 'status_band.dart';
import 'route_badge.dart';
import 'panel_picture.dart';

/// 승인 재검사 실패(409) 안내. 폰 앱과 같은 문장.
const kApprovalChangedMessage = '내용이 바뀌었어요. 다시 봐 주세요';

/// 제안 확인 화면.
///
/// 다가오면(UI 확정 2026-09-30 §3-2) — 제안 카드 **한 장**, 버튼은 "지금 실행"(10/17까지 "시작")과
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
    this.onTouch,
    this.onExtend,
    this.startedByUser = false,
  });

  /// 사람이 키오스크에서 방금 저장된 동작을 눌러 만든 카드(10/24 QA) — 제안이 아니다. 위 띠는 '확인', 질문은 '루틴' 말 없이
  /// '30초 데우기를 할까요?'. 스스로 뜬 제안·다른 곳에서 만든 카드는 false(서버 문장 그대로).
  final bool startedByUser;

  /// 질문 한 줄 — 직접 누른 저장된 동작이면 그 이름으로 묻는다.
  String get questionText {
    final name = suggestion.routineName;
    if (startedByUser && name != null && name.isNotEmpty) return '${withObject(name)} 할까요?';
    return suggestion.isScenario ? suggestion.purpose : '${actionName(suggestion.purpose)},\n지금 할까요?';
  }

  /// 화면을 만졌다(접근성 감사 10/18 — 시간 제한 조절) — 화면이 남은 시간을 처음으로 되돌린다. 단추 동작은 그대로 지나간다.
  final VoidCallback? onTouch;

  /// '시간 더 주기'(+60초). null이면 단추를 두지 않는다.
  final VoidCallback? onExtend;

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
    // 위 상태 띠(2026-10-16 디자인 규격 §4) — 제안 → 실행 → 정지 대기 → 결과가 같은 자리·같은 높이의 띠로 이어진다.
    // 화면 어디든 만지면 남은 시간이 처음으로(접근성 감사 10/18 — 읽는 중에 닫히지 않게). 단추 동작은 그대로(translucent).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onTouch?.call(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 시연 데이터로 만든 제안이면 위 띠가 말한다 — 가장 큰 글자(질문)에 표식을 넣지 않는다(외부 평가 10/16 2차).
          KioskStatusBand(
            tone: KioskBandTone.neutral,
            icon: startedByUser ? Icons.touch_app_outlined : Icons.lightbulb_outline,
            label: startedByUser ? '직접 실행' : (suggestion.isDemo ? '제안 연습' : '제안'),
          ),
          Expanded(child: _body(context, target, scenario, canExecute)),
        ],
      ),
    );
  }

  /// 사용자가 직접 고른 저장 동작 카드의 누를 버튼 순서 — 모든 명령이 [target] 가전의 버튼 누름이면 그 버튼을 이어 붙인다.
  /// 아니면(시스템 제안·ThinQ 섞임·다른 가전) null.
  List<String>? _userPressSteps(ApplianceMap? target) {
    if (!startedByUser || !suggestion.isScenario || target == null) return null;
    final out = <String>[];
    for (final c in suggestion.commands) {
      if (c.route != 'physical' || c.targetId != target.id || c.buttons.isEmpty) return null;
      out.addAll(c.buttons);
    }
    return out;
  }

  Widget _body(BuildContext context, ApplianceMap? target, bool scenario,
      bool canExecute) {
    final large = KioskLayout.isLarge(context);
    final question = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // purpose는 사용자가 예전에 했던 말이다. 질문에는 그 말의 할 일 이름(actionName)을 쓴다(평가 8차 10/18).
        // 질문은 따로 한 줄. 이어 쓰면 폭에 따라 '할까 / 요?'처럼
        // 끊긴다 -- 한글은 글자 단위로 줄이 바뀐다. 그래서 어절 단위로 그린다(2026-10-16 §1-3).
        KioskText(
          // 시나리오 질문은 서버 문장이 이미 물음으로 끝난다.
          // 사람 명령문('즉석밥 데워줘')을 그대로 붙이지 않고 할 일 이름('즉석밥 데우기')으로 — 실행·결과 화면과 같은
          // 규칙(평가 8차 10/18). 서버에 표시용 이름 칸은 없다. 끝 동사를 모르면 actionName이 문장을 그대로 둔다.
          questionText,
          textKey: const ValueKey('suggestion-question'),
          // '같이 / 먹을 준비,'처럼 어구 가운데에서 끊지 않는다(평가 5차 10/18).
          phrases: true,
          style: TextStyle(
            fontSize: KioskType.key,
            fontWeight: FontWeight.w700,
            height: 1.25,
            color: KioskColors.ink,
          ),
        ),
        // 근거를 줄여도 잘리면 안 되는 제한(예: '조리 완료가 아닐 수 있어요')은 근거 밖
        // 늘 보이는 줄로 뺀다. 시연 데이터 여부는 위 상태 띠('제안 · 시연 데이터')가 늘 말한다(2026-10-16).
        for (final caveat in kAlwaysShownCaveats)
          if (suggestion.whyNow.contains(caveat)) ...[
            const SizedBox(height: 8),
            Text(
              caveat,
              key: const ValueKey('suggestion-caveat'),
              style: TextStyle(
                  fontSize: KioskType.body, color: KioskColors.warning),
            ),
          ],
        // 근거는 실제로 셀 수 있을 때만 말한다 -- 어느
        // 시간대였는지까지 밝힌다. 판단의 주인공은 질문과 버튼이라 근거는
        // 두 줄까지만(2026-10-14 UI 정리). 넘치면 '근거 전체 보기'로 펼친다. 낭독에는 전문이 간다.
        // 시나리오 카드는 근거를 오른쪽 칸('할 일' 아래)에 둔다 — 왼쪽은 질문·단서로 차서 근거 둘째 줄이
        // 칸 아래에서 잘렸다(2026-10-16 결함 ③, 15.8형 실패널).
        if (!large &&
            !scenario &&
            suggestion.whyNow.isNotEmpty &&
            !suggestion.userStarted) ...[
          const SizedBox(height: 10),
          _WhyText(suggestion.whyNow),
        ],
      ],
    );
    final scenarioWhy = scenario &&
        !large &&
        suggestion.whyNow.isNotEmpty &&
        !suggestion.userStarted;
    // 오른쪽 칸 제목 — 버튼 누름만이면 '누를 버튼', ThinQ가 섞이면 '할 일'(폰과 같은 말, 2026-10-14).
    final stepsHeading = scenario
        ? (suggestion.commands.every((c) => c.route == 'physical')
            ? '누를 버튼'
            : '할 일')
        : '누름 장치가 누를 순서';
    final hasSteps = scenario || suggestion.steps.isNotEmpty;
    // 큰 글씨에서는 질문·제한을 먼저 읽고, 긴 순서와 근거는 별도 창에서 전문을 읽는다.
    final oneColumn = KioskScrollArea(
        key: const ValueKey('suggestion-one-column'), child: question);
    final details = OutlinedButton(
      onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(stepsHeading),
                content: SizedBox(
                    width: 640,
                    child: SingleChildScrollView(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasSteps)
                          scenario
                              ? _CommandList(
                                  commands: suggestion.commands,
                                  inline: true,
                                  stripMockMark: suggestion.isDemo)
                              : _StepList(
                                  steps: suggestion.steps, inline: true),
                        if (suggestion.whyNow.isNotEmpty &&
                            !suggestion.userStarted) ...[
                          const SizedBox(height: 12),
                          Text(suggestion.whyNow,
                              style: const TextStyle(fontSize: KioskType.body)),
                        ],
                      ],
                    ))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                          minimumSize: const Size(120, 48)),
                      child: const Text('닫기',
                          style: TextStyle(fontSize: KioskType.body)))
                ],
              )),
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48), foregroundColor: KioskColors.ink),
      child: const Text('자세히 보기', style: TextStyle(fontSize: KioskType.body)),
    );
    // 누를 버튼이 모두 버튼판에서 자리를 찾으면 그림으로(화면 구조 개편 10/18) — 실행·결과와 같은 자리(오른쪽)·같은 폭.
    // 하나라도 못 찾으면(이름이 다르거나 두 번 나옴) 지어내지 않고 지금처럼 순서 목록.
    // 내가 고른 저장 동작(루틴 '지금 하기') 확인 카드도 같은 그림(QA 10/25 — 가운데가 비어 보였다). 명령이 모두 이 가전의
    // 버튼 누름일 때만 — ThinQ가 섞이거나 다른 가전이면 지금처럼 할 일 목록. 근거 줄은 이 카드에 두지 않으니 잃는 말이 없다.
    final pictureSteps = _userPressSteps(target) ?? suggestion.steps;
    final order = large || (scenario && _userPressSteps(target) == null)
        ? null
        : KioskPanelPicture.orderOf(target, pictureSteps);
    final pictureMode = order != null;
    return Padding(
      padding: pictureMode
          ? const EdgeInsets.fromLTRB(KioskSizes.runLeft, KioskSizes.runTop,
              KioskSizes.stopRight, KioskSizes.actionsBottom)
          : const EdgeInsets.fromLTRB(KioskSpace.xl, KioskSpace.sm, KioskSpace.xl, KioskSizes.actionsBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (large) ...[
            Row(children: [
              Expanded(
                  child: target != null && !scenario
                      ? KioskTargetLine(appliance: target)
                      : const SizedBox.shrink()),
              details,
            ]),
            const SizedBox(height: 6),
          ] else if (target != null && !scenario && !pictureMode) ...[
            Align(
                alignment: Alignment.centerLeft,
                child: KioskTargetLine(appliance: target)),
            const SizedBox(height: 10),
          ],
          // 사용자가 붙인 루틴 이름 — 메뉴는 사용자가 만든다(§1-1).
          // 질문이 이미 루틴 이름을 말하면 되풀이하지 않는다(실패널 10/17 — "'30초 데우기' 루틴을 실행할까요?").
          if (suggestion.routineName != null &&
              suggestion.routineName!.isNotEmpty &&
              !questionText.contains(suggestion.routineName!)) ...[
            Text(
              '내 루틴 "${suggestion.routineName}"',
              style: TextStyle(
                  fontSize: KioskType.body, color: KioskColors.muted),
            ),
            const SizedBox(height: 6),
          ],
          // 시나리오 이름은 서버가 정한 이유 머리말('공기가 나빠요')이고 사용자 루틴이 아니다 — '루틴'을 붙이지 않는다
          // (실물 10/20 — 공기질 카드에 '루틴 공기가 나빠요'). '루틴'은 routine_id가 있는 카드(위 '내 루틴' 줄)에만.
          if (scenario && scenarioName != null && scenarioName!.isNotEmpty) ...[
            Text(
              scenarioName!,
              style: TextStyle(
                  fontSize: KioskType.body, color: KioskColors.muted),
            ),
            const SizedBox(height: 6),
          ],
          Expanded(
            child: large
                ? oneColumn
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 왼쪽: 무엇을 ─────────────────────────────────────────
                      Expanded(
                        flex: 5,
                        // 큰 글씨에서 근거 줄이 아래로 넘치면 스크롤 막대가 보인다(2026-10-15).
                        child: KioskScrollArea(
                            child: pictureMode
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      KioskTargetLine(appliance: target!),
                                      const SizedBox(height: KioskSpace.sm),
                                      question,
                                    ],
                                  )
                                : question),
                      ),
                      // ── 오른쪽(시나리오): 어느 가전을 어느 경로로 무엇을 ─────────
                      if (pictureMode) ...[
                        const SizedBox(width: KioskSizes.stopGap),
                        SizedBox(
                          width: KioskPanelPicture.width,
                          child: Semantics(
                            label: '누름 장치가 누를 순서. $kScreenNoPress. ${[
                              for (var i = 0; i < pictureSteps.length; i++)
                                '${i + 1} ${pictureSteps[i]}'
                            ].join(', ')}',
                            child: KioskPanelPicture(
                              appliance: target,
                              // 실행 화면과 같은 안내(접근성 감사 10/18) — 그림 칸을 눌러야 하는 줄 알지 않게.
                              caption: '누름 장치가 누를 순서예요. $kScreenNoPress',
                              captionKey: const ValueKey('suggestion-panel-caption'),
                              order: order,
                            ),
                          ),
                        ),
                      ] else if (scenario) ...[
                        const SizedBox(width: 28),
                        Expanded(
                          flex: 5,
                          // 할 일과 근거를 한 스크롤 칸에 — 넘치면 스크롤 막대가 보인다.
                          child: KioskScrollArea(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  stepsHeading,
                                  style: TextStyle(
                                      fontSize: KioskType.caption,
                                      color: KioskColors.muted),
                                ),
                                const SizedBox(height: 8),
                                _CommandList(
                                    commands: suggestion.commands,
                                  inline: true,
                                  stripMockMark: suggestion.isDemo),
                                if (scenarioWhy) ...[
                                  const SizedBox(height: 16),
                                  _WhyText('이유: ${suggestion.whyNow}'),
                                ],
                              ],
                            ),
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
                              Text(
                                '누름 장치가 누를 순서',
                                style: TextStyle(
                                    fontSize: KioskType.caption,
                                    color: KioskColors.muted),
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
          // 두 단추는 늘 같은 높이(UI 평가 3차 10/17 — 큰 글씨에서 거절이 두 줄로 접혀 높이가 달랐다).
          IntrinsicHeight(
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 보조 동작이 왼쪽, 주요 실행이 오른쪽 — 폰 앱과 같은 규칙.
              // 높이를 고정하지 않고 **최소 높이**로 준다. 고정하면 큰 글씨
              // 모드에서 글자가 버튼 안에서 잘린다. 선택 버튼은 질문 다음으로 크게 — 순서·근거보다
              // 먼저 눈에 들어와야 한다(2026-10-14 UI 정리).
              // 큰 글씨는 반반 — 3:4에서 '이번엔 안 할게요'가 두 줄로 접혔다.
              Expanded(
                flex: large ? 1 : 3,
                child: OutlinedButton(
                  key: const ValueKey('suggestion-later'),
                  onPressed: onReject,
                  // 보조 단추 모양(테두리) — 둘 중 하나를 고르는 자리라 높이만 주 단추와 같다(§1-5).
                  style: KioskButtons.secondary(
                          foreground: KioskColors.ink, border: KioskColors.muted)
                      .copyWith(
                    minimumSize: const WidgetStatePropertyAll(
                        Size(0, KioskSizes.primaryButton)),
                    padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 12)),
                  ),
                  // 서버 동작은 이번만 거절(mute=false)이다 — 그 뜻 그대로(2026-10-15).
                  child: const KioskText(
                    '이번엔 안 할게요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: KioskType.status,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: large ? 1 : 4,
                child: ElevatedButton(
                  key: const ValueKey('suggestion-approve'),
                  onPressed: canExecute ? onApprove : null,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, KioskSizes.primaryButton),
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
                  // 폰과 같은 '지금 실행' — 가전 버튼 이름 '시작'과 겹치면 가전 버튼을 바로 누르는 것으로 읽혔다(UI 평가 10/17).
                  child: const Text(
                    '지금 하기',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: KioskType.status,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // 카운트다운에서 정작 중요한 정보는 남은 초가 아니라 "가만히 두면
              // 아무 일도 없다"는 사실이다 — 자동으로 실행될까 봐 서두르지 않도록.
              // 1~2 m에서 읽히게 본문 크기·흰 글자, 남은 초는 굵게 따로(결선 모의 평가 10/18 — 작은 회색이었다).
              Expanded(
                child: KioskText(
                  canExecute
                      ? "'지금 하기'를 누르기 전에는 아무것도 하지 않아요"
                      : scenario
                          ? (blockedWhy ?? '')
                          : '이 가전을 찾지 못해 할 수 없어요. 휴대폰 앱에서 가전을 봐 주세요',
                  textKey: const ValueKey('suggestion-countdown'),
                  style: TextStyle(
                      fontSize: KioskType.body,
                      height: 1.25,
                      color: canExecute || !scenario
                          ? KioskColors.ink
                          : KioskColors.danger),
                ),
              ),
              // 남은 시간은 오른쪽에 따로, 초는 크게 — 문장을 다 읽지 않아도 얼마나 남았는지 보인다.
              // 남은 초는 이 화면에서 닫히는 시간이다 — 거절·실행을 보내지 않는다(2026-10-15).
              const SizedBox(width: KioskSpace.sm),
              Text.rich(
                key: const ValueKey('suggestion-countdown-seconds'),
                TextSpan(children: [
                  TextSpan(
                    text: '$cdRemaining초',
                    style: const TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w800),
                  ),
                  const TextSpan(text: ' 뒤 닫혀요'),
                ]),
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                    fontSize: KioskType.body, height: 1.1, color: KioskColors.ink),
              ),
              // 시간이 더 필요하면 60초 더(접근성 감사 10/18 — 시간 제한 늘리기). 작은 보조 단추(테두리), 누르는 자리 48 이상.
              if (onExtend != null) ...[
                const SizedBox(width: KioskSpace.sm),
                Semantics(
                  button: true,
                  label: '시간 더 주기. 1분 더 기다려요',
                  excludeSemantics: true,
                  child: OutlinedButton.icon(
                    key: const ValueKey('suggestion-more-time'),
                    onPressed: onExtend,
                    icon: const Icon(Icons.more_time, size: KioskType.body),
                    label: const Text('시간 더 주기',
                        maxLines: 1, softWrap: false, style: TextStyle(fontSize: KioskType.caption)),
                    style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border).copyWith(
                      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
                      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.sm)),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: cdTotal > 0 ? cdRemaining / cdTotal : 0,
              minHeight: 6,
              backgroundColor: KioskColors.border,
              valueColor: AlwaysStoppedAnimation(KioskColors.panelText),
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

  static TextStyle get _style =>
      TextStyle(fontSize: KioskType.body, color: KioskColors.muted);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // 그리는 글(어절 단위 줄바꿈)과 같은 글로 넘침을 잰다.
      final painter = TextPainter(
        text: TextSpan(text: keepWords(widget.text), style: _style),
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
            child: KioskText(
              widget.text,
              maxLines: _expanded ? null : 2,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: _style,
            ),
          ),
          if (overflows)
            // 글자만 있는 조작은 두지 않는다 — 작은 보조 단추(테두리, 48 이상, 2026-10-16 §1-5).
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton(
                key: const ValueKey('suggestion-why-more'),
                onPressed: () => setState(() => _expanded = !_expanded),
                style: KioskButtons.secondary(
                        foreground: KioskColors.ink, border: KioskColors.border)
                    .copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
                  padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 16)),
                ),
                child: Text(_expanded ? '접기' : '이유 더 보기',
                    style: const TextStyle(fontSize: KioskType.caption)),
              ),
            ),
        ],
      );
    });
  }
}

/// 눌릴 버튼을 번호와 라벨로. 서버가 준 **실제 버튼 라벨**만 쓴다 --
/// 버튼 id 같은 내부 값은 화면에 나오지 않는다.
class _StepList extends StatelessWidget {
  const _StepList({required this.steps, this.inline = false});

  final List<String> steps;

  /// 큰 글자 1열 배치 — 바깥 스크롤 안에 이어 그린다(자기 스크롤 없이, 번호를 붙여 옆으로 흘린다).
  final bool inline;

  static Widget _number(int n) => Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        // 순서 번호는 정보다. 강조색은 주 행동('지금 실행') 몫으로 남긴다.
        decoration: BoxDecoration(
          color: KioskColors.success,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$n',
          style: TextStyle(
            fontSize: KioskType.caption,
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
    if (steps.length > 4 || inline) {
      final flow = Wrap(
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
                  style: TextStyle(
                    fontSize: KioskType.body,
                    fontWeight: FontWeight.w500,
                    color: KioskColors.ink,
                  ),
                ),
              ],
            ),
        ],
      );
      return inline ? flow : SingleChildScrollView(child: flow);
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
              style: TextStyle(
                fontSize: KioskType.body,
                fontWeight: FontWeight.w500,
                color: KioskColors.ink,
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
  const _CommandList(
      {required this.commands, this.inline = false, this.stripMockMark = false});

  /// 시연 데이터 카드 — 위 띠가 이미 말하니 가전 이름의 '(모의)'를 되풀이하지 않는다.
  final bool stripMockMark;

  final List<KioskSuggestionCommand> commands;

  /// 큰 글자 1열 배치 — 바깥 스크롤 안에 이어 그린다(자기 스크롤 없음).
  final bool inline;

  @override
  Widget build(BuildContext context) => ListView.separated(
        shrinkWrap: inline,
        physics: inline ? const NeverScrollableScrollPhysics() : null,
        padding: EdgeInsets.zero,
        itemCount: commands.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final c = commands[i];
          final raw =
              c.summary.isNotEmpty ? c.summary : '휴대폰 앱에서 가전과 할 일을 봐 주세요';
          final summary = stripMockMark
              ? raw.replaceAll(RegExp(r'\(모의( 클라우드)?\)'), '')
              : raw;
          // 버튼 누름(physical)은 칩 없이 — routeLabel이 null을 주지만 '경로를 모름'이 아니다(10/14 회귀 수리).
          final path = c.route == 'physical'
              ? null
              : (routeLabel(c.route) ?? '할 일을 불러오지 못했어요');
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
                      style: TextStyle(
                        fontSize: KioskType.body,
                        fontWeight: FontWeight.w500,
                        color: KioskColors.ink,
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
