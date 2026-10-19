// 쉬운 말 사전 회귀 시험(2026-10-17 UI 개편안 §2·§3).
//
// 모든 화면에 나오는 결과 문장(command_result.dart·display_status.dart)이 사전에서 뺀 말
// (허브·모의·작은 팔(10/18 '누름 장치'로 바꿈)·모션/모터 보드·ThinQ·확인 주행)과 문장 잇기 기호('—'·' · ')를 다시
// 쓰지 않는지 입력 조합 전체로 본다. 확인 수준(안전 계약)은 각 화면 시험이 따로 지킨다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/services/rpi_api_service.dart';

const _banned = [
  '허브',
  '서버',
  '키오스크',
  '모의',
  '데모',
  '시연',
  '작은 팔',
  '모션',
  '모터',
  'ThinQ',
  '확인 주행',
  '접수',
  '—',
  ' · ',
];

void _expectPlain(String? text, String where) {
  if (text == null) return;
  for (final w in _banned) {
    expect(text.contains(w), isFalse, reason: "$where: '$w'가 남았어요 → $text");
  }
}

void main() {
  const modes = ['real', 'mock', 'unknown'];
  const routes = ['physical', 'thinq', 'unknown'];
  const receipts = ['accepted', 'not_dispatched', 'unknown'];
  const confirmations = [
    'state_confirmed',
    'state_confirmed_unknown_before',
    'already_at_target',
    'operation_confirmed',
    'press_confirmed',
    'reported',
    'none',
    'unknown',
  ];
  const levels = ['sent', 'mcu_ack', 'verified', null];
  const aborts = [
    'motion_alarm: stall',
    'motion_alarm: overcurrent',
    'motion_reset',
    'motion_timeout',
    'motion_not_ready',
    'motion_position_mismatch',
    'motion_link_error',
    'motion_other',
    null,
  ];

  test('결과 칩·결과 문장에 사전에서 뺀 말과 문장 잇기 기호가 없다', () {
    for (final kind in ResultKind.values) {
      _expectPlain(resultWord(kind), 'resultWord');
      for (final mode in modes) {
        for (final route in routes) {
          _expectPlain(routeLabel(route), 'routeLabel');
          for (final receipt in receipts) {
            for (final c in confirmations) {
              _expectPlain(
                  confirmationLabel(
                      route: route,
                      receipt: receipt,
                      confirmation: c,
                      kind: kind,
                      executionMode: mode),
                  'confirmationLabel($route,$receipt,$c,$kind,$mode)');
              for (final level in levels) {
                for (final abort in aborts) {
                  _expectPlain(
                      finishedMessage(
                          kind: kind,
                          executionMode: mode,
                          route: route,
                          receipt: receipt,
                          confirmation: c,
                          stopLevel: level,
                          abortReason: abort),
                      'finishedMessage($kind,$mode,$route,$receipt,$c,$level,$abort)');
                }
              }
            }
          }
        }
      }
    }
    for (final level in levels) {
      _expectPlain(stopLevelSentence(level), 'stopLevelSentence($level)');
      _expectPlain(stopLevelNextStep(level), 'stopLevelNextStep($level)');
    }
    for (final abort in aborts) {
      _expectPlain(motionAbortSentence(abort), 'motionAbortSentence($abort)');
    }
    _expectPlain(unconfirmedSentence(receipt: 'unknown'), 'unconfirmedSentence');
    _expectPlain(unconfirmedSentence(), 'unconfirmedSentence');
    for (final mode in modes) {
      for (final c in confirmations) {
        for (final ok in [true, false]) {
          _expectPlain(
              manualPressSentence('전원', success: ok, confirmation: c, executionMode: mode),
              'manualPressSentence($ok,$c,$mode)');
        }
      }
    }
  });

  test('기록 한 줄(제목·출처·결과·다음 할 일·연습 줄)에 사전에서 뺀 말이 없다', () {
    const statuses = ['succeeded', 'failed', 'safety_stopped', 'stopped', 'unconfirmed'];
    const outcomes = ['success', 'failed', 'stopped', 'safety_stop', 'unconfirmed', null];
    const terminations = ['completed', 'stopped_by_user', 'retries_exhausted', 'unknown'];
    for (final status in statuses) {
      for (final outcome in outcomes) {
        for (final t in terminations) {
          for (final mode in modes) {
            for (final route in routes) {
              for (final receipt in receipts) {
                for (final c in confirmations) {
                  for (final abort in aborts) {
                    final e = RpiHistoryEntry(
                      jobId: 'j',
                      finishedAt: DateTime(2026, 10, 17),
                      status: status,
                      outcome: outcome,
                      termination: t,
                      retryCount: 0,
                      buttons: const [RpiHistoryButton(button: '전원', success: true, attempts: 1)],
                      executionMode: mode,
                      route: route,
                      receipt: receipt,
                      confirmation: c,
                      abortReason: abort,
                    );
                    final r = historyResult(e, applianceName: '공기청정기');
                    final where = 'history($status,$outcome,$t,$mode,$route,$receipt,$c,$abort)';
                    _expectPlain(r.sentence, where);
                    _expectPlain(r.next, where);
                    _expectPlain(r.mockNote, where);
                    _expectPlain(historyTitle(e, applianceName: '공기청정기'), where);
                    _expectPlain(historySource(e), where);
                  }
                }
              }
            }
          }
        }
      }
    }
  });

  // 화면 문구 전체(개발자 도구 제외): 사전에서 뺀 이름이 문자열로 다시 들어오지 않는다.
  // 서버 문장과 비교하는 값(`.contains(`·서버 404 문장 상수)·서버 말을 쉬운 말로 바꾸는 자리(`.replaceAll(`)와 내부 예외 문장은 사용자 문장이 아니다.
  test('폰 화면 문자열에 허브·키오스크·작은 팔·확인 주행·잠시 쉬기·그만 쉬기·ThinQ·쉬는 자리·풍량·대시가 없다', () {
    const skipFiles = ['developer_', 'dev_api_service.dart'];
    final literal = RegExp(r"'[^'\n]*(허브|키오스크|작은 ?팔|확인 주행|잠시 쉬기|그만 쉬기|ThinQ|쉬는 자리|풍량| — )[^'\n]*'");
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (skipFiles.any(f.path.contains)) continue;
      for (final line in f.readAsLinesSync()) {
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('.contains(') ||
            line.contains('.replaceAll(') ||
            line.contains('noRecordDetail') ||
            line.contains('FormatException(')) {
          continue;
        }
        for (final m in literal.allMatches(line)) {
          hits.add('${f.path}: ${m.group(0)}');
        }
      }
    }
    expect(hits, isEmpty);
  });
}
