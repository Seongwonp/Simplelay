"""장애 복구 결과표(인계 2026-10-06 노트북-3 §F) — 상황마다 두 가지를 본다.

1. **자동 재전송·자동 재개가 없다** — 거절되거나 끊긴 실행이 링크가 살아나거나 걸림이 풀린 뒤 스스로
   다시 나가지 않는다(RPi4로 가는 execute 프레임 수·누름 수로 센다).
2. **무엇이 막히나** — 실행 거절(412·RPi4 error)·걸림 유지·사람의 확인 필요 등.

배선은 운영과 같다: RPi5 ``open_uart_act_controller``(재연결 connector 포함) + ``SimpleLayService`` + API,
RPi4 ``rpi4.act_main._run``(실행기·콘센트 모듈 배선 그대로). 둘 사이의 ``socket://``(socat)만 메모리 중개자
(`_Broker`)로 바꾼다. 모터·콘센트 모듈·모션 MCU는 가짜(MockGrblClient 대역·fake_outlet·FakeMcu)다.
**전부 모의 수준이다 — 실물 정지 지연은 측정하지 않았다.** 결과표: docs/장애-복구-결과표.md.
"""

from __future__ import annotations

import asyncio
import json
import sys
import threading
import time
import types

import pytest
from fastapi.testclient import TestClient

from rpi.controller import ButtonTarget
from rpi.controller.mock import MockGrblClient

RPI5_URL = "socket://rpi4:7000"
BUTTONS = ["즉석밥", "시작"]
EXECUTE_BODY = {"buttons": BUTTONS, "appliance_id": "microwave"}

_ENV_TO_CLEAR = (
    "SIMPLELAY_API_KEY", "SIMPLELAY_DB_PATH", "SIMPLELAY_THINQ_MODE", "SIMPLELAY_ACT_MODE",
    "SIMPLELAY_OUTLET_PORT", "SIMPLELAY_OUTLET_CHANNELS", "SIMPLELAY_OUTLET_RELAY_ON_START",
    "SIMPLELAY_L3_MODE", "SIMPLELAY_SENSORS_ENABLED", "SIMPLELAY_MOTION_MODE", "SIMPLELAY_MOTION_PORT",
    "SIMPLELAY_MOTION_BAUD", "SIMPLELAY_DONE_WATCH", "SIMPLELAY_RECORDER_PATH", "SIMPLELAY_MOTION_LOG_PATH",
    "SIMPLELAY_DANGER_SOUND_ENABLED", "SIMPLELAY_UART_BASE_TIMEOUT", "SIMPLELAY_UART_PER_BUTTON_TIMEOUT",
    "SIMPLELAY_FAKE_OUTLET_RELAY_CH", "SIMPLELAY_FAKE_OUTLET_CHANNELS", "SIMPLELAY_DEMO_PACING",
    "SIMPLELAY_LINK_KEY", "SIMPLELAY_LINK_AUTH", "SIMPLELAY_DEV_REAL_MOTION",
)
#: 링크 키는 필수다(2026-10-14). 모의 구성 결과표는 **명시적 모의 설정**으로 키 없이 돈다 — 줄을 그대로 세고 끼워 넣기 위해서다.
#: 실물 경로(모션 serial 등)를 켜는 결과표는 키를 준다(mcu_rig). 키 있는 경로는 아래 8절.
MOCK_LINK = {"SIMPLELAY_LINK_AUTH": "off_for_mock"}
LINK_KEY = "pairing-key-for-tests-0123"


def _wait(pred, timeout: float = 4.0, what: str = "condition") -> None:
    deadline = time.monotonic() + timeout
    while not pred():
        if time.monotonic() > deadline:
            raise AssertionError(f"{what} not met in time")
        time.sleep(0.01)


# ── socat 흉내: RPi4 실행기의 가상 시리얼 ↔ RPi5의 socket:// ─────────────────────────


