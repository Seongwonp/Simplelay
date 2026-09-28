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
  close(mm.buttons[0].x, 0.1); close(mm.buttons[1].y, 0.9);
  const partial = T.layoutButtons({rows: 4, cols: 3, buttons: [
    {label: 'a', x: 0, y: 0, x_mm: 10, y_mm: 20}, {label: 'b', x: 1, y: 1}]});
  assert.equal(partial.mode, 'grid');
  const none = T.layoutButtons(null, ['즉석밥', '시작', '즉석밥']);
  assert.equal(none.mode, 'placeholder');
  assert.equal(none.buttons.length, 2);
  assert.match(none.note, /임시 배치/);
});

test('sequence stepping: home, then move → press → return per button, A/B totals follow CoreXY', () => {
  const e = T.createEngine({timing: {home: 1, moveBase: 1, movePerUnit: 0, press: 1, ret: 1}});
  e.home();
  e.enqueue([1, 0], {label: 'x'});
  e.enqueue([1, 1], {label: 'y'});
  const phases = [];
  for (let t = 0.5; t < 8; t += 1) phases.push(e.tick(t).phase);
  assert.deepEqual(phases, ['home', 'move', 'press', 'return', 'move', 'press', 'return', 'idle']);
  const mid = T.createEngine({timing: {home: 1, moveBase: 1, movePerUnit: 0, press: 1, ret: 1}});
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
