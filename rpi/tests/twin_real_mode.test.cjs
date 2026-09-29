// 실모드 트윈(/twin)·기록 재생(/twin?replay=) 순수 함수 시험.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const T = require('../touchscreen/twin-motion.js');

test('page config: simulator path keeps its own routes, /twin is real, ?replay= is replay', () => {
  assert.deepEqual(T.pageConfig('/simulator/twin', ''), {kind: 'simulator', base: '/simulator/twin', replay: null});
  assert.deepEqual(T.pageConfig('/twin', ''), {kind: 'real', base: '/twin', replay: null});
  const r = T.pageConfig('/twin', '?replay=session-20261001.jsonl');
  assert.equal(r.kind, 'replay');
  assert.equal(T.stateUrl(r, 3.25), '/twin/state?replay=session-20261001.jsonl&t=3.25');
  assert.equal(T.stateUrl(T.pageConfig('/twin', ''), 5), '/twin/state');
  assert.equal(T.stateUrl(T.pageConfig('/simulator/twin', '?replay=x'), 5), '/simulator/twin/state');
});

test('mode badge: server status first, else RPi4-reported mode; replay ignores live status', () => {
  const twinReal = {execution_mode: 'real', execution_mode_source: 'rpi4_progress', source: 'link_tap'};
  // UART 링크는 /status가 unknown — RPi4 progress 보고로 REAL.
  let b = T.modeBadge({running: true, execution_mode: 'unknown', last_execution_mode: 'unknown'}, twinReal);
  assert.equal(b.text, 'REAL');
  assert.match(b.detail, /progress/);
  b = T.modeBadge({running: false, execution_mode: 'unknown', last_execution_mode: 'mock'}, twinReal);
  assert.equal(b.text, 'MOCK');
  assert.match(b.detail, /마지막 실행/);
  b = T.modeBadge({running: false, last_execution_mode: 'real'}, {execution_mode: 'mock', source: 'replay'});
  assert.equal(b.text, 'MOCK');
  assert.match(b.detail, /^기록/);
  assert.equal(T.modeBadge(null, {execution_mode: 'unknown', source: 'link_tap'}).text, 'UNKNOWN');
});

test('verdict never invents success; REAL wording only from a real result; error frame is not success', () => {
  const job = extra => Object.assign({sequence_id: 's', buttons: ['a'], result: {success: true, retry: 1}, abort_requested: false}, extra);
  assert.match(T.verdictText({execution_mode: 'real', source: 'link_tap', job: job()}, false), /실기기\(REAL\) 보고/);
  assert.match(T.verdictText({execution_mode: 'mock', source: 'link_tap', job: job()}, false), /모의 실행/);
  assert.match(T.verdictText({execution_mode: 'unknown', source: 'link_tap', job: job()}, false), /실행 환경 미확인/);
  assert.match(T.verdictText({execution_mode: 'real', source: 'replay', job: job()}, false), /기록 재생 · 실기기/);
  // result 없음 + error 프레임 → 결과 없음 문구, 성공 아님.
  const err = T.verdictText({running: false, source: 'link_tap', job: job({result: null, link_error: 'busy'})}, false);
  assert.match(err, /오류 보고\(error: busy\)/);
  assert.doesNotMatch(err, /성공/);
  // 모션이 끝나도 result가 없으면 결과 미확인.
  assert.equal(T.verdictText({running: false, source: 'link_tap', job: job({result: null})}, false), '결과 프레임 없음 · 결과 미확인');
});

test('carriage: encoder report drawn at its mm position only on an mm layout, else command estimate', () => {
  const appliance = {buttons: [{id: 'a', label: 'A', x_mm: 10, y_mm: 10}, {id: 'b', label: 'B', x_mm: 50, y_mm: 30}]};
  const mm = T.layoutButtons(appliance, [], {aspect: 1});
  assert.equal(mm.mode, 'mm');
  // 버튼 위치 = mm 변환 위치(같은 변환을 쓴다).
  const at = T.mmToLayout(mm, 50, 30);
  assert.ok(Math.abs(at[0] - mm.buttons[1].x) < 1e-9 && Math.abs(at[1] - mm.buttons[1].y) < 1e-9);
  const pose = {x: 0.1, y: 0.2};
  const enc = {job: {carriage: {kind: 'encoder', x_mm: 50, y_mm: 30, a_counts: 80, b_counts: 20, z_counts: 0}}};
  let v = T.carriageView(enc, mm, pose, 'real');
  assert.equal(v.kind, 'encoder');
  assert.equal(v.label, '엔코더 보고 위치');
  assert.deepEqual([v.x, v.y], at);
  // 격자 배치에는 mm를 옮길 수 없다 → 추정으로 표시, 근거는 적어 둔다.
  const grid = T.layoutButtons({rows: 1, cols: 2, buttons: [{id: 'a', label: 'A', x: 0, y: 0}, {id: 'b', label: 'B', x: 1, y: 0}]}, []);
  v = T.carriageView(enc, grid, pose, 'real');
  assert.equal(v.label, '명령 기준 추정');
  assert.match(v.note, /mm 배치가 아니어서/);
  assert.deepEqual([v.x, v.y], [0.1, 0.2]);
  // 위치 보고가 없으면 명령 기준 추정(엔진 위치).
  v = T.carriageView({job: {carriage: {kind: 'estimate', x_mm: 50, y_mm: 30}}}, mm, pose, 'real');
  assert.equal(v.label, '명령 기준 추정');
  assert.deepEqual([v.x, v.y], [0.1, 0.2]);
  // 시뮬레이터 화면은 종전대로 개념 모션.
  assert.equal(T.carriageView(enc, mm, pose, 'simulator').label, '개념 모션');
  assert.equal(T.mmToLayout(grid, 1, 1), null);
});

test('real-mode follower moves only on progress press records, and a result alone moves nothing', () => {
  const layout = T.layoutButtons({rows: 1, cols: 2, buttons: [{id: 'a', label: 'A', x: 0, y: 0}, {id: 'b', label: 'B', x: 1, y: 0}]}, []);
  const engine = T.createEngine({scale: 1});
  const follower = T.createFollower(engine);
  const state = (presses, result) => ({running: !result, source: 'link_tap', job: {sequence_id: 'q', buttons: ['A', 'B'], result,
    abort_requested: false, press_log: presses.map((label, n) => ({n, label, step_index: n, attempt: 1, correction: null}))}});
  follower.update(state([]), layout, 0);
  engine.tick(100);
  const home = engine.position;
  // progress 없는 옛 RPi4: 결과만 와도 캐리지는 원점에 머문다.
  follower.update(state([], {success: true, retry: 0}), layout, 100);
  engine.tick(200);
  assert.deepEqual(engine.position, home);
});