class _Wire:
    """한 방향 선. 보낸 줄을 기록하고(``frames``) 상대 StreamReader에 넣는다. ``drop``에 든 type은 한 번 버린다."""

    def __init__(self, peer: asyncio.StreamReader, frames: list, drop: set | None = None) -> None:
        self.peer, self.frames, self.drop = peer, frames, drop if drop is not None else set()
        self.dropped: list[bytes] = []
        self.closed = False

    def write(self, data: bytes) -> None:
        if self.closed:
            return
        for line in data.split(b"\n"):
            if not line.strip():
                continue
            doc = json.loads(line)
            if doc.get("type") in self.drop:
                self.drop.discard(doc["type"])
                self.dropped.append(line + b"\n")
                continue
            self.frames.append(doc)
            self.peer.feed_data(line + b"\n")

    async def drain(self) -> None:
        await asyncio.sleep(0)

    def close(self) -> None:
        self.closed = True


class _Broker:
    """RPi4 ``act_main._run``이 시리얼을 열면 새 선 한 쌍을 만들고, RPi5 connector는 그 반대쪽을 받는다.

    RPi4가 떠 있지 않으면 RPi5 연결은 거절(``OSError``)이다. ``drop()``은 socat이 끊긴 것처럼 양쪽을 끊는다:
    RPi5 읽기는 오류, RPi4 읽기는 EOF.
    """

    def __init__(self) -> None:
        self.to_act: list[dict] = []   # RPi5 → RPi4 (지금까지 모든 링크)
        self.to_hub: list[dict] = []   # RPi4 → RPi5
        self.drop_to_hub: set[str] = set()
        self._hub_side = None
        self._act_reader: asyncio.StreamReader | None = None
        self._hub_reader: asyncio.StreamReader | None = None
        self.hub_wire: _Wire | None = None
        self.act_wire: _Wire | None = None
        self.links = 0

    async def open_serial_connection(self, url, baudrate):
        if url == RPI5_URL:
            if self._hub_side is None:
                raise OSError("[Errno 111] Connection refused")
            side, self._hub_side = self._hub_side, None
            self.links += 1
            return side
        act_reader, hub_reader = asyncio.StreamReader(), asyncio.StreamReader()
        self.act_wire = _Wire(hub_reader, self.to_hub, self.drop_to_hub)
        self.hub_wire = _Wire(act_reader, self.to_act)
        self._act_reader, self._hub_reader = act_reader, hub_reader
        self._hub_side = (hub_reader, self.hub_wire)
        return act_reader, self.act_wire

    def drop(self) -> None:
        """이벤트 루프 스레드에서 부른다."""
        self._hub_side = None
        for wire in (self.act_wire, self.hub_wire):
            if wire is not None:
                wire.close()
        if self._hub_reader is not None:
            self._hub_reader.set_exception(ConnectionResetError("read failed: socket disconnected"))
        if self._act_reader is not None:
            self._act_reader.feed_eof()

    def executes(self) -> list[dict]:
        return [m for m in self.to_act if m.get("type") == "execute"]


class _SlowGrbl(MockGrblClient):
    """누름마다 ``press_s``만큼 걸리는 모의 모터(실행 중 장애를 끼워 넣으려고)."""

    press_s = 0.0

    def press(self, command) -> None:
        super().press(command)
        time.sleep(self.press_s)


