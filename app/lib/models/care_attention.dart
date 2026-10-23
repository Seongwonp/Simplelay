import '../services/rpi_api_service.dart' show RpiCareEvent;
import 'display_status.dart' show purposeActionName, summaryActionName;

/// 홈 '확인이 필요해요'의 안 본 알림 줄 — 이름은 하나, '안 본 알림 N건'(설정 줄·설정 탭 접근성 이름과 같은 말).
///
/// 평가 11·12차(10/18)에 종류 말('자동으로 한 일·루틴 안내 알림 4건, 아직 안 봤어요')을 붙였더니 평가 13차(10/18)에서
/// 분류 나열 말투에 어절 중간에서 끊겼고, 문제가 아닌 알림도 경고처럼 읽혔다. 그래서 종류는 **봐야 할 것이 섞였을 때만**
/// 가장 무거운 것 하나를 짧은 말로 붙인다('안 본 알림 3건, 못 한 일이 있어요'). 자동으로 한 일·루틴 안내뿐이면 건수만.
///
/// 평가 15차(10/18): '안 본 알림 7건, 못 한 일이 있어요'는 한 줄에 두 가지를 말하면서 **무엇을** 못 했는지는
/// 없었다 → 봐야 할 것이 있으면 그 갈래만 한 줄('못 한 일 1건: 공기청정기 바람 중간으로 하기' — 가장 최근 것의
/// 이름, 기록이 아는 말만), 나머지 알림은 따로 '안 본 알림 6건'([CareAttentionLines.rest]). 봐야 할 것이 없으면
/// 중립 한 줄 '안 본 알림 N건'만.
typedef CareAttentionLines = ({String? look, String? rest});

CareAttentionLines careAttentionLines(List<RpiCareEvent> unread) {
  if (unread.isEmpty) return (look: null, rest: null);
  final group = _careLookGroup(unread);
  if (group == null) return (look: null, rest: '안 본 알림 ${unread.length}건');
  final (word, kinds) = group;
  final hits = [for (final e in unread) if (kinds.contains(e.kind)) e]
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  final what = careEventWhat(hits.first);
  // 평가 16차(10/18): '못 한 일 3건: 공기청정기 바람 세기 중'은 끝 '중'이 '진행 중'처럼 읽혔고 기록('바람 중간으로 하기 ·
  // 3번 못 했어요')과 이름·단위가 달랐다 → 기록과 같은 행동 이름, 횟수는 '번'으로 끝 괄호에. 이름이 서로 다른 일이
  // 섞였으면 가장 최근 것의 이름과 '외 N번'(한 이름에 다른 일의 횟수를 붙이지 않는다).
  final String look;
  if (what == null) {
    look = '$word ${hits.length}번';
  } else {
    final same = hits.where((e) => careEventWhat(e) == what).length;
    final others = hits.length - same;
    // 평가 17차(10/18): 끝 괄호 '(3번)'이 혼자 다음 줄로 갔다 → 여러 번이면 '공기청정기 바람 중간으로 하기 · 3번 못
    // 했어요'처럼 횟수와 결과를 문장 끝에 붙인다(기록 칩 '3번 못 했어요'와 같은 말).
    final verb = switch (word) { '못 한 일' => '못 했어요', '멈춘 일' => '멈췄어요', _ => null };
    if (same > 1 && verb != null) {
      look = '$what · $same번 $verb${others > 0 ? ', 다른 일 $others번' : ''}';
    } else {
      look = '$word: $what${same > 1 ? ' $same번' : ''}${others > 0 ? ' 외 $others번' : ''}';
    }
  }
  return (
    look: look,
    // 휴리스틱 평가(10/18): '그 밖에 안 본 알림 4건'(홈)과 '안 본 알림 7건'(설정)이 달라 헷갈렸다 → 홈·설정 같은 수 하나
    // (전체 안 본 수). 위 실패 경고로 따로 보인 것도 이 수에 들어 있다.
    rest: '안 본 알림 ${unread.length}건',
  );
}

/// 홈·접근성에서 쓰는 한 문장(두 줄을 이은 것).
String careAttentionText(List<RpiCareEvent> unread) {
  final l = careAttentionLines(unread);
  return [if (l.look != null) l.look!, if (l.rest != null) l.rest!].join(', ');
}

/// 알림 한 건이 **무엇에 대한** 것인지 — 서버가 적은 목적 문장(행동 이름으로), 없으면 알림 문장의 따옴표 속 이름
/// (본체 요약 '공기청정기 바람 세기 중'도 기록과 같은 행동 이름 '공기청정기 바람 중간으로 하기'로). 둘 다 없으면 null.
String? careEventWhat(RpiCareEvent e) {
  final purpose = e.purpose?.trim() ?? '';
  if (purpose.isNotEmpty) return purposeActionName(purpose);
  final quoted = RegExp(r"'([^']+)'").firstMatch(e.message);
  final label = quoted?.group(1)?.trim();
  return (label == null || label.isEmpty) ? null : summaryActionName(label);
}

/// 안 본 알림 가운데 사람이 봐야 할 것(위험 소리·실패·정지·루틴 멈춤·안부 신호)이 있는가 — 경고색은 이때만.
bool careNeedsLook(List<RpiCareEvent> unread) => _careLookGroup(unread) != null;

bool careLookIsFailure(List<RpiCareEvent> unread) => _careLookGroup(unread)?.$1 == '못 한 일';

/// 봐야 할 갈래 가운데 가장 무거운 것 하나 — (짧은 이름, 그 갈래의 종류들). 없으면 null(자동으로 한 일·루틴 안내·모르는 종류).
(String, Set<String>)? _careLookGroup(List<RpiCareEvent> unread) {
  const order = [
    ('위험 소리', {'danger_sound'}),
    ('못 한 일', {'execution_failed', 'appliance_done_undelivered'}),
    ('멈춘 일', {'emergency_stop'}),
    ('멈춘 루틴', {'routine_stopped'}),
    ('안부 신호', {'quiet_routine'}),
  ];
  final kinds = {for (final e in unread) e.kind};
  for (final g in order) {
    if (kinds.any(g.$2.contains)) return g;
  }
  return null;
}
