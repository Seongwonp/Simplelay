import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import 'room_sleep.dart';

/// 키오스크 UI를 **고정 설계 캔버스(800x480)** 위에 그리고, 실제 화면이 그보다 크면
/// 캔버스를 통째로 비율 유지 확대해 채운다.
///
/// 왜 "더 많이"가 아니라 "더 크게"인가:
/// 15.8형 패널은 제품 사양표상 1920x1080이다(docs/하드웨어-연결-설계.md §0-1).
/// PPI가 7인치(133)와 15.8형(약 139.5)이 비슷하다. 즉 글씨가
/// 작아 보이는 게 아니라 **화면만 넓어져 콘텐츠가 가운데 작은 섬처럼 남는다.** 이때
/// 빈 공간에 정보를 더 채우는 선택지도 있지만, 우리 대상은 고령·저시력 사용자다 —
/// 정보를 늘리는 건 우리가 없애겠다던 복잡함을 되살리는 자기부정이다. 그래서 남는
/// 공간은 **글씨·버튼·터치타깃을 함께 키우는 데** 쓴다(접근성 향상).
///
/// 스케일 방식의 부수 효과(의도된 것):
/// - 800x480에서 튜닝한 레이아웃과 **오버플로 보장이 그대로 유지**된다. 해상도마다
///   레이아웃을 다시 검증할 필요가 없다(큰 글씨 모드 상한 1.22배도 그대로 유효).
/// - 터치 좌표는 Flutter가 변환을 통과시켜 처리하므로 히트테스트가 어긋나지 않는다.
/// - 화면비가 다르면(5:3 vs 16:9) 양옆에 얇은 여백이 남는다. 1920x1080 기준 한쪽 60px
///   정도이고 배경색으로 채워 베젤과 이어져 보이므로 시연에서 문제되지 않는다.
///
/// 자식에게는 MediaQuery 크기도 설계 캔버스로 알려준다 — 화면 크기에 따라 분기하는
/// 코드가 나중에 생겨도 캔버스 안에서는 항상 같은 세계를 보게 하기 위해서다.
///
/// **가장자리 안전 여백(2026-09-30 실기기).** 플랫폼 창 관리자는 화면 가장자리에서
/// 시작한 터치를 시스템 제스처로 가져간다 — 1920x1080에서 (1900, 1051)을 누르자
/// 아래에서 위로 쓸어 올리기로 읽혀 앱이 닫혔다. 그래서 화면이 설계 캔버스보다
/// 충분히 크면 네 가장자리에 [edgeInset]만큼 아무것도 두지 않고 그 안쪽에만
/// 캔버스를 확대한다. 화면마다 여백을 따로 챙기지 않아도 **누르는 자리 전부가**
/// 구조적으로 가장자리를 피한다(1920x1080에서 배율 2.05, 좌우 140·위아래 48px).
/// 800x480 그대로인 화면(옛 7인치·골든)은 여백 둘 자리가 없어 종전과 같다.
///
/// **조용한 시간 어둡게(평가 15차 10/18, 접근성 감사 10/18).** [dim]이면 **바탕만** 어둡게 한다 — 패널 전체(가장자리 여백까지)의
/// 바탕을 [quietBg]로 칠하고, 글자 위에 반투명 막을 얹지 않는다(막을 덮으면 날짜·'메뉴'·건너뛰기 글자 대비가 2.5~3:1로
/// 떨어졌다). 글자 밝기는 처음 화면이 대비 4.5:1 하한을 지키며 낮춘다([kQuietTextOpacity]).
class KioskCanvas extends StatelessWidget {
  const KioskCanvas({super.key, required this.child, this.dim = false, this.scrim = false, this.blackout = false});

  /// 자리 비움 화면 쉬기 — 가장자리 여백까지 같은 회색(10/26 실패널: 안쪽만 어둡고 바깥 띠가 밝게 남아 고장처럼 보였다).
  final bool blackout;

  /// 화면 안에 창(메뉴·설정·확인 창)이 떠 있다 — 가장자리 여백 띠도 창의 막과 같이 어둡게 한다(실패널 10/24: 막이 캔버스
  /// 안쪽만 덮어 가장자리 띠가 밝게 남았다). 창들의 막과 같은 짙기([scrimAlpha]).
  final bool scrim;

  /// 화면 안 창들의 막 짙기(검정 0.6 — idle_top·manual_view·help_guide·connection_status와 같은 값).
  static const double scrimAlpha = 0.6;

  /// 조용한 시간이라 패널 전체를 어둡게 하나(kiosk_screen의 판정 — 처음 화면에서만).
  final bool dim;

  /// 바탕을 어둡게 하는 짙기 — 평소 바탕 위에 이만큼 검정을 섞는다. 값은 추측이다(실패널에서 밤에 1~2 m로 보고 고친다).
  static const double dimAlpha = 0.5;

  /// 조용한 시간의 바탕(불투명) — 평소 바탕에 검정을 [dimAlpha]만큼 섞은 색. 고대비(검정 바탕)면 그대로 검정.
  static Color get quietBg => Color.alphaBlend(Colors.black.withValues(alpha: dimAlpha), KioskColors.bg);

  /// 모든 키오스크 화면이 전제하는 설계 해상도.
  static const Size design = Size(800, 480);

  /// 실제 출력 기준 가장자리 여백(논리 px). 실측 근거는 한 번의 오동작뿐이라
  /// 넉넉히 잡은 값이다 — 추측/측정 필요.
  static const double edgeInset = 48;

  /// 이 화면 크기에서 여백을 두는가 — 여백을 빼고도 설계 캔버스 이상이 남을 때만.
  static bool insetsFor(Size screen) =>
      screen.width >= design.width + 2 * edgeInset &&
      screen.height >= design.height + 2 * edgeInset;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final inset = insetsFor(media.size) ? edgeInset : 0.0;
    // 바탕은 따로 선 칸(뒤) — 조용한 시간이 켜지고 꺼져도 앞의 화면 나무는 그대로 남는다(바탕 칸만 바뀐다).
    return Stack(
      fit: StackFit.expand,
      children: [
        // 조용한 시간이면 패널 전체 바탕(가장자리 여백까지)을 어둡게 — 글자 위 막이 아니다.
        ColoredBox(
          key: dim ? const ValueKey('kiosk-panel-dim') : null,
          color: blackout
              ? KioskRoomSleep.sleepColor
              : scrim
              ? Color.alphaBlend(Colors.black.withValues(alpha: scrimAlpha), dim ? quietBg : KioskColors.bg)
              : (dim ? quietBg : KioskColors.bg),
        ),
        // SizedBox.expand로 **꽉 찬 제약**을 줘야 FittedBox가 확대한다.
        // Center처럼 느슨한 제약을 주면 FittedBox가 자식 크기(800x480)로
        // 쪼그라들어 배율이 1.0이 된다 -- 화면만 커지고 UI는 그대로인 함정.
        Padding(
          padding: EdgeInsets.all(inset),
          child: SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.contain,
              child: MediaQuery(
                // 캔버스 안은 언제나 800x480 세계. 실제 화면이 정확히 그 크기면
                // 배율 1.0이라 렌더 결과가 픽셀 단위로 동일하다(기존 골든 유지).
                data: media.copyWith(
                  size: design,
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                ),
                child: SizedBox(
                  width: design.width,
                  height: design.height,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
