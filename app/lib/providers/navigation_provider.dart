import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 지금 화면에 보이는 하단 탭 인덱스.
///
/// 탭은 go_router의 StatefulShellBranch라 **화면을 떠나도 위젯이 살아 있다**
/// (상태 보존이 목적). 그래서 `dispose()`나 `deactivate()`로는 "내 화면이
/// 가려졌다"를 알 수 없다. 마이크처럼 보이지 않을 때 반드시 멈춰야 하는
/// 자원을 쥔 화면은 이 값을 보고 스스로 정리한다.
///
/// 탭 전환은 하단바 탭 말고 `context.go`로도 일어나므로(실행 시작 시 상태
/// 탭으로 이동 등), 이벤트가 아니라 shell의 현재 인덱스를 동기화한다.
final currentTabIndexProvider = StateProvider<int>((ref) => 0);

/// 하단 탭에서 음성 화면의 위치(main.dart의 StatefulShellBranch 순서와 일치).
const int voiceTabIndex = 1;