class _Rig:
    """RPi5(API·서비스·UART 공장) + RPi4(act_main._run) + 중개자."""

    def __init__(self, monkeypatch) -> None:
        import rpi4.act_main as act_main
        from rpi.api import deps
        from rpi.services import act_client_controller as acc
        from rpi.services.act_client import ActClient

        self.act_main = act_main
        self.deps = deps
        self.broker = _Broker()
        fake = types.ModuleType("serial_asyncio")
        fake.open_serial_connection = self.broker.open_serial_connection  # type: ignore[attr-defined]
        monkeypatch.setitem(sys.modules, "serial_asyncio", fake)
        monkeypatch.setattr(ActClient, "RECONNECT_BACKOFF", (0.01, 0.05), raising=False)
        self.grbls: list[_SlowGrbl] = []

        def make_grbl(*_a, **_k):
            grbl = _SlowGrbl()
            self.grbls.append(grbl)
            return grbl

        monkeypatch.setattr(act_main, "MockGrblClient", make_grbl)
        self.executors: list = []
        original_build = act_main._build_executor

        def capture(*a, **k):
            executor = original_build(*a, **k)
            self.executors.append(executor)
            return executor

        monkeypatch.setattr(act_main, "_build_executor", capture)
        self.controller = acc.open_uart_act_controller(RPI5_URL, 115200)
        self.loop = self.controller._loop  # noqa: SLF001
        from rpi.api.service import SimpleLayService
        from rpi.intent import RuleBasedIntentResolver
        from rpi.main import app

        for dep in (deps.get_appliance_registry, deps.get_service):
            dep.cache_clear()
        self.service = SimpleLayService(RuleBasedIntentResolver(), self.controller,
                                        appliance_registry=deps.get_appliance_registry())
        self.app = app
        app.dependency_overrides[deps.get_service] = lambda: self.service
        self.client = TestClient(app)
        self.rpi4_tasks: list = []

    # RPi4 ──────────────────────────────────────────────────────────────────
    def start_rpi4(self) -> None:
        self.rpi4_tasks.append(asyncio.run_coroutine_threadsafe(self.act_main._run(), self.loop))

    def rpi4_running(self) -> bool:
        return bool(self.rpi4_tasks) and not self.rpi4_tasks[-1].done()

    def call(self, fn, *args) -> None:
        async def _do():
            fn(*args)
        asyncio.run_coroutine_threadsafe(_do(), self.loop).result(2.0)

    def wait_ready(self) -> None:
        _wait(lambda: self.service.estop_block_reason() is None, what="link up + estop_state")

    # RPi5 API ──────────────────────────────────────────────────────────────
    def post_execute(self):
        return self.client.post("/execute-buttons", json=EXECUTE_BODY)

    def wait_job(self, job_id: str, timeout: float = 8.0) -> dict:
        holder: dict = {}

        def done() -> bool:
            status = self.client.get("/status").json()
            holder["s"] = status
            return status.get("last_job_id") == job_id and not status.get("running")

        _wait(done, timeout, what=f"job {job_id}")
        return holder["s"]

    def close(self) -> None:
        self.app.dependency_overrides.pop(self.deps.get_service, None)
        for dep in (self.deps.get_appliance_registry, self.deps.get_service):
            dep.cache_clear()
        try:
            self.call(self.broker.drop)
            for task in self.rpi4_tasks:
                try:
                    task.result(10.0)
                except Exception:  # noqa: BLE001 - 정리 중
                    pass
            self.controller.close()
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
            if self.act_main._fake_outlet is not None:  # noqa: SLF001
                self.act_main._fake_outlet.close()  # noqa: SLF001
                self.act_main._fake_outlet = None  # noqa: SLF001


@pytest.fixture
def rig(monkeypatch):
    for name in _ENV_TO_CLEAR:
        monkeypatch.delenv(name, raising=False)
    made: list[_Rig] = []

    def build(**env) -> _Rig:
        if "SIMPLELAY_LINK_KEY" not in env:
            env = {**MOCK_LINK, **env}
        for key, value in env.items():
            monkeypatch.setenv(key, value)
        r = _Rig(monkeypatch)
        made.append(r)
        return r

    yield build
    for r in made:
        r.close()


def _presses(rig: _Rig, index: int = -1) -> list[str]:
    return [c.button for c in rig.grbls[index].commands]


# ── 1. RPi4가 늦게 켜짐 ─────────────────────────────────────────────────────────


def test_rpi4_started_late_refuses_and_never_sends_the_refused_request(rig):
    r = rig()
    _wait(lambda: r.controller.link_status()["reason"] is not None, what="factory up")
    refused = r.post_execute()
    # 막힘: 412 '누름 장치 연결 안 됨', 아무것도 보내지 않는다
    assert refused.status_code == 412, refused.text
    assert "누름 장치와 연결되지 않았어요" in refused.text
    assert r.broker.executes() == []

    r.start_rpi4()
    r.wait_ready()
    time.sleep(0.3)
    # 자동 재전송 없음: 링크가 이어지고 걸림 상태를 받은 뒤에도 거절된 요청은 나가지 않는다
    assert r.broker.executes() == []
    assert _presses(r) == []

    # 사람이 다시 요청해야 움직인다
    job = r.post_execute()
    assert job.status_code == 200, job.text
    assert r.wait_job(job.json()["job_id"])["last_outcome"] == "success"
    assert len(r.broker.executes()) == 1
    assert _presses(r) == BUTTONS


