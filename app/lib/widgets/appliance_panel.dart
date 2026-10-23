import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../models/hub.dart';
import '../theme/app_colors.dart';
import 'panel_photo_view.dart';
import '../theme/app_tokens.dart';

/// 가전의 조작부 — 등록 사진이 있으면 **사진 위 버튼**, 없으면 버튼판.
///
/// 가전 상세(누르기)와 루틴 녹화(순서 짚기)가 같이 쓴다. 사진 위 자리는
/// 서버가 기억하는 `panel_mapping`에서만 온다 -- 자리를 모르면 사진 위에
/// 지어 그리지 않고 버튼판으로 떨어진다.
class AppliancePanel extends StatelessWidget {
  const AppliancePanel({
    super.key,
    required this.appliance,
    required this.onButton,
    this.pinned = const [],
    this.imageOverride,
    this.unavailable = false,
  });

  /// 본체가 지금은 실행할 수 없다고 한 가전(누름 장치 끊김 등) — 판을 흐리게 그리고 낭독에 '지금은 쓸 수 없어요'를
  /// 붙인다(첫 사용 평가 10/24: 눌리는 판과 똑같이 보여 눌러 본 뒤에야 알았다). 이유 한 줄은 부르는 화면이 판 위에 적는다.
  /// 누르면 [onButton]은 그대로 불린다 — 부르는 화면이 실행하지 않고 이유를 다시 말한다.
  final bool unavailable;

  /// 쓸 수 없을 때 버튼 낭독 뒤에 붙는 말 — 홈 타일 '!'의 '지금은 쓸 수 없어요'와 같은 말.
  static const unavailableSuffix = '지금은 쓸 수 없어요';

  final ApplianceMap appliance;
  final void Function(ApplianceButton button) onButton;

  /// 녹화한 순서(버튼 id). 같은 버튼이 여러 번 나올 수 있다.
  final List<String> pinned;

  /// 골든·테스트용 이미지.
  final ImageProvider? imageOverride;

  bool get hasPhotoMapping => appliance.panelMapping != null;

  @override
  Widget build(BuildContext context) {
    final panel = _panel(context);
    if (!unavailable) return panel;
    return Opacity(opacity: 0.45, child: panel);
  }

  Widget _panel(BuildContext context) {
    final mapping = appliance.panelMapping;
    if (mapping == null) return _grid(context);
    return PanelPhotoView(
      markSemanticSuffix: unavailable ? unavailableSuffix : null,
      photoWidth: mapping.photoWidth,
      photoHeight: mapping.photoHeight,
      photoPath: appliance.photoPath,
      image: imageOverride,
      semanticsLabel: '${appliance.displayName} 버튼판 사진 위 버튼 표시',
      marks: applianceMarks(appliance, pinned: pinned),
      onTapMark: (m) {
        final b = appliance.buttons.where((b) => b.id == m.id).firstOrNull;
        if (b != null) onButton(b);
      },
    );
  }

  Widget _grid(BuildContext context) {
    final orders = <String, List<int>>{};
    for (var i = 0; i < pinned.length; i++) {
      orders.putIfAbsent(pinned[i], () => []).add(i + 1);
    }
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: context.appOverlayFaint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorderFaint),
      ),
      child: Column(
        children: List.generate(appliance.rows, (row) {
          return Padding(
            padding: EdgeInsets.only(bottom: row < appliance.rows - 1 ? AppSpace.sm : 0),
            child: Row(
              children: List.generate(appliance.cols, (col) {
                final b = appliance.buttonAt(col, row);
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: col < appliance.cols - 1 ? AppSpace.sm : 0),
                    child: b == null
                        ? const SizedBox(height: 48)
                        : _GridButton(
                            button: b,
                            isStop: b.id == appliance.stopButton,
                            order: orders[b.id],
                            unavailable: unavailable,
                            onTap: () => onButton(b),
                          ),
                  ),
                );
              }),
            ),
          );
        }),
      ),
    );
  }
}

class _GridButton extends StatelessWidget {
  const _GridButton({
    required this.button,
    required this.isStop,
    required this.order,
    required this.onTap,
    this.unavailable = false,
  });

  final ApplianceButton button;
  final bool isStop;
  final List<int>? order;
  final VoidCallback onTap;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final body = _button(context);
    if (!unavailable) return body;
    return Semantics(
      label: '${button.label}, ${AppliancePanel.unavailableSuffix}',
      button: true,
      excludeSemantics: true,
      child: body,
    );
  }

  Widget _button(BuildContext context) {
    final o = order;
    return OutlinedButton(
      key: Key('mark-${button.id}'),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: AppSpace.sm),
        side: BorderSide(
          color: isStop ? context.appDanger : context.appOutline,
          width: isStop ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            button.label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: AppFont.caption),
          ),
          if (o != null)
            Text(
              o.join('·'),
              style: TextStyle(
                fontSize: AppFont.caption,
                fontWeight: FontWeight.w700,
                color: context.appPrimary,
              ),
            ),
        ],
      ),
    );
  }
}

/// 가전의 사진 매핑을 표시 목록으로. 정지 버튼은 빨강, 쉬는 자리는 점선,
/// 녹화 순서는 번호 핀.
List<PanelMark> applianceMarks(
  ApplianceMap appliance, {
  List<String> pinned = const [],
}) {
  final mapping = appliance.panelMapping;
  if (mapping == null) return const [];
  final marks = <PanelMark>[];
  for (final b in appliance.buttons) {
    final p = mapping.buttons[b.id];
    if (p == null) continue;
    marks.add(PanelMark(
      id: b.id,
      kind: b.id == appliance.stopButton ? PanelMarkKind.stop : PanelMarkKind.button,
      point: p,
      label: b.label,
    ));
  }
  final park = mapping.parkPoint;
  if (park != null) {
    marks.add(PanelMark(id: 'park', kind: PanelMarkKind.park, point: park));
  }
  for (var i = 0; i < pinned.length; i++) {
    final p = mapping.buttons[pinned[i]];
    if (p == null) continue;
    marks.add(PanelMark(
      id: 'pin-$i',
      kind: PanelMarkKind.pin,
      point: PhotoPoint(p.x, p.y),
      number: i + 1,
      label: appliance.labelFor(pinned[i]),
    ));
  }
  return marks;
}
