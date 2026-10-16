import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';
import 'status_band.dart';

/// 실행 계열 화면(실행·정지 대기·정지 미확인)의 공통 틀(2026-10-16 디자인 규격 §1-1·§1-2).
///
/// ```
/// ┌ 상태 띠(같은 자리·같은 높이) ───────────────────────────────┐
/// │ [상태 아이콘] 상태 제목        │ 설명 그림(버튼판)            │
/// │ 할 일·설명(넘치면 스크롤)      │                              │
/// │                                │ ┌ 정지(같은 자리·크기) ┐     │
/// └────────────────────────────────┴─┴──────────────────────┴─────┘
/// ```
/// 정지 단추는 화면 오른쪽 아래에 **세 화면 모두 같은 자리·같은 크기·같은 아이콘·같은 테두리**로 고정된다 —
/// 오른쪽·아래에 붙여 재므로 위 띠(비상 버튼 띠 포함)가 늘어나도 자리가 바뀌지 않는다. 대기·제안·결과·설정
/// 화면에는 이 틀을 쓰지 않는다(정지 단추가 없다).
class KioskRunFrame extends StatelessWidget {
  const KioskRunFrame({
    super.key,
    required this.band,
    required this.header,
    required this.body,
    this.picture,
    required this.stop,
  });

  final KioskStatusBand band;

  /// 상태 영역 — 왼쪽 위 같은 기준선([KioskStatusHeader]).
  final Widget header;

  /// 상태 영역 아래 왼쪽 칸(할 일·설명). 남은 높이를 다 쓴다 — 넘치면 안에서 스크롤한다.
  final Widget body;

  /// 오른쪽 위 설명 그림(버튼판). 없으면 빈자리.
  final Widget? picture;

  /// 정지 단추([KioskStopButton]).
  final Widget stop;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: KioskColors.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            band,
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(KioskSizes.runLeft, KioskSizes.runTop,
                    KioskSizes.stopRight, KioskSizes.stopBottom),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          header,
                          const SizedBox(height: 10),
                          Expanded(child: body),
                        ],
                      ),
                    ),
                    const SizedBox(width: KioskSizes.stopGap),
                    SizedBox(
                      width: KioskSizes.stopWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: picture ?? const SizedBox.shrink()),
                          const SizedBox(height: 12),
                          stop,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

/// 상태 영역 한 줄 — 상태 아이콘 + 상태 제목(§1-2). 보냄·응답·확인·확인 불가가 **같은 자리에서** 갈아 끼워진다.
/// 제목 글자는 흰색이다 — 주의·실패는 아이콘 색과 위 띠가 말한다(앰버 제목·앰버 지시문·빨강 단추가 서로 다투지 않게).
class KioskStatusHeader extends StatelessWidget {
  const KioskStatusHeader({
    super.key,
    required this.icon,
    required this.title,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final String title;
  final Color iconColor;

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey('status-header'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: KioskSizes.statusIcon, color: iconColor),
          const SizedBox(width: 12),
          Flexible(
            child: Padding(
              // 아이콘(48)과 제목 첫 줄의 가운데를 맞춘다.
              padding: const EdgeInsets.only(top: 3),
              child: KioskText(
                title,
                style: const TextStyle(
                  fontSize: KioskType.status,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      );
}

/// 정지 단추 — 실행·정지 대기·정지 미확인 화면에서 **하나의 모양**(§1-1): 짙은 빨강 채움 + 흰 테두리 +
/// 같은 아이콘(■) + 같은 글자 크기. 이름만 상황별('정지' / '다시 정지 시도'). 이름이 길어져도 단추 크기는
/// 그대로이고 글자가 들어가도록만 줄어든다.
class KioskStopButton extends StatelessWidget {
  const KioskStopButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.buttonKey,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback onPressed;

  /// 화면별 단추 키(기존 시험이 쓰는 'hold-stop' 등).
  final Key? buttonKey;

  /// 화면 읽기 문장. 없으면 [label].
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('kiosk-stop-area'),
        width: KioskSizes.stopWidth,
        height: KioskSizes.stopHeight,
        child: Semantics(
          button: true,
          label: semanticsLabel ?? label,
          excludeSemantics: true,
          child: ElevatedButton(
            key: buttonKey,
            onPressed: onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: KioskColors.stop,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                // 색을 빼도 다른 단추와 구분되게 — 두꺼운 흰 테두리(세 화면 같은 두께).
                side: const BorderSide(
                    color: Colors.white, width: KioskSizes.stopBorder),
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.stop, size: KioskSizes.stopIcon),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: KioskType.status, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 설명 그림(버튼판, §1-6) — 실행·정지 대기 화면이 같은 모양으로 그린다.
///
/// 누를 수 있는 단추로 보이지 않게: 카드 테두리 없음, 어두운 평면, 칸 테두리 없음, 글자 50% 회색.
/// **지금 누르는(또는 작은 팔이 기다리는) 칸만** 앰버로 채운다. 실제 조작 단추(수동 조작)는 밝은 면·선명한
/// 경계·밝은 글자라 서로 다르게 보인다. 스크린리더에는 왼쪽 안내가 같은 말을 하므로 읽지 않는다.
class KioskPanelPicture extends StatelessWidget {
  const KioskPanelPicture({
    super.key,
    required this.appliance,
    required this.caption,
    this.current,
    this.caution = false,
    this.captionKey,
  });

  /// 대상 가전. 모르거나 버튼판이 없으면 '조작판 그림이 없어요'.
  final ApplianceMap? appliance;
  final String caption;

  /// 앰버로 채울 칸(지금 누르는 버튼·작은 팔이 기다리는 버튼). 없으면 채운 칸이 없다.
  final ApplianceButton? current;

  /// 자리를 맞춰 다시 누르는 중 — 채움을 주의색으로.
  final bool caution;

  final Key? captionKey;

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    return ExcludeSemantics(
      child: Container(
        decoration: BoxDecoration(
          color: KioskColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: a == null || a.isThinq || a.buttons.isEmpty
            ? const Center(
                child: Text(
                  '조작판 그림이 없어요',
                  style: TextStyle(fontSize: KioskType.body, color: KioskColors.panelText),
                ),
              )
            // 자리가 좁아지면(큰 글씨) 안내 글부터, 더 좁으면 그림도 접는다 — 정지 단추가 먼저다.
            : LayoutBuilder(builder: (context, outer) {
                if (outer.maxHeight < 48) return const SizedBox.expand();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (outer.maxHeight >= 110) ...[
                      KioskText(
                        caption,
                        textKey: captionKey,
                        // 큰 글씨에서 두 줄로는 잘렸다(2026-10-16 골든) — 세 줄까지.
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: KioskType.caption, color: KioskColors.muted),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Expanded(
                      child: Column(
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
                      ),
                    ),
                  ],
                );
              }),
      ),
    );
  }

  Widget _cell(ApplianceButton? button) {
    if (button == null) return const SizedBox.shrink();
    final on = current != null && button.id == current!.id;
    final fill = caution ? KioskColors.warning : KioskColors.primary;
    return DecoratedBox(
      key: on ? const ValueKey('panel-current') : null,
      decoration: BoxDecoration(
        color: on ? fill : KioskColors.bg,
        borderRadius: BorderRadius.circular(8),
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
                fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                color: on ? KioskColors.onAccent : KioskColors.panelText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
