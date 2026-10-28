/// 글자 5단계와 간격 7단계로 제한한 폰 디자인 토큰.
/// 화면 코드는 숫자 리터럴 대신 이 토큰을 사용하며 글자는 16 미만으로 두지 않는다.
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

/// 라이트 테마의 단일 카드 그림자. 다크 테마는 테두리를 사용한다.
class AppElevation {
  AppElevation._();

  static const double card = 1;
}

/// 글자 배율을 따르되 [maxScale]에서 제한하는 아이콘 크기.
double textScaledIcon(BuildContext context, double base, {double maxScale = 1.6}) =>
    base * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, maxScale);
