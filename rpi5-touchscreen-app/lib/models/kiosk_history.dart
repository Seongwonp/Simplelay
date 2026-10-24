/// 키오스크 '기록' 탭(시안 B 10/24) — `GET /history` 한 건을 읽기 전용으로 보인다.
///
/// 결과 말은 폰 기록(`app/lib/screens/history_screen.dart`의 `historyBadgeOf`)과 같은 확인 수준 규칙을 따른다:
/// **'완료'는 실제 실행에서 상태를 다시 읽었거나(LG 가전) 누름·동작을 확인했을 때만**이다. 보고·접수만 받은 것,
/// 됐는지 모르는 것은 '확인 못 함'. 연습(모의)은 '연습'. 멈춘 것은 '멈춤'·'스스로 멈춤', 못 한 것은 '실패'.
/// 키오스크는 기록을 바꾸지 않는다(답하기·지우기는 폰).
library;

import 'action_name.dart';
import 'command_result.dart';
import 'kiosk_time.dart';

/// 결과 말의 색 갈래 — 화면이 색을 고른다(색만으로 말하지 않는다 — 말이 늘 함께 있다).
enum KioskHistoryTone { confirmed, attention, stopped, danger, neutral }

/// 기록 한 건.
class KioskHistoryEntry {
  const KioskHistoryEntry({
    required this.jobId,
    required this.finishedAt,
    required this.status,
    this.purpose,
    this.outcome,
    this.route = 'unknown',
    this.receipt = 'unknown',
    this.confirmation = 'unknown',
    this.executionMode = 'unknown',
    this.applianceId,
    this.applianceName,
    this.buttons = const [],
  });

  final String jobId;

  /// 본체 벽시계 시각(본체 시간대 표기를 떼고 그대로 — 폰 `hubWallClock`과 같은 규칙).
  final DateTime finishedAt;
  final String status;
  final String? purpose;
  final String? outcome;
  final String route;
  final String receipt;
  final String confirmation;
  final String executionMode;
  final String? applianceId;
  final String? applianceName;

  /// 누른 버튼 이름(순서대로). LG 가전 기록은 비어 있다.
  final List<String> buttons;

  /// 필수 필드(job_id·finished_at·status)가 없거나 이상하면 null — 그 한 건만 빼고 나머지는 보인다.
  static KioskHistoryEntry? fromJson(Map<String, dynamic> json) {
    final id = json['job_id'];
    final at = json['finished_at'];
    final status = json['status'];
    if (id is! String || at is! String || status is! String) return null;
    final DateTime when;
    try {
      when = hubWallClock(at);
    } catch (_) {
      return null;
    }
    String? str(String key) => json[key] is String ? json[key] as String : null;
    final raw = json['buttons'];
    return KioskHistoryEntry(
      jobId: id,
      finishedAt: when,
      status: status,
      purpose: str('purpose'),
      outcome: str('outcome'),
      route: str('route') ?? 'unknown',
      receipt: str('receipt') ?? 'unknown',
      confirmation: str('confirmation') ?? 'unknown',
      executionMode: str('execution_mode') ?? 'unknown',
      applianceId: str('appliance_id'),
      applianceName: str('appliance_name'),
      buttons: [
        if (raw is List)
          for (final b in raw)
            if (b is Map && b['button'] is String && (b['button'] as String).trim().isNotEmpty)
              (b['button'] as String).trim(),
      ],
    );
  }

  /// 자동 실행이 한 일인가(서버 목적 문장 머리 '자동 실행 · ').
  bool get automatic => (purpose ?? '').trim().startsWith(_autoPrefix);

  /// 무엇을 했나 — 목적 문장이 있으면 행동 이름, 없으면 누른 버튼(폰 기록 제목과 같은 꼴), 그것도 없으면 가전 이름.
  String title({String? currentName}) {
    final name = _plainName(applianceName ?? currentName);
    var p = (purpose ?? '').trim();
    if (p.startsWith(_autoPrefix)) p = p.substring(_autoPrefix.length).trim();
    if (executionMode == 'mock') p = _plain(p);
    if (p.isNotEmpty) {
      final routine = _routineTitle.firstMatch(p);
      if (routine != null) return routine.group(1)!;
      return actionName(p);
    }
    if (buttons.isNotEmpty) {
      final pressed = buttons.length == 1 ? '${buttons.single} 버튼 누르기' : '버튼 ${buttons.length}번 누르기';
      return name == null ? pressed : '$name $pressed';
    }
    if (route == 'thinq') return name == null ? '가전 설정 바꾸기' : '$name 설정 바꾸기';
    return name == null ? '버튼 누르기' : '$name 버튼 누르기';
  }

  /// 결과 한 단어와 색 갈래 — 폰 기록 배지와 같은 확인 수준 규칙(위 머리말).
  (String, KioskHistoryTone) get result {
    if (executionMode == 'mock') return ('연습', KioskHistoryTone.neutral);
    final kind = resultKindOf(outcome: outcome, status: status);
    switch (kind) {
      case ResultKind.stopped:
      case ResultKind.safetyStop:
        return (resultWord(kind), KioskHistoryTone.stopped);
      case ResultKind.failed:
        return (resultWord(kind), KioskHistoryTone.danger);
      case ResultKind.unconfirmed:
        return (resultWord(ResultKind.unconfirmed), KioskHistoryTone.attention);
      case ResultKind.success:
        break;
    }
    final confirmed = route == 'thinq'
        ? const {'state_confirmed', 'state_confirmed_unknown_before', 'already_at_target'}.contains(confirmation)
        : const {'operation_confirmed', 'press_confirmed'}.contains(confirmation);
    if (executionMode == 'real' && confirmed) return (resultWord(ResultKind.success), KioskHistoryTone.confirmed);
    // 보고·접수만 받았다 — 됐는지는 확인하지 못했다('완료'라고 하지 않는다).
    return (resultWord(ResultKind.unconfirmed), KioskHistoryTone.attention);
  }

  /// 시각 — 오늘이면 '오후 3:12', 아니면 '10월 23일 오후 3:12'.
  String whenLabel(DateTime now) {
    final t = clockTime(finishedAt.hour, finishedAt.minute);
    final sameDay = finishedAt.year == now.year && finishedAt.month == now.month && finishedAt.day == now.day;
    return sameDay ? t : '${finishedAt.month}월 ${finishedAt.day}일 $t';
  }

  static const _autoPrefix = '자동 실행 · ';
  static final _routineTitle = RegExp(r"^'(.+)' 루틴$");
  static final _mockMark = RegExp(r'\s*\((모의|연습)\)');

  static String _plain(String s) => s.replaceAll(_mockMark, '').trim();

  String? _plainName(String? raw) {
    final t = raw?.trim();
    if (t == null || t.isEmpty) return null;
    return executionMode == 'mock' ? _plain(t) : t;
  }
}

/// 본체가 보낸 시각을 본체 벽시계 그대로 읽는다(폰 `hubWallClock`과 같은 규칙) — 시간대 표기가 있으면 떼고, UTC면 지역 시각.
DateTime hubWallClock(String iso) {
  final m = RegExp(r'^(.+T[0-9:.]+)([+-]\d{2}:?\d{2})$').firstMatch(iso.trim());
  if (m != null) return DateTime.parse(m.group(1)!);
  final t = DateTime.parse(iso);
  return t.isUtc ? t.toLocal() : t;
}
