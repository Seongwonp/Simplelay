// 홈 가전 타일의 '확인 주행' 보조 줄(2026-10-13). 표시만 — 실행을 막지 않는다.
//
// 근거 표:
//   실제(real) 확인 주행 완료 → 없음
//   모의 확인 주행 완료       → 연습 주행만 확인했어요
//   실제 확인 주행 실패       → 확인 주행을 마치지 못했어요
//   서버가 기록 없음을 명시   → 확인 주행 기록이 없어요
//   조회 실패·로딩·근거 불명  → 확인 주행 여부를 확인하지 못했어요
// 조회 실패(옛 코드의 null)를 '확인 주행 전'으로 단정하지 않는다.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/server_appliance_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/appliance_setup_card.dart';

ApplianceMap _appliance({
  bool mapped = true,
  bool custom = true,
  bool thinq = false,
  bool demo = false,
}) {
  final a = ApplianceMap.fromJson({
      'id': 'mw',
      'name': '주방 전자레인지',
      'rows': 1,
      'cols': 1,
      'buttons': const [],
      'is_custom': custom,
      if (thinq) 'control_path': 'thinq',
      if (mapped)
        'panel_mapping': {
          'photo': {'width': 100, 'height': 100},
        },
    });
  if (!demo) return a;
  return ApplianceMap(
    id: a.id,
    name: a.name,
    category: a.category,
    rows: a.rows,
    cols: a.cols,
    buttons: a.buttons,
    isDemo: true,
    panelMapping: a.panelMapping,
  );
}

VerifyPass _pass(String state, String? mode) =>
    VerifyPass(state: state, executionMode: mode);

String? _note(
  VerifyPassLookup lookup, {
  ApplianceMap? appliance,
  RpiConnectionState hub = RpiConnectionState.connected,
  ServerCatalogStatus catalog = ServerCatalogStatus.loaded,
}) =>
    verifyPassTileNote(
      appliance: appliance ?? _appliance(),
      hub: hub,
      catalog: catalog,
      lookup: lookup,
    );

const _unknownText = '확인 주행 여부를 확인하지 못했어요';

RpiApiService _api(Future<http.Response> Function(http.Request) handler) =>
    RpiApiService('http://rpi5.local:8000', client: MockClient(handler));

