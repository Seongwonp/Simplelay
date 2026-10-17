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

  /// 알려 드리기만(알림만 루틴) — 종. 가전을 움직이지 않는다는 것을 아이콘으로도 가른다(평가 4차 10/18).
  static const notify = Icons.notifications_none_rounded;

  /// 정해진 시각 — 시계(오늘 예정).
  static const schedule = Icons.schedule_rounded;

  /// 실행 중(정지 줄 왼쪽). 자동과 섞이지 않게 반복 화살표를 쓰지 않는다.
  static const running = Icons.timelapse_rounded;

  /// 조용한 시간(매일 시간대) — 달. 켜져 지금 그 시간이면 채운 달(평가 7차 10/18: 기능 하나 = 아이콘 하나).
  /// 키오스크도 같은 규칙으로 맞춘다 — 조용한 시간 = 달, 잠시 쉬기 = 일시정지.
  static const quietHours = Icons.bedtime_outlined;
  static const quietHoursActive = Icons.bedtime;

  /// 잠시 쉬기(몇 시간 묻지도 자동으로 하지도 않기) — 일시정지. 켜져 있으면 채운 것.
  /// 예전에는 방해 금지(⊖)와 달이 섞였다(평가 7차 10/18).
  static const pause = Icons.pause_circle_outline;
  static const pauseActive = Icons.pause_circle;

  /// 꺼 둔 규칙(자동으로 하기 '지금은 안 해요') — 스위치 꺼짐. 일시정지는 잠시 쉬기만 쓴다.
  static const off = Icons.toggle_off_outlined;

  /// 출처 문자열('직접'·'루틴'·'자동'·'음성') → 아이콘.
  static IconData source(String source) => switch (source) {
        '자동' => auto,
        '루틴' => routine,
        '음성' => voice,
        _ => manual,
      };
}
