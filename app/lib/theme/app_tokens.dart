/// 폰 디자인 토큰 — 글자 5단계와 간격 7단계(UI 개편안 2026-10-17 §5).
///
/// 화면 코드는 글자 크기·간격을 **숫자로 쓰지 않고** 이 이름으로만 쓴다.
/// `test/theme/design_tokens_test.dart`가 소스의 숫자 리터럴을 막는다 — 토큰이
/// 있어도 코드가 따르지 않아 글자 15종·간격 14종이 됐던 것(감사 10/17)을 되풀이하지 않게.
///
/// 16 미만 글자는 없다. 주 사용자가 고령자라 보조 글씨도 16이다.
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
