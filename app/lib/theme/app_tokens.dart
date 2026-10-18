/// 폰 디자인 토큰 — 글자 5단계와 간격 7단계(UI 개편안 2026-10-17 §5).
///
/// 화면 코드는 글자 크기·간격을 **숫자로 쓰지 않고** 이 이름으로만 쓴다.
/// `test/theme/design_tokens_test.dart`가 소스의 숫자 리터럴을 막는다 — 토큰이
/// 있어도 코드가 따르지 않아 글자 15종·간격 14종이 됐던 것(감사 10/17)을 되풀이하지 않게.
///
/// 16 미만 글자는 없다. 주 사용자가 고령자라 보조 글씨도 16이다.
library;

import 'package:flutter/widgets.dart';

class AppFont {
  AppFont._();

  /// 크게 보이는 숫자(다음 실행 시각 등).
  static const double number = 32;

  /// 탭 제목('우리 집'·'루틴'·'기록'·'설정').
  static const double tabTitle = 24;

  /// 카드 제목·하위 화면 제목.
  static const double cardTitle = 20;

  /// 본문.
  static const double body = 18;

  /// 보조 설명·배지. 이보다 작은 글자는 쓰지 않는다.
  static const double caption = 16;

  static const List<double> all = [number, tabTitle, cardTitle, body, caption];
}

/// 간격은 4의 배수 일곱 단계만 쓴다.
class AppSpace {
  AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  static const List<double> all = [xs, sm, md, lg, xl, xxl, xxxl];
}

/// 카드 그림자 한 단계(라이트). 화면마다 높이를 따로 주지 않는다 — 흰 카드가 줄지어 뜬 인상이
/// 그림자가 짙을수록 커졌다(평가 3차 10/18). 다크는 그림자 대신 테두리(테마).
class AppElevation {
  AppElevation._();

  static const double card = 1;
}

/// 글자 배율을 따라 커지는 아이콘 크기(평가 15차 10/18: 큰 글씨에서 글자만 커지고 목록 아이콘은 그대로 작았다).
/// 너무 커져 글 칸을 밀지 않게 [maxScale]배에서 멈춘다.
double textScaledIcon(BuildContext context, double base, {double maxScale = 1.6}) =>
    base * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, maxScale);
