const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {sample} = require('../touchscreen/parking-motion.js');

test('CoreXY equal, opposite and single motor displacement', () => {
  assert.equal(sample([0,0], [1,0], 1).a, 1);
  assert.equal(sample([0,0], [1,0], 1).b, 1);
  assert.equal(sample([0,0], [0,1], 1).a, 1);
  assert.equal(sample([0,0], [0,1], 1).b, -1);
  assert.equal(sample([0,0], [1,1], 1).b, 0);
  assert.equal(sample([0,1], [1,0], 1).a, 0);
});

test('interpolation endpoints, bounds and inverse kinematics', () => {
  for (const t of [-1, 0, .2, .5, .9, 1, 2]) {
    const s = sample([.2,.7], [.8,.1], t);
    assert.ok(s.x >= .2 && s.x <= .800001);
    assert.ok(s.y >= .099999 && s.y <= .7);
    assert.ok(Math.abs((s.a+s.b)/2 - (s.x-.2)) < 1e-10);
    assert.ok(Math.abs((s.a-s.b)/2 - (s.y-.7)) < 1e-10);
  }
});

function harness() {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, {style:{}, value:'3', checked:false,
      attrs:{}, setAttribute(k,v){this.attrs[k]=v;}});
    return elements.get(id);
  };
  const frames = new Map();
  let counter = 0;
  const context = {document:{getElementById:get, addEventListener(){}},
    performance:{now:()=>0}, requestAnimationFrame:fn=>{frames.set(++counter,fn);return counter;},
    cancelAnimationFrame:id=>frames.delete(id),
    matchMedia:()=>({matches:false,addEventListener(){}})};
  context.window = context;
  vm.runInNewContext(fs.readFileSync(require.resolve('../touchscreen/parking-motion.js'),'utf8'), context);
  return {get, frames, preview:context.CoreXYPreview};
}
const state = () => ({session:'s',phase:'awaiting_motion_ack',position:[.3,.4],
  z_retracted:true,pending:{id:2,kind:'move',target:[.8,.7]}});

test('animation completion does not acknowledge, and repeated polls do not replay', () => {
  const h = harness(), s = state(), original = JSON.stringify(s);
  h.preview.update(s,true);
  const size=h.frames.size;
  h.preview.update(s,true);
  assert.equal(h.frames.size,size);
  const callback=[...h.frames.values()][0];
  h.frames.clear(); callback(3001);
  assert.match(h.get('motionNote').textContent,/성공 응답은 별도로/);
  assert.equal(JSON.stringify(s),original);
  assert.equal(h.frames.size,0);
});

test('link failure and emergency lock cancel motion; unknown origin is not invented', () => {
  const h=harness(); h.preview.update(state(),true);
  h.preview.update(state(),false);
  assert.equal(h.frames.size,0);
  assert.equal(h.get('previewHead').style.display,'none');
  h.preview.update({...state(),phase:'locked_manual_recovery_required'},true);
  h.get('replay').onclick();
  assert.equal(h.frames.size,0);
  const unknown=harness();unknown.preview.update({...state(),position:null},true);
  assert.equal(unknown.frames.size,0);
  assert.match(unknown.get('motionNote').textContent,/출발 위치 미확인/);
});
