/// 화면에 보일 상태 문구를 정하는 **순수 함수**(2026-10-13 폰 UI B안).
///
/// 세 축을 섞지 않는다(검토 §3):
/// - readiness: 서버가 이 가전에 실행 요청을 받아 줄지.
/// - execution: 우리 누름 장치의 버튼 조작 job이 진행 중인지.
/// - CT 판정: 그 실행에서 가전 동작을 확인했는지(과거 한 번의 판정).
///
/// 그래서 타일은 "돌아가는 중"이라고 말하지 않는다 — 우리가 아는 것은 버튼 조작
/// 진행뿐이다. 과거 `operationConfirmed`도 지금의 운전으로 옮기지 않는다.
/// 정지 문구는 정지 확인 단계(`command_result.dart`)의 것을 그대로 쓴다.
library;

import '../providers/rpi_api_provider.dart' show RpiConnectionState;
import '../providers/server_appliance_provider.dart' show ServerCatalogStatus;
import '../services/rpi_api_service.dart' show RpiHistoryEntry;
import 'appliance.dart';
import 'command_result.dart';
import 'execution_status.dart';
import 'hub.dart' show VerifyPassLookup, VerifyPassLookupKind;

// ── 가전 타일 ────────────────────────────────────────────────────────────────

/// 타일 상태의 무게. 색은 이 값에서 나오고, 뜻은 언제나 [TileStatus.text]가 말한다.
enum TileTone {
  /// 실행을 요청할 수 있다(긍정은 이것뿐).
  ready,

  /// 이 가전을 대상으로 한 버튼 조작 job이 진행 중이다.
  active,

  /// 사람이 할 일이 있다(설정·연결·준비).
  attention,

  /// 모른다·확인 중이다. 긍정도 부정도 하지 않는다.
  unknown,

  /// 켜진 ThinQ 가전(서버 전원 기억이 켜짐, 2026-10-16) — 띠의 말은 '켜져 있어요'(평가 7차 10/18: 문장과 명사가 섞였다).
  on,

  /// 꺼진 ThinQ 가전 — 서버가 **읽은** 꺼짐일 때만(2026-10-18). 모르면 이 상태가 아니다.
  off,
}

class TileStatus {
  const TileStatus(this.text, this.tone, {this.detail, this.progress = false});

  /// 타일에 보일 한 줄. Semantics 이름에도 그대로 넣는다.
  final String text;
  final TileTone tone;

  /// 서버가 준 실제 이유(있을 때만). 지어내지 않는다.
  final String? detail;

  /// 진행 막대를 그릴지(버튼 조작 진행 중일 때만).
  final bool progress;

  @override
  bool operator ==(Object other) =>
      other is TileStatus &&
      other.text == text &&
      other.tone == tone &&
      other.detail == detail &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(text, tone, detail, progress);

  @override
  String toString() => 'TileStatus($text, $tone, detail: $detail)';
}

/// 위치를 맞추지 않은 가전의 상태 말. 홈 타일은 이 글자를 그리지 않고 아이콘 점 + 접근성 이름으로만 쓴다 —
/// 화면 글자로는 '확인이 필요해요' 카드 한 곳에서만 말한다(평가 3차 10/18).
const kSetupNeededText = '설정이 필요해요';

/// 위치(사진 위 버튼 자리)를 맞춰야 하는 가전인가 — 홈 설정 안내와 같은 조건.
bool needsPanelMapping(ApplianceMap a) =>
    a.isCustom && !a.isDemo && !a.isThinq && a.panelMapping == null;

