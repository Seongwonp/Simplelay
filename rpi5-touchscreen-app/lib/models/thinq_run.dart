/// LG 가전(클라우드로 바꾸는 가전) 실행의 간단한 화면 말(사용자 요청 10/18, 평가 10차 10/18).
///
/// 작은 팔이 누르지 않는 실행에 버튼판·누를 순서·작은 팔 문구를 보이지 않는다 — 보내는 동안은 기다림 표시와
/// **하려는 일** 한 줄('공기청정기를 켜고 있어요'), 끝나면 결과 창 하나. '명령'은 엔지니어 말이라 화면에 쓰지 않는다
/// (평가 10차 10/18). 결과는 **서버가 준 확인 수준만큼** 말한다:
/// - `state_confirmed`(보내기 전 다른 값 → 보낸 뒤 목표값): 바뀐 결과('공기청정기가 켜졌어요') + '가전에서 확인했어요'(이름은 제목에 한 번,
///   평가 14차 10/18).
/// - `state_confirmed_unknown_before`(보낸 뒤 목표값, 전 값 모름): 본 상태('공기청정기가 켜져 있어요') — '바꿨어요'라고 하지 않는다.
/// - `already_at_target`(이미 목표값, 보내지 않음): '이미 켜져 있어요' + '그대로 두었어요'.
/// - 확인 못 함(`unconfirmed`): 체크 없이 '공기청정기에 켜 달라고 했어요' + '켜졌는지는 아직 몰라요'
///   (평가 11차 10/18 — 누가 누구에게인지 알게 제목에 가전 이름. 평가 15차 10/18 — '켜기를 보냈어요'는 기계가 한 일이었다.
///   무엇을 볼지는 결과 화면의 번호 안내가 한 번만 말한다).
/// 실패·정지는 이 화면이 아니라 기존 결과 화면이 말한다.
///
/// 어느 설정인지는 승인에 묶인 명령의 서버 문장(`commands[].summary` — '공기청정기 전원 켜기'), LG 가전 상세에서 고른
/// 이름('공기청정기 바람 세기 강으로 바꾸기'), 또는 결과의 서버 문장([detail] — `rpi/services/thinq/wording.py`)에서만
/// 읽는다. 모르면 일반 문장(지어내지 않는다).
library;

import 'action_name.dart';
import 'command_result.dart';
import 'josa.dart';

/// 결과 창의 뜻(색·아이콘). 확인한 결과만 [confirmed](초록 체크).
enum ThinqResultTone { confirmed, attention, practice }

class ThinqResultCopy {
  const ThinqResultCopy({required this.headline, required this.sub, required this.tone});

  /// 가장 큰 글자(마침표 없음).
  final String headline;

  /// 그 아래 한두 줄(마침표 없음, 두 줄이면 줄바꿈).
  final String sub;
  final ThinqResultTone tone;

  /// 음성·화면 읽기용 한 문장.
  String get spoken => '$headline. ${sub.replaceAll('\n', '. ')}.';
}

/// 이 실행을 간단한 LG 가전 화면으로 보일까 — 승인에 묶인 명령이 **LG 가전 명령 하나**일 때만.
/// 작은 팔 단계가 섞였거나(루틴) 여러 단계면 기존 화면(단계별 결과)을 쓴다.
bool isSingleThinqCommand(Iterable<String> routes) => routes.length == 1 && routes.single == 'thinq';

/// 이어받은 실행(폰·다른 단말이 시작한 실행)을 LG 가전 화면으로 보일까(평가 10차 10/18 — 폰에서 켠 공기청정기가
/// 키오스크에 '준비 중' 빈 화면으로 보였다). 서버 /status가 지금 단계의 경로를 `thinq`로, 전체 단계 수를 **1**로
/// 말하고, 대상 가전을 알면 그 가전도 LG 가전일 때만. 경로·단계 수를 모르면(옛 서버) 종전 화면 — 작은 팔이 누르는
/// 실행을 LG 가전 화면으로 잘못 보이지 않게.
bool isAdoptedThinqRun({String? route, int? totalSteps, bool? applianceIsThinq}) =>
    route == 'thinq' && totalSteps == 1 && applianceIsThinq != false;

/// 하려는 일의 종류.
enum ThinqActionKind { powerOn, powerOff, wind, other }

/// 하려는 일 하나(평가 10차 10/18) — 보내는 중 위 띠·큰 글씨, 확인 못 함 결과에 같은 말.
class ThinqAction {
  const ThinqAction._(this.kind, this.applianceName, {this.windWord});

  final ThinqActionKind kind;
  final String applianceName;

  /// 바람 세기 값 말('세게'·'약하게'·'중간으로'·'자동으로'). 바람이 아니면 null.
  final String? windWord;

  String get _obj => '$applianceName${_objectParticle(applianceName)}';

  /// 위 띠 이름 — '공기청정기 켜기' · '공기청정기 바람 세게'. 모르면 가전 이름.
  String get title => switch (kind) {
        ThinqActionKind.powerOn => '$applianceName 켜기',
        ThinqActionKind.powerOff => '$applianceName 끄기',
        ThinqActionKind.wind => '$applianceName 바람 $windWord',
        ThinqActionKind.other => applianceName,
      };