# ── 2. 실행 중 링크 끊김 ───────────────────────────────────────────────────────


def test_link_drop_mid_execution_fails_the_job_stops_rpi4_and_nothing_is_resent(rig):
    r = rig()
    _SlowGrbl.press_s = 0.3
    try:
        r.start_rpi4()
        r.wait_ready()
        job = r.post_execute()
        assert job.status_code == 200, job.text
        _wait(lambda: len(r.grbls[0].commands) >= 1, what="first press")
        r.call(r.broker.drop)

        # RPi5: 기다리던 실행은 타임아웃이 아니라 바로 실패(성공으로 적지 않는다)
        status = r.wait_job(job.json()["job_id"], timeout=3.0)
        assert status["last_outcome"] != "success"
        # RPi4: EOF → act_main._run이 실행기를 협조적으로 멈추고 끝난다 — 남은 버튼을 누르지 않는다
        r.rpi4_tasks[0].result(8.0)
        assert _presses(r, 0) == ["즉석밥"]
        # 막힘: 끊긴 동안 실행 거절
        refused = r.post_execute()
        assert refused.status_code == 412 and "누름 장치와 연결되지 않았어요" in refused.text

        # RPi4 실행기가 다시 뜬다(컨테이너 재시작) — RPi5가 다시 잇고 걸림 상태를 받는다
        executes_before = len(r.broker.executes())
        r.start_rpi4()
        r.wait_ready()
        time.sleep(0.3)
        # 자동 재전송·재개 없음: 끊긴 실행도, 끊긴 동안 거절된 요청도 다시 나가지 않는다
        assert len(r.broker.executes()) == executes_before == 1
        assert _presses(r, 1) == []
        assert _presses(r, 0) == ["즉석밥"]

        _SlowGrbl.press_s = 0.0
        again = r.post_execute()
        assert again.status_code == 200, again.text
        assert r.wait_job(again.json()["job_id"])["last_outcome"] == "success"
        assert _presses(r, 1) == BUTTONS
    finally:
        _SlowGrbl.press_s = 0.0


# ── 3. 결과 유실 ───────────────────────────────────────────────────────────────


def test_lost_result_times_out_as_failed_sends_abort_and_does_not_resend(rig):
    # 응답 기한을 짧게(시험용): 0.5 s + 버튼당 0.1 s
    r = rig(SIMPLELAY_UART_BASE_TIMEOUT="0.5", SIMPLELAY_UART_PER_BUTTON_TIMEOUT="0.1")
    r.start_rpi4()
    r.wait_ready()
    r.broker.drop_to_hub.add("result")  # RPi4가 보낸 결과 한 줄이 선에서 사라진다
    job = r.post_execute()
    assert job.status_code == 200, job.text
    status = r.wait_job(job.json()["job_id"], timeout=8.0)

    # RPi4는 실제로 다 눌렀다 — RPi5는 결과를 모르니 성공으로 적지 않는다(사람이 가전을 확인)
    assert _presses(r) == BUTTONS
    assert status["last_outcome"] != "success"
    assert len(r.broker.act_wire.dropped) == 1
    # 막힘(안전 쪽): 기한이 지나면 RPi4에 중단(abort)을 보낸다
    seq = r.broker.executes()[0]["sequence_id"]
    after = r.broker.to_act[r.broker.to_act.index(r.broker.executes()[0]) + 1:]
    # 2026-10-19: 구동부만(scope=drive)·그 실행 표지(run_ref) — 정지 버튼 위 대기 중이어도 가전 정지 버튼을 누르지 않는다
    aborts = [m for m in after if m.get("type") == "abort"]
    assert aborts and aborts[0].get("scope") == "drive", after
    assert aborts[0].get("run_ref") == r.broker.executes()[0].get("run_ref"), after
    # 자동 재전송 없음
    time.sleep(0.3)
    assert len(r.broker.executes()) == 1
    assert _presses(r) == BUTTONS

    # 늦게 도착한 그 결과는 버린다 — 다음 실행의 결과로 쓰지 않는다
    late = r.broker.act_wire.dropped[0]
    assert json.loads(late)["sequence_id"] == seq
    r.call(r.broker._hub_reader.feed_data, late)  # noqa: SLF001
    again = r.post_execute()
    assert again.status_code == 200, again.text
    assert r.wait_job(again.json()["job_id"])["last_outcome"] == "success"
    assert len(r.broker.executes()) == 2
    assert _presses(r) == BUTTONS * 2


