/// 키오스크 화면 전환 상태 — kiosk_screen.dart와 top_progress_bar.dart가 공유.
///
/// UI 확정(2026-09-30) §3의 네 상태와의 대응: 평소 = [idle], 다가오면 =
/// [suggestion], 동작 중 = [executing](누르는 중)·[done](결과)·[hold](누른 뒤
/// 정지 버튼 위 대기·보관), 내 가전 = [manual].
enum KioskPhase { idle, suggestion, executing, done, manual, hold }
