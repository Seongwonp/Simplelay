import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/server_appliance_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';

/// 2026-10-13 폰 UI B안 — 타일 상태·기록 제목·결과 문구의 판단 함수.
/// 근거: 검토 보고서 §3(타일)·§5(기록).

ApplianceMap _server(Map<String, dynamic> extra) => ApplianceMap.fromJson({
      'id': 'mw',
      'name': '전자레인지',
      'rows': 1,
      'cols': 1,
      'buttons': const [],
      'is_custom': false,
      ...extra,
    });

final _plain = _server(const {}); // 서버 판정 없음(readinessKnown=false)

TileStatus _tile({
  ApplianceMap? appliance,
  ApplianceMap? source,
  RpiConnectionState hub = RpiConnectionState.connected,
  ServerCatalogStatus catalog = ServerCatalogStatus.loaded,
  ExecutionStatus execution = const ExecutionStatus(),
  bool thinqOn = false,
  bool thinqOff = false,
}) =>
    applianceTileStatus(
      appliance: appliance ?? _plain,
      readinessSource: source,
      hub: hub,
      catalog: catalog,
      execution: execution,
      thinqOn: thinqOn,
      thinqOff: thinqOff,
    );

RpiHistoryEntry _entry(Map<String, dynamic> extra) => RpiHistoryEntry.fromJson({
      'job_id': 'j',
      'finished_at': '2026-10-13T08:00:00+09:00',
      'status': 'succeeded',
      'retry_count': 0,
      'buttons': const [],
      ...extra,
    });

List<Map<String, dynamic>> _buttons(List<String> labels) => [
      for (final l in labels) {'button': l, 'success': true, 'attempts': 1},
    ];

