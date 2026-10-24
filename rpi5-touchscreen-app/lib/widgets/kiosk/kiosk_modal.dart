import 'package:flutter/widgets.dart';

/// 화면 안 창(메뉴·사용 방법·연결·방해 금지·설정)을 화면 읽기에도 **이름 있는 한 화면**으로 둔다(10/24 QA) — 누르기 확인
/// 창(`manual-press-confirm`)과 같은 방식. 창 뒤 화면은 창을 띄운 쪽이 [ExcludeSemantics]로 뺀다(비상 멈춤 띠처럼 늘
/// 닿아야 하는 것은 빼지 않게, 뒤에서 무엇을 뺄지는 띄운 쪽이 안다).
class KioskModalSemantics extends StatelessWidget {
  const KioskModalSemantics({super.key, required this.label, required this.child});

  /// 창 이름(화면 읽기가 창에 들어설 때 읽는다).
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: label,
        child: child,
      );
}
