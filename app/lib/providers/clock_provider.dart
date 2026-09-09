import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 지금 시각을 읽는 곳.
///
/// 화면이 `DateTime.now()`를 직접 부르면 **골든이 실행 시각에 따라 달라진다**
/// — 아침에 만든 골든이 저녁에 실패하고, 그러면 진짜 회귀와 시간 차이를
/// 구분할 수 없게 된다. 테스트가 고정할 수 있도록 한 겹 둔다.
///
/// 서버 쪽 `rpi.intent.clock`과 같은 이유의 장치다.
final nowProvider = Provider<DateTime Function()>((ref) => DateTime.now);
