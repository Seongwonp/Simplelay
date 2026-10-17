import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';

/// 설명 그림(버튼판, §1-6) — **제안·실행·정지 대기·결과** 화면이 같은 자리(오른쪽)에 같은 모양으로 그린다
/// (화면 구조 개편 10/18 — 이 제품만의 그림을 중심에). 누를 곳 → 누르는 곳 → 누른 곳.
///
/// 누를 수 있는 단추로 보이지 않게: 카드 테두리 없음, 어두운 평면, 칸 테두리 없음. 칸 글자는 밝은 회색이다
/// (50% 회색이던 때는 꺼진 것처럼 보였다). 표시는 세 가지뿐이다.
/// - [order] 제안: 누를 칸에 순서 번호(흰 원) + 흰 테.
/// - [current] 실행·정지 대기: 지금 누르는(또는 작은 팔이 기다리는) 칸을 진행색으로 채운다(다시 누르면 주의색).
/// - [pressed] 결과: 작은 팔이 누른 칸에 흰 테 + 표시(눌렀다고 알려 옴 체크, 모름 물음표). 가전이 켜졌다는 뜻이 아니다.
/// 스크린리더에는 왼쪽 글이 같은 말을 하므로 읽지 않는다.
class KioskPanelPicture extends StatelessWidget {
  const KioskPanelPicture({
    super.key,
    required this.appliance,
    required this.caption,
    this.current,
    this.caution = false,
    this.captionKey,
    this.compact = false,
    this.order = const {},
    this.pressed = const {},
  });

  /// 오른쪽 그림 칸 폭 — 실행 계열 화면의 정지 단추 폭과 같다(같은 자리·같은 폭).
  static const double width = KioskSizes.stopWidth;

  /// 큰 글자 1열 배치(§1-8)에서 정지 단추 왼쪽 한 줄(정지 단추 높이)로 줄인 모양 — 현재 버튼 이름만 크게 표시.
  final bool compact;

  /// 같은 그림을 줄인 모양으로([KioskRunFrame]이 큰 글자에서 쓴다).
  KioskPanelPicture compactCopy() => KioskPanelPicture(
        key: key,
        appliance: appliance,
        caption: caption,
        current: current,
        caution: caution,
        captionKey: captionKey,
        compact: true,
        order: order,
        pressed: pressed,
      );

  /// 대상 가전. 모르거나 버튼판이 없으면 '버튼판 그림이 없어요'.
  final ApplianceMap? appliance;
  final String caption;

  /// 채울 칸(지금 누르는 버튼·작은 팔이 기다리는 버튼). 없으면 채운 칸이 없다.
  final ApplianceButton? current;

  /// 자리를 맞춰 다시 누르는 중 — 채움을 주의색으로.
  final bool caution;

  final Key? captionKey;

  /// 제안 — 버튼 id → 누를 순서(1부터). 같은 버튼을 여러 번 누르면 번호가 여럿이다.
  final Map<String, List<int>> order;

  /// 결과 — 버튼 id → 작은 팔이 눌렀다고 알려 왔는가(true) / 모름(false).
  final Map<String, bool> pressed;

  /// 이 버튼판에서 이름이 **정확히 한 번** 나오는 버튼. 없거나 둘 이상이면 null — 틀린 자리를 가리키지 않는다.
  static ApplianceButton? uniqueButton(ApplianceMap? a, String label) {
    if (a == null) return null;
    final hits = a.buttons.where((b) => b.label == label).toList();
    return hits.length == 1 ? hits.first : null;
  }

  static bool _drawable(ApplianceMap? a) =>
      a != null && !a.isThinq && a.buttons.isNotEmpty;

  /// 순서 목록(버튼 이름) → 칸별 번호. 하나라도 버튼판에서 자리를 못 찾으면 null(그림 대신 목록을 쓴다).
  static Map<String, List<int>>? orderOf(ApplianceMap? a, List<String> steps) {
    if (!_drawable(a) || steps.isEmpty) return null;
    final out = <String, List<int>>{};
    for (var i = 0; i < steps.length; i++) {
      final b = uniqueButton(a, steps[i]);
      if (b == null) return null;
      (out[b.id] ??= []).add(i + 1);
    }
    return out;
  }

