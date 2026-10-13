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
              thinq ? '모의 명령 처리 중' : '모의 버튼 조작 중$count', TileTone.active,
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
      return r.canExecute
          ? const TileStatus('실행을 요청할 수 있어요', TileTone.ready)
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
  if (purpose != null && purpose.isNotEmpty) return purpose;
  final labels = [
    for (final b in e.buttons)
      if (b.button.trim().isNotEmpty) b.button.trim(),
  ];
  final name = applianceName?.trim();
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

  /// 모의 기록에만: "연습(모의) · 실제로 누르지 않았어요". 그 밖에는 null.
  final String? mockNote;
}

/// 결과 문장(검토 §5 표). 선택 순서: executionMode → resultKind(outcome 우선) →
/// route·receipt·termination·confirmation. 정지·안전 정지는 기존 문장을 그대로 쓴다.
HistoryResult historyResult(RpiHistoryEntry e, {String? applianceName}) {
  final kind = resultKindOf(outcome: e.outcome, status: e.status);
  final mock = e.executionMode == 'mock';
  final thinq = e.route == 'thinq';
  final name = applianceName?.trim();
  final target = (name == null || name.isEmpty) ? '가전' : name;
  final checkTarget = '$target${objectParticle(target)} 직접 확인해 주세요';
  final mockNote = !mock
      ? null
      : thinq
          ? '연습(모의) · 실제 가전에 명령하지 않았어요'
          : '연습(모의) · 실제로 누르지 않았어요';

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
    return HistoryResult(
      kind: kind,
      sentence: e.termination == 'retries_exhausted'
          ? '다시 눌러도 확인하지 못해 안전 정지'
          : '안전 정지',
      mockNote: mockNote,
    );
  }

  final base = _liveResult(e, kind, thinq: thinq, target: target, checkTarget: checkTarget);
  if (!mock) return base;
  // 모의 기록: 성공 문장은 모의라고 말하고, 실제 가전 확인을 부탁하지 않는다.
  return HistoryResult(
    kind: kind,
    sentence: kind == ResultKind.success
        ? (thinq ? '모의 상태만 확인했어요' : '모의 버튼 조작을 마쳤어요')
        : base.sentence,
    next: kind == ResultKind.success ? null : '연습 결과를 확인해 주세요',
    mockNote: mockNote,
  );
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
      ResultKind.success => HistoryResult(kind: kind, sentence: '가전 상태를 확인했어요'),
      // 접수 여부(받았는지 모름·접수됨)는 아래 보조 줄이 말한다. 다시 보내라고 권하지 않는다.
      ResultKind.unconfirmed => HistoryResult(
          kind: kind,
          sentence: '보냈지만 확인하지 못했어요',
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
