import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'appliance_artwork.dart';

/// 가전 종류 고르기 — 홈과 같은 [ApplianceArtwork] 그림 + 한글 이름 카드(2026-10-24, 가전 그림 통일 1단계).
///
/// 기기 추가 마법사와 가전 편집 화면이 같이 쓴다. 고른 칸은 테두리·체크 표시·낭독 '선택됨'으로 함께 알린다
/// (색만으로 알리지 않는다). 종류를 이름에서 짐작하지 않는다 — 사람이 고른 값만 쓴다.
class ApplianceKindPicker extends StatelessWidget {
  const ApplianceKindPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.artSize = 48,
  });

  final ApplianceCategory selected;
  final ValueChanged<ApplianceCategory> onSelected;
  final double artSize;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: [
          for (final c in ApplianceCategory.values)
            _KindTile(
              category: c,
              selected: c == selected,
              artSize: artSize,
              onTap: () => onSelected(c),
            ),
        ],
      );
}

class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.category,
    required this.selected,
    required this.artSize,
    required this.onTap,
  });

  final ApplianceCategory category;
  final bool selected;
  final double artSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? context.appPrimary : context.appBorderSubtle;
    return Semantics(
      key: Key('kind-${category.value}'),
      button: true,
      selected: selected,
      label: category.label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          // 폭은 이름에 맞춘다 — '전자레인지'·'공기청정기'가 글자 중간에서 줄이 바뀌지 않게(10/24 골든 확인).
          constraints: BoxConstraints(minHeight: 48, minWidth: artSize + AppSpace.xl * 2),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm, vertical: AppSpace.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent, width: selected ? 2.5 : 1),
            color: selected ? context.appOverlayFaint : null,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ApplianceArtwork(
                    category: category,
                    size: artSize,
                    color: selected ? context.appPrimary : null,
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    category.label,
                    textAlign: TextAlign.center,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: AppFont.caption,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? context.appPrimary
                          : context.appOnSurfaceSoft,
                    ),
                  ),
                ],
              ),
              if (selected)
                Positioned(
                  top: -AppSpace.xs,
                  right: -AppSpace.xs,
                  child: Icon(Icons.check_circle,
                      key: Key('kind-selected-${category.value}'),
                      size: 20,
                      color: context.appPrimary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