/// 가전 타일 한 칸의 상태.
///
/// [readinessSource]: 서버가 이 가전에 대해 말해 준 판정(같은 id의 서버 목록 항목).
/// 이 폰이 저장한 가전 정의는 준비 상태를 들고 있지 않으므로(`readinessKnown=false`)
/// 그 자체를 긍정 근거로 쓰지 않는다. 이름·사진은 [appliance]의 것을 쓴다.
///
/// 우선순위(검토 §3): 이 가전을 대상으로 한 현재 job → 허브 장애 → 위치 미설정 →
/// 서버 판정(없거나 상충하면 미확인).
TileStatus applianceTileStatus({
  required ApplianceMap appliance,
  required ApplianceMap? readinessSource,
  required RpiConnectionState hub,
  required ServerCatalogStatus catalog,
  required ExecutionStatus execution,
  bool thinqOn = false,
  bool thinqOff = false,
}) {
  // 1. 이 가전이 지금 추적 중인 실행의 대상인가(서버가 말한 대상 id로만).
  if (execution.applianceId == appliance.id) {
    final total = execution.totalSteps ?? execution.steps.length;
    final count = total > 0 ? ' ${execution.completedSteps}/$total' : '';
    final thinq = appliance.isThinq;
    switch (execution.phase) {
      case ExecutionPhase.unknown:
        return const TileStatus('지금 상태를 몰라요', TileTone.attention);
      case ExecutionPhase.waiting:
        return const TileStatus('차례를 기다려요', TileTone.active);
      case ExecutionPhase.running:
      case ExecutionPhase.retrying:
        final mock = execution.isDemo || execution.executionMode == 'mock';
        if (mock) {
          return TileStatus(
              thinq ? '연습으로 보내는 중' : '연습으로 누르는 중$count', TileTone.active,
              progress: true);
        }
        if (execution.executionMode == 'real') {
          return TileStatus(thinq ? '가전에 보내는 중' : '버튼 누르는 중$count', TileTone.active,
              progress: true);
        }
        return const TileStatus('하는 중이에요', TileTone.active,
            progress: true);
      case ExecutionPhase.idle:
      case ExecutionPhase.completed:
      case ExecutionPhase.failed:
      case ExecutionPhase.unconfirmed:
        break; // 끝난 실행은 지금의 상태가 아니다.
    }
  }

  // 2. 허브 장애가 가전 판정보다 앞선다 — 옛 '준비됨'을 지금의 사실로 쓰지 않는다.
  switch (hub) {
    case RpiConnectionState.unreachable:
      return const TileStatus('본체 연결을 봐 주세요', TileTone.attention);
    case RpiConnectionState.keyRequired:
    case RpiConnectionState.unconfigured:
      return const TileStatus('본체 연결 설정이 필요해요', TileTone.attention);
    case RpiConnectionState.checking:
      return const TileStatus('확인하는 중이에요', TileTone.unknown);
    case RpiConnectionState.connected:
      break;
  }
  switch (catalog) {
    case ServerCatalogStatus.loading:
      return const TileStatus('확인하는 중이에요', TileTone.unknown);
    case ServerCatalogStatus.failed:
      return const TileStatus('본체 연결을 봐 주세요', TileTone.attention);
    case ServerCatalogStatus.unconfigured: // 허브 상태가 이미 위에서 말했다 — 아래 판정(미확인)으로
    case ServerCatalogStatus.loaded:
      break;
  }

  // 3. 위치를 아직 맞추지 않은 가전 — 설치 근거가 있는 '설정'.
  if (needsPanelMapping(appliance)) {
    return const TileStatus(kSetupNeededText, TileTone.attention);
  }

  // 4. 서버 판정. 들은 적이 없으면 canExecute 기본값(true)으로 긍정하지 않는다.
  final r = readinessSource;
  if (r == null || !r.readinessKnown) {
    return const TileStatus('준비됐는지 몰라요', TileTone.unknown);
  }
  final reason = r.readinessReasons.isEmpty ? null : r.readinessReasons.first;
  switch (r.readiness) {
    case 'operable':
      // 평소(실행 가능)는 말하지 않는다 — 빈 상태 줄(2026-10-14 UX). 문제 상태만 적는다.
      if (!r.canExecute) {
        return const TileStatus('지금 할 수 있는지 봐 주세요', TileTone.unknown);
      }
      // 켜진 ThinQ 가전만 말한다(서버가 최근 10분 안에 읽은 전원). 모르면 비운다 — 꺼짐이라 단정하지 않는다.
      if (appliance.isThinq && thinqOn) return const TileStatus('켜져 있어요', TileTone.on);
      if (appliance.isThinq && thinqOff) return const TileStatus('꺼져 있어요', TileTone.off);
      return const TileStatus('', TileTone.ready);
    case 'needs_setup':
      // 서버는 비상정지 걸림·링크 확인 대기도 needs_setup으로 보낸다 —
      // '설정'이라 단정하지 않고 서버의 이유를 그대로 붙인다.
      return r.canExecute
          ? const TileStatus('지금 할 수 있는지 봐 주세요', TileTone.unknown)
          : TileStatus('준비가 필요해요', TileTone.attention, detail: reason);
    case 'disconnected':
      return r.canExecute
          ? const TileStatus('지금 할 수 있는지 봐 주세요', TileTone.unknown)
          : TileStatus('연결이 필요해요', TileTone.attention, detail: reason);
    default:
      return const TileStatus('준비됐는지 몰라요', TileTone.unknown);
  }
}

// ── 가전 타일: 확인 주행 보조 줄 (2026-10-13) ──────────────────────────────────

