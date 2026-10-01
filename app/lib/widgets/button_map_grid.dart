import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../theme/app_colors.dart';

/// 누르는 순서에서 버튼 하나가 지금 어디에 있는가.
enum ButtonMapStepState { planned, done, current, pending }

/// 실제 버튼판 위에 순서 번호를 얹은 **읽는 그림**. 조작판이 아니다.
///
/// 제안 확인 화면은 순서만 얹는다([completed]가 null). 실행 상태 화면은
/// 진행도 얹는다 -- 이 제품이 하는 일은 "앱이 빙글빙글 돌다 끝났다"가 아니라
/// **실제 버튼판의 어느 버튼을 지금 누르고 있는가**라서, 그 자리가 그림으로
/// 보여야 한다.
///
/// 진행 상태는 색만으로 말하지 않는다. 끝난 버튼은 체크 배지, 지금 버튼은
/// 채운 면과 두꺼운 테두리, 남은 버튼은 얇은 테두리와 번호 -- 흑백에서도 셋이
/// 구분된다.
class ButtonMapGrid extends StatelessWidget {
  const ButtonMapGrid({
    super.key,
    required this.appliance,
    required this.steps,
    this.completed,
    this.active = false,
    this.caution = false,
  });

  final ApplianceMap appliance;

  /// 누를 버튼 ID. 같은 버튼이 여러 번 나올 수 있다(예: 30초를 두 번).
  final List<String> steps;

  /// 확인을 마친 단계 수. null이면 진행을 그리지 않는다(제안 확인).
  final int? completed;

  /// 지금 누르고 있는가. 끝났거나 멈췄으면 '지금' 버튼이 없다 --
  /// 실패한 실행에서 어느 버튼이 문제였는지는 서버가 말해 주지 않으므로
  /// 그림이 지어내지 않는다.
  final bool active;

  /// 보정 후 다시 누르는 중. 지금 버튼을 주의색으로 그린다.
  final bool caution;

  /// 버튼 하나의 상태. 여러 번 나오는 버튼은 **아직 남은 차례가 있으면**
  /// 끝나지 않은 것이다.
  ButtonMapStepState stateOf(String buttonId) {
    final at = [
      for (var i = 0; i < steps.length; i++)
        if (steps[i] == buttonId) i,
    ];
    if (at.isEmpty) return ButtonMapStepState.pending;
    final done = completed;
    if (done == null) return ButtonMapStepState.planned;
    if (active && at.contains(done)) return ButtonMapStepState.current;
    if (at.every((i) => i < done)) return ButtonMapStepState.done;
    return ButtonMapStepState.pending;
  }

  @override
  Widget build(BuildContext context) {
    // 버튼 ID마다 순서 번호들. 두 번 누르는 버튼은 "1·3"처럼 둘 다 적는다 --
    // 첫 번호만 적으면 3번째 차례에 그림이 아무것도 가리키지 않는다.
    final orders = <String, List<int>>{};
    for (var i = 0; i < steps.length; i++) {
      orders.putIfAbsent(steps[i], () => []).add(i + 1);
    }

    return Container(
      decoration: BoxDecoration(
        color: context.appOverlayFaint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorderFaint),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: List.generate(appliance.rows, (row) {
          return Padding(
            padding: EdgeInsets.only(bottom: row < appliance.rows - 1 ? 8 : 0),
            // 큰 글씨에서 긴 이름이 두 줄이 되면 칸이 늘어나야 한다. 한 줄의
            // 칸 높이는 가장 긴 칸에 맞춘다 -- 들쭉날쭉하면 배치가 틀어져
            // 보이고, 높이를 고정하면 글자가 잘린다.
            child: IntrinsicHeight(
             child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(appliance.cols, (col) {
                final btn = appliance.buttonAt(col, row);
                return Expanded(
                  child: Padding(
                    padding:
                        EdgeInsets.only(right: col < appliance.cols - 1 ? 8 : 0),
                    child: btn == null
                        ? const SizedBox(height: 52)
                        : _Cell(
                            label: btn.label,
                            orders: orders[btn.id],
                            state: stateOf(btn.id),
                            caution: caution,
                          ),
                  ),
                );
              }),
             ),
            ),
          );
        }),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.orders,
    required this.state,
    required this.caution,
  });

  final String label;

  /// 이 버튼의 순서 번호들. 순서에 없는 버튼이면 null.
  final List<int>? orders;
  final ButtonMapStepState state;
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final inSequence = orders != null;
    final accent = caution && state == ButtonMapStepState.current
        ? context.appWarning
        : context.appPrimary;

    final (Color fill, Border? border, Color text, FontWeight weight) =
        switch (state) {
      // 순서에 든 버튼만 테두리를 준다. 나머지까지 두르면 전부 눌러도 되는
      // 버튼처럼 보이는데, 이 지도는 읽는 그림이지 조작판이 아니다.
      _ when !inSequence => (
          context.appOverlayFaint,
          null,
          context.appOnSurfaceFaint,
          FontWeight.normal,
        ),
      // 순서에 든 버튼은 무채색 테두리와 굵은 글자로. 강조색은 '지금'에만 쓴다.
      ButtonMapStepState.planned => (
          context.appInk.withValues(alpha: 0.08),
          Border.all(color: context.appInk, width: 1.5),
          context.appInk,
          FontWeight.w700,
        ),
      ButtonMapStepState.current => (
          accent,
          Border.all(color: accent, width: 3),
          context.appOnAccent,
          FontWeight.w700,
        ),
      ButtonMapStepState.done => (
          context.appOverlayFaint,
          Border.all(color: context.appSuccess, width: 1.5),
          context.appSuccess,
          FontWeight.w600,
        ),
      ButtonMapStepState.pending => (
          context.appOverlayFaint,
          Border.all(color: context.appOutline, width: 1),
          context.appInk,
          FontWeight.w600,
        ),
    };

    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: border,
      ),
      // 여백은 글자에만 준다. 칸 전체에 주면 배지의 기준이 칸 모서리가 아니라
      // 글자 상자가 되어, 배지가 이름 옆으로 내려와 글자와 겹친다.
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: weight, color: text),
            ),
          ),
          if (inSequence)
            Positioned(
              top: 4,
              right: 4,
              child: _Badge(orders: orders!, state: state, accent: accent),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.orders,
    required this.state,
    required this.accent,
  });

  final List<int> orders;
  final ButtonMapStepState state;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (state == ButtonMapStepState.done) {
      return Icon(Icons.check_circle, size: 20, color: context.appSuccess);
    }
    // 지금 버튼은 면이 강조색이라, 배지를 반대로 칠해야 보인다.
    final current = state == ButtonMapStepState.current;
    // 높이를 고정하지 않는다 -- 200% 글씨에서 숫자가 배지 밖으로 잘렸다.
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: current ? context.appOnAccent : context.appInk,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          orders.join('·'),
          style: TextStyle(
            // 9px는 고령 사용자에게 사실상 안 보인다 — 배지째 키웠다
            fontSize: 12,
            fontWeight: FontWeight.w700,
            // 검정 고정이면 라이트 모드(어두운 강조색 위)에서 3.78:1
            color: current ? accent : context.appOnAccent,
          ),
        ),
      ),
    );
  }
}
