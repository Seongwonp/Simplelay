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
}) =>
    applianceTileStatus(
      appliance: appliance ?? _plain,
      readinessSource: source,
      hub: hub,
      catalog: catalog,
      execution: execution,
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
      expect(s.text, '버튼 조작 중');
      expect(s.text.contains('돌아가'), isFalse);
      expect(s.progress, isTrue);
    });

    test('mock·데모 실행은 모의 버튼 조작 중', () {
      expect(_tile(execution: run(ExecutionPhase.retrying, mode: 'mock')).text,
          '모의 버튼 조작 중');
      expect(_tile(execution: run(ExecutionPhase.running, demo: true)).text,
          '모의 버튼 조작 중');
    });

    test('모드를 모르면 real·mock을 추정하지 않는다', () {
      expect(_tile(execution: run(ExecutionPhase.running)).text, '실행을 확인하고 있어요');
    });

    test('waiting은 누르는 중이 아니다', () {
      expect(_tile(execution: run(ExecutionPhase.waiting, mode: 'real')).text,
          '실행을 기다리고 있어요');
    });

    test('연결이 끊겨 모르면 준비됨으로 덮지 않는다', () {
      final ready = _server(const {'can_execute': true, 'readiness': 'operable'});
      expect(
          _tile(source: ready, execution: run(ExecutionPhase.unknown)).text,
          '동작을 확인할 수 없어요');
    });

    test('다른 가전의 실행·끝난 실행은 이 타일의 상태가 아니다', () {
      const other = ExecutionStatus(
          phase: ExecutionPhase.running, applianceId: 'washer', executionMode: 'real');
      expect(_tile(execution: other).text, '준비 상태를 확인하지 못했어요');
      const done = ExecutionStatus(
        phase: ExecutionPhase.completed,
        applianceId: 'mw',
        executionMode: 'real',
        operationConfirmed: true,
        operationSource: 'real',
      );
      // 과거의 CT 판정(operationConfirmed)을 지금의 운전으로 옮기지 않는다.
      final s = _tile(execution: done);
      expect(s.text, '준비 상태를 확인하지 못했어요');
      expect(s.tone, isNot(TileTone.active));
    });
  });

  group('타일 — 준비 상태', () {
    test('서버 판정이 없으면 canExecute 기본 true로 긍정하지 않는다', () {
      expect(_plain.canExecute, isTrue, reason: '모델 기본값이 true다');
      final s = _tile(source: _plain);
      expect(s.text, '준비 상태를 확인하지 못했어요');
      expect(s.tone, TileTone.unknown);
      expect(_tile(source: null).text, '준비 상태를 확인하지 못했어요');
    });

    test('operable + canExecute만 긍정한다 — "실행을 요청할 수 있어요"', () {
      final s = _tile(source: _server(const {'can_execute': true, 'readiness': 'operable'}));
      expect(s.text, '실행을 요청할 수 있어요');
      expect(s.tone, TileTone.ready);
    });

    test('상충하는 응답은 긍정으로 정규화하지 않는다', () {
      for (final r in ['disconnected', 'needs_setup']) {
        expect(_tile(source: _server({'can_execute': true, 'readiness': r})).text,
            '실행 가능 여부를 확인해 주세요');
      }
      expect(
          _tile(source: _server(const {'can_execute': false, 'readiness': 'operable'})).text,
          '실행 가능 여부를 확인해 주세요');
    });

    test('needs_setup은 "준비가 필요해요" + 서버의 실제 이유(비상정지 포함)', () {
      final s = _tile(
          source: _server(const {
        'can_execute': false,
        'readiness': 'needs_setup',
        'readiness_reasons': ['비상정지가 걸려 있어요'],
      }));
      expect(s.text, '준비가 필요해요');
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
          '준비 상태를 확인하지 못했어요');
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
          '연결을 확인해 주세요');
      expect(_tile(source: ready, hub: RpiConnectionState.keyRequired).text,
          '허브 설정이 필요해요');
      expect(_tile(source: ready, hub: RpiConnectionState.checking).text, '확인하는 중이에요');
      expect(_tile(source: ready, catalog: ServerCatalogStatus.loading).text,
          '확인하는 중이에요');
      expect(_tile(source: ready, catalog: ServerCatalogStatus.failed).text,
          '연결을 확인해 주세요');
    });
  });

  group('기록 제목', () {
    test('비어 있지 않은 purpose는 그대로(이름을 바꾸지 않는다)', () {
      expect(historyTitle(_entry({'purpose': '즉석밥 데워줘'})), '즉석밥 데워줘');
    });

    test('purpose 없음 → 등록 이름 + 버튼 라벨', () {
      final e = _entry({'buttons': _buttons(['문열림'])});
      expect(historyTitle(e, applianceName: '인터폰'), '인터폰 · 문열림 버튼 조작');
    });

    test('빈 문자열 purpose도 없음으로 본다', () {
      final e = _entry({'purpose': '  ', 'buttons': _buttons(['문열림'])});
      expect(historyTitle(e, applianceName: '인터폰'), '인터폰 · 문열림 버튼 조작');
    });

    test('버튼이 없으면 이름 + 버튼 조작(ThinQ는 명령)', () {
      expect(historyTitle(_entry(const {}), applianceName: '인터폰'), '인터폰 버튼 조작');
      expect(historyTitle(_entry(const {'route': 'thinq'}), applianceName: '세탁기'),
          '세탁기 명령');
    });

    test('모두 없으면 "실행 기록" — 목적을 지어내지 않는다', () {
      expect(historyTitle(_entry(const {'purpose': ''})), '실행 기록');
    });

    test('이름을 모르면 버튼 라벨만', () {
      expect(historyTitle(_entry({'buttons': _buttons(['즉석밥', '시작'])})),
          '즉석밥, 시작 버튼 조작');
    });
  });

  group('기록 결과·다음 행동', () {
    test('모의 성공 — 연습(모의) 표시는 mock 기록에만', () {
      final r = historyResult(_entry(const {
        'outcome': 'success',
        'execution_mode': 'mock',
        'route': 'physical',
        'confirmation': 'reported',
      }));
      expect(r.sentence, '모의 버튼 조작을 마쳤어요');
      expect(r.mockNote, '연습(모의) · 실제로 누르지 않았어요');
      expect(r.next, isNull);
      for (final mode in ['real', 'unknown']) {
        expect(
            historyResult(_entry({'outcome': 'success', 'execution_mode': mode})).mockNote,
            isNull);
      }
    });

    test('모의 실패는 실제 가전 확인을 지어내지 않는다', () {
      final r = historyResult(_entry(const {
        'outcome': 'failed',
        'status': 'failed',
        'execution_mode': 'mock',
      }), applianceName: '인터폰');
      expect(r.next, '연습 결과를 확인해 주세요');
      expect(r.next!.contains('인터폰'), isFalse);
    });

    test('실물 동작 확인(real) 성공은 다음 행동이 없다', () {
      final r = historyResult(_entry(const {
        'outcome': 'success',
        'execution_mode': 'real',
        'route': 'physical',
        'confirmation': 'operation_confirmed',
      }));
      expect(r.sentence, '가전이 켜진 것을 확인했어요');
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
      expect(r.next, '세탁기 동작을 확인해 주세요');
    });

    test('응답만 받은 성공은 대상을 직접 확인하라고 한다(받침 따라 을/를)', () {
      final e = _entry(const {
        'outcome': 'success',
        'execution_mode': 'real',
        'confirmation': 'reported',
      });
      expect(historyResult(e, applianceName: '인터폰').next, '인터폰을 직접 확인해 주세요');
      expect(historyResult(e, applianceName: '세탁기').next, '세탁기를 직접 확인해 주세요');
      expect(historyResult(e).next, '가전을 직접 확인해 주세요');
    });

    test('재시도 소진은 눌렸는지 확인 못 함', () {
      final r = historyResult(_entry(const {
        'outcome': 'failed',
        'status': 'failed',
        'execution_mode': 'real',
        'termination': 'retries_exhausted',
      }));
      expect(r.sentence, '다시 눌러도 확인하지 못했어요');
      expect(r.next, '가전을 직접 확인해 주세요');
    });

    test('ThinQ 미전송은 눌림 실패로 말하지 않는다', () {
      final r = historyResult(_entry(const {
        'outcome': 'failed',
        'status': 'failed',
        'route': 'thinq',
        'receipt': 'not_dispatched',
        'execution_mode': 'real',
      }));
      expect(r.sentence, '명령을 보내지 않았어요');
      expect(r.next, '연결 상태를 확인해 주세요');
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
      expect(r.next, '다시 보내기 전에 세탁기를 직접 확인해 주세요');
    });

    test('원인 불명 실패는 원인을 추정하지 않는다', () {
      final r = historyResult(_entry(const {'status': 'failed'}));
      expect(r.sentence, '끝까지 실행하지 못했어요');
      expect(r.next, '가전 상태를 확인해 주세요');
    });

    test('정지 문구는 기존 그대로', () {
      expect(
          historyResult(_entry(const {'status': 'safety_stopped', 'termination': 'stopped_by_user'}))
              .sentence,
          '직접 멈췄어요');
      expect(historyResult(_entry(const {'status': 'safety_stopped'})).sentence, '안전 정지');
      expect(historyResult(_entry(const {'outcome': 'stopped', 'status': 'stopped'})).sentence,
          '정지됨');
    });
  });
}