/// 타일 상태 줄 아래에 붙는 '확인 주행' 보조 줄. **표시만** 한다 — 실행을 막지 않는다.
///
/// | 근거 | 보조 줄 |
/// |---|---|
/// | 실제(real) 확인 주행 완료 | 없음(null) |
/// | 모의 확인 주행 완료 | 모의 주행만 확인했어요 |
/// | 실제 확인 주행 실패 | 확인 주행을 마치지 못했어요 |
/// | 서버가 기록 없음을 명시 | 확인 주행 기록이 없어요 |
/// | 조회 실패·로딩·근거 불명(진행 중·실행 모드 모름·모의 실패 포함) | 확인 주행 여부를 확인하지 못했어요 |
///
/// 붙이지 않는 타일(null): 확인 주행이 없는 가전(내장·ThinQ·데모), 위치를 아직
/// 맞추지 않아 이미 "설정이 필요해요"인 타일, 허브가 연결되지 않았거나(확인 중 포함)
/// 가전 목록 조회가 실패해 상태 줄이 연결 문제인 타일 — 같은 말을 겹치지 않는다.
String? verifyPassTileNote({
  required ApplianceMap appliance,
  required RpiConnectionState hub,
  required ServerCatalogStatus catalog,
  required VerifyPassLookup lookup,
}) {
  if (!appliance.isCustom || appliance.isDemo || appliance.isThinq) return null;
  if (needsPanelMapping(appliance)) return null;
  if (hub != RpiConnectionState.connected) return null;
  if (catalog == ServerCatalogStatus.failed) return null;
  return verifyPassLookupNote(lookup);
}

/// 확인 주행 여부를 모를 때의 말(평가 12차 10/18).
const kVerifyUnknownNote = '버튼 자리를 다시 맞춰 주세요';

/// 확인 주행 조회 결과 하나를 말로 — 타일 보조 줄과 설정 카드가 **같은 근거 수준**으로
/// 쓴다(검토 M4, 2026-10-13). 실제 완료면 null. 진행 중·모의 실패·모드 모름은 모름.
String? verifyPassLookupNote(VerifyPassLookup lookup) {
  // 평가 12차(10/18): '자리 확인을 했는지 몰라요'는 무엇을 하라는 말인지 없었다 → 할 일로. 설정 화면의 '버튼 자리를
  // 맞춰 주세요'와 같은 말 계열. 언제 이 말을 쓰는지(판정)는 그대로다 — 실제 확인 주행 완료를 확인하지 못한 경우.
  const unknown = kVerifyUnknownNote;
  switch (lookup.kind) {
    case VerifyPassLookupKind.noRecord:
      return '아직 자리 확인을 안 했어요';
    case VerifyPassLookupKind.unknown:
      return unknown;
    case VerifyPassLookupKind.found:
      final p = lookup.pass!;
      final mode = p.executionMode;
      if (p.state == 'done' && mode == 'real') return null;
      if (p.state == 'done' && mode == 'mock') return '연습으로만 자리 확인했어요';
      if (p.state == 'failed' && mode == 'real') return '자리 확인을 마치지 못했어요';
      return unknown;
  }
}

// ── 실행 기록 ────────────────────────────────────────────────────────────────

/// 받침이 있으면 '을', 없으면 '를'. 한글이 아니면 '을(를)'.
String objectParticle(String word) {
  if (word.isEmpty) return '을(를)';
  final code = word.runes.last;
  if (code < 0xAC00 || code > 0xD7A3) return '을(를)';
  return (code - 0xAC00) % 28 == 0 ? '를' : '을';
}

/// 기록 한 건의 제목 — **규칙 하나: '무엇을 하기'(행동 이름)**(평가 3차 10/18).
///
/// 왜 과거형('공기청정기를 켰어요')이 아닌가: 오른쪽 배지가 결과(됐어요·몰라요·못 했어요)를 말한다. 제목이
/// '켰어요'면 배지가 '몰라요'일 때 둘이 엇갈린다 — 확인 수준을 높여 보이게 된다(안전 계약). '켜려고 했어요'는
/// 결과를 피하지만 말이 어색하고 길다. 그래서 제목은 할 일 목록처럼 **행동 이름**('공기청정기 켜기')으로 두고,
/// 배지와 이어 읽으면 '공기청정기 켜기 — 됐어요/몰라요'가 되게 한다. 말로 한 명령('켜줘')·질문('바꿀까요?')·
/// 해요체('켜요')·설정표 말('전원 켜기'·'풍량')이 섞이던 것을 이 한 꼴로 맞춘다.
///
/// 1. 목적 문장이 있으면 그 행동을 행동 이름으로. 출처('자동 실행 · '·''…' 루틴')는 [historySource]·
///    [historyOrigin]이 부제에서 말한다.
/// 2. 루틴 기록은 목적 문장이 루틴 이름뿐이다 — 누른 버튼이 있으면 '가전 버튼 N번 누르기'가 제목이고
///    루틴 이름은 부제, 기록이 한 일을 말하지 않으면(LG 가전 루틴) 루틴 이름이 곧 행동 이름이다.
/// 3. 목적이 없으면 가전 + 버튼 — '인터폰 문열림 버튼 누르기', 여럿이면 '전자레인지 버튼 2번 누르기'.
/// 4. 그것도 없으면 '버튼 누르기'(LG 가전은 '가전 설정 바꾸기'). 목적을 지어내지 않는다.
///
/// [applianceName]: 지금 등록 목록에서 찾은 이름. 지웠거나 모르면 null —
/// 알 수 없는 id를 이름처럼 내놓지 않는다.
const _autoPrefix = '자동 실행 · ';
final _routineTitle = RegExp(r"^'(.+)' 루틴$");

