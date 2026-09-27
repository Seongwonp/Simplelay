// Screen-only kinematics. This file sends no requests and produces no sensor ACKs.
// Coordinates share one normalized unit; pulley radii, mm and motor RPM are unknown.
(function (root) {
  'use strict';
  function sample(from, to, progress) {
    const t = Math.max(0, Math.min(1, progress));
    const eased = t * t * (3 - 2 * t);
    const dx = (to[0] - from[0]) * eased;
    const dy = (to[1] - from[1]) * eased;
    return { x: from[0] + dx, y: from[1] + dy, a: dx + dy, b: dx - dy, progress: t };
  }
  root.CoreXYPreview = { sample };
  if (typeof module !== 'undefined') module.exports = { sample };
  if (typeof document === 'undefined') return;

  const el = id => document.getElementById(id);
  let frame = null, key = null, latest = null, connected = false, endZ = 0;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const xy = p => [80 + 340 * p[0], 65 + 340 * p[1]];
  const signed = n => (n >= 0 ? '+' : '') + n.toFixed(3);
  function cancel() { if (frame !== null) cancelAnimationFrame(frame); frame = null; }
  function pose(p, depth, a = 0, b = 0) {
    el('previewHead').style.display = p ? '' : 'none';
    el('gantry').style.display = p ? '' : 'none';
    if (p) {
      const [x, y] = xy(p);
      el('previewHead').setAttribute('transform', `translate(${x},${y})`);
      el('gantry').setAttribute('transform', `translate(0,${y})`);
    }
    el('zRod').setAttribute('transform', `translate(0,${depth * 45})`);
    el('motorA').setAttribute('transform', `rotate(${a * 360} 80 455)`);
    el('motorB').setAttribute('transform', `rotate(${b * 360} 420 455)`);
    el('beltA').style.strokeDashoffset = String(-a * 100);
    el('beltB').style.strokeDashoffset = String(-b * 100);
    el('motorReadout').textContent = `ΔA ${signed(a)} · ΔB ${signed(b)} (상대 단위)`;
  }
  function animate(s) {
    cancel();
    const action = s.pending;
    if (!action) {
      pose(s.position, s.z_retracted ? 0 : endZ);
      el('motionNote').textContent = '진행 중인 모의 이동 명령이 없습니다.';
      return;
    }
    const from = s.position;
    if (!from && action.kind === 'move') {
      pose(null, 0);
      el('motionNote').textContent = '출발 위치 미확인 · XY 경로를 추정하지 않습니다.';
      return;
    }
    const to = action.target || from;
    // Normalized preview stroke, not a measured depth: input-complete Z is unknown.
    const startZ = action.kind === 'press_stop' ? 0 : (s.z_retracted ? 0 : 1);
    const goalZ = action.kind === 'press_stop' ? 1 : 0;
    const duration = Number(el('duration').value) * 1000;
    const noMotion = reduced.matches || el('reduceMotion').checked;
    const started = performance.now();
    function tick(now) {
      const t = noMotion ? 1 : Math.min(1, (now - started) / duration);
      const motion = from && to ? sample(from, to, t) : null;
      const z = action.kind === 'move' ? 0 : startZ + (goalZ - startZ) * t;
      pose(motion ? [motion.x, motion.y] : null, z,
        action.kind === 'move' ? motion?.a || 0 : 0,
        action.kind === 'move' ? motion?.b || 0 : 0);
      endZ = z;
      el('motionNote').textContent = t < 1
        ? `예상 ${action.kind === 'move' ? 'CoreXY 이동' : 'Z 동작'} ${Math.round(t * 100)}% · 센서 확인 아님`
        : '예상 모션 끝 · 성공 응답은 별도로 주입해야 합니다.';
      frame = t < 1 ? requestAnimationFrame(tick) : null;
    }
    frame = requestAnimationFrame(tick);
  }
  root.CoreXYPreview.update = function (s, online) {
    latest = s;
    connected = online;
    if (!online || !s || s.phase === 'locked_manual_recovery_required') {
      cancel(); pose(null, endZ);
      el('motionNote').textContent = online ? '잠금 · 모션 중지, 위치 미확인' : '연결 미확인 · 모션 중지';
      el('replay').disabled = true;
      return;
    }
    el('replay').disabled = !s.pending;
    // A repeated status poll must not restart an animation or turn it into evidence.
    const nextKey = `${s.session}:${s.phase}:${s.pending?.id || 0}`;
    if (nextKey === key) return;
    if (!key || !key.startsWith(s.session + ':')) endZ = 0;
    key = nextKey;
    animate(s);
  };
  el('replay').onclick = () => {
    if (connected && latest?.pending && latest.phase !== 'locked_manual_recovery_required') animate(latest);
  };
  function reduceChanged() { if (latest && connected && latest.phase !== 'locked_manual_recovery_required') animate(latest); }
  el('reduceMotion').onchange = reduceChanged;
  reduced.addEventListener('change', reduceChanged);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { cancel(); el('motionNote').textContent = '화면을 떠나 모션 일시 중지 · 다시 재생 가능'; }
  });
})(typeof window === 'undefined' ? globalThis : window);
