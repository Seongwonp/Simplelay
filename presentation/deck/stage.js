// 무대 창 — 장 넘김·레터박스·본체 실시간 값(읽기만)·발표자 창 동기화.
// 본체 값은 같은 출처의 /api/* 로만 읽는다(serve.py가 본체로 전달하고 키를 붙인다 — 이 파일에 키·주소를 두지 않는다).
// 본체에 닿지 못하면 각 장은 '미리보기'로 보이고, 미리보기 값은 늘 '미리보기'라고 표시한다.
(function () {
  "use strict";
  const DATA = window.DECK_SLIDES;
  const slides = [...document.querySelectorAll(".slide")];
  const stage = document.getElementById("stage");
  const chan = "BroadcastChannel" in window ? new BroadcastChannel("simplelay-deck") : null;

  // 실시간 소비전력(W)을 주는 본체 GET 경로가 아직 없다 — 생기면 여기에 경로를 넣는다.
  const POWER_ENDPOINT = null;

  let cur = 0;
  let timers = [];
  let slideToken = 0;
  let emergency = false; // E 키 대체 장면 — 전자레인지 장은 '11월 2일 실측', 모은 기록 장은 '11월 3일 스냅숏'
  const hub = { connected: false, version: null, checkedAt: null };

  // ---------- 레터박스 ----------
  function fit() {
    const s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    stage.style.transform = "translate(-50%, -50%) scale(" + s + ")";
  }
  window.addEventListener("resize", fit);
  fit();

  // ---------- 공통 ----------
  function clearTimers() { timers.forEach((t) => { clearTimeout(t); clearInterval(t); }); timers = []; }
  function later(ms, f) { timers.push(setTimeout(f, ms)); }
  // 앞 요청이 아직 안 끝났으면 건너뛴다 — 본체가 느릴 때 요청이 쌓이지 않게.
  function every(ms, f) {
    let busy = false;
    const tick = async () => {
      if (busy) return;
      busy = true;
      try { await f(); } finally { busy = false; }
    };
    tick();
    timers.push(setInterval(tick, ms));
  }
  const $ = (id) => document.getElementById(id);

  function setSrc(el, kind, text) {
    el.className = "src" + (kind === "live" ? " live" : kind === "off" ? " off" : "");
    el.textContent = text;
  }

  async function getJSON(path) {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 3500);
    try {
      const res = await fetch("/api" + path, { cache: "no-store", signal: ctl.signal, headers: { Accept: "application/json" } });
      if (!res.ok) return null;
      return await res.json();
    } catch (e) {
      return null;
    } finally {
      clearTimeout(t);
    }
  }

  // ---------- 본체 연결 ----------
  async function checkHub() {
    const h = await getJSON("/health");
    const was = hub.connected;
    hub.connected = !!(h && h.ok);
    hub.version = h && h.version ? h.version : null;
    hub.checkedAt = Date.now();
    const live = $("live");
    live.classList.toggle("on", hub.connected);
    live.querySelector("span").textContent = hub.connected ? "본체 연결됨" : "본체 미연결 · 미리보기";
    if (was !== hub.connected) run(); // 연결이 바뀌면 지금 장을 다시 그린다
    broadcast();
  }

  // ---------- 장 이동 ----------
  function show(i) {
    const n = Math.max(0, Math.min(slides.length - 1, i));
    if (n !== cur) emergency = false;
    cur = n;
    slides.forEach((s, j) => s.classList.toggle("on", j === cur));
    const mainCount = DATA.filter((d) => !d.appendix).length;
    const isAp = !!(DATA[cur] && DATA[cur].appendix);
    $("progress").style.width = (isAp ? 100 : ((cur + 1) / mainCount) * 100) + "%";
    $("pageno").textContent = isAp ? "부록 " + (cur + 1 - mainCount) : cur + 1 + " / " + mainCount;
    try { history.replaceState(null, "", "#" + (cur + 1)); } catch (e) { /* file 열기 등 */ }
    run();
    broadcast();
  }

  function run() {
    clearTimers();
    const token = ++slideToken;
    const k = slides[cur].dataset.k;
    const alive = () => token === slideToken;
    if (k === "presence") runPresence(alive);
    if (k === "records") runRecords(alive);
    if (k === "method") runMethod(alive);
    if (k === "habit") runHabit(alive);
    if (k === "steps") runSteps(alive);
    if (k === "chat") runChat();
    if (k === "microwave") runPower();
    if (k === "toggles") runToggles(alive);
  }

  // ---------- 집에 옴: GET /presence/room ----------
  const PRESENCE_TEXT = {
    present: ["사람이 보여요", "화면을 깨웠어요"],
    idle: ["잠시 자리 비움", "화면이 쉬는 중"],
    away: ["한동안 안 보임", "화면이 쉬는 중"],
    unknown: ["살펴보는 중", "아직 판단 전이에요"],
  };
  function setPresence(state, sub) {
    const p = $("pres");
    const t = PRESENCE_TEXT[state] || PRESENCE_TEXT.unknown;
    p.textContent = t[0];
    p.classList.toggle("yes", state === "present");
    $("presSub").textContent = sub || t[1];
  }
  function runPresence(alive) {
    if (!hub.connected) {
      setPresence("away", "화면이 쉬는 중");
      $("pres").textContent = "아무도 없음";
      setSrc($("presSrc"), "preview", "미리보기 — 본체 미연결");
      later(1500, () => setPresence("present"));
      return;
    }
    setSrc($("presSrc"), "off", "본체 값 불러오는 중");
    every(1500, async () => {
      const r = await getJSON("/presence/room");
      if (!alive()) return;
      if (!r) { setPresence("unknown", "본체에서 값을 받지 못했어요"); setSrc($("presSrc"), "off", "값 못 받음"); return; }
      if (!r.enabled) { setPresence("unknown", "사람 감지가 꺼져 있어요"); $("pres").textContent = "사람 감지 꺼짐"; }
      else if (!r.camera_enabled) { setPresence("unknown", "카메라를 꺼 두었어요"); $("pres").textContent = "카메라 꺼짐"; }
      else setPresence(r.state);
      setSrc($("presSrc"), "live", "본체 실시간 값");
    });
  }

  // ---------- 공통: 날짜·습관 ----------
  const SNAP = window.DECK_RECORDS_SNAPSHOT || { label: "", records: [], habits: [] };
  function md(iso) {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || "");
    return m ? Number(m[2]) + "/" + Number(m[3]) : iso;
  }
  // 무대 표기: 날짜는 '10월 18일', 시각은 '낮 12시 59분'처럼 말로.
  function kd(v) {
    const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(v || "");
    if (iso) return Number(iso[2]) + "월 " + Number(iso[3]) + "일";
    const short = /^(\d{1,2})\/(\d{1,2})$/.exec(v || "");
    return short ? Number(short[1]) + "월 " + Number(short[2]) + "일" : v;
  }
  function spoken(hhmm) {
    const m = /^(\d{1,2}):(\d{2})/.exec(hhmm || "");
    if (!m) return hhmm;
    const h = Number(m[1]), mi = Number(m[2]);
    const part = h < 6 ? "새벽" : h < 12 ? "오전" : h < 13 ? "낮" : h < 18 ? "오후" : h < 21 ? "저녁" : "밤";
    const hh = h === 0 ? 12 : h > 12 ? h - 12 : h;
    return part + " " + hh + "시" + (mi ? " " + mi + "분" : "");
  }
  function pickHabit(routines) {
    const list = (routines || []).filter((r) => !r.muted && r.state !== "hidden");
    list.sort((a, b) => (b.established - a.established) || (b.distinct_days - a.distinct_days) || (b.occurrences - a.occurrences));
    return list[0] || null;
  }

  // ---------- 모은 기록: GET /history (본체 실행 기록) · 미연결이면 11월 3일 스냅숏 ----------
  const KIND_STYLE = { on: "#11a39a", off: "#14302c", wind: "#e39320", micro: "#7a5cc7", other: "#5b726e" };
  function kindOf(text) {
    const t = text || "";
    if (/전자레인지/.test(t)) return "micro";
    if (/바람|풍량|강풍|세기|수면/.test(t)) return "wind";
    if (/끄|꺼/.test(t)) return "off";
    if (/켜|켬/.test(t)) return "on";
    return "other";
  }
  function drawRecords(recs) {
    // recs: [{day:"YYYY-MM-DD", min: 0..1439, k, mock:boolean}]
    const svg = $("recSvg");
    const NS = "http://www.w3.org/2000/svg";
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    const X0 = 90, X1 = 1580, Y0 = 20, Y1 = 540;
    const days = recs.map((r) => r.day).sort();
    const first = days.length ? new Date(days[0] + "T00:00:00") : new Date();
    const last = days.length ? new Date(days[days.length - 1] + "T00:00:00") : new Date();
    const span = Math.max(1, Math.round((last - first) / 86400000));
    const xOf = (day) => X0 + 20 + ((Math.round((new Date(day + "T00:00:00") - first) / 86400000)) / span) * (X1 - X0 - 40);
    const yOf = (min) => Y0 + (min / 1440) * (Y1 - Y0);
    const el = (tag, attrs, text) => {
      const e = document.createElementNS(NS, tag);
      Object.entries(attrs).forEach(([k, v]) => e.setAttribute(k, v));
      if (text != null) e.textContent = text;
      svg.append(e); return e;
    };
    [0, 6, 12, 18, 24].forEach((h) => {
      const y = yOf(h * 60);
      el("line", { x1: X0, x2: X1, y1: y, y2: y, class: "gl" });
      el("text", { x: X0 - 14, y: y + 8, "text-anchor": "end", class: "ax" }, (h === 12 ? "낮 12시" : h === 0 || h === 24 ? "밤 12시" : h < 12 ? "오전 " + h + "시" : "오후 " + (h - 12) + "시"));
    });
    const step = span > 20 ? 3 : 2;
    for (let i = 0; i <= span; i += step) {
      const d = new Date(first.getTime() + i * 86400000);
      const iso = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
      el("text", { x: xOf(iso), y: Y1 + 40, "text-anchor": "middle", class: "ax" }, (d.getMonth() + 1) + "월 " + d.getDate() + "일");
    }
    recs.forEach((r) => {
      const x = xOf(r.day), y = yOf(r.min);
      const fill = r.mock ? "#c9d3d1" : (KIND_STYLE[r.k] || KIND_STYLE.other);
      if (r.k === "wind") el("rect", { x: x - 9, y: y - 9, width: 18, height: 18, fill, transform: "rotate(45 " + x + " " + y + ")" });
      else if (r.k === "micro") el("rect", { x: x - 10, y: y - 10, width: 20, height: 20, rx: 3, fill });
      else el("circle", { cx: x, cy: y, r: 10, fill, "fill-opacity": 0.9 });
      if (r.mock) el("text", { x: x + 16, y: y + 7, class: "ax" }, "모의");
      if (r.note) el("text", { x: x - 16, y: y + 7, class: "ax", "text-anchor": "end" }, r.note);
    });
  }
  function snapRecords() {
    return SNAP.records.map((r) => {
      const [h, m] = r.t.split(":").map(Number);
      return { day: r.d, min: h * 60 + m, k: r.k, mock: r.mode === "mock", note: r.note };
    });
  }
  function showSnapshotRecords() {
    drawRecords(snapRecords());
    setSrc($("recSrc"), "live", SNAP.label);
    const real = SNAP.records.filter((r) => r.mode !== "mock").length;
    $("recNote").textContent = "실제 " + real + "건 · 모의 " + (SNAP.records.length - real) + "건(회색)";
  }
  function runRecords(alive) {
    if (!hub.connected || emergency) { showSnapshotRecords(); return; }
    setSrc($("recSrc"), "off", "본체 기록 불러오는 중");
    every(30000, async () => {
      const list = await getJSON("/history?limit=200");
      if (!alive()) return;
      if (!Array.isArray(list)) { showSnapshotRecords(); $("recNote").textContent += " · 본체 기록을 받지 못해 스냅숏을 보여요"; return; }
      const recs = [];
      list.forEach((e) => {
        if (e.outcome !== "success") return;
        const d = new Date(e.finished_at);
        if (isNaN(d)) return;
        const day = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
        recs.push({ day, min: d.getHours() * 60 + d.getMinutes(),
          k: kindOf([e.purpose, e.detail, e.appliance_name].join(" ")), mock: e.execution_mode !== "real" });
      });
      drawRecords(recs);
      const mock = recs.filter((r) => r.mock).length;
      setSrc($("recSrc"), "live", "본체 실행 기록 · 최근 " + list.length + "건 중 성공");
      $("recNote").textContent = "실제 " + (recs.length - mock) + "건 · 모의·불명 " + mock + "건(회색)";
    });
  }

  // ---------- 알아채는 방법: GET /learning 의 established 습관 · 미연결이면 스냅숏 ----------
  function renderHabitList(items) {
    const box = $("habitList");
    box.innerHTML = "";
    items.forEach((h) => {
      const c = document.createElement("div"); c.className = "hcard";
      const b = document.createElement("b"); b.textContent = h.title;
      const s = document.createElement("span"); s.textContent = h.sub;
      c.append(b, s); box.append(c);
    });
  }
  function snapHabits() {
    renderHabitList(SNAP.habits.map((h) => ({ title: h.what + " · " + h.when, sub: h.days.map(kd).join(" · ") + " · " + h.count })));
    setSrc($("methodSrc"), "live", SNAP.label);
  }
  function runMethod(alive) {
    if (!hub.connected) { snapHabits(); return; }
    setSrc($("methodSrc"), "off", "본체 기록 불러오는 중");
    every(30000, async () => {
      const r = await getJSON("/learning");
      if (!alive()) return;
      if (!r) { snapHabits(); $("methodSrc").textContent += " · 본체 값을 못 받음"; return; }
      const est = (r.routines || []).filter((h) => h.established && !h.muted);
      if (!est.length) {
        renderHabitList([{ title: "아직 잡힌 습관이 없어요", sub: "기록을 세는 중이에요" }]);
      } else {
        renderHabitList(est.slice(0, 4).map((h) => ({
          title: (h.when_text || spoken(h.usual_time) || h.time_band) + (h.routine_name ? " · " + h.routine_name : ""),
          sub: (h.recent_days || []).map(kd).join(" · ") + " · " + h.distinct_days + "일 " + h.occurrences + "번",
        })));
      }
      setSrc($("methodSrc"), "live", "본체 실시간 값");
    });
  }

  // ---------- 습관 카드: 캡처 자리 + GET /learning · 미연결이면 스냅숏 ----------
  function renderDays(days) {
    const box = $("habitDays");
    box.innerHTML = "";
    days.forEach(([d, s, empty]) => {
      const el = document.createElement("div");
      el.className = "day" + (empty ? " empty" : "");
      const b = document.createElement("b"); b.textContent = d;
      const sp = document.createElement("span"); sp.textContent = s;
      el.append(b, sp); box.append(el);
    });
  }
  // '10월 18·23·25일'처럼 같은 달은 묶어 쓴다.
  function joinDays(list) {
    const groups = [];
    list.forEach((d) => {
      const m = /^(\d+)월 (\d+)일$/.exec(kd(d));
      if (!m) { groups.push({ raw: kd(d) }); return; }
      const g = groups[groups.length - 1];
      if (g && g.mon === m[1]) g.days.push(m[2]); else groups.push({ mon: m[1], days: [m[2]] });
    });
    return groups.map((g) => g.raw || g.mon + "월 " + g.days.join("·") + "일").join(", ");
  }
  // 스냅숏의 첫 습관(낮 12시 59분쯤 켜기) — 그 날들의 실제 켠 시각을 그대로 보인다.
  function snapHabitCard() {
    const h = SNAP.habits[0];
    if (!h) return;
    const days = h.days.map((md0) => {
      const times = SNAP.records.filter((r) => r.k === "on" && r.mode !== "mock" && md(r.d) === md0)
        .map((r) => r.t).filter((t) => { const [a, b] = t.split(":").map(Number); const m = a * 60 + b; return Math.abs(m - 779) <= 45; });
      return [kd(md0), times.map(spoken).join(" · ") + " 직접 켬"];
    });
    // 이유 줄 — 쓴 날을 먼저 말한다.
    $("habitHead").textContent = joinDays(h.days) + "에도 이 시간쯤 직접 켰어요";
    renderDays(days);
    $("habitAsk").textContent = "공기청정기, 지금 켤까요?";
    setSrc($("habitSrc"), "live", SNAP.label);
  }
  function runHabit(alive) {
    if (!hub.connected) { snapHabitCard(); return; }
    renderDays([["…", "불러오는 중", true]]);
    $("habitAsk").textContent = "";
    setSrc($("habitSrc"), "off", "본체 기록 불러오는 중");
    every(15000, async () => {
      const r = await getJSON("/learning");
      if (!alive()) return;
      if (!r) {
        snapHabitCard();
        $("habitSrc").textContent += " · 본체 값을 못 받음";
        return;
      }
      const h = pickHabit(r.routines);
      const days = h ? (h.recent_days || []).slice(-5) : [];
      const time = h && h.confident && h.usual_time ? h.usual_time : null;
      if (!h || !days.length) {
        $("habitHead").textContent = "이렇게 쓰셨어요";
        renderDays([["아직", "기록을 세는 중", true]]);
        $("habitAsk").textContent = "아직 잡힌 습관이 없어요";
        setSrc($("habitSrc"), "live", "본체 실제 기록");
        return;
      }
      const need = r.minimum_days || 3;
      $("habitHead").textContent = joinDays(days) + "에도 " + (h.when_text || "이 시간쯤") + " 직접 쓰셨어요";
      renderDays(days.map((d) => [kd(d), (time ? spoken(time) + " " : "") + "직접 사용"]));
      if (h.state === "auto") $("habitAsk").textContent = "맡겨 두셨어요 — 알아서 하고 알려 드려요";
      else if (h.established) $("habitAsk").textContent = "평소처럼, 지금 할까요?";
      else $("habitAsk").textContent = "아직 세는 중이에요 · " + h.distinct_days + "/" + need + "일";
      setSrc($("habitSrc"), "live", "본체 실시간 값");
    });
  }

  // ---------- '네' 단계: GET /status (+ 실행 중이면 GET /jobs/{id}) ----------
  const CONFIRMED = ["state_confirmed", "operation_confirmed", "press_confirmed", "already_at_target"];
  function setStep(i, cls, label) {
    const el = $("steps").children[i];
    el.className = "step" + (cls ? " " + cls : "");
    if (label) el.querySelector(".lbl").textContent = label;
  }
  function previewSteps() {
    $("stepsBand").style.display = "block";
    setStep(0, "", "LG 공기청정기에 보냄");
    setStep(1, "", "상태를 다시 읽음");
    setStep(2, "", "켜진 것을 확인했어요");
    $("stepsDetail").textContent = "";
    setSrc($("stepsSrc"), "preview", "예시 — 실제 실행 기록이 아닙니다");
    [0, 1, 2].forEach((j) => later(700 + j * 1100, () => setStep(j, "done")));
  }
  function renderSteps(s) {
    const route = s.running ? s.route : s.last_route;
    const target = route === "thinq" ? "LG 가전에 보냄" : route === "physical" ? "누름 장치에 보냄" : "보냄";
    if (!s.running && !s.last_job_id) {
      setStep(0, "", target); setStep(1, "", "상태를 다시 읽음"); setStep(2, "", "결과");
      $("stepsDetail").textContent = "아직 실행한 기록이 없어요";
      return;
    }
    if (s.running) {
      setStep(0, "done", target); setStep(1, "", "확인하는 중"); setStep(2, "", "결과");
      $("stepsDetail").textContent = "";
      return;
    }
    const conf = s.last_confirmation;
    const sent = s.last_receipt === "accepted" || (conf && conf !== "none") || s.last_receipt === "not_dispatched";
    setStep(0, sent ? "done" : "", s.last_receipt === "not_dispatched" ? "보내기 전에 상태를 먼저 읽음" : target);
    const checked = CONFIRMED.includes(conf);
    setStep(1, checked ? "done" : "", "상태를 다시 읽음");
    const out = s.last_outcome;
    if (out === "success" && conf === "already_at_target") setStep(2, "done", "이미 그 상태였어요");
    else if (out === "success" && checked) setStep(2, "done", "정말 됐는지 확인했어요");
    else if (out === "success") setStep(2, "done", "끝났어요");
    else if (out === "unconfirmed") setStep(2, "bad", "확인하지 못했어요");
    else if (out === "stopped") setStep(2, "bad", "멈췄어요");
    else setStep(2, "bad", "하지 못했어요");
    $("stepsDetail").textContent = s.last_detail || "";
  }
  function runSteps(alive) {
    if (!hub.connected) { previewSteps(); return; }
    $("stepsBand").style.display = "none";
    [0, 1, 2].forEach((j) => setStep(j, ""));
    $("stepsDetail").textContent = "";
    setSrc($("stepsSrc"), "off", "본체 값 불러오는 중");
    every(1000, async () => {
      let s = await getJSON("/status");
      if (!alive()) return;
      if (!s) {
        // 직전에 받은 단계 표시가 '이번 결과'처럼 남지 않게 지운다.
        setStep(0, "", "보냄"); setStep(1, "", "상태를 다시 읽음"); setStep(2, "", "결과");
        setSrc($("stepsSrc"), "off", "값 못 받음");
        $("stepsDetail").textContent = "본체에서 실행 상태를 받지 못했어요";
        return;
      }
      if (s.running && s.job_id) {
        const j = await getJSON("/jobs/" + encodeURIComponent(s.job_id));
        if (!alive()) return;
        if (j && j.finished) s = j;
      }
      renderSteps(s);
      setSrc($("stepsSrc"), "live", "본체 실시간 값 · 가장 최근 실행");
    });
  }

  // ---------- 한마디로(그림) ----------
  function runChat() {
    const b = [...slides[cur].querySelectorAll(".bubble")];
    b.forEach((e) => e.classList.remove("show"));
    b.forEach((e, j) => later(500 + j * 1400, () => e.classList.add("show")));
  }

  // ---------- 전자레인지 소비전력 ----------
  function resetGraph() {
    $("ln").setAttribute("d", ""); $("area").setAttribute("d", "");
    $("toast").classList.remove("show");
    $("w").textContent = "0 W"; $("tsec").textContent = "대기";
  }
  // 여러 날의 실측 수치(대기 0 W, 시작 순간 약 3,550 W, 가열 약 1,000 W, 1분 가열 판정 60.6~60.7초)로 다시 그린 모양 — 그때 기록 그대로가 아니다.
  function playRecorded() {
    const W = $("w"), T = $("tsec"), L = $("ln"), A = $("area"), toast = $("toast");
    resetGraph();
    const pts = []; const total = 80, scale = 600 / total, ymax = 3600; let t = 0;
    const watt = (x) => (x < 6 ? 0 : x < 6.6 ? 3550 : x < 66.7 ? 1000 + Math.sin(x * 1.7) * 40 : 0);
    const y = (w) => 240 - (w / ymax) * 220;
    const iv = setInterval(() => {
      t += 0.5; const w = watt(t); pts.push([t * scale, y(w)]);
      const d = "M" + pts.map((p) => p[0].toFixed(1) + "," + p[1].toFixed(1)).join(" L");
      L.setAttribute("d", d); A.setAttribute("d", d + " L" + (t * scale).toFixed(1) + ",240 L0,240 Z");
      W.textContent = Math.round(w).toLocaleString("ko-KR") + " W";
      T.textContent = t >= 6 && t < 66.7 ? Math.floor(t - 6) + "초 가열 중" : t >= 66.7 ? "끝" : "대기";
      if (t >= 69 && !toast.classList.contains("show")) toast.classList.add("show");
      if (t >= total) clearInterval(iv);
    }, 50);
    timers.push(iv);
  }
  // 본체에 실시간 소비전력 경로가 생기기 전까지는 늘 측정값으로 다시 그린 그림을 보인다(무대 표제도 그렇게 적혀 있다).
  const RECORDED_NOTE = "여러 날의 측정값으로 다시 그렸습니다(가열 중 센서 출력 10월 30일, 시작 순간 11월 2일, 1분 가열 네 번 11월 2~3일).";
  function runPower() {
    const g = $("graph");
    g.classList.remove("disconnected");
    if (!POWER_ENDPOINT || emergency || !hub.connected) {
      $("ctNote").textContent = (emergency ? "지금 값이 아닙니다. " : "") + RECORDED_NOTE;
      playRecorded();
      return;
    }
    resetGraph();
  }

  // ---------- 끄기: 카메라 스위치는 GET /presence/room 의 camera_enabled ----------
  function runToggles(alive) {
    const a = $("sw1"), b = $("sw2");
    a.classList.remove("off"); b.classList.remove("off");
    if (!hub.connected) {
      setSrc($("camSrc"), "preview", "미리보기 — 끄는 모습을 보여 주는 그림");
      later(1200, () => a.classList.add("off"));
      later(2200, () => b.classList.add("off"));
      return;
    }
    setSrc($("camSrc"), "off", "본체 값 불러오는 중");
    every(2000, async () => {
      const r = await getJSON("/presence/room");
      if (!alive()) return;
      if (!r) { setSrc($("camSrc"), "off", "카메라 스위치 값 못 받음"); return; }
      b.classList.toggle("off", !r.camera_enabled);
      setSrc($("camSrc"), "live", "카메라 스위치는 본체 실시간 값 · 자동 실행 스위치는 그림");
    });
  }

  // ---------- 발표자 창 동기화 ----------
  function broadcast() {
    if (!chan) return;
    chan.postMessage({ t: "state", i: cur, n: slides.length, emergency, mismatch,
      hub: { connected: hub.connected, version: hub.version, checkedAt: hub.checkedAt } });
  }
  if (chan) {
    chan.onmessage = (ev) => {
      const m = ev.data || {};
      if (m.t === "nav") show(cur + (m.dir > 0 ? 1 : -1));
      else if (m.t === "goto") show(m.i);
      else if (m.t === "emergency") toggleEmergency();
      else if (m.t === "hello") broadcast();
    };
  }
  function toggleEmergency() {
    // 전자레인지 장: 11월 2일 실측 장면 · 모은 기록 장: 11월 3일 스냅숏
    if (!["microwave", "records"].includes(slides[cur].dataset.k)) return;
    emergency = !emergency;
    run(); broadcast();
  }

  // ---------- 입력 ----------
  function openPresenter() {
    window.open("presenter.html", "simplelay-presenter", "width=1200,height=800");
  }
  function toggleFull() {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen().catch(() => {});
  }
  document.addEventListener("keydown", (e) => {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    const k = e.key;
    if (k === "ArrowRight" || k === "PageDown" || k === " " || k === "Spacebar") { e.preventDefault(); show(cur + 1); }
    else if (k === "ArrowLeft" || k === "PageUp") { e.preventDefault(); show(cur - 1); }
    else if (k === "Home") show(0);
    else if (k === "End") show(slides.length - 1);
    else if (k === "f" || k === "F") toggleFull();
    else if (k === "p" || k === "P") openPresenter();
    else if (k === "e" || k === "E") toggleEmergency();
  });
  document.addEventListener("click", () => show(cur + 1));

  // 장 목록과 HTML 장 수가 어긋나면 발표자 창 대본이 밀린다 — 발표자 창에 빨간 경고로 띄운다(콘솔에도 남긴다).
  const firstBad = DATA.findIndex((d, j) => !slides[j] || d.id !== slides[j].dataset.k);
  const mismatch = (DATA.length !== slides.length || firstBad >= 0)
    ? "무대 " + slides.length + "장 · 대본 " + DATA.length + "장" + (firstBad >= 0 ? " · " + (firstBad + 1) + "번째 장부터 어긋남" : "")
    : null;
  if (mismatch) console.error("slides.js 장 목록이 index.html과 다릅니다: " + mismatch);

  const start = parseInt((location.hash || "").slice(1), 10);
  show(Number.isFinite(start) ? start - 1 : 0);
  checkHub();
  setInterval(checkHub, 4000);
})();
