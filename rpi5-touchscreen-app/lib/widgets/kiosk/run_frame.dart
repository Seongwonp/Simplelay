import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';
import 'panel_picture.dart';
import 'status_band.dart';

export 'panel_picture.dart';

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
    this.oneColumn = false,
  });

  /// 보통 글씨에서도 큰 글씨처럼 한 열(평가 10차 10/18) — 설명 그림이 없는 LG 가전 보내는 중 화면은 2열이면 글이
  /// 왼쪽으로 쏠리고 오른쪽 위가 비었다. 정지 단추는 오른쪽·아래에 붙여 재므로 자리·크기가 같다.
  final bool oneColumn;

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
  Widget build(BuildContext context) {
    const padding = EdgeInsets.fromLTRB(KioskSizes.runLeft, KioskSizes.runTop,
        KioskSizes.stopRight, KioskSizes.stopBottom);
    // 큰 글자(§1-8): 가로 2열 → 세로 1열. 상태 영역·할 일이 화면 폭을 다 쓰고(글은 여러 줄로), 버튼판 그림은
    // 정지 단추 왼쪽 한 줄로 줄인다(상태가 먼저). 정지 단추는 오른쪽·아래에 붙여 재므로 보통 글씨와 같은 자리·크기.
    if (oneColumn || KioskLayout.isLarge(context)) {
      final picture = this.picture;
      return ColoredBox(
        key: const ValueKey('run-frame-one-column'),
        color: KioskColors.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            band,
            Expanded(
              child: Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 10),
                    Expanded(child: body),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: KioskSizes.stopHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: picture is KioskPanelPicture
                                ? picture.compactCopy()
                                : picture ?? const SizedBox.shrink(),
                          ),
                          const SizedBox(width: KioskSizes.stopGap),
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
    return ColoredBox(
      color: KioskColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          band,
          Expanded(
            child: Padding(
              padding: padding,
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
  final VoidCallback? onPressed;

  /// 화면별 단추 키(기존 시험이 쓰는 'hold-stop' 등).
  final Key? buttonKey;

  /// 화면 읽기 문장. 없으면 [label].
  final String? semanticsLabel;

  /// 단추 안쪽 좌우 여백(흰 테두리 3 안쪽으로 글자까지 약 15 — 1920x1080에서 약 31px).
  static const double _labelInset = 18;
  static const double _labelWidth = KioskSizes.stopWidth - 2 * _labelInset;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('kiosk-stop-area'),
        width: KioskSizes.stopWidth,
        height: KioskSizes.stopHeight,
        child: Semantics(
          button: true,
          enabled: onPressed != null,
          label: semanticsLabel ?? label,
          excludeSemantics: true,
          child: ElevatedButton(
            key: buttonKey,
            onPressed: onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: KioskColors.stop,
              foregroundColor: Colors.white,
              disabledBackgroundColor: KioskColors.surface2,
              disabledForegroundColor: KioskColors.muted,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: _labelInset),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                // 색을 빼도 다른 단추와 구분되게 — 두꺼운 흰 테두리(세 화면 같은 두께).
                // 못 누를 때는 흐린 테두리 — 흰 테두리가 남으면 누를 수 있는 것처럼 보였다(UI 평가 4차 10/17).
                side: BorderSide(
                    color: onPressed == null ? KioskColors.border : Colors.white,
                    width: KioskSizes.stopBorder),
              ),
            ),
            // 글자가 한 줄에 다 들어가지 않는 이름('다시 정지 시도')은 줄이지 않고 어절에서 두 줄로 나눈다 —
            // 예전에는 한 줄로 줄여 넣어 글자가 작아지고 오른쪽 테두리에 붙었다(2026-10-16 골든). 단추 크기·아이콘
            // 크기·글자 크기는 그대로다. 큰 글씨에서 두 줄도 높이를 넘으면 그때만 전체를 조금 줄인다.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: _labelWidth,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.stop, size: KioskSizes.stopIcon),
                    const SizedBox(width: 12),
                    Flexible(
                      child: KioskText(
                        label,
                        textAlign: TextAlign.center,
                        textWidthBasis: TextWidthBasis.longestLine,
                        style: const TextStyle(
                            fontSize: KioskType.status,
                            fontWeight: FontWeight.w800,
                            height: 1.1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
