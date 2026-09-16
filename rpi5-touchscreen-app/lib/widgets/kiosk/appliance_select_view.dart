import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';

/// 수동 조작 진입 시 가전 선택 — 키오스크는 특정 가전 전속이 아니라
/// 공간의 가전들을 다루는 허브다.
///
/// 이전에는 "제어 가전"이 설정 오버레이(점 3연타 진입) 안의 칩이었다.
/// 고령 사용자가 가전을 바꾸려면 숨은 설정을 찾아야 했고, 설정 화면에
/// 왜 전자레인지·인덕션이 떠 있는지 맥락도 없었다. 조작하려는 순간에
/// 묻는 것이 흐름상 자연스럽고(NN/g: 설정보다 과업 흐름 안에서),
/// 폰에서 추가한 가전도 서버 목록으로 함께 나타난다.
class KioskApplianceSelectView extends StatelessWidget {
  const KioskApplianceSelectView({
    super.key,
    required this.appliances,
    required this.lastUsedId,
    required this.onSelect,
    required this.onCancel,
  });

  final List<ApplianceMap> appliances;

  /// 지난번에 조작한 가전 — 카드에 "지난번" 배지로 표시해 재선택을 돕는다.
  final String? lastUsedId;
  final ValueChanged<ApplianceMap> onSelect;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 뒤로가기 — 수동 조작 화면과 같은 52px 히트박스 관례
                Semantics(
                  button: true,
                  label: '대기 화면으로 돌아가기',
                  child: InkWell(
                    onTap: onCancel,
                    borderRadius: BorderRadius.circular(10),
                    child: const SizedBox(
                      width: 52,
                      height: 52,
                      child: Icon(
                        Icons.arrow_back,
                        color: KioskColors.muted,
                        size: 26,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '어느 가전을 조작할까요?',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              // 0대는 정상 상태다(마지막 가전을 폰에서 삭제한 직후, B11) —
              // GridView는 crossAxisCount 0으로 죽으므로 먼저 가른다.
              child: appliances.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_home_outlined,
                              size: 44, color: KioskColors.muted),
                          SizedBox(height: 14),
                          Text(
                            '아직 조작할 가전이 없어요',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '휴대폰 앱에서 가전을 추가하면 여기에 나타나요',
                            style: TextStyle(
                                fontSize: 18, color: KioskColors.muted),
                          ),
                        ],
                      ),
                    )
                  : GridView.count(
                      crossAxisCount:
                          appliances.length <= 4 ? appliances.length : 4,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 1.1,
                      children: [
                        for (final appliance in appliances)
                          _ApplianceCard(
                            appliance: appliance,
                            isLastUsed: appliance.id == lastUsedId,
                            onTap: () => onSelect(appliance),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplianceCard extends StatelessWidget {
  const _ApplianceCard({
    required this.appliance,
    required this.isLastUsed,
    required this.onTap,
  });

  final ApplianceMap appliance;
  final bool isLastUsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${appliance.name} 조작하기'
          '${isLastUsed ? '. 지난번에 썼어요' : ''}',
      child: Material(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isLastUsed
                    ? KioskColors.primary.withValues(alpha: 0.55)
                    : KioskColors.border,
                width: isLastUsed ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(appliance.icon, size: 44, color: KioskColors.primary),
                const SizedBox(height: 12),
                Text(
                  appliance.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                if (isLastUsed) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: KioskColors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '지난번',
                      style: TextStyle(
                        fontSize: 13,
                        color: KioskColors.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