/// 기록의 출처 — 제목 아래 시각 줄에 붙인다(외부 평가 10/16 2차 p03). 서버 목적 문장으로 아는 자동 실행·루틴,
/// 그 밖은 '직접 실행'(말로 한 명령·제안 승인·화면 조작 — 모두 사람이 시작했다. 어느 쪽인지는 목적 문장만으로
/// 가를 수 없어 나누지 않는다). 시각만 있는 줄은 누가 실행했는지 몰랐다(UI 평가 4차 10/17).
String historySource(RpiHistoryEntry e) {
  final purpose = e.purpose?.trim() ?? '';
  if (purpose.startsWith(_autoPrefix)) return '자동';
  if (_routineTitle.hasMatch(historyStatement(purpose))) return '루틴';
  return '직접';
}

/// 시각 줄에 쓰는 출처 말 — 루틴이면 **어떻게 시작했는지**까지(평가 7차 10/18: '22:04 · 루틴'만으로는 '아침' 루틴이
/// 밤에 저절로 돈 것처럼 읽혔다).
///
/// 서버 기록(`/history`)에는 '지금 하기'와 '정해진 시각에 물어본 카드를 허락'을 가르는 필드가 없다 — 둘 다 목적
/// 문장이 `'이름' 루틴`이다. 가를 수 있는 것은 묻지 않고 한 자동 실행(`자동 실행 · '이름' 루틴`)뿐이라, 그 밖의
/// 루틴 기록은 '물어보고(사람이 허락해서) 했다'까지만 말한다(지어내지 않는다).
String historySourceLabel(RpiHistoryEntry e) {
  final source = historySource(e);
  final purpose = e.purpose?.trim() ?? '';
  final routine = purpose.isEmpty ? null : _purposeParts(purpose).routine;
  // 평가 10차(10/18): '허락하고 실행'은 딱딱했다 → '물어보고'('자동으로'와 짝). '했어요'를 붙이지 않는다 — 오른쪽 배지가
  // '못 했어요'·'봐 주세요'일 때 엇갈린다(결과는 배지 하나가 말한다).
  // '직접'은 누가 직접인지 몰랐다 → '사람이 직접'. 폰·본체 화면·말 가운데 어디서 했는지는 기록에 가를 자료가 없어
  // 지어내지 않는다(사람이 시작했다는 것까지만).
  // 평가 12차(10/18): LG 가전(클라우드) 기록에 '사람이 직접'과 손 아이콘이 붙어 작은 팔·손 누름과 헷갈렸다 →
  // 출처는 'LG 가전'. 폰·본체 화면 가운데 어디서 보냈는지는 기록(/history)에 가를 필드가 없어 거기까지만 말한다.
  // 평가 13차(10/18): LG 가전 자동 실행('자동')도 출처를 같이 — '자동 · LG 가전'. 작은 팔 가전의 자동 실행은 '자동' 그대로.
  if (historyIsLgAppliance(e)) return source == '자동' ? '자동 · LG 가전' : 'LG 가전';
  // 평가 13차(10/18): '사람이 직접'은 손으로 직접 눌렀다는 뜻으로 읽혔다. 기록이 아는 사실만 —
  // 목적 문장이 없는 실행은 수동 조작 화면에서 버튼을 고른 것(`/execute-buttons`, 폰·본체 화면)이라 '화면에서 골라 누름'.
  // 목적 문장이 있으면 말·제안 가운데 무엇인지 가를 필드가 없어 중립어 '바로 실행'(물어보고 한 루틴·자동과 구분).
  if (routine == null) {
    if (source != '직접') return source;
    return purpose.isEmpty ? '화면에서 골라 누름' : '바로 실행';
  }
  return source == '자동' ? '루틴 · 자동으로' : '루틴 · 물어보고';
}

