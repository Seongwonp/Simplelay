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
}) {
  // 1. 이 가전이 지금 추적 중인 실행의 대상인가(서버가 말한 대상 id로만).
  if (execution.applianceId == appliance.id) {
    final total = execution.totalSteps ?? execution.steps.length;
    final count = total > 0 ? ' · ${execution.completedSteps}/$total' : '';
    final thinq = appliance.isThinq;
    switch (execution.phase) {
      case ExecutionPhase.unknown:
        return const TileStatus('동작을 확인할 수 없어요', TileTone.attention);
      case ExecutionPhase.waiting:
        return const TileStatus('실행을 기다리고 있어요', TileTone.active);
      case ExecutionPhase.running:
      case ExecutionPhase.retrying:
        final mock = execution.isDemo || execution.executionMode == 'mock';
        if (mock) {
          return TileStatus(
              thinq ? '연습 명령 처리 중' : '연습 버튼 조작 중$count', TileTone.active,
              progress: true);
        }
        if (execution.executionMode == 'real') {
          return TileStatus(thinq ? '명령 처리 중' : '버튼 조작 중$count', TileTone.active,
              progress: true);
        }
        return const TileStatus('실행을 확인하고 있어요', TileTone.active,
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
      return const TileStatus('연결을 확인해 주세요', TileTone.attention);
    case RpiConnectionState.keyRequired:
    case RpiConnectionState.unconfigured:
      return const TileStatus('허브 설정이 필요해요', TileTone.attention);
    case RpiConnectionState.checking:
      return const TileStatus('확인하는 중이에요', TileTone.unknown);
    case RpiConnectionState.connected:
      break;
  }
  switch (catalog) {
    case ServerCatalogStatus.loading:
      return const TileStatus('확인하는 중이에요', TileTone.unknown);
    case ServerCatalogStatus.failed:
      return const TileStatus('연결을 확인해 주세요', TileTone.attention);
    case ServerCatalogStatus.unconfigured: // 허브 상태가 이미 위에서 말했다 — 아래 판정(미확인)으로
    case ServerCatalogStatus.loaded:
      break;
  }

  // 3. 위치를 아직 맞추지 않은 가전 — 설치 근거가 있는 '설정'.
  if (needsPanelMapping(appliance)) {
    return const TileStatus('설정이 필요해요', TileTone.attention);
  }

  // 4. 서버 판정. 들은 적이 없으면 canExecute 기본값(true)으로 긍정하지 않는다.
  final r = readinessSource;
  if (r == null || !r.readinessKnown) {
    return const TileStatus('준비 상태를 확인하지 못했어요', TileTone.unknown);
  }
  final reason = r.readinessReasons.isEmpty ? null : r.readinessReasons.first;
  switch (r.readiness) {
    case 'operable':
      // 평소(실행 가능)는 말하지 않는다 — 빈 상태 줄(2026-10-14 UX). 문제 상태만 적는다.
      return r.canExecute
          ? const TileStatus('', TileTone.ready)
          : const TileStatus('실행 가능 여부를 확인해 주세요', TileTone.unknown);
    case 'needs_setup':
      // 서버는 비상정지 걸림·링크 확인 대기도 needs_setup으로 보낸다 —
      // '설정'이라 단정하지 않고 서버의 이유를 그대로 붙인다.
      return r.canExecute
          ? const TileStatus('실행 가능 여부를 확인해 주세요', TileTone.unknown)
          : TileStatus('준비가 필요해요', TileTone.attention, detail: reason);
    case 'disconnected':
      return r.canExecute
          ? const TileStatus('실행 가능 여부를 확인해 주세요', TileTone.unknown)
          : TileStatus('연결이 필요해요', TileTone.attention, detail: reason);
    default:
      return const TileStatus('준비 상태를 확인하지 못했어요', TileTone.unknown);
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

/// 확인 주행 조회 결과 하나를 말로 — 타일 보조 줄과 설정 카드가 **같은 근거 수준**으로
/// 쓴다(검토 M4, 2026-10-13). 실제 완료면 null. 진행 중·모의 실패·모드 모름은 모름.
String? verifyPassLookupNote(VerifyPassLookup lookup) {
  const unknown = '확인 주행 여부를 확인하지 못했어요';
  switch (lookup.kind) {
    case VerifyPassLookupKind.noRecord:
      return '확인 주행 기록이 없어요';
    case VerifyPassLookupKind.unknown:
      return unknown;
    case VerifyPassLookupKind.found:
      final p = lookup.pass!;
      final mode = p.executionMode;
      if (p.state == 'done' && mode == 'real') return null;
      if (p.state == 'done' && mode == 'mock') return '연습 주행만 확인했어요';
      if (p.state == 'failed' && mode == 'real') return '확인 주행을 마치지 못했어요';
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

/// 기록 한 건의 제목. **목적을 추정하지 않는다**(검토 §5).
///
/// 1. 비어 있지 않은 purpose 그대로
/// 2. 대상 이름 + 버튼 라벨 — "인터폰 · 문열림 버튼 조작"
/// 3. 대상 이름만 — "인터폰 버튼 조작"(ThinQ면 "인터폰 명령")
/// 4. 버튼 라벨만 — "문열림 버튼 조작"
/// 5. 아무것도 없으면 "실행 기록"
///
/// [applianceName]: 지금 등록 목록에서 찾은 이름. 지웠거나 모르면 null —
/// 알 수 없는 id를 이름처럼 내놓지 않는다.
String historyTitle(RpiHistoryEntry e, {String? applianceName}) {
  final purpose = e.purpose?.trim();
  if (purpose != null && purpose.isNotEmpty) {
    final title = historyStatement(purpose);
    // 모의 기록은 아래 '연습' 한 줄이 말한다 — 제목의 "(모의)"를 되풀이하지 않는다.
    return e.executionMode == 'mock' ? withoutMockMark(title) : title;
  }
  final labels = [
    for (final b in e.buttons)
      if (b.button.trim().isNotEmpty) b.button.trim(),
  ];
  final rawName = applianceName?.trim();
  final name = rawName != null && e.executionMode == 'mock'
      ? withoutMockMark(rawName)
      : rawName;
  final hasName = name != null && name.isNotEmpty;
  if (labels.isNotEmpty) {
    final pressed = '${labels.join(', ')} 버튼 조작';
    return hasName ? '$name · $pressed' : pressed;
  }
  if (hasName) return e.route == 'thinq' ? '$name 명령' : '$name 버튼 조작';
  return '실행 기록';
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

/// 결과 문장(검토 §5 표). 선택 순서: executionMode → resultKind(outcome 우선) →
/// route·receipt·termination·confirmation. 정지·안전 정지는 기존 문장을 그대로 쓴다.
HistoryResult historyResult(RpiHistoryEntry e, {String? applianceName}) {
  final kind = resultKindOf(outcome: e.outcome, status: e.status);
  final mock = e.executionMode == 'mock';
  final thinq = e.route == 'thinq';
  final rawName = applianceName?.trim();
  final name = rawName != null && mock ? withoutMockMark(rawName) : rawName;
  final target = (name == null || name.isEmpty) ? '가전' : name;
  final checkTarget = '$target${objectParticle(target)} 직접 확인해 주세요';
  // 모의는 한 번만 말한다(2026-10-14 UX) — 이름의 "(모의)"·연습 줄·다음 행동에 세 번 나오던 것을 이 한 줄로.
  // 실제·연습을 모르는 기록(옛 RPi4·보고 없음)은 성공 문장만 두면 실제 성공처럼 보인다(F4 경계) —
  // 일반 화면 띠는 생략해도 기록에는 한 줄 남긴다(2026-10-14).
  final unknownMode = !mock && e.executionMode != 'real';
  final mockNote = mock
      ? (thinq ? '연습 · $target에 보내지 않았어요' : '연습 · 실제로 누르지 않았어요')
      : unknownMode
          ? '실제 기기 동작 여부를 확인하지 못했어요'
          : null;

  // 정지·안전 정지 — 정지 확인 단계 작업의 계약을 건드리지 않는다.
  if (kind == ResultKind.stopped) {
    final byUser = e.outcome == null && e.termination == 'stopped_by_user';
    final safety = e.outcome == null && e.status == 'safety_stopped' && !byUser;
    return HistoryResult(
      kind: kind,
      sentence: byUser ? '직접 멈췄어요' : safety ? '안전 정지' : '정지됨',
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
        next: '다시 누르지 않았어요 · 장치를 확인해 주세요',
        mockNote: mockNote,
      );
    }
    return HistoryResult(
      kind: kind,
      sentence: e.termination == 'retries_exhausted'
          ? '다시 눌러도 확인하지 못해 안전 정지'
          : '안전 정지',
      mockNote: mockNote,
    );
  }

  // 이미 목표값(2026-10-14): 보내지 않은 성공 — '보내지 않았어요·연결 확인'이나 '바꿨어요'로 말하지 않는다.
  if (thinq && kind == ResultKind.success && e.confirmation == 'already_at_target') {
    return HistoryResult(
      kind: kind,
      sentence: mock
          ? '연습 · 이미 그 설정이라 변경 명령을 보내지 않았어요'
          : '이미 그 설정이라 변경 명령을 보내지 않았어요',
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
          kind: kind, sentence: '명령을 보내지 않았어요', next: '연결 상태를 확인해 주세요');
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
          sentence: '보냈지만 설정이 바뀌었는지 확인하지 못했어요',
          next: '다시 보내기 전에 $checkTarget',
        ),
      _ => HistoryResult(
          kind: kind, sentence: '가전이 명령을 실행하지 않았어요', next: checkTarget),
    };
  }

  // 물리(옛 기록의 unknown 경로 포함).
  switch (kind) {
    case ResultKind.success:
      if (e.confirmation == 'operation_confirmed' && e.executionMode == 'real') {
        return HistoryResult(kind: kind, sentence: '가전이 켜진 것을 확인했어요');
      }
      if (e.confirmation == 'press_confirmed') {
        return HistoryResult(
            kind: kind,
            sentence: '버튼을 눌렀어요',
            next: '$target 동작을 확인해 주세요');
      }
      return HistoryResult(
          kind: kind, sentence: '버튼 조작을 마쳤어요', next: checkTarget);
    case ResultKind.unconfirmed:
      return HistoryResult(
          kind: kind, sentence: '눌렸는지 확인하지 못했어요', next: checkTarget);
    case ResultKind.failed:
      if (e.receipt == 'not_dispatched') {
        return HistoryResult(
            kind: kind, sentence: '누름 장치에 보내지 못했어요', next: '연결 상태를 확인해 주세요');
      }
      if (e.termination == 'retries_exhausted') {
        return HistoryResult(
            kind: kind, sentence: '다시 눌러도 확인하지 못했어요', next: checkTarget);
      }
      return HistoryResult(
          kind: kind,
          sentence: '끝까지 실행하지 못했어요',
          next: '$target 상태를 확인해 주세요');
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