http.Response _json(Object body, int status) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('보조 줄 — 근거 표 5경우', () {
    test('실제 확인 주행 완료면 보조 줄이 없다', () {
      expect(_note(VerifyPassLookup.found(_pass('done', 'real'))), isNull);
    });
    test('모의 확인 주행 완료', () {
      expect(_note(VerifyPassLookup.found(_pass('done', 'mock'))),
          '연습 주행만 확인했어요');
    });
    test('실제 확인 주행 실패', () {
      expect(_note(VerifyPassLookup.found(_pass('failed', 'real'))),
          '확인 주행을 마치지 못했어요');
    });
    test('서버가 기록 없음을 명시', () {
      expect(_note(const VerifyPassLookup.noRecord()), '확인 주행 기록이 없어요');
    });
    test('조회 실패·로딩', () {
      expect(_note(const VerifyPassLookup.unknown()), _unknownText);
    });
  });

  group('근거가 모자라면 단정하지 않는다', () {
    test('조회 실패(옛 null)는 "확인 주행 전"이 아니다', () {
      final n = _note(const VerifyPassLookup.unknown());
      expect(n, isNot('확인 주행 기록이 없어요'));
      expect(n, _unknownText);
    });
    test('진행 중·실행 모드 모름·모의 실패는 근거 불명', () {
      expect(_note(VerifyPassLookup.found(_pass('running', 'real'))), _unknownText);
      expect(_note(VerifyPassLookup.found(_pass('done', null))), _unknownText);
      expect(_note(VerifyPassLookup.found(_pass('failed', null))), _unknownText);
      expect(_note(VerifyPassLookup.found(_pass('failed', 'mock'))), _unknownText);
    });
  });

  group('보조 줄을 붙이지 않는 타일', () {
    test('위치 미설정("설정이 필요해요")', () {
      expect(_note(const VerifyPassLookup.unknown(),
          appliance: _appliance(mapped: false)), isNull);
    });
    test('허브 장애·확인 중', () {
      for (final h in [
        RpiConnectionState.unreachable,
        RpiConnectionState.keyRequired,
        RpiConnectionState.unconfigured,
        RpiConnectionState.checking,
      ]) {
        expect(_note(const VerifyPassLookup.unknown(), hub: h), isNull,
            reason: '$h');
      }
      expect(
          _note(const VerifyPassLookup.unknown(),
              catalog: ServerCatalogStatus.failed),
          isNull);
    });
    test('확인 주행이 없는 가전(내장·ThinQ·데모)', () {
      expect(_note(const VerifyPassLookup.unknown(),
          appliance: _appliance(custom: false)), isNull);
      expect(_note(const VerifyPassLookup.unknown(),
          appliance: _appliance(thinq: true)), isNull);
      expect(_note(const VerifyPassLookup.unknown(),
          appliance: _appliance(demo: true)), isNull);
    });
  });

  group('조회 결과 구분(lookupVerifyPass)', () {
    test('200이면 결과 있음', () async {
      final r = await lookupVerifyPass(
          _api((_) async => _json({'state': 'done', 'execution_mode': 'mock'}, 200)),
          'mw');
      expect(r.kind, VerifyPassLookupKind.found);
      expect(r.pass?.isMock, isTrue);
    });
    test('서버가 "확인 주행 기록이 없어요"를 명시한 404만 기록 없음', () async {
      final r = await lookupVerifyPass(
          _api((_) async => _json({'detail': '확인 주행 기록이 없어요'}, 404)), 'mw');
      expect(r.kind, VerifyPassLookupKind.noRecord);
    });
    test('일반 404는 모름', () async {
      final r = await lookupVerifyPass(
          _api((_) async => _json({'detail': 'Not Found'}, 404)), 'mw');
      expect(r.kind, VerifyPassLookupKind.unknown);
      final bare = await lookupVerifyPass(
          _api((_) async => http.Response('', 404)), 'mw');
      expect(bare.kind, VerifyPassLookupKind.unknown);
    });
    test('응답 해석 실패는 모름', () async {
      final r = await lookupVerifyPass(
          _api((_) async => http.Response('<html>oops', 200)), 'mw');
      expect(r.kind, VerifyPassLookupKind.unknown);
      final list = await lookupVerifyPass(
          _api((_) async => _json(['done'], 200)), 'mw');
      expect(list.kind, VerifyPassLookupKind.unknown);
    });
    // 검토 M2(2026-10-13): 해석은 되지만 필수 근거(state)가 빠진 응답을 '실패'로 바꾸지 않는다.
    test('정상 JSON이지만 state가 없거나 null·알 수 없는 값이면 모름', () async {
      for (final body in <Map<String, dynamic>>[
        {'execution_mode': 'real'},
        {'state': null, 'execution_mode': 'real'},
        {'state': 'paused', 'execution_mode': 'real'},
        {'state': '', 'execution_mode': 'mock'},
      ]) {
        final r = await lookupVerifyPass(_api((_) async => _json(body, 200)), 'mw');
        expect(r.kind, VerifyPassLookupKind.unknown, reason: '$body');
        expect(_note(r), _unknownText, reason: '$body');
      }
      final wrongType = await lookupVerifyPass(
          _api((_) async => _json({'state': 3, 'execution_mode': 'real'}, 200)), 'mw');
      expect(wrongType.kind, VerifyPassLookupKind.unknown);
    });
    test('state가 빠진 응답을 실패로 읽지 않는다(모델)', () {
      expect(VerifyPass.fromJson({'execution_mode': 'real'}).state, isNot('failed'));
    });
    test('예외·서버 오류·허브 없음은 모름', () async {
      final thrown = await lookupVerifyPass(
          _api((_) async => throw http.ClientException('down')), 'mw');
      expect(thrown.kind, VerifyPassLookupKind.unknown);
      final e500 = await lookupVerifyPass(
          _api((_) async => _json({'detail': '확인 주행 기록이 없어요'}, 500)), 'mw');
      expect(e500.kind, VerifyPassLookupKind.unknown);
      expect((await lookupVerifyPass(null, 'mw')).kind,
          VerifyPassLookupKind.unknown);
    });
  });
}