/// LG 가전(클라우드) 기록인가 — 루틴이 아닌 ThinQ 경로(사람이 시작했든 자동이든). 기록 줄은 출처 아이콘 대신
/// 가전 아이콘(평가 12·13차 10/18).
bool historyIsLgAppliance(RpiHistoryEntry e) {
  if (e.route != 'thinq' || historySource(e) == '루틴') return false;
  final purpose = e.purpose?.trim() ?? '';
  return purpose.isEmpty || _purposeParts(purpose).routine == null;
}

/// 목적 문장에서 출처 머리('자동 실행 · ')를 떼고, 루틴이면 그 이름을 돌려준다.
({String body, String? routine}) _purposeParts(String purpose) {
  var body = purpose.trim();
  if (body.startsWith(_autoPrefix)) body = body.substring(_autoPrefix.length).trim();
  final routine = _routineTitle.firstMatch(historyStatement(body));
  return (body: body, routine: routine?.group(1));
}

/// 서버 목적 문장 → 짧은 행동 이름(홈 알림 줄 '못 한 일 1건: …', 평가 15차 10/18). 루틴이면 "'이름' 루틴".
String purposeActionName(String purpose) {
  final parts = _purposeParts(purpose);
  if (parts.routine case final r?) return "'$r' 루틴";
  return actionName(withoutMockMark(parts.body));
}

/// 본체 가전 요약('공기청정기 바람 세기 중'·'공기청정기 전원 켜기') → 기록과 같은 행동 이름
/// ('공기청정기 바람 중간으로 하기'·'공기청정기 켜기', 평가 16차 10/18). 요약 꼴이 아니면 [actionName] 그대로.
String summaryActionName(String summary) {
  final t = summary.trim();
  final wind = RegExp(r'^(.*바람 세기) (약|중|강)$').firstMatch(t);
  if (wind != null) return actionName('${wind[1]} ${wind[2]}으로 바꾸기');
  return actionName(t);
}

/// 누른 버튼으로 만든 행동 이름. 버튼을 모르면 null.
String? _pressTitle(RpiHistoryEntry e, String? name) {
  final labels = [
    for (final b in e.buttons)
      if (b.button.trim().isNotEmpty) b.button.trim(),
  ];
  if (labels.isEmpty) return null;
  final hasName = name != null && name.isNotEmpty;
  // 하나면 버튼 이름까지, 여럿이면 키오스크와 같은 단위 '버튼 N번'.
  final pressed =
      labels.length == 1 ? '${labels.single} 버튼 누르기' : '버튼 ${labels.length}번 누르기';
  return hasName ? '$name $pressed' : pressed;
}

String? _cleanName(RpiHistoryEntry e, String? applianceName) {
  final raw = applianceName?.trim();
  return raw != null && e.executionMode == 'mock' ? withoutMockMark(raw) : raw;
}

String historyTitle(RpiHistoryEntry e, {String? applianceName}) {
  final name = _cleanName(e, applianceName);
  final purpose = e.purpose?.trim();
  if (purpose != null && purpose.isNotEmpty) {
    final parts = _purposeParts(purpose);
    final routine = parts.routine;
    if (routine != null) {
      return _pressTitle(e, name) ??
          (e.executionMode == 'mock' ? withoutMockMark(routine) : routine);
    }
    // 모의 기록은 '연습' 배지가 말한다 — 제목의 "(모의)"를 되풀이하지 않는다.
    final body = e.executionMode == 'mock' ? withoutMockMark(parts.body) : parts.body;
    return actionName(body);
  }
  final pressed = _pressTitle(e, name);
  if (pressed != null) return pressed;
  final hasName = name != null && name.isNotEmpty;
  if (e.route == 'thinq') return hasName ? '$name 설정 바꾸기' : '가전 설정 바꾸기';
  return hasName ? '$name 버튼 누르기' : '버튼 누르기';
}

/// 부제에 붙일 루틴 이름 — 제목이 루틴 이름이 아닐 때만(같은 말을 두 번 쓰지 않는다). 루틴이 아니면 null.
/// 자동 규칙의 이름은 서버가 목적 문장에 루틴 이름으로만 적는다(시각 규칙) — 그 밖의 규칙은 '자동'까지만.
String? historyOrigin(RpiHistoryEntry e, {String? applianceName}) {
  final purpose = e.purpose?.trim();
  if (purpose == null || purpose.isEmpty) return null;
  final routine = _purposeParts(purpose).routine;
  if (routine == null) return null;
  final shown = e.executionMode == 'mock' ? withoutMockMark(routine) : routine;
  return historyTitle(e, applianceName: applianceName) == shown ? null : shown;
}