# ── 4. 모션 MCU 재부팅 ────────────────────────────────────────────────────────


@pytest.fixture
def mcu_rig(rig, monkeypatch):
    """RPi4가 ``SIMPLELAY_MOTION_MODE=serial``로 FakeMcu(리허설 임의 기구 값)에 붙는다."""
    import dataclasses

    from rpi.controller.serial_motion import InMemoryLinePipe, MotionConfig
    from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu

    import rpi4.act_main as act_main

    made: list = []

    def build(auto_home: bool):
        pipe = InMemoryLinePipe()
        mcu = FakeMcu(pipe, homed=True, ready_banner=True)
        made.append(mcu)
        config = dataclasses.replace(REHEARSAL_CONFIG, auto_home=auto_home, press_timeout_s=3.0)
        monkeypatch.setattr(act_main, "_open_motion_transport", lambda port, baud: pipe.host)
        monkeypatch.setattr(MotionConfig, "from_env", classmethod(lambda cls, env=None: config))
        # 실물 경로(모션 serial)라 무인증 모의 설정으로는 RPi4가 시작을 거절한다 — 짝 키로 돈다(2026-10-14).
        r = rig(SIMPLELAY_MOTION_MODE="serial", SIMPLELAY_MOTION_PORT="/dev/test-mcu",
                SIMPLELAY_MOTION_BAUD="115200", SIMPLELAY_LINK_KEY=LINK_KEY)
        r.start_rpi4()
        r.wait_ready()
        # 이미 원점을 잡고 쓰던 상태에서 시작한다 — 실행기 시작 뒤에는 MCU의 homed를 믿지 않으므로(10/19)
        # 사람이(개발자 원점 잡기처럼) 이 실행기에서 원점을 한 번 잡아 둔다.
        act_main._motion_watch._client.home()
        return r, mcu

    yield build
    for mcu in made:
        mcu.close()


TARGETS = {"즉석밥": ButtonTarget(10.0, 20.0), "시작": ButtonTarget(30.0, 5.0)}


def _refuse_motion_until_homed(mcu) -> None:
    """펌웨어 ``motion_refusal()``처럼 원점 복귀 전 이동·누름을 ``not_homed``로 거절한다(FakeMcu는 받는다)."""
    for cmd in ("move", "press"):
        inner = mcu.handlers[cmd]

        def handler(doc, _inner=inner):
            if not mcu.homed:
                return [{"id": doc.get("id"), "ok": False, "error": "not_homed"}]
            return _inner(doc)

        mcu.handlers[cmd] = handler


def _execute_with_targets(r: _Rig):
    r.controller.arm_execute_target("microwave")
    return r.controller.execute(BUTTONS, TARGETS)


