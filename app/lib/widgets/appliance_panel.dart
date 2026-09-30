import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../models/hub.dart';
import '../theme/app_colors.dart';
import 'panel_photo_view.dart';

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
  });

  final ApplianceMap appliance;
  final void Function(ApplianceButton button) onButton;

  /// 녹화한 순서(버튼 id). 같은 버튼이 여러 번 나올 수 있다.
  final List<String> pinned;

  /// 골든·테스트용 이미지.
  final ImageProvider? imageOverride;

  bool get hasPhotoMapping => appliance.panelMapping != null;

  @override
  Widget build(BuildContext context) {
    final mapping = appliance.panelMapping;
    if (mapping == null) return _grid(context);
    return PanelPhotoView(
      photoWidth: mapping.photoWidth,
      photoHeight: mapping.photoHeight,
      photoPath: appliance.photoPath,
      image: imageOverride,
      semanticsLabel: '${appliance.displayName} 조작부 사진 위 버튼 표시',
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.appOverlayFaint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorderFaint),
      ),
      child: Column(
        children: List.generate(appliance.rows, (row) {
          return Padding(
            padding: EdgeInsets.only(bottom: row < appliance.rows - 1 ? 8 : 0),
            child: Row(
              children: List.generate(appliance.cols, (col) {
                final b = appliance.buttonAt(col, row);
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: col < appliance.cols - 1 ? 8 : 0),
                    child: b == null
                        ? const SizedBox(height: 48)
                        : _GridButton(
                            button: b,
                            isStop: b.id == appliance.stopButton,
                            order: orders[b.id],
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
  });

  final ApplianceButton button;
  final bool isStop;
  final List<int>? order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = order;
    return OutlinedButton(
      key: Key('mark-${button.id}'),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
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
            style: const TextStyle(fontSize: 15),
          ),
          if (o != null)
            Text(
              o.join('·'),
              style: TextStyle(
                fontSize: 12,
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