// 끝 동사 → 행동 이름. '줘'·'주세요'·'요'·'까요'를 뗀 줄기로 찾는다. 모르는 줄기는 그대로 둔다(지어내지 않는다).
const _verbStems = {
  '켜': '켜기', '켤': '켜기',
  '꺼': '끄기', '끌': '끄기',
  '데워': '데우기', '데울': '데우기',
  '끓여': '끓이기', '끓일': '끓이기',
  '잠가': '잠그기', '잠글': '잠그기',
  '바꿔': '바꾸기', '바꿀': '바꾸기',
  '눌러': '누르기', '누를': '누르기',
  '돌려': '돌리기', '돌릴': '돌리기',
  '열어': '열기', '열': '열기',
  '틀어': '틀기', '틀': '틀기',
  '멈춰': '멈추기', '멈출': '멈추기',
  '줄여': '줄이기', '줄일': '줄이기',
  '올려': '올리기', '올릴': '올리기',
  '낮춰': '낮추기', '낮출': '낮추기',
  '높여': '높이기', '높일': '높이기',
  '해': '하기', '할': '하기',
};

/// 명령·질문·해요체 문장을 행동 이름('공기청정기 켜기')으로. 설정표 말('풍량'·'전원 켜기')도 쉬운 말로.
/// 끝 동사를 모르면 문장을 그대로 둔다.
String actionName(String text) {
  var t = text.trim();
  while (t.isNotEmpty && '.!?'.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1).trimRight();
  }
  final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return text.trim();
  // '꺼 줘'처럼 띄어 쓴 도움말을 붙인다.
  if (words.length > 1 && const {'줘', '주세요', '줄래', '줄래요'}.contains(words.last)) {
    final aux = words.removeLast();
    words[words.length - 1] = words.last + aux;
  }
  final last = words.last;
  String? stem;
  for (final end in const ['주세요', '줄래요', '줄래', '까요', '줘', '요']) {
    if (last.length > end.length && last.endsWith(end)) {
      stem = last.substring(0, last.length - end.length);
      break;
    }
  }
  if (stem != null) {
    final mapped = _verbStems[stem] ??
        // '실행해'·'시작할' → '실행하기'·'시작하기'
        ((stem.endsWith('해') || stem.endsWith('할')) && stem.length > 1
            ? '${stem.substring(0, stem.length - 1)}하기'
            : null);
    if (mapped != null) {
      words[words.length - 1] = mapped;
      // 목적격 조사(을/를)를 뗀다 — '풍량을 강으로' → '풍량 강으로'. 따옴표로 끝난 이름은 건드리지 않는다.
      for (var i = 0; i < words.length - 1; i++) {
        final w = words[i];
        if (w.length > 1 && (w.endsWith('을') || w.endsWith('를'))) {
          words[i] = w.substring(0, w.length - 1);
        }
      }
    }
  }
  return _windWords(words
      .join(' ')
      .replaceAll('풍량', '바람 세기')
      .replaceAll('전원 켜기', '켜기')
      .replaceAll('전원 끄기', '끄기'));
}

/// 옛 기록의 바람 세기 말 → 쉬운 말(평가 4차 10/18: 옛 기록 제목에 '약풍으로 바꾸기'·'강풍'·'중풍'이 남았다).
///
/// '약풍·중풍·강풍(으로)'과 '바람 세기 약·중·강(으로)'를 '바람 약하게·중간으로·세게'로. 뒤에 '바꾸기'·'하기'가
/// 있으면 행동 이름 규칙대로 '하기'를 붙인다('바람 세게 하기'). 무엇을 했는지만 바꾸고 결과는 배지가 말한다.
String _windWords(String text) {
  const how = {'약': '약하게', '중': '중간으로', '강': '세게'};
  return text.replaceAllMapped(
    RegExp(r'(?:(약|중|강)풍|바람 세기 (약|중|강))(?:으로)?( 바꾸기| 하기)?(?=$|\s)'),
    (m) => '바람 ${how[m[1] ?? m[2]]}${m[3] != null ? ' 하기' : ''}',
  );
}

/// 기록 한 건의 결과 문장과 다음 행동.
class HistoryResult {
  const HistoryResult({
    required this.kind,
    required this.sentence,
    this.next,
    this.mockNote,
  });

  final ResultKind kind;

  /// 무엇이 됐는지 한 문장(데이터가 아는 수준까지만).
  final String sentence;

  /// 사람이 이어서 할 일. 없으면 null(무조건 '확인해 주세요'를 붙이지 않는다).
  final String? next;

  /// 모의 기록에만: "연습 · 실제로 누르지 않았어요"(결과 문장이 이미 그 말이면 null). 그 밖에는 null.
  final String? mockNote;
}

/// 작은 팔이 버튼을 다 눌렀지만 가전 동작은 확인하지 못한 기록의 한 줄(평가 12차 10/18).
const kPressedAllSentence = '버튼은 다 눌렀어요, 움직이는지 봐 주세요';