void main() {
  group('타일 — 실행 중', () {
    ExecutionStatus run(ExecutionPhase p, {String mode = 'unknown', bool demo = false}) =>
        ExecutionStatus(
          phase: p,
          applianceId: 'mw',
          executionMode: mode,
          isDemo: demo,
        );

    test('"돌아가는 중"이라고 말하지 않는다 — real은 버튼 조작 중', () {
      final s = _tile(execution: run(ExecutionPhase.running, mode: 'real'));
      expect(s.text, '버튼 누르는 중');
      expect(s.text.contains('돌아가'), isFalse);
      expect(s.progress, isTrue);
    });

    test('mock·데모 실행은 연습 버튼 조작 중', () {
      expect(_tile(execution: run(ExecutionPhase.retrying, mode: 'mock')).text,
          '연습으로 누르는 중');
      expect(_tile(execution: run(ExecutionPhase.running, demo: true)).text,
          '연습으로 누르는 중');
    });

    test('모드를 모르면 real·mock을 추정하지 않는다', () {
      expect(_tile(execution: run(ExecutionPhase.running)).text, '하는 중이에요');
    });

    test('waiting은 누르는 중이 아니다', () {
      expect(_tile(execution: run(ExecutionPhase.waiting, mode: 'real')).text,
          '차례를 기다려요');
    });

    test('연결이 끊겨 모르면 준비됨으로 덮지 않는다', () {
      final ready = _server(const {'can_execute': true, 'readiness': 'operable'});
      expect(
          _tile(source: ready, execution: run(ExecutionPhase.unknown)).text,
          '지금 상태를 몰라요');
    });

    test('다른 가전의 실행·끝난 실행은 이 타일의 상태가 아니다', () {
      const other = ExecutionStatus(
          phase: ExecutionPhase.running, applianceId: 'washer', executionMode: 'real');
      expect(_tile(execution: other).text, '준비됐는지 몰라요');
      const done = ExecutionStatus(
        phase: ExecutionPhase.completed,
        applianceId: 'mw',
        executionMode: 'real',
        operationConfirmed: true,
        operationSource: 'real',
      );
      // 과거의 CT 판정(operationConfirmed)을 지금의 운전으로 옮기지 않는다.
      final s = _tile(execution: done);
      expect(s.text, '준비됐는지 몰라요');
      expect(s.tone, isNot(TileTone.active));
    });
  });

  group('타일 — 준비 상태', () {
    test('서버 판정이 없으면 canExecute 기본 true로 긍정하지 않는다', () {
      expect(_plain.canExecute, isTrue, reason: '모델 기본값이 true다');
      final s = _tile(source: _plain);
      expect(s.text, '준비됐는지 몰라요');
      expect(s.tone, TileTone.unknown);
      expect(_tile(source: null).text, '준비됐는지 몰라요');
    });

    test('operable + canExecute는 상태 줄을 비운다(평소 상태는 말하지 않는다, 2026-10-14)', () {
      final s = _tile(source: _server(const {'can_execute': true, 'readiness': 'operable'}));
      expect(s.text, '');
      expect(s.tone, TileTone.ready);
    });

    // 외부 평가 10/16: 가전 타일에 상태가 없다(키오스크는 켜진 ThinQ 가전에 초록 '켜짐').
    test('켜진 ThinQ 가전은 준비된 타일에 "켜짐"(초록) — 서버 전원 기억이 켜짐일 때만', () {
      final thinq = _server(const {
        'id': 'air_purifier',
        'name': '공기청정기',
        'control_path': 'thinq',
        'can_execute': true,
        'readiness': 'operable',
      });
      final on = _tile(appliance: thinq, source: thinq, thinqOn: true);
      expect(on.text, '켜져 있어요'); // 띠는 문장(평가 7차 10/18)
      expect(on.tone, TileTone.on);
      expect(_tile(appliance: thinq, source: thinq).text, kThinqUncheckedText, reason: '모르면 "확인 전이에요" — 손 아이콘 준비됐어요가 아니다(휴리스틱 평가 10/18)');
      // 물리 가전에는 붙이지 않는다(전원 기억은 ThinQ 클라우드 상태다).
      final physical = _server(const {'can_execute': true, 'readiness': 'operable'});
      expect(_tile(source: physical, thinqOn: true).text, '');
      // 허브 장애·준비 문제가 '켜짐'보다 앞선다.
      expect(_tile(appliance: thinq, source: thinq, thinqOn: true,
              hub: RpiConnectionState.unreachable).text,
          '본체 연결을 봐 주세요');
    });

    // 2026-10-18 홈 개편: LG 가전은 서버가 **읽은** 꺼짐일 때만 '꺼짐' — 모르면 비운다.
    test('LG 가전은 서버가 읽은 꺼짐일 때만 "꺼짐", 모르면 비운다(초록·체크 아님)', () {
      final thinq = _server(const {
        'id': 'air_purifier',
        'name': '공기청정기',
        'control_path': 'thinq',
        'can_execute': true,
        'readiness': 'operable',
      });
      final off = _tile(appliance: thinq, source: thinq, thinqOff: true);
      expect(off.text, '꺼져 있어요');
      expect(off.tone, TileTone.off);
      expect(_tile(appliance: thinq, source: thinq).text, kThinqUncheckedText);
      final physical = _server(const {'can_execute': true, 'readiness': 'operable'});
      expect(_tile(source: physical, thinqOff: true).text, '', reason: '버튼식 가전에는 붙이지 않는다');
      expect(_tile(appliance: thinq, source: thinq, thinqOff: true,
              hub: RpiConnectionState.unreachable).text,
          '본체 연결을 봐 주세요');
    });

    test('상충하는 응답은 긍정으로 정규화하지 않는다', () {
      for (final r in ['disconnected', 'needs_setup']) {
        expect(_tile(source: _server({'can_execute': true, 'readiness': r})).text,
            '지금 할 수 있는지 봐 주세요');
      }
      expect(
          _tile(source: _server(const {'can_execute': false, 'readiness': 'operable'})).text,
          '지금 할 수 있는지 봐 주세요');
    });

    test('needs_setup은 "준비가 필요해요" + 서버의 실제 이유(비상정지 포함)', () {
      final s = _tile(
          source: _server(const {
        'can_execute': false,
        'readiness': 'needs_setup',
        'readiness_reasons': ['비상정지가 걸려 있어요'],
      }));
      expect(s.text, '설정이 필요해요');
      expect(s.detail, '비상정지가 걸려 있어요');
    });

    test('disconnected는 "연결이 필요해요"', () {
      final s = _tile(
          source: _server(const {'can_execute': false, 'readiness': 'disconnected'}));
      expect(s.text, '연결이 필요해요');
      expect(s.detail, isNull);
    });

    test('모르는 state는 미확인', () {
      expect(_tile(source: _server(const {'can_execute': true, 'readiness': 'weird'})).text,
          '준비됐는지 몰라요');
    });

    test('위치를 맞추지 않은 사용자 가전은 "설정이 필요해요"', () {
      final custom = ApplianceMap.fromJson({
        'id': 'mw',
        'name': '전자레인지',
        'rows': 1,
        'cols': 1,
        'buttons': const [],
      });
      expect(custom.isCustom, isTrue);
      final ready = _server(const {'can_execute': true, 'readiness': 'operable'});
      expect(_tile(appliance: custom, source: ready).text, '설정이 필요해요');
    });

    test('허브 장애가 서버 판정보다 앞선다', () {
      final ready = _server(const {'can_execute': true, 'readiness': 'operable'});
      expect(_tile(source: ready, hub: RpiConnectionState.unreachable).text,
          '본체 연결을 봐 주세요');
      expect(_tile(source: ready, hub: RpiConnectionState.keyRequired).text,
          '본체 연결 설정이 필요해요');
      expect(_tile(source: ready, hub: RpiConnectionState.checking).text, '확인하는 중이에요');
      expect(_tile(source: ready, catalog: ServerCatalogStatus.loading).text,
          '확인하는 중이에요');
      expect(_tile(source: ready, catalog: ServerCatalogStatus.failed).text,
          '본체 연결을 봐 주세요');
    });
  });

  group('기록 제목', () {
    // 평가 3차 10/18: 제목 규칙은 하나 — 행동 이름('즉석밥 데우기'). 무엇을 데웠는지는 바꾸지 않는다.
    test('비어 있지 않은 purpose는 그 행동의 이름으로(대상은 바꾸지 않는다)', () {
      expect(historyTitle(_entry({'purpose': '즉석밥 데워줘'})), '즉석밥 데우기');
    });

    test('purpose 없음 → 등록 이름 + 버튼 라벨', () {
      final e = _entry({'buttons': _buttons(['문열림'])});
      expect(historyTitle(e, applianceName: '인터폰'), '인터폰 문열림 버튼 누르기');
    });

    test('빈 문자열 purpose도 없음으로 본다', () {
      final e = _entry({'purpose': '  ', 'buttons': _buttons(['문열림'])});
      expect(historyTitle(e, applianceName: '인터폰'), '인터폰 문열림 버튼 누르기');
    });

    test('버튼이 없으면 이름 + 버튼 누르기(LG 가전은 설정 바꾸기)', () {
      expect(historyTitle(_entry(const {}), applianceName: '인터폰'), '인터폰 버튼 누르기');
      expect(historyTitle(_entry(const {'route': 'thinq'}), applianceName: '세탁기'),
          '세탁기 설정 바꾸기');
    });

    test('모두 없으면 "버튼 누르기" — 목적을 지어내지 않는다', () {
      expect(historyTitle(_entry(const {'purpose': ''})), '버튼 누르기');
    });

    // 외부 평가 10/16 2차 p03: 제목이 발화문 / ''…' 루틴' / '자동 실행 · …' 세 형식으로 섞였다.
    // 제목은 무엇을 했는지, 출처(루틴·자동 실행)는 아래 시각 줄로 — 확실히 아는 출처만.
    // UI 평가 4차 10/17: 시각만 있는 줄은 누가 실행했는지 몰랐다 — 자동 실행·루틴이 아니면 사람이 시작한 실행이다.
    test('제목은 한 일만, 출처는 따로(자동 실행·루틴·그 밖은 직접 실행)', () {
      final auto = _entry({'purpose': '자동 실행 · 공기청정기 전원 켜기'});
      expect(historyTitle(auto), '공기청정기 켜기');
      expect(historySource(auto), '자동');
      final routine = _entry({'purpose': "'아침 공기청정기 끄기' 루틴을 실행할까요?"});
      expect(historyTitle(routine), '아침 공기청정기 끄기');
      expect(historySource(routine), '루틴');
      final direct = _entry({'purpose': '공기청정기 켜줘'});
      expect(historyTitle(direct), '공기청정기 켜기');
      // 말로 한 명령·제안 승인·화면 조작은 모두 사람이 시작했다 — 어느 쪽인지는 지어내지 않고 '직접'.
      expect(historySource(direct), '직접');
      expect(historySource(_entry(const {})), '직접');
      // 시각 규칙 자동 실행은 서버가 루틴 이름으로 적는다 — 제목은 루틴 탭과 같은 이름, 출처는 자동 실행(UI 평가 5차 10/17).
      final timed = _entry({'purpose': "자동 실행 · '아침 공기청정기 끄기' 루틴"});
      expect(historyTitle(timed), '아침 공기청정기 끄기');
      expect(historySource(timed), '자동');
    });

    test('이름을 모르면 버튼만 — 여럿이면 키오스크와 같은 단위 "버튼 N번"', () {
      expect(historyTitle(_entry({'buttons': _buttons(['즉석밥', '시작'])})),
          '버튼 2번 누르기');
      expect(historyTitle(_entry({'buttons': _buttons(['즉석밥'])})), '즉석밥 버튼 누르기');
    });
  });

  group('기록 결과·다음 행동', () {
    test('모의 성공 — 연습 한 줄은 mock 기록에만(결과 문장이 그 한 줄, 2026-10-14)', () {
      final r = historyResult(_entry(const {
        'outcome': 'success',
        'execution_mode': 'mock',
        'route': 'physical',
        'confirmation': 'reported',
      }));
      expect(r.sentence, '연습이라 실제로 누르지 않았어요');
      expect(r.mockNote, isNull, reason: '같은 말을 두 줄로 되풀이하지 않는다');
      expect(r.next, isNull);
      expect(historyResult(_entry({'outcome': 'success', 'execution_mode': 'real'})).mockNote,
          isNull);
      // 실제·연습을 모르면 실제 성공처럼 보이지 않게 한 줄 남긴다(F4, 2026-10-14 — 연습 표시와는 다른 말).
      expect(historyResult(_entry({'outcome': 'success', 'execution_mode': 'unknown'})).mockNote,
          '실제 가전이 움직였는지 몰라요');
    });

    test('모의 실패는 실제 가전 확인을 지어내지 않는다', () {
      final r = historyResult(_entry(const {
        'outcome': 'failed',
        'status': 'failed',
        'execution_mode': 'mock',
      }), applianceName: '인터폰');
      // 다음 행동 줄을 두지 않는다 — 모의는 '연습' 한 줄로만 말한다(2026-10-14 UX).
      expect(r.next, isNull);
      expect(r.mockNote, '연습이라 실제로 누르지 않았어요');
    });

    test('모의 ThinQ — "(모의)" 이름·보냈지만 확인 못 함을 겹치지 않고 한 줄', () {
      final r = historyResult(_entry(const {
        'outcome': 'unconfirmed',
        'status': 'unconfirmed',
        'execution_mode': 'mock',
        'route': 'thinq',
        'receipt': 'unknown',
      }), applianceName: '공기청정기(모의)');
      expect(r.sentence, '연습이라 공기청정기에 보내지 않았어요');
      expect(r.mockNote, isNull);
      expect(r.next, isNull);
    });

    test('기록 제목은 질문이 아니라 서술', () {
      expect(historyStatement('공기청정기 풍량을 강으로 바꿀까요?'), '공기청정기 풍량 강으로');
      expect(historyStatement("'아침 데우기' 루틴을 실행할까요?"), "'아침 데우기' 루틴");
      expect(historyStatement('즉석밥 데워줘'), '즉석밥 데워줘');
    });

    test('실물 동작 확인(real) 성공은 다음 행동이 없다', () {
      final r = historyResult(_entry(const {
        'outcome': 'success',
        'execution_mode': 'real',
        'route': 'physical',
        'confirmation': 'operation_confirmed',
      }));
      expect(r.sentence, '가전이 전기를 쓰기 시작했어요');
      expect(r.next, isNull);
    });

    test('눌림 확인까지면 동작 확인을 부탁한다', () {
      final r = historyResult(
          _entry(const {
            'outcome': 'success',
            'execution_mode': 'real',
            'confirmation': 'press_confirmed',
          }),
          applianceName: '세탁기');
      expect(r.sentence, '버튼을 눌렀어요');
      expect(r.next, '세탁기 동작은 집에서 확인이 필요해요');
    });

    // 평가 12차(10/18): 볼 것은 결과 한 줄이 함께 말한다('버튼은 다 눌렀어요. 움직였는지는 집에서 확인이 필요해요') — 가전 이름은 시각 줄에.
    test('응답만 받은 성공은 가전을 직접 보라고 한 줄로 말한다', () {
      final e = _entry(const {
        'outcome': 'success',
        'execution_mode': 'real',
        'confirmation': 'reported',
      });
      for (final name in ['인터폰', '세탁기', null]) {
        final r = historyResult(e, applianceName: name);
        expect(r.sentence, '버튼은 다 눌렀어요. 움직였는지는 집에서 확인이 필요해요');
        expect(r.next, isNull);
      }
    });

    test('재시도 소진은 눌렸는지 확인 못 함', () {
      final r = historyResult(_entry(const {
        'outcome': 'failed',
        'status': 'failed',
        'execution_mode': 'real',
        'termination': 'retries_exhausted',
      }));
      expect(r.sentence, '한 번 더 눌렀지만 눌렸는지 몰라요');
      expect(r.next, '다시 누르기 전에 집에서 가전을 확인해야 해요');
    });

    test('ThinQ 미전송은 눌림 실패로 말하지 않는다', () {
      final r = historyResult(_entry(const {
        'outcome': 'failed',
        'status': 'failed',
        'route': 'thinq',
        'receipt': 'not_dispatched',
        'execution_mode': 'real',
      }));
      expect(r.sentence, '가전에 보내지 않았어요');
      expect(r.next, '본체 연결을 봐 주세요');
      expect(r.sentence.contains('눌'), isFalse);
    });

    test('ThinQ 확인 못 함은 다시 보내기 전에 확인하라고 한다', () {
      final r = historyResult(
          _entry(const {
            'outcome': 'unconfirmed',
            'status': 'unconfirmed',
            'route': 'thinq',
            'receipt': 'unknown',
            'execution_mode': 'real',
          }),
          applianceName: '세탁기');
      expect(r.next, '다시 보내기 전에 집에서 세탁기를 확인해야 해요');
    });

    test('원인 불명 실패는 원인을 추정하지 않는다', () {
      final r = historyResult(_entry(const {'status': 'failed'}));
      expect(r.sentence, '끝까지 하지 못했어요');
      expect(r.next, '가전 상태는 집에서 확인이 필요해요');
    });

    test('정지 문구는 기존 그대로', () {
      expect(
          historyResult(_entry(const {'status': 'safety_stopped', 'termination': 'stopped_by_user'}))
              .sentence,
          '멈춰 달라는 요청으로 멈췄어요');
      expect(historyResult(_entry(const {'status': 'safety_stopped'})).sentence, '스스로 멈췄어요');
      expect(historyResult(_entry(const {'outcome': 'stopped', 'status': 'stopped'})).sentence,
          '멈췄어요');
    });
  });
}
