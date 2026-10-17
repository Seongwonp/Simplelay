import 'package:flutter/material.dart';

/// 개념당 아이콘 하나(UI 개편안 §5). 같은 '루틴'에 아이콘 셋을 쓰던 것(감사 10/17)을 막는다.
///
/// 선형(outlined·rounded) 한 세트만 쓴다. 출처(누가 했나)는 손·루틴·반복·마이크.
class AppIcons {
  AppIcons._();

  /// 루틴 — 탭·목록·홈 타일·기록 출처가 모두 이것.
  static const routine = Icons.playlist_play_rounded;
  static const routineSelected = Icons.playlist_play_rounded;

  /// 자동으로 하기(조건이 되면 저절로) — 반복.
  static const auto = Icons.autorenew_rounded;

  /// 직접 누름 — 손.
  static const manual = Icons.pan_tool_alt_outlined;

  /// 말로 하기 — 마이크.
  static const voice = Icons.mic_none_rounded;

  /// 정해진 시각 — 시계(오늘 예정).
  static const schedule = Icons.schedule_rounded;

  /// 실행 중(정지 줄 왼쪽). 자동과 섞이지 않게 반복 화살표를 쓰지 않는다.
  static const running = Icons.timelapse_rounded;

  /// 출처 문자열('직접'·'루틴'·'자동'·'음성') → 아이콘.
  static IconData source(String source) => switch (source) {
        '자동' => auto,
        '루틴' => routine,
        '음성' => voice,
        _ => manual,
      };
}
