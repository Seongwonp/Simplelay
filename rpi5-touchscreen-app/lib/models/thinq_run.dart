/// LG 가전(클라우드로 바꾸는 가전) 실행의 간단한 화면 말(사용자 요청 10/18).
///
/// 작은 팔이 누르지 않는 실행에 버튼판·누를 순서·작은 팔 문구를 보이지 않는다 — 보내는 동안은 기다림 표시와
/// '공기청정기에 명령을 보내는 중이에요' 한 줄, 끝나면 결과 창 하나. 결과는 **서버가 준 확인 수준만큼** 말한다:
/// - `state_confirmed`(보내기 전 다른 값 → 보낸 뒤 목표값): 바뀐 결과('공기청정기가 켜졌어요', '바람 세기 강으로 바꿨어요').
/// - `state_confirmed_unknown_before`(보낸 뒤 목표값, 전 값 모름): 본 상태('공기청정기가 켜져 있어요') — '바꿨어요'라고 하지 않는다.
/// - `already_at_target`(이미 목표값, 보내지 않음): '이미 켜져 있어요'.
/// - 확인 못 함(`unconfirmed`): 체크 없이 '명령은 보냈어요' + '가전에서 확인해 주세요'.
/// 실패·정지는 이 화면이 아니라 기존 결과 화면이 말한다.
///
/// 어느 설정인지는 서버 문장([detail], 그 실행의 기록 — `rpi/services/thinq/wording.py`)에서만 읽는다. 전원은
/// '전원 켜기'·'전원 끄기'(서버 설정 이름)로 가른다. 모르면 일반 문장.
library;

import 'command_result.dart';
import 'josa.dart';

/// 결과 창의 뜻(색·아이콘). 확인한 결과만 [confirmed](초록 체크).
enum ThinqResultTone { confirmed, attention, practice }

class ThinqResultCopy {
  const ThinqResultCopy({required this.headline, required this.sub, required this.tone});

  /// 가장 큰 글자(마침표 없음).
  final String headline;

  /// 그 아래 한 줄(마침표 없음).
  final String sub;
  final ThinqResultTone tone;

  /// 음성·화면 읽기용 한 문장.
  String get spoken => '$headline. $sub.';
}

/// 이 실행을 간단한 LG 가전 화면으로 보일까 — 승인에 묶인 명령이 **LG 가전 명령 하나**일 때만.
/// 작은 팔 단계가 섞였거나(루틴) 여러 단계면 기존 화면(단계별 결과)을 쓴다.
bool isSingleThinqCommand(Iterable<String> routes) => routes.length == 1 && routes.single == 'thinq';

/// 보내는 중 한 줄.
String thinqSendingLine(String applianceName, {bool practice = false}) =>
    practice ? '$applianceName에 연습으로 보내는 중이에요' : '$applianceName에 명령을 보내는 중이에요';

/// 보내는 중 아래 작은 한 줄.
String thinqSendingSub({bool practice = false}) =>
    practice ? '실제 가전에는 보내지 않아요' : '바뀐 것을 확인하면 알려 드릴게요';

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

/// 전원 켜기·끄기 결과인가(서버 설정 이름 '전원 켜기'·'전원 끄기'). 아니면 null.
bool? _powerOn(String? detail) {
  final d = detail ?? '';
  if (d.contains('전원 켜기')) return true;
  if (d.contains('전원 끄기')) return false;
  return null;
}

/// 끝난 LG 가전 실행의 결과 창 말. 성공(확인 수준별)과 확인 못 함만 — 실패·정지는 null(기존 화면).
ThinqResultCopy? thinqResultCopy({
  required String applianceName,
  required ResultKind kind,
  String? receipt,
  String? confirmation,
  String? detail,
  String executionMode = 'unknown',
}) {
  if (kind != ResultKind.success && kind != ResultKind.unconfirmed) return null;
  final mock = executionMode == 'mock';
  if (mock) {
    return ThinqResultCopy(
      headline: kind == ResultKind.success
          ? '연습을 마쳤어요'
          : receipt == 'unknown'
              ? '연습 명령이 닿았는지 몰라요'
              : '연습 명령은 보냈어요',
      sub: '실제 가전은 바꾸지 않았어요',
      tone: ThinqResultTone.practice,
    );
  }
  const verifiedLevels = {'state_confirmed', 'state_confirmed_unknown_before', 'already_at_target'};
  // 확인한 성공은 실제 실행(real)에서 서버가 상태를 다시 읽은 것뿐이다(실행 환경을 모르면 단정하지 않는다).
  if (kind == ResultKind.success && executionMode == 'real' && verifiedLevels.contains(confirmation)) {
    final power = _powerOn(detail);
    final d = detail?.trim() ?? '';
    final who = withSubject(applianceName);
    switch (confirmation) {
      case 'already_at_target':
        return ThinqResultCopy(
          headline: power == null ? '이미 그 설정이에요' : '이미 ${power ? '켜져' : '꺼져'} 있어요',
          sub: power == null && d.isNotEmpty ? '${_firstSentence(d)}. 명령은 보내지 않았어요' : '그래서 명령은 보내지 않았어요',
          tone: ThinqResultTone.confirmed,
        );
      case 'state_confirmed':
        return ThinqResultCopy(
          headline: power == null
              ? (d.contains('바꿨어요') ? _firstSentence(d) : '$applianceName 설정을 바꿨어요')
              : '$who ${power ? '켜졌어요' : '꺼졌어요'}',
          sub: '가전에서 바뀐 것을 확인했어요',
          tone: ThinqResultTone.confirmed,
        );
      default: // state_confirmed_unknown_before — 전 값을 몰라 '바꿨어요'·'켜졌어요'라고 하지 않는다.
        return ThinqResultCopy(
          headline: power == null
              ? (d.contains('설정된 것을 확인') ? _firstSentence(d) : '원하는 설정인 것을 봤어요')
              : '$who ${power ? '켜져' : '꺼져'} 있어요',
          sub: '가전에서 확인했어요',
          tone: ThinqResultTone.confirmed,
        );
    }
  }
  // 보냈지만 확인하지 못했다 — 체크 없이, 사람이 가전을 본다. 받았는지조차 모르면 다시 보내기 전에 보라고 한다.
  if (receipt == 'unknown') {
    return const ThinqResultCopy(
      headline: '명령이 전해졌는지 몰라요',
      sub: '다시 보내기 전에 가전을 봐 주세요',
      tone: ThinqResultTone.attention,
    );
  }
  return const ThinqResultCopy(
    headline: '명령은 보냈어요',
    sub: '가전에서 확인해 주세요',
    tone: ThinqResultTone.attention,
  );
}