@pytest.mark.parametrize("auto_home", [False, True], ids=["auto_home_off", "auto_home_on"])
def test_motion_mcu_reboot_mid_press_fails_the_run_and_never_rehomes_or_presses_again(mcu_rig, auto_home):
    r, mcu = mcu_rig(auto_home)
    _refuse_motion_until_homed(mcu)
    mcu.delays["press"] = 0.4  # 누름이 끝나기 전에 재부팅을 끼운다

    def reboot_on_first_press() -> None:
        _wait(lambda: "press" in mcu.cmds(), what="first press sent")
        mcu.reboot(reset="brownout")

    threading.Thread(target=reboot_on_first_press, daemon=True).start()
    result = _execute_with_targets(r)
    rebooted_at = len(mcu.cmds())

    # 막힘: 실행은 실패로 끝난다(성공 아님), RPi4 어댑터는 재홈 필요(UNHOMED)
    assert result.status.value != "succeeded"
    assert result.buttons and result.buttons[0].button == "즉석밥"
    time.sleep(0.2)
    sent = mcu.cmds()
    after_reboot = sent[sent.index("press") + 1:]
    # 자동 재개 없음: 재부팅 뒤 같은 실행 안에서 원점 복귀·이동·누름을 다시 보내지 않는다
    # (auto_home이 켜져 있어도 — 재부팅은 사람이 확인할 일이다)
    assert not any(cmd in ("home", "move", "press") for cmd in after_reboot), sent
    assert set(sent[rebooted_at:]) <= {"stop"}, sent  # 실패 뒤 안전 정지 명령만 더 갈 수 있다
    assert mcu.homed is False
    # RPi5도 다시 보내지 않는다
    assert len(r.broker.executes()) == 1

    # 사람이 새로 요청하면: auto_home이면 그 새 실행이 원점 복귀부터 하고, 꺼져 있으면 홈 전까지 움직이지 않는다
    before = len(mcu.cmds())
    again = _execute_with_targets(r)
    sent_again = mcu.cmds()[before:]
    if auto_home:
        assert again.status.value == "succeeded" and sent_again[0] == "home"
    else:
        assert again.status.value != "succeeded"
        assert "home" not in sent_again and "press" not in sent_again and "move" not in sent_again


def test_motion_mcu_reboot_blocks_presses_until_rehome_without_auto_home(mcu_rig):
    """auto_home 꺼짐(기본): 재부팅 뒤 사람이 다시 요청해도 원점 복귀 전에는 움직이지 않는다."""
    r, mcu = mcu_rig(False)
    _refuse_motion_until_homed(mcu)
    mcu.reboot(reset="brownout")
    _wait(lambda: mcu.homed is False, what="reboot")
    time.sleep(0.1)
    before = len(mcu.cmds())
    result = _execute_with_targets(r)
    assert result.status.value != "succeeded"
    sent = mcu.cmds()[before:]
    # 쉬는 동안의 재부팅은 RPi4가 다음 명령 때에야 안다(배너가 그때 읽힌다) — 첫 이동 한 줄은 나가고
    # 펌웨어가 not_homed로 거절한다. 그 뒤로는 원점 복귀도 누름도 보내지 않는다.
    assert "home" not in sent and "press" not in sent, sent
    assert sent.count("move") <= 1, sent
    assert mcu.homed is False and (mcu.a, mcu.b) == (0, 0)  # 실제로 움직이지 않았다
    assert len(r.broker.executes()) == 1


# ── 5. 콘센트 모듈 재부팅 ──────────────────────────────────────────────────────


def _outlet_rig(rig):
    import rpi4.act_main as act_main

    r = rig(SIMPLELAY_OUTLET_PORT="fake", SIMPLELAY_OUTLET_RELAY_ON_START="1")
    r.start_rpi4()
    r.wait_ready()
    fake = act_main._fake_outlet  # noqa: SLF001
    assert fake is not None and fake.relay_on is True
    return r, fake


def test_outlet_module_reboot_mid_execution_stops_latches_and_only_power_returns_after_ack(rig):
    r, fake = _outlet_rig(rig)
    _SlowGrbl.press_s = 0.3
    try:
        job = r.post_execute()
        assert job.status_code == 200, job.text
        _wait(lambda: len(r.grbls[0].commands) >= 1, what="first press")
        fake.reboot()  # 전원 순간 끊김 — 모듈 부팅 기본 = 릴레이 꺼짐

        status = r.wait_job(job.json()["job_id"])
        assert status["last_outcome"] != "success"
        assert _presses(r) == ["즉석밥"]  # 남은 버튼을 누르지 않는다
        _wait(lambda: r.client.get("/status").json()["estop_latched"] is True, what="latch at RPi5")
        # 막힘: 걸림(사유 그대로), 실행 412, 릴레이는 스스로 켜지지 않는다
        refused = r.post_execute()
        assert refused.status_code == 412 and "다시 켜져" in refused.text
        time.sleep(0.3)
        assert fake.relay_on is False
        assert len(r.broker.executes()) == 1

        # 사람의 확인 뒤에만 전원이 돌아온다 — 끊긴 실행은 다시 돌지 않는다
        body = r.client.post("/stop/ack").json()
        assert body["ok"] is True and body["latched"] is False
        _wait(lambda: fake.relay_on is True, what="relay restored after ack")
        time.sleep(0.3)
        assert len(r.broker.executes()) == 1
        assert _presses(r) == ["즉석밥"]
    finally:
        _SlowGrbl.press_s = 0.0