  /// 보내는 중 큰 글씨 — '공기청정기를 켜고 있어요' · '바람을 세게 바꾸고 있어요'.
  String get doing => switch (kind) {
        ThinqActionKind.powerOn => '$_obj 켜고 있어요',
        ThinqActionKind.powerOff => '$_obj 끄고 있어요',
        ThinqActionKind.wind => '바람을 $windWord 바꾸고 있어요',
        ThinqActionKind.other => '$applianceName 설정을 바꾸고 있어요',
      };

  /// 확인 못 함 결과의 큰 글자 — 어느 가전에 무엇을 부탁했는지(평가 11차 10/18, 가전 이름 포함). '명령'(평가 10차)·
  /// '보냈어요'(기계가 한 일, 평가 15차 10/18)는 쓰지 않는다 — '공기청정기에 켜 달라고 했어요'.
  String get asked => switch (kind) {
        ThinqActionKind.powerOn => '$applianceName에 켜 달라고 했어요',
        ThinqActionKind.powerOff => '$applianceName에 꺼 달라고 했어요',
        ThinqActionKind.wind => '$applianceName에 바람을 $windWord 해 달라고 했어요',
        ThinqActionKind.other => '$applianceName에 설정을 바꿔 달라고 했어요',
      };

  /// 확인 못 함 결과의 아래 줄 — 아직 모른다는 것.
  String get unknown => switch (kind) {
        ThinqActionKind.powerOn => '켜졌는지는 아직 몰라요',
        ThinqActionKind.powerOff => '꺼졌는지는 아직 몰라요',
        ThinqActionKind.wind => '바람이 $windWord 바뀌었는지는 아직 몰라요',
        ThinqActionKind.other => '바뀌었는지는 아직 몰라요',
      };
}

const _windWords = {'강': '세게', '약': '약하게', '중': '중간으로', '자동': '자동으로'};

/// [texts](명령 요약·고른 이름·실행 이름, 앞에 둔 것이 먼저) 중 처음 알아본 것으로 하려는 일을 정한다.
/// [serverSentence]면(결과 서버 문장) 설정 이름('전원 켜기'·'바람 세기 강')만 본다 — 안내 문장의 '꺼 주세요' 같은
/// 끝 동사를 하려던 일로 읽지 않게.
ThinqAction thinqActionOf(String applianceName, Iterable<String?> texts, {bool serverSentence = false}) {
  for (final raw in texts) {
    final t = raw?.trim() ?? '';
    if (t.isEmpty) continue;
    if (t.contains('전원 켜기')) return ThinqAction._(ThinqActionKind.powerOn, applianceName);
    if (t.contains('전원 끄기')) return ThinqAction._(ThinqActionKind.powerOff, applianceName);
    final m = RegExp(r'(?:바람 세기|풍량)\s*(강|약|중|자동)').firstMatch(t);
    if (m != null) {
      return ThinqAction._(ThinqActionKind.wind, applianceName, windWord: _windWords[m.group(1)]);
    }
    // 사람 말 실행 이름('공기청정기를 켤까요?'·'공기청정기 켜줘')은 행동 이름으로 바꿔 끝 동사만 본다.
    if (serverSentence) continue;
    final act = actionName(t);
    if (act.endsWith(' 켜기')) return ThinqAction._(ThinqActionKind.powerOn, applianceName);
    if (act.endsWith(' 끄기')) return ThinqAction._(ThinqActionKind.powerOff, applianceName);
  }
  return ThinqAction._(ThinqActionKind.other, applianceName);
}

String _objectParticle(String word) {
  final t = word.trim();
  if (t.isEmpty) return '를';
  final code = t.runes.last;
  if (code < 0xAC00 || code > 0xD7A3) return '을';
  return (code - 0xAC00) % 28 == 0 ? '를' : '을';
}

/// 보내는 중 한 줄. 연습은 실제 가전을 바꾸지 않는다 — 하려는 일 앞에 '연습으로'.
String thinqSendingLine(ThinqAction action, {bool practice = false}) =>
    practice ? '연습으로 ${action.doing}' : action.doing;

/// 보내는 중 아래 작은 한 줄.
String thinqSendingSub({bool practice = false}) =>
    practice ? '실제 가전은 그대로예요' : '바뀐 것을 확인하면 알려 드릴게요';

/// 보내는 중 정지 단추 옆 한 문장(평가 10차 10/18, 한 문장은 평가 12차) — 서버 /stop이 실제로 하는 일만: 아직 가전에 전하지 않았으면
/// 전하지 않고(ThinQ 실행기의 보내기 직전 확인), 이미 전했으면 되돌리지 않고 확인만 그만둔다(취소·반대 명령 없음). 평가 14차(10/18) —
/// '이미 바뀐 설정은 그대로일 수 있어요'는 엔지니어 설명투였다. 평가 15차(10/18) — '보내다'는 기계가 한 일이라 '더 하지 않아요'로:
/// 그 뒤의 일만 말하고, 이미 바뀐 것을 되돌린다고 약속하지 않는다.
const kThinqStopNote = '정지를 누르면 더 하지 않아요';

