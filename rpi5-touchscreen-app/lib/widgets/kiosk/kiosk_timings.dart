/// 화면 전환·카운트다운 타이밍의 단일 출처.
///
/// kiosk_screen(전환 로직)과 suggestion_view·done_view(진행바 표시)가 같은
/// 값을 봐야 바와 실제 전환이 어긋나지 않는다 — 이전에는 세 파일이 각자
/// 하드코딩해서 한쪽만 바꾸면 조용히 어긋났다.
class KioskTimings {
  /// 제안 화면 자동 닫힘 카운트다운
  static const int countdownSeconds = 10;

  /// 완료 화면 → 대기 화면 자동 복귀
  static const Duration doneReturn = Duration(seconds: 3);

  /// 서버가 total_steps를 안 줄 때(UART 집계 모드)만 쓰는 폴백 채움 시간
  static const Duration execBarFill = Duration(seconds: 9);
}
