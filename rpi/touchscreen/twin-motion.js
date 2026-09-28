// Digital-twin concept motion. Pure: no DOM, no requests, no results.
// Coordinates are normalized to the control-panel workspace (0~1, y down).
// Pulley radius, mm scale, motor RPM and real timing are unknown, so every
// duration here is a screen pacing value, not a device speed.
(function (root) {
  'use strict';

  const DEFAULT_TIMING = { home: 0.7, moveBase: 0.3, movePerUnit: 0.8, press: 0.25, ret: 0.25 };
  const HOME = [0, 0];

  // CoreXY: ΔA = ΔX + ΔY, ΔB = ΔX − ΔY (same relative unit as X/Y).
  function corexy(dx, dy) { return { a: dx + dy, b: dx - dy }; }
  function inverse(a, b) { return { dx: (a + b) / 2, dy: (a - b) / 2 }; }
  function ease(t) { const c = Math.max(0, Math.min(1, t)); return c * c * (3 - 2 * c); }

  // Button map → normalized positions. Never invents mm: grid cells stay grid cells.
  function layoutButtons(appliance, fallbackLabels) {
    const buttons = (appliance && Array.isArray(appliance.buttons)) ? appliance.buttons : [];
    const num = v => typeof v === 'number' && Number.isFinite(v);
    if (buttons.length && buttons.every(b => num(b.x_mm) && num(b.y_mm))) {
      const xs = buttons.map(b => b.x_mm), ys = buttons.map(b => b.y_mm);
      const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
      const n = (v, lo, hi) => (hi - lo > 1e-9 ? 0.1 + 0.8 * (v - lo) / (hi - lo) : 0.5);
      return { mode: 'mm', note: '보정된 mm 좌표를 패널 범위로 정규화했습니다. 축척·원점은 개념입니다.',
        buttons: buttons.map(b => ({ id: b.id, label: b.label, x: n(b.x_mm, minX, maxX), y: n(b.y_mm, minY, maxY) })) };
    }
    const rows = appliance && appliance.rows, cols = appliance && appliance.cols;
    if (buttons.length && rows > 0 && cols > 0 && buttons.every(b => num(b.x) && num(b.y))) {
      return { mode: 'grid', note: '편집기 격자 칸 배치입니다. 실제 mm 좌표가 아닙니다(보정 전).',
        buttons: buttons.map(b => ({ id: b.id, label: b.label, x: (b.x + 0.5) / cols, y: (b.y + 0.5) / rows })) };
    }
    const labels = buttons.length ? buttons.map(b => b.label) : (fallbackLabels || []);
    const unique = [...new Set(labels.map(String))];
    const c = 3, r = Math.max(1, Math.ceil(unique.length / c));
    return { mode: 'placeholder', note: '버튼 좌표가 없어 임시 배치로 표시합니다. 실제 위치가 아닙니다.',
      buttons: unique.map((label, i) => ({ id: 'tmp-' + i, label, x: ((i % c) + 0.5) / c, y: (Math.floor(i / c) + 0.5) / r })) };
  }

  function createEngine(options) {
    const timing = Object.assign({}, DEFAULT_TIMING, options && options.timing);
    let scale = options && typeof options.scale === 'number' ? options.scale : 1;
    let pos = (options && options.start) ? options.start.slice() : HOME.slice();
    let z = 0, totalA = 0, totalB = 0;
    let queue = [], active = null, stopped = false, events = [], last = null;

    function emit(e) { events.push(e); }
    function dur(seg) {
      if (seg.kind === 'home') return timing.home * scale;
      if (seg.kind === 'move') return (timing.moveBase + timing.movePerUnit * Math.hypot(seg.to[0] - seg.from[0], seg.to[1] - seg.from[1])) * scale;
      return (seg.kind === 'press' ? timing.press : timing.ret) * scale;
    }
    function begin(seg, start) {
      if (seg.kind === 'home' || seg.kind === 'move') seg.from = pos.slice();
      seg.start = start; seg.duration = dur(seg);
      seg.zFrom = z;
      active = seg;
      emit({ type: 'phase', kind: seg.kind, label: seg.label || null, step_index: seg.step_index, attempt: seg.attempt });
    }
    function poseOf(seg, t) {
      const e = ease(t);
      if (seg.kind === 'home' || seg.kind === 'move') {
        const dx = (seg.to[0] - seg.from[0]) * e, dy = (seg.to[1] - seg.from[1]) * e;
        const d = corexy(dx, dy);
        // Homing retracts Z first (concept); a normal move keeps Z retracted.
        return { x: seg.from[0] + dx, y: seg.from[1] + dy, z: seg.kind === 'home' ? seg.zFrom * (1 - Math.min(1, t * 3)) : 0,
          da: d.a, db: d.b };
      }
      const zz = seg.kind === 'press' ? seg.zFrom + (1 - seg.zFrom) * e : seg.zFrom * (1 - e);
      return { x: pos[0], y: pos[1], z: zz, da: 0, db: 0 };
    }
    function finish(seg) {
      if (seg.kind === 'home' || seg.kind === 'move') {
        const d = corexy(seg.to[0] - seg.from[0], seg.to[1] - seg.from[1]);
        totalA += d.a; totalB += d.b; pos = seg.to.slice(); z = 0;
      } else z = seg.kind === 'press' ? 1 : 0;
      active = null;
    }
    function snapshot(extra) {
      return Object.assign({ x: pos[0], y: pos[1], z, a: totalA, b: totalB, da: 0, db: 0,
        phase: stopped ? 'stopped' : 'idle', label: null, step_index: null, attempt: null,
        pressing: z > 0.9, queued: queue.length }, extra || {});
    }

    const api = {
      home() { if (!stopped) queue.push({ kind: 'home', to: HOME.slice(), label: '원점' }); },
      enqueue(target, meta) {
        if (stopped) return false;
        const m = meta || {};
        const base = { label: m.label || null, step_index: m.step_index ?? null, attempt: m.attempt ?? null };
        queue.push(Object.assign({ kind: 'move', to: [target[0], target[1]] }, base));
        queue.push(Object.assign({ kind: 'press' }, base));
        queue.push(Object.assign({ kind: 'return' }, base));
        return true;
      },
      tick(now) {
        if (stopped) return last || (last = snapshot());
        let clock = null;
        for (;;) {
          if (!active) {
            if (!queue.length) { last = snapshot(); return last; }
            begin(queue.shift(), clock === null ? now : clock);
          }
          const t = active.duration > 0 ? (now - active.start) / active.duration : 1;
          if (t < 1) {
            const p = poseOf(active, t);
            const d = corexy(p.x - (active.from ? active.from[0] : pos[0]) , p.y - (active.from ? active.from[1] : pos[1]));
            last = snapshot({ x: p.x, y: p.y, z: p.z, a: totalA + d.a, b: totalB + d.b, da: p.da, db: p.db,
              phase: active.kind, label: active.label, step_index: active.step_index, attempt: active.attempt,
              pressing: p.z > 0.9, progress: t });
            return last;
          }
          clock = active.start + active.duration;
          finish(active);
        }
      },
      // Freeze where the carriage is now. Queued concept steps are dropped;
      // nothing about the server result is implied.
      stop(now) {
        if (stopped) return last;
        const p = api.tick(now);
        pos = [p.x, p.y]; z = p.z; totalA = p.a; totalB = p.b;
        queue = []; active = null; stopped = true;
        last = snapshot({ phase: 'stopped' });
        emit({ type: 'phase', kind: 'stopped', label: null });
        return last;
      },
      reset() { queue = []; active = null; stopped = false; last = null; z = 0; },
      place(p) { pos = p.slice(); z = 0; last = null; },
      setScale(s) { scale = s; },
      drain() { const out = events; events = []; return out; },
      get stopped() { return stopped; },
      get busy() { return !!active || queue.length > 0; },
    };
    return api;
  }

  // Follows /simulator/twin/state. Only server press records create motion;
  // repeated polls add nothing, and no result is ever produced here.
  function createFollower(engine) {
    let key = null, cursor = 0, missing = new Set(), historic = false;
    function where(layout, label) {
      const b = layout && layout.buttons.find(x => x.label === label);
      return b ? [b.x, b.y] : null;
    }
    function feed(job, layout, from) {
      const notes = [];
      for (const p of job.press_log.slice(from)) {
        const at = where(layout, p.label);
        if (!at) { if (!missing.has(p.label)) notes.push('버튼맵에 없는 이름: ' + p.label); missing.add(p.label); continue; }
        engine.enqueue(at, { label: p.label, step_index: p.step_index, attempt: p.attempt });
      }
      return notes;
    }
    return {
      update(state, layout, now) {
        const out = { changed: false, historic: false, froze: false, notes: [] };
        const job = state && state.job;
        if (!job) return out;
        if (job.sequence_id !== key) {
          const first = key === null;
          key = job.sequence_id; cursor = 0; missing = new Set(); out.changed = true; historic = false;
          engine.reset();
          if (first && job.result && !state.running) {
            // Already finished before this page opened: show where the last
            // recorded press was, without replaying it as if it were live.
            const lastPress = job.press_log[job.press_log.length - 1];
            const at = lastPress && where(layout, lastPress.label);
            if (at) engine.place(at);
            cursor = job.press_log.length; out.historic = historic = true;
            return out;
          }
          engine.home();
        }
        if (job.press_log.length > cursor) {
          out.notes = feed(job, layout, cursor);
          cursor = job.press_log.length;
        }
        // A finished job's old abort must not freeze the static view.
        if (job.abort_requested && !historic && !engine.stopped) { engine.stop(now); out.froze = true; }
        return out;
      },
      replay(job, layout, now) {
        if (!job) return;
        engine.reset(); engine.home(); missing = new Set(); historic = !!job.result; feed(job, layout, 0);
        engine.tick(now);
      },
      get key() { return key; },
    };
  }

  const api = { corexy, inverse, ease, layoutButtons, createEngine, createFollower, DEFAULT_TIMING, HOME };
  root.TwinMotion = api;
  if (typeof module !== 'undefined') module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