String _trimDot(String s) {
  var t = s.trim();
  while (t.endsWith('.')) {
    t = t.substring(0, t.length - 1).trimRight();
  }
  return t;
}

/// 서버 문장의 첫 문장(이미 목표값 문장은 '…설정돼 있어요. 그래서 보내지 않았어요.' 두 문장이다).
String _firstSentence(String detail) {
  final i = detail.indexOf('.');
  return _trimDot(i < 0 ? detail : detail.substring(0, i));
}

/// 끝난 LG 가전 실행의 결과 창 말. 성공(확인 수준별)과 확인 못 함만 — 실패·정지는 null(기존 화면).
/// [action]은 하려던 일(모르면 [detail]로 알아본다).
ThinqResultCopy? thinqResultCopy({
  required String applianceName,
  required ResultKind kind,
  String? receipt,
  String? confirmation,
  String? detail,
  String executionMode = 'unknown',
  ThinqAction? action,
}) {
  if (kind != ResultKind.success && kind != ResultKind.unconfirmed) return null;
  final act = action != null && action.kind != ThinqActionKind.other
      ? action
      : thinqActionOf(applianceName, [detail], serverSentence: true);
  final mock = executionMode == 'mock';
  if (mock) {
    return ThinqResultCopy(
      headline: kind == ResultKind.success
          ? '연습을 마쳤어요'
          : receipt == 'unknown'
              ? '연습이 전해졌는지 몰라요'
              : '연습으로 부탁했어요',
      sub: '실제 가전은 바꾸지 않았어요',
      tone: ThinqResultTone.practice,
    );
  }
  const verifiedLevels = {'state_confirmed', 'state_confirmed_unknown_before', 'already_at_target'};
  // 확인한 성공은 실제 실행(real)에서 서버가 상태를 다시 읽은 것뿐이다(실행 환경을 모르면 단정하지 않는다).
  if (kind == ResultKind.success && executionMode == 'real' && verifiedLevels.contains(confirmation)) {
    // 바뀐 결과의 전원은 결과 서버 문장이 먼저(실제로 확인한 설정), 없으면 하려던 일.
    final fromDetail = thinqActionOf(applianceName, [detail], serverSentence: true);
    final seen = fromDetail.kind != ThinqActionKind.other ? fromDetail : act;
    final power = switch (seen.kind) {
      ThinqActionKind.powerOn => true,
      ThinqActionKind.powerOff => false,
      _ => null,
    };
    final d = detail?.trim() ?? '';
    final who = withSubject(applianceName);
    switch (confirmation) {
      case 'already_at_target':
        return ThinqResultCopy(
          headline: power == null ? '이미 그 설정이에요' : '이미 ${power ? '켜져' : '꺼져'} 있어요',
          sub: power == null && d.isNotEmpty ? '${_firstSentence(d)}. 그대로 두었어요' : '그대로 두었어요',
          tone: ThinqResultTone.confirmed,
        );
      case 'state_confirmed':
        // 위 띠 '됐어요'·제목 '켜졌어요'와 같은 뜻을 또 쓰지 않는다 — 아래 줄은 어디서 확인했는지만(평가 10차 10/18).
        // 가전 이름은 제목에 이미 있다 — 아래 줄은 '가전에서'(평가 14차 10/18).
        return ThinqResultCopy(
          headline: power == null
              ? (d.contains('바꿨어요') ? _firstSentence(d) : '$applianceName 설정을 바꿨어요')
              : '$who ${power ? '켜졌어요' : '꺼졌어요'}',
          sub: '가전에서 확인했어요',
          tone: ThinqResultTone.confirmed,
        );
      default: // state_confirmed_unknown_before — 전 값을 몰라 '바꿨어요'·'켜졌어요'라고 하지 않는다.
        return ThinqResultCopy(
          headline: power == null
              ? (d.contains('설정된 것을 확인') ? _firstSentence(d) : '원하는 설정인 것을 봤어요')
              : '$who ${power ? '켜져' : '꺼져'} 있어요',
          sub: '지금 상태를 가전에서 봤어요',
          tone: ThinqResultTone.confirmed,
        );
    }
  }
  // 부탁했지만 확인하지 못했다 — 체크 없이, 사람이 가전을 본다. 받았는지조차 모르면 다시 하기 전에 보라고 한다.
  if (receipt == 'unknown') {
    return ThinqResultCopy(
      headline: '$applianceName에 전해졌는지 몰라요',
      sub: '다시 하기 전에 가전을 봐 주세요',
      tone: ThinqResultTone.attention,
    );
  }
  // 아래 줄은 아직 모른다는 것만(평가 15차 10/18) — 무엇을 볼지는 결과 화면의 번호 안내가 한 번만 말한다('가전을 봐 주세요'를 또 두지 않는다).
  return ThinqResultCopy(
    headline: act.asked,
    sub: act.unknown,
    tone: ThinqResultTone.attention,
  );
}
