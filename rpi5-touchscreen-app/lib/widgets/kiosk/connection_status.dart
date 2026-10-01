import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';

/// 평소 화면 오른쪽 위의 연결 아이콘 세 개(와이파이·누름 장치·플러그).
///
/// 정상이면 회색 아이콘뿐이다. 문제가 생기면 그 아이콘이 노란색이 되고 "!" 배지가
/// 붙는다. 누르면 [KioskConnectionModal]이 무엇이 안 되는지와 해결 방법을 말한다.
/// 설치 안 됨(플러그가 아직 없음)은 문제가 아니라 배지를 붙이지 않고 흐린 모양만
/// 바꾼다 — 누르면 설명은 열린다.
class KioskConnectionIcons extends StatelessWidget {
  const KioskConnectionIcons({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<ConnectionItem> items;
  final ValueChanged<ConnectionItem> onOpen;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _ConnectionIcon(item: item, onTap: () => onOpen(item)),
            ),
        ],
      );
}

/// 항목별 모양. 상태가 나쁘면 모양도 바뀐다(색만으로 말하지 않는다).
IconData connectionIcon(ConnectionItem item) => switch (item.id) {
      'network' => item.state == 'error' ? Icons.wifi_off : Icons.wifi,
      'press' => Icons.precision_manufacturing_outlined,
      'plug' => item.state == 'not_installed' || item.state == 'error'
          ? Icons.power_off_outlined
          : Icons.power_outlined,
      _ => Icons.link,
    };

String _name(String id) => switch (id) {
      'network' => '와이파이',
      'press' => '누름 장치',
      'plug' => '플러그',
      _ => '연결',
    };

class _ConnectionIcon extends StatelessWidget {
  const _ConnectionIcon({required this.item, required this.onTap});

  final ConnectionItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final warn = item.needsAttention;
    final color = warn
        ? KioskColors.warning
        : item.state == 'not_installed'
            ? KioskColors.muted.withValues(alpha: 0.5)
            : KioskColors.muted;
    return Semantics(
      button: true,
      label: warn
          ? '${_name(item.id)} 확인이 필요해요. ${item.title}. 자세히 보기'
          : '${_name(item.id)}: ${item.title}',
      child: ExcludeSemantics(
        child: InkWell(
          key: ValueKey('conn-${item.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 66,
            height: 80,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(connectionIcon(item), size: 28, color: color),
                  if (item.state == 'unknown') const Text('모름', style: TextStyle(fontSize: 33, color: KioskColors.muted)),
                ]),
                if (warn)
                  Positioned(
                    top: 4,
                    right: 6,
                    child: Container(
                      key: ValueKey('conn-badge-${item.id}'),
                      width: 18,
                      height: 18,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: KioskColors.warning,
                        shape: BoxShape.circle,
                      ),
                      child: const Text(
                        '!',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          color: KioskColors.onAccent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 연결 문제 모달 — 제목, 무엇이 안 되는지, 해결 방법, "다시 연결하기/닫기".
///
/// "다시 연결하기"는 허브에 연결 상태를 **다시 묻는다**. 서버에 재연결 명령은
/// 없어서, 고쳐진 뒤 확인하는 단추다(해결 방법의 "잠시 뒤 다시 연결하기"와 같은 뜻).
class KioskConnectionModal extends StatelessWidget {
  const KioskConnectionModal({
    super.key,
    required this.item,
    required this.checking,
    required this.onRecheck,
    required this.onClose,
  });

  final ConnectionItem item;
  final bool checking;
  final VoidCallback onRecheck;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final warn = item.needsAttention;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          width: 520,
          constraints: const BoxConstraints(maxHeight: 420),
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          decoration: BoxDecoration(
            color: KioskColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: KioskColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(connectionIcon(item),
                      size: 32,
                      color: warn ? KioskColors.warning : KioskColors.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.message.isNotEmpty)
                        Text(
                          item.message,
                          style: const TextStyle(
                            fontSize: 33,
                            height: 1.45,
                            color: KioskColors.muted,
                          ),
                        ),
                      for (final fix in item.fixes)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 9, right: 10),
                                child: Icon(Icons.circle,
                                    size: 7, color: Colors.white),
                              ),
                              Expanded(
                                child: Text(
                                  fix,
                                  style: const TextStyle(
                                    fontSize: 33,
                                    height: 1.4,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: ElevatedButton(
                      onPressed: checking ? null : onRecheck,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                        backgroundColor: KioskColors.primary,
                        foregroundColor: KioskColors.onAccent,
                        disabledBackgroundColor: KioskColors.border,
                        disabledForegroundColor: KioskColors.muted,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        checking ? '확인하고 있어요' : '다시 연결하기',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(
                      onPressed: onClose,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: KioskColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('닫기',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w500)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