# ── 6. 비상 버튼을 누른 채 유지 / 7. 해제 직후 재요청 ────────────────────────────


def test_estop_held_keeps_latch_through_acks_then_release_allows_only_a_new_request(rig):
    r, fake = _outlet_rig(rig)
    _SlowGrbl.press_s = 0.3
    try:
        job = r.post_execute()
        assert job.status_code == 200, job.text
        _wait(lambda: len(r.grbls[0].commands) >= 1, what="first press")
        fake.press_estop()  # 누른 채 둔다

        status = r.wait_job(job.json()["job_id"])
        assert status["last_outcome"] != "success"
        assert _presses(r) == ["즉석밥"]
        _wait(lambda: r.client.get("/status").json()["estop_latched"] is True, what="latch at RPi5")
        assert fake.relay_on is False  # 모듈이 스스로 릴레이를 열었다

        # 막힘: 버튼이 눌린 채면 확인을 몇 번 눌러도 풀리지 않는다 + 실행 412
        for _ in range(2):
            body = r.client.post("/stop/ack").json()
            assert body["ok"] is False and body["latched"] is True
            assert body["reason"] == "estop_button_pressed"
        refused = r.post_execute()
        assert refused.status_code == 412 and "비상 버튼이 눌려 있어요" in refused.text
        assert len(r.broker.executes()) == 1

        # 버튼을 풀기만 해서는 풀리지 않는다(사람의 확인 필요)
        fake.release_estop_button()
        time.sleep(0.3)
        assert r.client.get("/status").json()["estop_latched"] is True
        assert r.post_execute().status_code == 412
        assert len(r.broker.executes()) == 1

        # 해제 확인 → 바로 다시 요청: 새 요청만 한 번 돈다. 끊긴 실행은 이어지지 않고, 릴레이는 꺼진 채다.
        _SlowGrbl.press_s = 0.0
        body = r.client.post("/stop/ack").json()
        assert body["ok"] is True and body["latched"] is False
        time.sleep(0.3)
        assert len(r.broker.executes()) == 1  # 해제만으로는 아무것도 나가지 않는다
        again = r.post_execute()
        assert again.status_code == 200, again.text
        assert r.wait_job(again.json()["job_id"])["last_outcome"] == "success"
        assert len(r.broker.executes()) == 2
        assert _presses(r) == ["즉석밥", *BUTTONS]
        assert fake.relay_on is False  # 비상정지로 꺼진 전원은 자동으로 다시 켜지 않는다
    finally:
        _SlowGrbl.press_s = 0.0


def test_request_during_release_confirmation_is_refused_not_queued(rig, monkeypatch):
    """해제 확인이 모듈 답을 기다리는 사이 온 요청: RPi5 412, RPi4도 estop_latched로 거절 — 풀린 뒤 저절로 돌지 않는다."""
    from rpi.verifier.outlet import OutletLink

    gate = threading.Event()
    entered = threading.Event()
    original = OutletLink.acknowledge_and_restore

    def slow_ack(self):
        entered.set()
        gate.wait(5.0)
        return original(self)

    monkeypatch.setattr(OutletLink, "acknowledge_and_restore", slow_ack)
    r, fake = _outlet_rig(rig)
    fake.press_estop()
    fake.release_estop_button()
    _wait(lambda: r.client.get("/status").json()["estop_latched"] is True, what="latch at RPi5")

    ack_result: dict = {}
    ack = threading.Thread(target=lambda: ack_result.update(r.client.post("/stop/ack").json()), daemon=True)
    ack.start()
    assert entered.wait(3.0)
    # RPi5: 확인 중에는 여전히 걸림 — 412, 보내지 않는다
    refused = r.post_execute()
    assert refused.status_code == 412, refused.text
    assert r.broker.executes() == []
    # RPi4: 링크로 바로 온 execute도 확인이 끝나기 전에는 거절한다(대기열에 넣지 않는다)
    executor = r.executors[-1]
    r.call(r.broker._act_reader.feed_data, json.dumps(  # noqa: SLF001
        {"type": "execute", "sequence_id": "race-1", "buttons": BUTTONS, "appliance_id": "microwave"},
        ensure_ascii=False).encode() + b"\n")
    _wait(lambda: any(m.get("sequence_id") == "race-1" for m in r.broker.to_hub), what="race reply")
    reply = next(m for m in r.broker.to_hub if m.get("sequence_id") == "race-1")
    assert reply["type"] == "error" and reply["reason"] == "estop_latched"

    gate.set()
    ack.join(5.0)
    assert ack_result.get("ok") is True and executor.estop_latched is False
    time.sleep(0.3)
    # 풀린 뒤에도 거절된 두 요청은 돌지 않는다
    assert _presses(r) == []
    assert r.broker.executes() == []