/// 결과 문장(검토 §5 표). 선택 순서: executionMode → resultKind(outcome 우선) →
/// route·receipt·termination·confirmation. 정지·안전 정지는 기존 문장을 그대로 쓴다.
HistoryResult historyResult(RpiHistoryEntry e, {String? applianceName}) {
  final kind = resultKindOf(outcome: e.outcome, status: e.status);
  final mock = e.executionMode == 'mock';
  final thinq = e.route == 'thinq';
  final rawName = applianceName?.trim();
  final name = rawName != null && mock ? withoutMockMark(rawName) : rawName;
  final target = (name == null || name.isEmpty) ? '가전' : name;
  final checkTarget = '$target${objectParticle(target)} 봐 주세요';
  // 모의는 한 번만 말한다(2026-10-14 UX) — 이름의 "(모의)"·연습 줄·다음 행동에 세 번 나오던 것을 이 한 줄로.
  // 실제·연습을 모르는 기록(옛 RPi4·보고 없음)은 성공 문장만 두면 실제 성공처럼 보인다(F4 경계) —
  // 일반 화면 띠는 생략해도 기록에는 한 줄 남긴다(2026-10-14).
  final unknownMode = !mock && e.executionMode != 'real';
  final mockNote = mock
      ? (thinq ? '연습이라 $target에 보내지 않았어요' : '연습이라 실제로 누르지 않았어요')
      : unknownMode
          ? '실제 가전이 움직였는지 몰라요'
          : null;

  // 정지·안전 정지 — 정지 확인 단계 작업의 계약을 건드리지 않는다.
  if (kind == ResultKind.stopped) {
    final byUser = e.outcome == null && e.termination == 'stopped_by_user';
    final safety = e.outcome == null && e.status == 'safety_stopped' && !byUser;
    return HistoryResult(
      kind: kind,
      sentence: byUser ? '직접 멈췄어요' : safety ? '스스로 멈췄어요' : '멈췄어요',
      mockNote: mockNote,
    );
  }
  if (kind == ResultKind.safetyStop) {
    // 모션 걸림 등(2026-10-14) — 다시 눌러 본 것이 아니다. 원인 그대로.
    final motion = motionAbortSentence(e.abortReason);
    if (motion != null) {
      return HistoryResult(
        kind: kind,
        sentence: motion,
        next: '다시 누르지 않았어요. 작은 팔을 봐 주세요',
        mockNote: mockNote,
      );
    }
    return HistoryResult(
      kind: kind,
      sentence: e.termination == 'retries_exhausted'
          ? '다시 눌러도 몰라서 스스로 멈췄어요'
          : '스스로 멈췄어요',
      mockNote: mockNote,
    );
  }

  // 이미 목표값(2026-10-14): 보내지 않은 성공 — '보내지 않았어요·연결 확인'이나 '바꿨어요'로 말하지 않는다.
  if (thinq && kind == ResultKind.success && e.confirmation == 'already_at_target') {
    return HistoryResult(
      kind: kind,
      sentence: mock
          ? '연습이에요. 이미 그 설정이라 보내지 않았어요'
          : '이미 그 설정이라 보내지 않았어요',
      mockNote: unknownMode ? mockNote : null,
    );
  }
  final base = _liveResult(e, kind, thinq: thinq, target: target, checkTarget: checkTarget);
  if (unknownMode) {
    return HistoryResult(kind: base.kind, sentence: base.sentence, next: base.next, mockNote: mockNote);
  }
  if (!mock) return base;
  // 모의 기록: 실제 가전 확인을 부탁하지 않는다(다음 행동 없음). ThinQ 모의는 "보냈지만 확인 못 함"과
  // "보내지 않았다"가 한 카드에서 엇갈리지 않게 결과 문장 하나로 말한다. 물리 성공도 같은 말 한 줄.
  if (thinq || kind == ResultKind.success) {
    return HistoryResult(kind: kind, sentence: mockNote!);
  }
  return HistoryResult(kind: kind, sentence: base.sentence, mockNote: mockNote);
}

String? _noDot(String? s) =>
    s == null ? null : (s.endsWith('.') ? s.substring(0, s.length - 1) : s);

/// "(모의)"·"(모의 클라우드)" 같은 괄호 표기를 뺀 이름(표시만). 모의 기록은 '연습' 줄이 이미 말한다.
String withoutMockMark(String text) =>
    text.replaceAll(RegExp(r'\s*\((?:모의|연습)[^)]*\)'), '').trim();