  /// 누른 버튼 기록(이름·성공) → 칸별 표시. 하나라도 자리를 못 찾으면 null.
  static Map<String, bool>? pressedOf(
      ApplianceMap? a, List<(String, bool)> results) {
    if (!_drawable(a) || results.isEmpty) return null;
    final out = <String, bool>{};
    for (final (label, ok) in results) {
      final b = uniqueButton(a, label);
      if (b == null) return null;
      out[b.id] = (out[b.id] ?? true) && ok;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('panel-picture'),
        decoration: BoxDecoration(
          color: KioskColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(KioskSpace.xs),
        child: !_drawable(a)
            ? const Center(
                child: Text(
                  '버튼판 그림이 없어요',
                  style: TextStyle(
                      fontSize: KioskType.body, color: KioskColors.panelText),
                ),
              )
            : compact
                ? _compact()
                // 자리가 낮아지면(위 비상 버튼 띠가 길 때) 안내 글부터, 더 낮으면 그림도 접는다 — 정지 단추가 먼저다.
                : LayoutBuilder(builder: (context, outer) {
                    if (outer.maxHeight < 48) return const SizedBox.expand();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (outer.maxHeight >=
                            KioskSizes.panelCaptionMinHeight) ...[
                          KioskText(
                            caption,
                            textKey: captionKey,
                            // 큰 글씨에서 두 줄로는 잘렸다(2026-10-16 골든) — 세 줄까지.
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: KioskType.caption,
                                color: KioskColors.muted),
                          ),
                          const SizedBox(height: KioskSpace.xs),
                        ],
                        Expanded(child: _grid(a!)),
                      ],
                    );
                  }),
      ),
    );
  }

  /// 큰 글자에서는 전체 버튼판을 생략하고 현재 버튼 이름만 읽을 수 있는 크기로 둔다.
  Widget _compact() => Center(
        child: current == null
            ? KioskText(caption,
                textKey: captionKey,
                style: const TextStyle(
                    fontSize: KioskType.body, color: KioskColors.muted))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('작은 팔 위치',
                    style: TextStyle(
                        fontSize: KioskType.caption, color: KioskColors.muted)),
                const SizedBox(width: KioskSpace.sm),
                Flexible(
                    child: Text(current!.label,
                        key: const ValueKey('panel-current'),
                        style: TextStyle(
                            fontSize: KioskType.status,
                            color: caution
                                ? KioskColors.warning
                                : KioskColors.running,
                            fontWeight: FontWeight.w800))),
              ]),
      );

  Widget _grid(ApplianceMap a) => Column(
        children: [
          for (var y = 0; y < a.rows; y++)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var x = 0; x < a.cols; x++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: _cell(a.buttonAt(x, y)),
                      ),
                    ),
                ],
              ),
            ),
        ],
      );

  Widget _cell(ApplianceButton? button) {
    if (button == null) return const SizedBox.shrink();
    final on = current != null && button.id == current!.id;
    final numbers = order[button.id];
    final mark = pressed[button.id];
    final marked = numbers != null || mark != null;
    final fill = caution ? KioskColors.warning : KioskColors.running;
    final Color edge = mark == false ? KioskColors.warning : Colors.white;
    final cell = DecoratedBox(
      key: on ? const ValueKey('panel-current') : null,
      decoration: BoxDecoration(
        color: on ? fill : KioskColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: marked && !on ? Border.all(color: edge, width: 2) : null,
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // 칸이 작다. 긴 이름은 잘리지 않게 줄여서 한 줄에 넣는다.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              button.label,
              style: TextStyle(
                fontSize: KioskType.caption,
                fontWeight: on || marked ? FontWeight.w800 : FontWeight.w500,
                color: on
                    ? KioskColors.onAccent
                    : marked
                        ? Colors.white
                        : KioskColors.panelText,
              ),
            ),
          ),
        ),
      ),
    );
    if (!marked) return cell;
    // 번호·표시는 칸 왼쪽 위 작은 원 — 칸 글자를 가리지 않는다.
    final badge = numbers != null
        ? _Badge(
            key: ValueKey('panel-order-${button.id}'),
            text: numbers.join(','),
            fill: Colors.white)
        : _Badge(
            key: ValueKey('panel-pressed-${button.id}'),
            icon: mark! ? Icons.check : Icons.question_mark,
            fill: mark ? Colors.white : KioskColors.warning);
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: cell),
      Positioned(left: -7, top: -9, child: badge),
    ]);
  }
}

/// 칸 왼쪽 위 작은 표시(순서 번호·눌렀다는 표시). 칸 안에서 글자 배율을 얹지 않는다 — 칸 크기가 정해져 있다.
class _Badge extends StatelessWidget {
  const _Badge({super.key, this.text, this.icon, required this.fill});

  final String? text;
  final IconData? icon;
  final Color fill;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 26),
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: KioskColors.surface, width: 2),
        ),
        child: icon != null
            ? Icon(icon, size: KioskType.caption, color: KioskColors.onAccent)
            : Text(text!,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(
                    fontSize: KioskType.caption,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: KioskColors.onAccent)),
      );
}