# ── 8. 링크 인증(2026-10-12, 무선 전환 뒤) ─────────────────────────────────────────
# 운영 공장 두 개(open_uart_act_controller·act_main._run)가 SIMPLELAY_LINK_KEY를 읽는다. RPi5는 공장을 만들 때,
# RPi4는 _run이 시작할 때 읽으므로 그 사이에 env를 바꾸면 두 보드의 키가 다른 상황이 된다.

def test_matching_link_keys_execute_end_to_end_and_survive_a_reconnect(rig):
    r = rig(SIMPLELAY_LINK_KEY=LINK_KEY)
    r.start_rpi4()
    r.wait_ready()
    job = r.post_execute()
    assert job.status_code == 200, job.text
    assert r.wait_job(job.json()["job_id"])["last_outcome"] == "success"
    assert _presses(r) == BUTTONS
    assert all("mac" in f for f in r.broker.to_act) and all("mac" in f for f in r.broker.to_hub)

    # 끊긴 뒤 RPi4가 다시 뜨면 새 hello로 새 세션 — 다시 실행된다
    r.call(r.broker.drop)
    r.rpi4_tasks[0].result(8.0)
    r.start_rpi4()
    r.wait_ready()
    again = r.post_execute()
    assert again.status_code == 200, again.text
    assert r.wait_job(again.json()["job_id"])["last_outcome"] == "success"
    assert _presses(r, 1) == BUTTONS
    hellos = [f for f in r.broker.to_act if f.get("type") == "hello"]
    assert len({h["cn"] for h in hellos}) == len(hellos) >= 2


def test_different_link_keys_keep_the_link_down_with_the_auth_reason(rig, monkeypatch):
    from rpi.services.act_client import ActClient

    monkeypatch.setattr(ActClient, "AUTH_REPLY_TIMEOUT_S", 0.05, raising=False)
    r = rig(SIMPLELAY_LINK_KEY=LINK_KEY)
    monkeypatch.setenv("SIMPLELAY_LINK_KEY", "a-different-pairing-key-987")
    r.start_rpi4()
    _wait(lambda: "인증 실패" in (r.controller.link_status()["reason"] or ""), what="auth failure reason")
    assert r.controller.link_status()["link_up"] is False
    assert r.client.get("/health/detail").json()["actuator_ready"] is False
    refused = r.post_execute()
    assert refused.status_code == 412, refused.text
    time.sleep(0.3)
    assert r.broker.executes() == [] and _presses(r) == []
    assert r.broker.to_hub == []  # RPi4는 키가 맞지 않는 hello에 답하지 않는다


def test_short_link_key_refuses_to_open_either_side(monkeypatch):
    import rpi4.act_main as act_main
    from rpi.services import act_client_controller as acc
    from rpi.services.link_auth import LinkKeyError

    monkeypatch.setenv("SIMPLELAY_LINK_KEY", "too-short")
    opened: list = []

    async def open_serial_connection(url, baudrate):
        opened.append(url)
        raise AssertionError("must not open the link with a short key")

    fake = types.ModuleType("serial_asyncio")
    fake.open_serial_connection = open_serial_connection  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "serial_asyncio", fake)
    with pytest.raises(LinkKeyError):
        acc.open_uart_act_controller(RPI5_URL, 115200)
    with pytest.raises(LinkKeyError):
        asyncio.run(act_main._run())
    assert opened == []
