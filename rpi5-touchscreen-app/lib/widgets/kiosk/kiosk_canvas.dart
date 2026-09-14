import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

/// 키오스크 UI를 **고정 설계 캔버스(800x480)** 위에 그리고, 실제 화면이 그보다 크면
/// 캔버스를 통째로 비율 유지 확대해 채운다.
///
/// 왜 "더 많이"가 아니라 "더 크게"인가:
/// 15인치 패널을 1920x1080으로 가정하면(실제 해상도는 확인 필요 —
/// docs/하드웨어-연결-설계.md §0-1) PPI는 7인치(133)와 15인치(147)가 비슷하다. 즉 글씨가
/// 작아 보이는 게 아니라 **화면만 넓어져 콘텐츠가 가운데 작은 섬처럼 남는다.** 이때
/// 빈 공간에 정보를 더 채우는 선택지도 있지만, 우리 대상은 고령·저시력 사용자다 —
/// 정보를 늘리는 건 우리가 없애겠다던 복잡함을 되살리는 자기부정이다. 그래서 남는
/// 공간은 **글씨·버튼·터치타깃을 함께 키우는 데** 쓴다(접근성 향상).
///
/// 스케일 방식의 부수 효과(의도된 것):
/// - 800x480에서 튜닝한 레이아웃과 **오버플로 보장이 그대로 유지**된다. 해상도마다
///   레이아웃을 다시 검증할 필요가 없다(큰 글씨 모드 상한 1.22배도 그대로 유효).
/// - 터치 좌표는 Flutter가 변환을 통과시켜 처리하므로 히트테스트가 어긋나지 않는다.
/// - 화면비가 다르면(5:3 vs 16:9) 양옆에 얇은 여백이 남는다. 1920x1080(가정) 기준 한쪽 60px
///   정도이고 배경색으로 채워 베젤과 이어져 보이므로 시연에서 문제되지 않는다.
///
/// 자식에게는 MediaQuery 크기도 설계 캔버스로 알려준다 — 화면 크기에 따라 분기하는
/// 코드가 나중에 생겨도 캔버스 안에서는 항상 같은 세계를 보게 하기 위해서다.
class KioskCanvas extends StatelessWidget {
  const KioskCanvas({super.key, required this.child});

  /// 모든 키오스크 화면이 전제하는 설계 해상도.
  static const Size design = Size(800, 480);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ColoredBox(
      color: KioskColors.bg,
      // SizedBox.expand로 **꽉 찬 제약**을 줘야 FittedBox가 확대한다.
      // Center처럼 느슨한 제약을 주면 FittedBox가 자식 크기(800x480)로
      // 쪼그라들어 배율이 1.0이 된다 -- 화면만 커지고 UI는 그대로인 함정.
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
    );
  }
}
