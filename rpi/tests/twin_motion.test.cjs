const {test} = require('node:test');
const assert = require('node:assert/strict');
const T = require('../touchscreen/twin-motion.js');

const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b}`);

test('CoreXY conversion and inverse', () => {
  assert.deepEqual(T.corexy(1, 0), {a: 1, b: 1});
  assert.deepEqual(T.corexy(0, 1), {a: 1, b: -1});
  assert.deepEqual(T.corexy(1, 1), {a: 2, b: 0});
  assert.deepEqual(T.corexy(1, -1), {a: 0, b: 2});
  for (const [dx, dy] of [[.3, -.7], [0, 0], [-.25, .5]]) {
    const {a, b} = T.corexy(dx, dy);
    const back = T.inverse(a, b);
    close(back.dx, dx); close(back.dy, dy);
  }
});

const microwave = {rows: 4, cols: 3, buttons: [
  {id: 'BT-08', label: '즉석밥', x: 1, y: 2}, {id: 'BT-05', label: '시작', x: 2, y: 3}]};

test('layout keeps grid cells as grid, uses mm only when every button has it, else placeholder', () => {
  const grid = T.layoutButtons(microwave);
  assert.equal(grid.mode, 'grid');
  assert.match(grid.note, /mm 좌표가 아닙니다/);
  close(grid.buttons[0].x, 0.5); close(grid.buttons[0].y, 2.5 / 4);
  const mm = T.layoutButtons({rows: 4, cols: 3, buttons: [
    {label: 'a', x: 0, y: 0, x_mm: 10, y_mm: 20}, {label: 'b', x: 1, y: 1, x_mm: 30, y_mm: 60}]});
  assert.equal(mm.mode, 'mm');
  // span 20 x 40 mm: uniform scale fits the taller side, centered horizontally
  close(mm.buttons[0].x, 0.3); close(mm.buttons[1].x, 0.7); close(mm.buttons[0].y, 0.1); close(mm.buttons[1].y, 0.9);
  const partial = T.layoutButtons({rows: 4, cols: 3, buttons: [
    {label: 'a', x: 0, y: 0, x_mm: 10, y_mm: 20}, {label: 'b', x: 1, y: 1}]});
  assert.equal(partial.mode, 'grid');
  const none = T.layoutButtons(null, ['즉석밥', '시작', '즉석밥']);
  assert.equal(none.mode, 'placeholder');
  assert.equal(none.buttons.length, 2);
  assert.match(none.note, /임시 배치/);
});

test('sequence stepping: home, then move → press → return per button, A/B totals follow CoreXY', () => {
  const e = T.createEngine({catchUp: false, timing: {home: 1, moveBase: 1, movePerUnit: 0, press: 1, ret: 1}});
  e.home();
  e.enqueue([1, 0], {label: 'x'});
  e.enqueue([1, 1], {label: 'y'});
  const phases = [];
  for (let t = 0.5; t < 8; t += 1) phases.push(e.tick(t).phase);
  assert.deepEqual(phases, ['home', 'move', 'press', 'return', 'move', 'press', 'return', 'idle']);
  const mid = T.createEngine({catchUp: false, timing: {home: 1, moveBase: 1, movePerUnit: 0, press: 1, ret: 1}});
  mid.enqueue([0.4, 0], {label: 'p'});
  mid.tick(0);
  const pressing = mid.tick(1.99);
  assert.equal(pressing.phase, 'press');
  assert.ok(pressing.z > 0.9 && pressing.pressing);
  const end = e.tick(100);
  close(end.x, 1); close(end.y, 1); assert.equal(end.z, 0);
  close(end.a, 2); close(end.b, 0);
  assert.equal(end.phase, 'idle');
});

test('stop freezes the carriage mid-move and ignores later work', () => {
  const e = T.createEngine({timing: {home: 0, moveBase: 2, movePerUnit: 0, press: 1, ret: 1}});
  e.enqueue([1, 0], {label: 'x'});
  e.tick(0);
  const frozen = e.stop(1);
  assert.equal(frozen.phase, 'stopped');
  close(frozen.x, 0.5); close(frozen.a, 0.5); close(frozen.b, 0.5);
  assert.equal(e.enqueue([0, 1], {label: 'y'}), false);
  e.home();
  const later = e.tick(50);
  assert.equal(later.phase, 'stopped');
  close(later.x, 0.5); assert.equal(later.y, 0);
  assert.equal(e.busy, false);
});

test('reduced motion (scale 0) jumps to final poses without timing', () => {
  const e = T.createEngine({scale: 0});
  e.home(); e.enqueue([0.3, 0.6], {label: 'x'});
  const p = e.tick(0);
  close(p.x, 0.3); close(p.y, 0.6); assert.equal(p.phase, 'idle');
});

function job(presses, extra) {
  return {running: true, job: Object.assign({sequence_id: 's1', buttons: ['즉석밥', '시작'], result: null,
    abort_requested: false, press_log: presses.map((label, n) => ({n, label, step_index: 0, attempt: 1}))}, extra)};
}

test('animation completion emits no result; repeated polls do not replay', () => {
  const e = T.createEngine({scale: 0});
  const f = T.createFollower(e);
  const layout = T.layoutButtons(microwave);
  const state = job(['즉석밥']);
  const before = JSON.stringify(state);
  f.update(state, layout, 0);
  e.tick(0);
  const n = e.drain().length;
  assert.ok(n >= 4);
  f.update(state, layout, 1); f.update(state, layout, 2);
  e.tick(3);
  assert.equal(e.drain().length, 0, 'repeated poll must not enqueue motion again');
  assert.equal(JSON.stringify(state), before, 'server state must not be modified');
  assert.equal(state.job.result, null);
  const all = [];
  f.update(job(['즉석밥', '시작']), layout, 4); e.tick(10); all.push(...e.drain());
  for (const ev of all) {
    assert.equal(ev.type, 'phase');
    for (const k of ['success', 'result', 'retry', 'status']) assert.ok(!(k in ev));
  }
  assert.equal(e.tick(20).phase, 'idle');
});

test('abort observed from server freezes; finished job seen on open is not replayed', () => {
  const e = T.createEngine({timing: {home: 5}});
  const f = T.createFollower(e);
  const layout = T.layoutButtons(microwave);
  f.update(job(['즉석밥']), layout, 0);
  e.tick(0);
  const out = f.update(job(['즉석밥'], {abort_requested: true}), layout, 1);
  assert.ok(out.froze);
  assert.equal(e.tick(99).phase, 'stopped');

  const g = T.createEngine({scale: 0});
  const h = T.createFollower(g);
  const done = {running: false, job: Object.assign(job(['즉석밥', '시작']).job, {result: {success: true, retry: 0}})};
  const res = h.update(done, layout, 0);
  assert.ok(res.historic);
  g.tick(0);
  assert.equal(g.drain().length, 0);
  const p = g.tick(1);
  close(p.x, 2.5 / 3); close(p.y, 3.5 / 4);
  // later polls of the same finished, aborted job do not freeze the static view
  h.update({running: false, job: Object.assign({}, done.job, {abort_requested: true})}, layout, 2);
  assert.equal(g.stopped, false);
});

test('unknown button label is reported, not guessed', () => {
  const e = T.createEngine({scale: 0});
  const f = T.createFollower(e);
  const out = f.update(job(['없는버튼']), T.layoutButtons(microwave), 0);
  assert.deepEqual(out.notes, ['버튼맵에 없는 이름: 없는버튼']);
  e.tick(0);
  assert.deepEqual(e.drain().map(x => x.kind), ['home']);
});

test('mm layout preserves aspect ratio on a non-square workspace; grid fallback unchanged', () => {
  const wide = {rows: 2, cols: 2, buttons: [
    {id: 'a', label: 'a', x: 0, y: 0, x_mm: 0, y_mm: 0}, {id: 'b', label: 'b', x: 1, y: 1, x_mm: 100, y_mm: 20}]};
  const sq = T.layoutButtons(wide);
  close(sq.buttons[0].x, 0.1); close(sq.buttons[1].x, 0.9);
  close(sq.buttons[1].y - sq.buttons[0].y, 0.16);  // 20/100 of the x spread, not stretched to 0.8
  close((sq.buttons[0].y + sq.buttons[1].y) / 2, 0.5);
  // Workspace half as wide as tall: 1 mm must cover the same screen length on both axes.
  const tall = T.layoutButtons(wide, [], {aspect: 0.5});
  const dxScreen = (tall.buttons[1].x - tall.buttons[0].x) * 0.5, dyScreen = (tall.buttons[1].y - tall.buttons[0].y) * 1;
  close(dxScreen / dyScreen, 100 / 20);
  close(tall.buttons[1].x - tall.buttons[0].x, 0.8);
  assert.equal(T.layoutButtons(microwave, [], {aspect: 0.5}).mode, 'grid');
  close(T.layoutButtons(microwave, [], {aspect: 0.5}).buttons[0].x, 0.5);
});

test('button lookup prefers id over label', () => {
  const layout = {buttons: [{id: 'p1', label: '시작', x: 0.1, y: 0.1}, {id: 'p2', label: '시작', x: 0.9, y: 0.9}]};
  assert.equal(T.findButton(layout, {id: 'p2', label: '시작'}).x, 0.9);
  assert.equal(T.findButton(layout, {label: '시작'}).x, 0.1);
  assert.equal(T.findButton(layout, {id: 'zz', label: '시작'}).x, 0.1);
  assert.equal(T.findButton(layout, {id: 'zz'}), null);
});

function runUntilIdle(e, dt = 0.01, limit = 100) {
  let t = 0; while (t < limit) { const p = e.tick(t); if (!e.busy && p.phase === 'idle') return t; t += dt; }
  return Infinity;
}

test('catch-up: a backed-up queue plays faster than one-by-one, single button unchanged', () => {
  const timing = {home: 0, moveBase: 0.3, movePerUnit: 0.8, press: 0.25, ret: 0.25};
  const targets = [[0.2, 0.2], [0.8, 0.3], [0.5, 0.9], [0.1, 0.6], [0.9, 0.9]];
  const slow = T.createEngine({timing, catchUp: false});
  const fast = T.createEngine({timing});
  for (const e of [slow, fast]) for (const t of targets) e.enqueue(t, {label: 'x'});
  const tSlow = runUntilIdle(slow), tFast = runUntilIdle(fast);
  assert.ok(tFast < tSlow * 0.75, `catch-up ${tFast} vs ${tSlow}`);
  // Server presses arrive every 0.8 s (step_seconds). Without catch-up the lag
  // behind the last press grows with sequence length; with it, it stays bounded.
  const lagAfterLast = (n, catchUp) => {
    const e = T.createEngine({timing, catchUp});
    let t = 0, i = 0;
    while (t < 200) {
      if (i < n && t >= 0.8 * i - 1e-9) { e.enqueue(targets[i % targets.length], {label: 'x'}); i++; }
      e.tick(t);
      if (i === n && !e.busy) return t - 0.8 * (n - 1);
      t += 0.01;
    }
    return Infinity;
  };
  const lag8 = lagAfterLast(8), lag32 = lagAfterLast(32), off32 = lagAfterLast(32, false);
  assert.ok(lag32 < 3 && lag8 < 3, `bounded lag ${lag8} / ${lag32}`);
  assert.ok(off32 > 10, `without catch-up the lag grows (${off32})`);
  const one = T.createEngine({timing}), ref = T.createEngine({timing, catchUp: false});
  one.enqueue([0.5, 0.5]); ref.enqueue([0.5, 0.5]);
  close(runUntilIdle(one), runUntilIdle(ref));
  // hurry (server result already in) shortens further
  const h = T.createEngine({timing}); h.enqueue([0.5, 0.5]); h.hurry(true);
  const ref2 = T.createEngine({timing, catchUp: false}); ref2.enqueue([0.5, 0.5]);
  assert.ok(runUntilIdle(h) < runUntilIdle(ref2) * 0.6);
  // final pose is exact regardless of speed
  const end = fast.tick(999); close(end.x, 0.9); close(end.y, 0.9); assert.equal(end.z, 0);
});

test('verdict: held back while motion replays; abort + success wording; never from animation', () => {
  const j = (extra) => ({running: false, job: Object.assign({sequence_id: 's', buttons: ['a'], press_log: [], abort_requested: false, result: {success: true, retry: 0}}, extra)});
  assert.equal(T.verdictText(j(), true), '모션 재생 중 · 서버 결과 도착');
  assert.match(T.verdictText(j(), false), /성공\(success=true, 재시도 0회\)/);
  assert.match(T.verdictText(j({abort_requested: true}), false), /정지 요청이 늦어 모든 버튼 입력 후 성공 보고/);
  assert.match(T.verdictText(j({abort_requested: true, result: {success: false, retry: 1}}), false), /실패.*정지 요청 뒤/);
  assert.equal(T.verdictText(j({result: null}), false), '결과 프레임 없음 · 결과 미확인');
  assert.equal(T.verdictText({running: true, job: j({result: null}).job}, true), '결과 대기 · 서버 보고 전');
  assert.equal(T.verdictText({running: false, job: null}, false), '아직 실행 기록이 없습니다.');
});

test('follower hurries once the server result is in but motion is still behind', () => {
  const e = T.createEngine({timing: {home: 1, moveBase: 1, movePerUnit: 0, press: 1, ret: 1}});
  const f = T.createFollower(e);
  const layout = T.layoutButtons(microwave);
  f.update(job(['즉석밥', '시작']), layout, 0);
  assert.equal(e.tick(0.1).hurry, false);
  f.update({running: false, job: Object.assign(job(['즉석밥', '시작']).job, {result: {success: true, retry: 0}})}, layout, 0.2);
  assert.equal(e.tick(0.3).hurry, true);
  assert.equal(e.busy, true, 'result must not jump the carriage to the end');
  assert.equal(e.tick(999).hurry, false, 'hurry ends once playback drains');
});

test('stop mid-Z retracts and aligns to the server last press, then stays; realigns on a later press', () => {
  const e = T.createEngine({catchUp: false, timing: {home: 0, moveBase: 1, movePerUnit: 0, press: 1, ret: 1}});
  e.enqueue([0.2, 0.2], {label: 'a'});
  e.enqueue([0.8, 0.8], {label: 'b'});
  e.tick(0);
  const mid = e.tick(1.5);   // pressing 'a', halfway down
  assert.equal(mid.phase, 'press'); assert.ok(mid.z > 0.2 && mid.z < 0.9);
  e.drain();
  const s = e.stop(1.5, [0.5, 0.25], {label: '즉석밥'});
  assert.equal(s.phase, 'aligning');
  assert.ok(e.stopped);
  assert.equal(e.enqueue([0, 0], {label: 'x'}), false);
  let p; for (let t = 1.5; t < 10; t += 0.05) { p = e.tick(t); }
  assert.deepEqual(e.drain().map(x => x.kind), ['halt', 'align_return', 'align_move', 'stopped']);
  assert.equal(p.phase, 'stopped'); assert.equal(p.z, 0);
  close(p.x, 0.5); close(p.y, 0.25);
  assert.equal(e.busy, false);
  // a press the server recorded after the stop request moves the alignment
  e.stop(20, [0.9, 0.1], {label: '시작'});
  const q = e.tick(40); assert.equal(q.phase, 'stopped'); close(q.x, 0.9); close(q.y, 0.1);
  // same target again: no-op
  e.drain(); e.stop(41, [0.9, 0.1]); assert.deepEqual(e.drain(), []);
  // reduced motion: instant
  const r = T.createEngine({scale: 0}); r.enqueue([0.3, 0.3]); r.tick(0);
  const rs = r.stop(0, [0.6, 0.6]); assert.equal(rs.phase, 'stopped'); close(rs.x, 0.6);
});

test('follower stop realignment uses the last recorded press and reports it', () => {
  const e = T.createEngine({scale: 0});
  const f = T.createFollower(e);
  const layout = T.layoutButtons(microwave);
  f.update(job(['즉석밥']), layout, 0);
  const out = f.update(job(['즉석밥'], {abort_requested: true}), layout, 1);
  assert.ok(out.froze);
  const p = e.tick(2);
  assert.equal(p.phase, 'stopped'); close(p.x, 1.5 / 3); close(p.y, 2.5 / 4); assert.equal(p.z, 0);
  const again = f.update(job(['즉석밥', '시작'], {abort_requested: true}), layout, 3);
  assert.ok(again.realigned);
  const q = e.tick(4); close(q.x, 2.5 / 3); close(q.y, 3.5 / 4);
  assert.equal(f.stopTarget(job(['즉석밥', '시작']), layout).label, '시작');
});

test('retry presses carry a concept XY nudge and the recorded correction flag', () => {
  const e = T.createEngine({scale: 0});
  const f = T.createFollower(e);
  const layout = T.layoutButtons(microwave);
  const state = job(['즉석밥']);
  state.job.press_log.push({n: 1, label: '즉석밥', step_index: 0, attempt: 2,
    correction: {retry_number: 1, xy_adjustment_required: true, increase_press_depth: true}});
  state.job.press_log.push({n: 2, label: '즉석밥', step_index: 0, attempt: 3, correction: null});
  f.update(state, layout, 0);
  e.tick(0);
  const moves = e.drain().filter(x => x.kind === 'move');
  assert.equal(moves.length, 3);
  assert.equal(moves[0].nudge, null);
  assert.deepEqual(moves[1].nudge, T.conceptNudge(1));
  assert.deepEqual(moves[1].correction, {recorded: true, xy: true, depth: true});
  assert.deepEqual(moves[2].nudge, T.conceptNudge(2));
  assert.equal(moves[2].correction.recorded, false);
  assert.ok(Math.hypot(...T.conceptNudge(1)) > 0);
});

test('single-motor demo: A only moves X and Y together (dB = 0), B only moves them oppositely', () => {
  const a = T.demoTarget([0.2, 0.2], 'A', 0.3);
  close(a.dx, 0.15); close(a.dy, 0.15); close(a.db, 0);
  const d = T.corexy(a.dx, a.dy); close(d.b, 0); close(d.a, 0.3);
  const b = T.demoTarget([0.2, 0.8], 'B', 0.3);
  close(b.dx, 0.15); close(b.dy, -0.15); close(T.corexy(b.dx, b.dy).a, 0);
  const flipped = T.demoTarget([0.95, 0.95], 'A', 0.3);
  close(flipped.dx, -0.15); close(flipped.dy, -0.15);
  const e = T.createEngine({scale: 0}); e.moveTo(a.to, {label: 'A만 회전'}); const p = e.tick(0);
  close(p.x, 0.35); close(p.y, 0.35); assert.equal(p.z, 0);
});

test('exec mode falls back to the simulator declaration before any job; poll pacing', () => {
  assert.equal(T.execModeText({running: false, execution_mode: 'unknown', last_execution_mode: 'unknown'}, {execution_mode: 'mock'}),
    'mock (시뮬레이터 선언 · 아직 실행 기록 없음)');
  assert.equal(T.execModeText({running: true, execution_mode: 'mock'}, {execution_mode: 'mock'}), 'mock (실행 중)');
  assert.equal(T.execModeText({running: false, execution_mode: 'unknown', last_execution_mode: 'mock'}, {}), 'mock (마지막 실행)');
  assert.equal(T.execModeText(null, null), 'unknown');
  assert.equal(T.pollInterval({running: true}), 400);
  assert.equal(T.pollInterval({running: false}), 2000);
  assert.equal(T.pollInterval(null), 2000);
});
