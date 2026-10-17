import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 지금 화면에 보이는 하단 탭 인덱스.
///
/// 탭은 go_router의 StatefulShellBranch라 **화면을 떠나도 위젯이 살아 있다**
/// (상태 보존이 목적). 그래서 `dispose()`나 `deactivate()`로는 "내 화면이
/// 가려졌다"를 알 수 없다. 마이크처럼 보이지 않을 때 반드시 멈춰야 하는
/// 자원을 쥔 화면은 이 값을 보고 스스로 정리한다.
///
/// 탭 전환은 하단바 탭 말고 `context.go`로도 일어나므로(실행 시작 시 상태
/// 화면으로 이동 등), 이벤트가 아니라 shell의 현재 인덱스를 동기화한다.
final currentTabIndexProvider = StateProvider<int>((ref) => 0);

/// 하단 탭 순서(main.dart의 StatefulShellBranch 순서와 일치, UI 확정 §2).
const int homeTabIndex = 0;
const int routinesTabIndex = 1;
const int historyTabIndex = 2;
const int settingsTabIndex = 3;

// 개발자 도구는 탭이 아니다(2026-10-18) — 설정 맨 아래 항목에서 '/dev'로 연다.

/// 음성 화면이 사는 탭. 2026-09-30 개편으로 음성은 탭이 아니라 **홈 위에
/// 얹는 화면**(`/voice`)이 됐다 -- 다른 탭으로 가면 마이크를 놓는다.
const int voiceTabIndex = homeTabIndex;