/// 기록 제목은 묻지 않는다 — 끝난 일이다. 서버 목적이 질문("공기청정기 풍량을 강으로 바꿀까요?")이면
/// 서술형("공기청정기 풍량 강으로")으로 줄인다. 질문이 아니면 그대로.
String historyStatement(String purpose) {
  final text = purpose.trim();
  if (!text.endsWith('?')) return text;
  final words = text.substring(0, text.length - 1).trim().split(RegExp(r'\s+'));
  // 끝 동사("바꿀까요"·"켤까요"·"실행할까요")를 뗀다.
  if (words.length > 1 && words.last.endsWith('까요')) words.removeLast();
  // 목적격 조사(을/를)를 뗀다 — "풍량을 강으로" → "풍량 강으로". 따옴표로 끝난 이름은 건드리지 않는다.
  final out = [
    for (final w in words)
      (w.length > 1 && (w.endsWith('을') || w.endsWith('를')))
          ? w.substring(0, w.length - 1)
          : w,
  ];
  return out.join(' ');
}

HistoryResult _liveResult(
  RpiHistoryEntry e,
  ResultKind kind, {
  required bool thinq,
  required String target,
  required String checkTarget,
}) {
  if (thinq) {
    if (e.receipt == 'not_dispatched') {
      return HistoryResult(
          kind: kind, sentence: '가전에 보내지 않았어요', next: '본체 연결을 봐 주세요');
    }
    return switch (kind) {
      // 확인한 사실만큼(2026-10-14): 바꿈 · 보낸 뒤 목표값(전 값 모름). 서버 문장이 없으면 종전 문장.
      ResultKind.success => HistoryResult(
          kind: kind,
          sentence: _noDot(thinqOutcomeSentence(e.confirmation, e.detail)) ??
              '가전 상태를 확인했어요'),
      // 접수 여부(받았는지 모름·접수됨)는 아래 보조 줄이 말한다. 다시 보내라고 권하지 않는다.
      ResultKind.unconfirmed => HistoryResult(
          kind: kind,
          sentence: '보냈지만 설정이 바뀌었는지 몰라요',
          next: '다시 보내기 전에 $checkTarget',
        ),
      _ => HistoryResult(
          kind: kind, sentence: '가전이 하지 않았어요', next: checkTarget),
    };
  }

  // 물리(옛 기록의 unknown 경로 포함).
  switch (kind) {
    case ResultKind.success:
      if (e.confirmation == 'operation_confirmed' && e.executionMode == 'real') {
        return HistoryResult(kind: kind, sentence: '가전이 전기를 쓰기 시작했어요');
      }
      if (e.confirmation == 'press_confirmed') {
        return HistoryResult(
            kind: kind,
            sentence: '버튼을 눌렀어요',
            next: '$target 동작을 봐 주세요');
      }
      // 평가 12차(10/18): '다 눌렀다고 알려 왔어요'는 기계 보고 말투였다 → 사람 말. 뜻은 그대로 — 작은 팔은 다
      // 눌렀지만 가전이 움직였는지는 확인하지 못했다(배지 '봐 주세요'·초록 아님). 볼 것은 이 한 줄이 함께 말한다.
      return HistoryResult(kind: kind, sentence: kPressedAllSentence);
    case ResultKind.unconfirmed:
      return HistoryResult(
          kind: kind, sentence: '눌렸는지 몰라요', next: checkTarget);
    case ResultKind.failed:
      if (e.receipt == 'not_dispatched') {
        return HistoryResult(
            kind: kind, sentence: '작은 팔에 보내지 못했어요', next: '본체 연결을 봐 주세요');
      }
      if (e.termination == 'retries_exhausted') {
        return HistoryResult(
            kind: kind, sentence: '다시 눌러도 눌렸는지 몰라요', next: checkTarget);
      }
      return HistoryResult(
          kind: kind,
          sentence: '끝까지 하지 못했어요',
          next: '$target 상태를 봐 주세요');
    case ResultKind.stopped:
    case ResultKind.safetyStop:
      throw StateError('handled above');
  }
}

// ── 가전 타일: 같은 이름 구분 (2026-10-14) ──────────────────────────────────

/// 타일에 적을 이름(가전 id → 이름). **표시만** 바꾼다 — 저장된 이름은 그대로다.
///
/// 방이 있으면 타일이 방을 부제로 적으므로 이름은 그대로 둔다. 이름과 방(없음 포함)이
/// 모두 같은 가전이 둘 이상이면 두 번째부터 " (2)"·" (3)"을 붙인다 — '전자레인지'와
/// '전자레인지'를 타일에서 가를 수 없었다.
Map<String, String> distinctTileNames(List<ApplianceMap> appliances) {
  final seen = <String, int>{};
  return {
    for (final a in appliances)
      a.id: () {
        final key = '${a.name.trim()}\u0000${(a.location ?? '').trim()}';
        final n = (seen[key] ?? 0) + 1;
        seen[key] = n;
        return n == 1 ? a.name : '${a.name} ($n)';
      }(),
  };
}
