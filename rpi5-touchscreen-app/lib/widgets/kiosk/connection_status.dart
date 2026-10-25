import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_scroll_area.dart';
import 'kiosk_text.dart';

/// 평소 화면 오른쪽 위의 연결 아이콘 세 개(와이파이·누름 장치·콘센트).
///
/// 정상이면 회색 아이콘뿐이다. 문제가 생기면 그 아이콘이 노란색이 되고 "!" 배지가
/// 붙는다. 누르면 [KioskConnectionModal]이 무엇이 안 되는지와 해결 방법을 말한다.
/// 설치 안 됨(플러그가 아직 없음)은 문제가 아니라 아이콘 자체를 그리지 않는다(2026-10-14).
class KioskConnectionIcons extends StatelessWidget {
  const KioskConnectionIcons({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<ConnectionItem> items;
  final ValueChanged<ConnectionItem> onOpen;

  /// 설치되지 않은 플러그(콘센트 모듈)는 그리지 않는다(2026-10-14) — 줄 그은 플러그가 늘 떠 있어
  /// 고장처럼 보였다. 없는 장치는 문제가 아니다.
  static bool _shown(ConnectionItem item) =>
      !(item.id == 'plug' && item.state == 'not_installed');

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items.where(_shown))
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

/// 위쪽 아이콘 아래 짧은 이름(UI 평가 3차 10/17 — 1~2 m에서 로봇·플러그 아이콘만으로는 뜻을 몰랐다).
/// 66px 칸 안에 한 줄로 들어가는 말만 쓴다. 평소 화면의 설정·제안 쉬기 단추도 같은 모양을 쓴다.
class KioskTopIconLabel extends StatelessWidget {
  const KioskTopIconLabel(this.text, {super.key, Color? color}) : _color = color;

  final String text;
  final Color? _color;
  Color get color => _color ?? KioskColors.muted;

  @override
  Widget build(BuildContext context) => Text(text,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(fontSize: KioskType.caption, height: 1.15, color: color));
}

String _shortName(String id) => switch (id) {
      'network' => '와이파이',
      'press' => '누름 장치',
      'plug' => '콘센트',
      _ => '연결',
    };

String _name(String id) => switch (id) {
      'network' => '와이파이',
      'press' => '누름 장치',
      'plug' => '콘센트',
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
          ? '${_name(item.id)}. ${item.title}. 자세히 보기'
          : '${_name(item.id)}: ${item.title}',
      child: ExcludeSemantics(
        child: InkWell(
          key: ValueKey('conn-${item.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 74, // 큰 글씨 이름('와이파이' 17px)이 옆과 붙지 않게(UI 평가 3차 10/17)
            height: 64,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(connectionIcon(item), size: 28, color: color),
                  // 66x64 칸(평소 화면 위 줄 64, 10/7) 안에 아이콘과 한 줄로 들어가야 한다 — 33px이면 두 줄로
                  // 꺾여 아래로 넘친다(d965888 회귀). 모르면 이름 자리에 '모름'.
                  if (item.state != 'unknown')
                    KioskTopIconLabel(_shortName(item.id), color: color)
                  else
                    Text('확인 못 함',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                            fontSize: KioskType.body, height: 1.2, color: KioskColors.muted)),
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
                      decoration: BoxDecoration(
                        color: KioskColors.warning,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '!',
                        style: TextStyle(
                          fontSize: KioskType.caption,
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

/// 연결 문제 모달 — 제목, 무엇이 안 되는지, 해결 방법, "다시 확인하기/닫기".
///
/// "다시 연결해 보기"(2차 평가 10/18 — 할 일을 마친 사람이 누를 말)는 본체에 연결 상태를 **다시 묻는다**. 서버에 재연결 명령은
/// 없어서, 고쳐진 뒤 확인하는 단추다(예전 이름 '다시 연결하기'는 다시 연결해 주는 줄 알았다, 2026-10-15).
///
/// 글이 길면 안에서 스크롤하고 막대가 보인다(B4 — 예전에는 잘린 채 끝나 보였다).
/// 예전의 'SimpleLay 본체: …' 풀이 줄은 뺐다(쉬운 말 10/17) — 이름이 '본체'·'본체 화면'으로 짧아져 풀어 쓸 말이 없다.

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
    // 큰 글씨는 캔버스를 거의 다 쓰고 줄 간격·여백을 줄인다 — 셋째 할 일이 스크롤 아래였다(UI 평가 3차 10/17).
    final large = KioskLayout.isLarge(context);
    final bodyHeight = large ? 1.22 : 1.35;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          // 넓혀서 스크롤 없이 다 보이게(UI 평가 10/17 — 셋째 항목이 스크롤 아래였다). 캔버스 800 안 양옆 40.
          width: large ? 784 : 720,
          margin: EdgeInsets.symmetric(vertical: large ? 4 : 12),
          padding: large
              ? const EdgeInsets.fromLTRB(20, 12, 16, 10)
              : const EdgeInsets.fromLTRB(28, 20, 28, 16),
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
                      style: TextStyle(
                        fontSize: KioskType.status,
                        fontWeight: FontWeight.w700,
                        color: KioskColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: large ? 6 : 12),
              Flexible(
                child: KioskScrollArea(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 어절 단위 줄바꿈('주세/요.' 방지, UI 평가 10/17).
                      if (item.message.isNotEmpty)
                        KioskText(
                          kioskLine(item.message),
                          style: TextStyle(
                            fontSize: large ? 20 : 22,
                            height: bodyHeight,
                            color: KioskColors.muted,
                          ),
                        ),
                      // 할 일은 번호 붙은 단계(2차 평가 10/18) — 위에서부터 차례로 해 보면 된다.
                      for (final (i, fix) in item.fixes.indexed)
                        Padding(
                          padding: EdgeInsets.only(top: large ? 4 : 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                margin: const EdgeInsets.only(top: 2, right: KioskSpace.sm),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                    color: KioskColors.ink, shape: BoxShape.circle),
                                child: Text('${i + 1}',
                                    textScaler: TextScaler.noScaling,
                                    style: TextStyle(
                                        fontSize: KioskType.caption,
                                        height: 1,
                                        fontWeight: FontWeight.w800,
                                        color: KioskColors.onAccent)),
                              ),
                              Expanded(
                                child: KioskText(
                                  kioskLine(fix),
                                  style: TextStyle(
                                    fontSize: KioskType.body,
                                    height: bodyHeight,
                                    color: KioskColors.ink,
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
              SizedBox(height: large ? 8 : 14),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: ElevatedButton(
                      onPressed: checking ? null : onRecheck,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                        // 주 행동은 primary 청록 한 색(10/24 시각 QA). primary는 이제 골드가 아니라 문제 창에서도 같다.
                        backgroundColor: KioskColors.primary,
                        foregroundColor: KioskColors.onAccent,
                        disabledBackgroundColor: KioskColors.border,
                        disabledForegroundColor: KioskColors.muted,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        checking ? '연결하고 있어요' : '다시 연결해 보기',
                        style: const TextStyle(
                            fontSize: KioskType.body, fontWeight: FontWeight.w700),
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
                        foregroundColor: KioskColors.ink,
                        side: BorderSide(color: KioskColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('닫기',
                          style: TextStyle(
                              fontSize: KioskType.body, fontWeight: FontWeight.w500)),
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
