// Digital-twin concept motion. Pure: no DOM, no requests, no results.
// Coordinates are normalized to the control-panel workspace (0~1, y down).
// Pulley radius, mm scale, motor RPM and real timing are unknown, so every
// duration here is a screen pacing value, not a device speed. The official
// 310 rpm no-load speed is an upper bound for display only and is never used
// in timing.
(function (root) {
  'use strict';

  const DEFAULT_TIMING = { home: 0.7, moveBase: 0.3, movePerUnit: 0.8, press: 0.25, ret: 0.25 };
  const HOME = [0, 0];
  // Catch-up: every button still queued behind the current one shortens the
  // current segment. Once the server result is in, playback hurries further.
  // Screen pacing only (the server presses every step_seconds, ~0.8 s).
  const CATCH_UP = { gain: 0.6, hurry: 2, max: 6 };
  // Retry XY nudge drawn on screen. The executor records only a qualitative
  // correction request (no distance), so this size is a concept marker.
  const CONCEPT_NUDGE = 0.03;

  // CoreXY: ΔA = ΔX + ΔY, ΔB = ΔX − ΔY (same relative unit as X/Y).
  function corexy(dx, dy) { return { a: dx + dy, b: dx - dy }; }
  function inverse(a, b) { return { dx: (a + b) / 2, dy: (a - b) / 2 }; }
  function ease(t) { const c = Math.max(0, Math.min(1, t)); return c * c * (3 - 2 * c); }
  const clamp01 = v => Math.max(0, Math.min(1, v));

  // Button map → normalized positions. Never invents mm: grid cells stay grid cells.
  // mm coordinates keep their aspect ratio (uniform scale, centered). `aspect`
  // is the workspace width/height on screen so a square stays square.
  function layoutButtons(appliance, fallbackLabels, options) {
    const buttons = (appliance && Array.isArray(appliance.buttons)) ? appliance.buttons : [];
    const num = v => typeof v === 'number' && Number.isFinite(v);
    const aspect = options && num(options.aspect) && options.aspect > 0 ? options.aspect : 1;
    if (buttons.length && buttons.every(b => num(b.x_mm) && num(b.y_mm))) {
      const xs = buttons.map(b => b.x_mm), ys = buttons.map(b => b.y_mm);
      const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
      const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
      // Workspace in "height units": width = aspect, height = 1. Fit the span into 80 %.
      const sx = maxX - minX, sy = maxY - minY;
      const k = Math.min(sx > 1e-9 ? 0.8 * aspect / sx : Infinity, sy > 1e-9 ? 0.8 / sy : Infinity);
      const kk = Number.isFinite(k) ? k : 0;
      return { mode: 'mm', note: '보정된 mm 좌표를 가로세로 비율을 유지해 패널 가운데에 배치했습니다. 축척·원점은 개념입니다.',
        transform: { cx, cy, k: kk, aspect },
        buttons: buttons.map(b => ({ id: b.id, label: b.label,
          x: 0.5 + (b.x_mm - cx) * kk / aspect, y: 0.5 + (b.y_mm - cy) * kk })) };
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

  // Id first (unique), label only as a fallback (the wire protocol sends labels).
  function findButton(layout, ref) {
    if (!layout || !ref) return null;
    const r = typeof ref === 'string' ? { label: ref } : ref;
    if (r.id != null) { const b = layout.buttons.find(x => x.id === r.id); if (b) return b; }
    return r.label != null ? layout.buttons.find(x => x.label === r.label) || null : null;
  }

  // Concept nudge for retry n (1-based): rotates right/down/left/up.
  function conceptNudge(retry) {
    const dirs = [[1, 0], [0, 1], [-1, 0], [0, -1]];
    const d = dirs[(Math.max(1, retry) - 1) % 4];
    return [d[0] * CONCEPT_NUDGE, d[1] * CONCEPT_NUDGE];
  }

  // Single-motor demo: A only → ΔB = 0 → ΔX = ΔY (diagonal); B only → ΔX = −ΔY.
  // Flips direction if the move would leave the workspace.
  function demoTarget(pos, motor, amount) {
    const d = amount == null ? 0.3 : amount;
    for (const s of [1, -1]) {
      const { dx, dy } = motor === 'A' ? inverse(s * d, 0) : inverse(0, s * d);
      const t = [pos[0] + dx, pos[1] + dy];
      if (t[0] >= 0 && t[0] <= 1 && t[1] >= 0 && t[1] <= 1) {
        return { to: t, da: motor === 'A' ? s * d : 0, db: motor === 'B' ? s * d : 0, dx, dy };
      }
    }
    const { dx, dy } = motor === 'A' ? inverse(d, 0) : inverse(0, d);
    const t = [clamp01(pos[0] + dx), clamp01(pos[1] + dy)];
    const back = corexy(t[0] - pos[0], t[1] - pos[1]);
    return { to: t, da: back.a, db: back.b, dx: t[0] - pos[0], dy: t[1] - pos[1] };
  }

  function createEngine(options) {
    const timing = Object.assign({}, DEFAULT_TIMING, options && options.timing);
    const catchUp = options && options.catchUp === false ? null : Object.assign({}, CATCH_UP, options && options.catchUp);
    let scale = options && typeof options.scale === 'number' ? options.scale : 1;
    let pos = (options && options.start) ? options.start.slice() : HOME.slice();
    let z = 0, totalA = 0, totalB = 0;
    let queue = [], active = null, events = [], last = null, hurry = false;
    // halt: null (normal) | 'aligning' (stop: Z up, then go to last press) | 'stopped'
    let halt = null, alignTarget = null, alignLabel = null;

    function emit(e) { events.push(e); }
    function backlog() { return queue.filter(s => s.kind === 'move' && !s.align).length; }
    function speedup() {
      if (!catchUp || halt) return 1;
      const f = (1 + catchUp.gain * backlog()) * (hurry ? catchUp.hurry : 1);
      return Math.min(catchUp.max, f);
    }
    function dur(seg) {
      let base;
      if (seg.kind === 'home') base = timing.home;
      else if (seg.kind === 'move') base = timing.moveBase + timing.movePerUnit * Math.hypot(seg.to[0] - seg.from[0], seg.to[1] - seg.from[1]);
      else base = seg.kind === 'press' ? timing.press : timing.ret;
      return base * scale / speedup();
    }
    function begin(seg, start) {
      if (seg.kind === 'home' || seg.kind === 'move') seg.from = pos.slice();
      seg.zFrom = z;
      seg.start = start; seg.speedup = speedup(); seg.duration = dur(seg);
      active = seg;
      emit({ type: 'phase', kind: seg.align ? 'align_' + seg.kind : seg.kind, label: seg.label || null,
        id: seg.id ?? null, step_index: seg.step_index, attempt: seg.attempt, nudge: seg.nudge || null,
        correction: seg.correction || null, speedup: seg.speedup, demo: !!seg.demo });
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
    function phaseName() { return halt === 'stopped' ? 'stopped' : halt === 'aligning' ? 'aligning' : 'idle'; }
    function snapshot(extra) {
      return Object.assign({ x: pos[0], y: pos[1], z, a: totalA, b: totalB, da: 0, db: 0,
        phase: phaseName(), label: null, id: null, step_index: null, attempt: null, nudge: null, base: null,
        correction: null, pressing: z > 0.9, queued: queue.length, backlog: backlog(), speedup: 1, hurry }, extra || {});
    }
    function settleHalt() {
      if (halt === 'aligning' && !active && !queue.length) {
        halt = 'stopped';
        emit({ type: 'phase', kind: 'stopped', label: alignLabel });
      }
    }
    function freezeAt(now) {
      // Take the live pose as the new base (mid-move or mid-Z).
      const p = api.tick(now);
      pos = [p.x, p.y]; z = p.z; totalA = p.a; totalB = p.b;
      queue = []; active = null;
      return p;
    }

    const api = {
      home() { if (!halt) queue.push({ kind: 'home', to: HOME.slice(), label: '원점' }); },
      enqueue(target, meta) {
        if (halt) return false;
        const m = meta || {};
        const base = { label: m.label || null, id: m.id ?? null, step_index: m.step_index ?? null, attempt: m.attempt ?? null,
          nudge: m.nudge || null, correction: m.correction || null, base: [target[0], target[1]] };
        const to = m.nudge ? [clamp01(target[0] + m.nudge[0]), clamp01(target[1] + m.nudge[1])] : [target[0], target[1]];
        queue.push(Object.assign({ kind: 'move', to }, base));
        queue.push(Object.assign({ kind: 'press' }, base));
        queue.push(Object.assign({ kind: 'return' }, base));
        return true;
      },
      // XY only (no Z) — used by the single-motor demo.
      moveTo(target, meta) {
        if (halt) return false;
        queue.push(Object.assign({ kind: 'move', to: [target[0], target[1]], demo: true }, meta || {}));
        return true;
      },
      tick(now) {
        if (halt === 'stopped') return last || (last = snapshot());
        let clock = null;
        for (;;) {
          if (!active) {
            if (!queue.length) { hurry = false; settleHalt(); last = snapshot(); return last; }
            begin(queue.shift(), clock === null ? now : clock);
          }
          const t = active.duration > 0 ? (now - active.start) / active.duration : 1;
          if (t < 1) {
            const p = poseOf(active, t);
            const d = corexy(p.x - (active.from ? active.from[0] : pos[0]), p.y - (active.from ? active.from[1] : pos[1]));
            last = snapshot({ x: p.x, y: p.y, z: p.z, a: totalA + d.a, b: totalB + d.b, da: p.da, db: p.db,
              phase: active.align ? 'aligning' : active.kind, label: active.label, id: active.id ?? null,
              step_index: active.step_index, attempt: active.attempt, nudge: active.nudge || null,
              base: active.base || null, correction: active.correction || null,
              pressing: p.z > 0.9, progress: t, speedup: active.speedup || 1 });
            return last;
          }
          clock = active.start + active.duration;
          finish(active);
        }
      },
      // Stop: drop queued concept steps, never freeze mid-Z. Retract Z, then
      // (if given) move to the server's last recorded press position. Calling
      // again with a different target realigns (a press recorded after stop).
      // Nothing about the server result is implied.
      stop(now, target, meta) {
        const m = meta || {};
        const same = (target && alignTarget && Math.abs(target[0] - alignTarget[0]) < 1e-9 && Math.abs(target[1] - alignTarget[1]) < 1e-9)
          || (!target && halt);
        if (halt && same) return last;
        const wasHalted = !!halt;
        const p = freezeAt(now);
        halt = 'aligning'; hurry = false;
        alignTarget = target ? [target[0], target[1]] : alignTarget;
        alignLabel = m.label || alignLabel || null;
        if (z > 1e-6) queue.push({ kind: 'return', align: true, label: alignLabel });
        if (target && (Math.abs(target[0] - pos[0]) > 1e-9 || Math.abs(target[1] - pos[1]) > 1e-9)) {
          queue.push({ kind: 'move', to: [target[0], target[1]], align: true, label: alignLabel });
        }
        emit({ type: 'phase', kind: wasHalted ? 'realign' : 'halt', label: alignLabel, z: p.z, target: alignTarget });
        const out = api.tick(now);
        return out;
      },
      hurry(on) { hurry = !!on; },
      reset() { queue = []; active = null; halt = null; alignTarget = null; alignLabel = null; last = null; z = 0; hurry = false; },
      place(p) { pos = p.slice(); z = 0; last = null; },
      setScale(s) { scale = s; },
      drain() { const out = events; events = []; return out; },
      get stopped() { return !!halt; },
      get halted() { return halt; },
      get busy() { return !!active || queue.length > 0; },
      get backlog() { return backlog(); },
      get alignTarget() { return alignTarget; },
      get position() { return pos.slice(); },
    };
    return api;
  }

  // Follows /simulator/twin/state. Only server press records create motion;
  // repeated polls add nothing, and no result is ever produced here.
  function createFollower(engine) {
    let key = null, cursor = 0, missing = new Set(), historic = false;
    function where(layout, p) {
      const b = findButton(layout, { id: p.button_id, label: p.label });
      return b ? [b.x, b.y] : null;
    }
    function lastPressTarget(job, layout) {
      for (let i = job.press_log.length - 1; i >= 0; i--) {
        const at = where(layout, job.press_log[i]);
        if (at) return { at, label: job.press_log[i].label };
      }
      return null;
    }
    function feed(job, layout, from) {
      const notes = [];
      for (const p of job.press_log.slice(from)) {
        const at = where(layout, p);
        if (!at) { if (!missing.has(p.label)) notes.push('버튼맵에 없는 이름: ' + p.label); missing.add(p.label); continue; }
        const retry = p.attempt > 1 ? p.attempt - 1 : 0;
        const b = findButton(layout, { id: p.button_id, label: p.label });
        engine.enqueue(at, { label: p.label, id: b ? b.id : null, step_index: p.step_index, attempt: p.attempt,
          nudge: retry ? conceptNudge(retry) : null,
          correction: retry ? { recorded: !!p.correction, xy: !!(p.correction && p.correction.xy_adjustment_required),
            depth: !!(p.correction && p.correction.increase_press_depth) } : null });
      }
      return notes;
    }
    return {
      update(state, layout, now) {
        const out = { changed: false, historic: false, froze: false, realigned: false, notes: [] };
        const job = state && state.job;
        if (!job) return out;
        if (job.sequence_id !== key) {
          const first = key === null;
          key = job.sequence_id; cursor = 0; missing = new Set(); out.changed = true; historic = false;
          engine.reset();
          if (first && job.result && !state.running) {
            // Already finished before this page opened: show where the last
            // recorded press was, without replaying it as if it were live.
            const lp = lastPressTarget(job, layout);
            if (lp) engine.place(lp.at);
            cursor = job.press_log.length; out.historic = historic = true;
            return out;
          }
          engine.home();
        }
        if (job.press_log.length > cursor) {
          out.notes = feed(job, layout, cursor);
          cursor = job.press_log.length;
        }
        // Result in while motion is still behind: hurry (screen pacing only).
        if (job.result && engine.busy && !engine.stopped) engine.hurry(true);
        // A finished job's old abort must not freeze the static view.
        if (job.abort_requested && !historic) {
          const lp = lastPressTarget(job, layout);
          const was = engine.halted;
          const target = lp ? lp.at : null;
          const differs = target && (!engine.alignTarget || engine.alignTarget[0] !== target[0] || engine.alignTarget[1] !== target[1]);
          if (!was || differs) {
            engine.stop(now, target, { label: lp ? lp.label : null });
            if (!was) out.froze = true; else out.realigned = true;
          }
        }
        return out;
      },
      // Server's last recorded press position for the current job (for the stop button).
      stopTarget(state, layout) {
        const job = state && state.job;
        return job && job.sequence_id === key ? lastPressTarget(job, layout) : null;
      },
      replay(job, layout, now) {
        if (!job) return;
        engine.reset(); engine.home(); missing = new Set(); historic = !!job.result; feed(job, layout, 0);
        engine.tick(now);
      },
      get key() { return key; },
    };
  }

  // Server verdict text. The animation never decides it; while a result has
  // arrived but motion is still replaying, the final verdict is held back.
  function verdictText(twin, motionBusy) {
    const job = twin && twin.job;
    if (!job) return '아직 실행 기록이 없습니다.';
    const r = job.result;
    // RPi4 error frame (busy / actuator_fail): no result frame, never a success.
    if (!r && job.link_error) return `RPi4 오류 보고(error: ${job.link_error}) · 결과 프레임 없음`;
    if (!r) return twin.running ? '결과 대기 · 서버 보고 전' : '결과 프레임 없음 · 결과 미확인';
    if (motionBusy) return '모션 재생 중 · 서버 결과 도착';
    const retry = r.retry ?? '?';
    if (r.success && job.abort_requested) return `서버 보고: 성공(success=true, 재시도 ${retry}회) · 정지 요청이 늦어 모든 버튼 입력 후 성공 보고`;
    if (r.success) return `서버 보고: 성공(success=true, 재시도 ${retry}회) · ${runKindText(twin)}`;
    if (job.abort_requested) return `서버 보고: 실패(success=false) · 정지 요청 뒤 · 재시도 ${retry}회`;
    return `서버 보고: 실패(success=false) · 재시도 ${retry}회`;
  }

  // Execution mode line: running → execution_mode; else last_execution_mode;
  // before any job, the simulator's own declared mode (not "unknown").
  function execModeText(status, twin) {
    const ok = v => v && v !== 'unknown';
    if (status && status.running && ok(status.execution_mode)) return `${status.execution_mode} (실행 중)`;
    if (status && ok(status.last_execution_mode)) return `${status.last_execution_mode} (마지막 실행)`;
    if (twin && ok(twin.execution_mode)) return `${twin.execution_mode} (시뮬레이터 선언 · 아직 실행 기록 없음)`;
    return 'unknown';
  }

  // Poll pacing: fast only while the server job runs.
  function pollInterval(twin) { return twin && twin.running ? 400 : 2000; }

  // Real-mode twin (/twin) and recorded replay (/twin?replay=)
  // Which page is this? /simulator/twin keeps the simulator's own state route.
  function pageConfig(pathname, search) {
    const path = String(pathname || '');
    if (path.startsWith('/simulator/')) return { kind: 'simulator', base: '/simulator/twin', replay: null };
    let replay = null;
    try { replay = new URLSearchParams(search || '').get('replay'); } catch (e) { replay = null; }
    return replay ? { kind: 'replay', base: '/twin', replay } : { kind: 'real', base: '/twin', replay: null };
  }
  function stateUrl(cfg, t) {
    if (cfg.kind !== 'replay') return cfg.base + '/state';
    return `${cfg.base}/state?replay=${encodeURIComponent(cfg.replay)}&t=${Math.max(0, t || 0).toFixed(2)}`;
  }

  // Success wording suffix: which kind of run reported it.
  function runKindText(twin) {
    const mode = twin && twin.execution_mode;
    const replay = twin && twin.source === 'replay' ? '기록 재생 · ' : '';
    if (mode === 'real') return replay + '실기기(REAL) 보고';
    if (mode === 'mock') return replay + '모의 실행';
    if (twin && (twin.source === 'link_tap' || twin.source === 'replay')) return replay + '실행 환경 미확인';
    return '모의 실행';
  }

  // REAL / MOCK / UNKNOWN badge. Server status first (running → execution_mode,
  // else last_execution_mode); if it cannot tell (UART link = unknown), the
  // RPi4-reported mode in the twin state. A replay never reads the live status.
  function modeBadge(status, twin) {
    const ok = v => v === 'real' || v === 'mock';
    const out = (v, detail) => ({ text: String(v).toUpperCase(), mode: v, detail });
    const replay = twin && twin.source === 'replay';
    if (!replay && status && status.running && ok(status.execution_mode)) return out(status.execution_mode, '서버 /status · 실행 중');
    if (!replay && status && ok(status.last_execution_mode)) return out(status.last_execution_mode, '서버 /status · 마지막 실행');
    if (twin && ok(twin.execution_mode)) {
      const src = ({ rpi4_result: 'RPi4 result 프레임', rpi4_progress: 'RPi4 progress 프레임', controller: '서버 컨트롤러 선언' })[twin.execution_mode_source] || '트윈 상태';
      return out(twin.execution_mode, (replay ? '기록 · ' : '') + src);
    }
    return { text: 'UNKNOWN', mode: 'unknown', detail: replay ? '기록에 실행 환경 보고 없음' : '아직 보고 없음' };
  }

  // mm → normalized panel coords, only when the layout itself is mm-based.
  function mmToLayout(layout, xMm, yMm) {
    const num = v => typeof v === 'number' && Number.isFinite(v);
    if (!layout || layout.mode !== 'mm' || !layout.transform || !num(xMm) || !num(yMm)) return null;
    const { cx, cy, k, aspect } = layout.transform;
    return [clamp01(0.5 + (xMm - cx) * k / aspect), clamp01(0.5 + (yMm - cy) * k)];
  }

  // Where to draw the carriage and what to call it. Only the MCU-reported
  // encoder position (converted to mm on RPi4) is labelled as a measurement;
  // everything else is the command-based estimate (real page) or concept motion.
  function carriageView(twin, layout, pose, pageKind) {
    const base = { x: pose.x, y: pose.y };
    if (pageKind === 'simulator') return Object.assign(base, { kind: 'concept', label: '개념 모션' });
    const c = twin && twin.job && twin.job.carriage;
    if (c && c.kind === 'encoder') {
      const at = mmToLayout(layout, c.x_mm, c.y_mm);
      if (at) return { x: at[0], y: at[1], kind: 'encoder', label: '엔코더 보고 위치', counts: c };
      return Object.assign(base, { kind: 'estimate', label: '명령 기준 추정',
        note: '엔코더 보고는 있지만 버튼맵이 mm 배치가 아니어서 그림에 옮기지 못함', counts: c });
    }
    return Object.assign(base, { kind: 'estimate', label: '명령 기준 추정',
      counts: c && c.encoder_counts ? c.encoder_counts : null });
  }

  const api = { corexy, inverse, ease, layoutButtons, findButton, conceptNudge, demoTarget, createEngine, createFollower,
    verdictText, execModeText, pollInterval, pageConfig, stateUrl, runKindText, modeBadge, mmToLayout, carriageView,
    DEFAULT_TIMING, CATCH_UP, CONCEPT_NUDGE, HOME };
  root.TwinMotion = api;
  if (typeof module !== 'undefined') module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
