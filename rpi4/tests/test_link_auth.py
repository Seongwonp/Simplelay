"""RPi5↔RPi4 링크 인증(2026-10-12, 무선 전환 뒤) — 진짜 ActClient ⇄ 진짜 ActExecutor를 메모리 선으로 잇는다.

링크가 TCP가 되면서 같은 Wi-Fi의 누구나 RPi4에 execute·dev_motion을 보낼 수 있었다. 고친 뒤 기대:
  - 같은 키: execute·정지·개발자 조작이 종전처럼 오가고, 모든 프레임에 봉투(cn·sn / seq·mac)가 붙는다.
  - 다른 키·한쪽만 키: 링크가 '인증 실패'로 내려가 있고 아무것도 누르지 않는다(fail closed).
  - 세션 중 끼워 넣은 서명 없는 프레임·재전송한 프레임·재전송한 hello는 버린다(답도 없다).
  - 두 쪽 다 키 없음(클래스 수준 — 운영 진입점은 2026-10-14부터 키가 필수이고, 무인증은 명시적 모의 설정
    ``SIMPLELAY_LINK_AUTH=off_for_mock``에서만 연다. test_link_key_required.py): 줄이 종전과 바이트까지 같다.
  - 짧은 키: 링크를 열지 않는다.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time

import pytest

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.services.act_client import ActClient, ActClientConfig, ActLinkError
from rpi.services.link_auth import LinkKeyError, ServerAuth, is_nonce, link_key_from_env
from rpi.verifier import MockVerifier

from rpi4.services.act_executor import ActExecutor

KEY = "pairing-key-for-tests-0123"
OTHER_KEY = "a-different-pairing-key-987"
BUTTONS = ["즉석밥", "시작"]


class _Pipe:
    """한 방향 선 — 쓴 줄을 남기고 상대 StreamReader에 넣는다."""

    def __init__(self, peer: asyncio.StreamReader) -> None:
        self.peer = peer
        self.lines: list[bytes] = []

    def write(self, data: bytes) -> None:
        self.lines.extend(line + b"\n" for line in data.split(b"\n") if line.strip())
        self.peer.feed_data(data)

    async def drain(self) -> None:
        pass

    def docs(self) -> list[dict]:
        return [json.loads(line) for line in self.lines]


class _SlowGrbl(MockGrblClient):
    press_s = 0.0

    def press(self, command) -> None:
        super().press(command)
        time.sleep(self.press_s)


class _Link:
    def __init__(self, client_key, executor_key, *, press_s: float = 0.0,
                 config: ActClientConfig | None = None) -> None:
        self.act_reader, self.hub_reader = asyncio.StreamReader(), asyncio.StreamReader()
        self.to_hub, self.to_act = _Pipe(self.hub_reader), _Pipe(self.act_reader)
        self.grbl = _SlowGrbl()
        self.grbl.press_s = press_s
        controller = ClosedLoopController(self.grbl, MockVerifier([True] * 50), MockAlertSink(),
                                          MockSafetyController())
        self.executor = ActExecutor(reader=self.act_reader, writer=self.to_hub, controller=controller,
                                    link_key=executor_key)
        self.client = ActClient(self.hub_reader, self.to_act, config, hello=True, link_key=client_key,
                                reconnect_backoff=(0.02, 0.05))
        self.task: asyncio.Task | None = None

    async def start(self) -> "_Link":
        self.task = asyncio.create_task(self.executor.run())
        await self.client.start()
        return self

    async def close(self) -> None:
        await self.client.stop()
        if self.task is not None:
            self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.task

    def presses(self) -> list[str]:
        return [c.button for c in self.grbl.commands]

    def inject(self, doc_or_line) -> None:
        """공격자: RPi4 읽기 쪽에 줄을 그대로 넣는다."""
        line = doc_or_line if isinstance(doc_or_line, bytes) else (json.dumps(doc_or_line) + "\n").encode()
        self.act_reader.feed_data(line)


async def _until(pred, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while not pred():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.005)


async def _ready(link: _Link) -> None:
    await _until(lambda: link.client.link_up and link.client.estop_latched is False)


@pytest.fixture
def fast_auth(monkeypatch):
    monkeypatch.setattr(ActClient, "AUTH_REPLY_TIMEOUT_S", 0.05, raising=False)


# ── 같은 키: 종전처럼 오간다 ─────────────────────────────────────────────────────


def test_matching_keys_execute_round_trip_and_every_frame_is_signed():
    async def _t():
        link = await _Link(KEY, KEY).start()
        await _ready(link)
        result = await link.client.execute(BUTTONS, sequence_id="a1", appliance_id="microwave")
        assert result.success is True and link.presses() == BUTTONS

        sent, received = link.to_act.docs(), link.to_hub.docs()
        hello = sent[0]
        assert set(hello) == {"type", "cn", "mac"} and hello["type"] == "hello" and is_nonce(hello["cn"])
        reply = received[0]
        assert reply["type"] == "act_info" and reply["cn"] == hello["cn"] and is_nonce(reply["sn"])
        assert "seq" not in reply and len(reply["mac"]) == 64
        for frames in (sent[1:], received[1:]):
            seqs = [f["seq"] for f in frames]
            assert seqs == list(range(1, len(frames) + 1))
            assert all(len(f["mac"]) == 64 for f in frames)
        assert any(f["type"] == "execute" for f in sent[1:])
        assert any(f["type"] == "result" for f in received[1:])
        await link.close()

    asyncio.run(_t())


def test_matching_keys_abort_mid_execution_still_stops():
    async def _t():
        link = await _Link(KEY, KEY, press_s=0.05).start()
        await _ready(link)
        buttons = ["b1", "b2", "b3", "b4", "b5"]
        task = asyncio.create_task(link.client.execute(buttons, sequence_id="stop-1", appliance_id="microwave"))
        await asyncio.sleep(0.08)
        await link.client.abort()
        result = await task
        assert result.success is False and result.outcome == "stopped"
        assert len(link.presses()) < 5
        await link.close()

    asyncio.run(_t())


def test_unsigned_abort_is_not_a_stop_bypass():
    """위조 정지도 공격 경로다 — 서명 없는 abort는 실행을 멈추지 않는다(정지는 서명된 abort로만)."""
    async def _t():
        link = await _Link(KEY, KEY, press_s=0.03).start()
        await _ready(link)
        task = asyncio.create_task(link.client.execute(["b1", "b2", "b3"], sequence_id="s", appliance_id="microwave"))
        await asyncio.sleep(0.02)
        link.inject({"type": "abort"})
        result = await task
        assert result.success is True and link.presses() == ["b1", "b2", "b3"]
        await link.close()

    asyncio.run(_t())


# ── 다른 키·한쪽만 키: fail closed ──────────────────────────────────────────────


def test_wrong_key_keeps_link_down_with_auth_reason_and_nothing_executes(fast_auth):
    async def _t():
        link = await _Link(KEY, OTHER_KEY).start()
        await _until(lambda: "인증 실패" in (link.client.link_down_reason or ""))
        assert "SIMPLELAY_LINK_KEY" in link.client.link_down_reason
        assert link.client.link_up is False and link.client.estop_latched is None
        with pytest.raises(ActLinkError):
            await link.client.execute(BUTTONS, sequence_id="x", appliance_id="microwave")
        await asyncio.sleep(0.4)
        # RPi4는 답하지 않는다(서명이 맞지 않는 hello) — 아무것도 누르지 않는다.
        assert link.to_hub.docs() == [] and link.presses() == []
        # hello는 다시 보내되 늘어나는 간격으로(뜨겁게 돌지 않는다)
        hellos = [d for d in link.to_act.docs() if d["type"] == "hello"]
        assert 2 <= len(hellos) <= 12
        assert len({h["cn"] for h in hellos}) == len(hellos)
        assert not any(d["type"] != "hello" for d in link.to_act.docs())
        await link.close()

    asyncio.run(_t())


def test_key_on_rpi4_only_fails_closed():
    async def _t():
        link = await _Link(None, KEY).start()
        await asyncio.sleep(0.2)
        # 서명 없는 hello는 버린다 — 답이 없으니 걸림 상태는 끝까지 '모름'(실행 거절)
        assert link.to_hub.docs() == [] and link.client.estop_latched is None
        link.inject({"type": "execute", "sequence_id": "plain", "buttons": BUTTONS, "appliance_id": "microwave"})
        link.inject({"type": "dev_motion", "request_id": "d1", "op": "home"})
        await asyncio.sleep(0.2)
        assert link.presses() == [] and link.to_hub.docs() == []
        await link.close()

    asyncio.run(_t())


def test_key_on_rpi5_only_fails_closed():
    async def _t():
        link = await _Link(KEY, None).start()
        await _until(lambda: "인증 실패" in (link.client.link_down_reason or ""))
        # RPi4는 서명 없이 답했다 — RPi5는 그 답(걸림 상태·구성)을 믿지 않는다
        assert any(d["type"] == "estop_state" for d in link.to_hub.docs())
        assert link.client.link_up is False and link.client.estop_latched is None and link.client.act_info == {}
        with pytest.raises(ActLinkError):
            await link.client.execute(BUTTONS, sequence_id="x", appliance_id="microwave")
        assert link.presses() == []
        await link.close()

    asyncio.run(_t())


# ── 세션 중 끼워 넣기·재전송 ───────────────────────────────────────────────────


def test_unsigned_or_forged_execute_during_live_session_is_dropped():
    async def _t():
        link = await _Link(KEY, KEY).start()
        await _ready(link)
        # 연결 알림의 마지막(사건 신선도 기준점 답 clock_ref, 3차 평가 M1)까지 받은 뒤 센다.
        await _until(lambda: any(d["type"] == "clock_ref" for d in link.to_hub.docs()))
        before = len(link.to_hub.docs())
        evil = {"type": "execute", "sequence_id": "evil", "buttons": BUTTONS, "appliance_id": "microwave"}
        link.inject(evil)
        link.inject({**evil, "seq": 999, "mac": "0" * 64})
        link.inject({"type": "dev_motion", "request_id": "d1", "op": "jog", "axis": "x", "delta_mm": 5.0,
                     "seq": 1000, "mac": "f" * 64})
        await asyncio.sleep(0.2)
        assert link.presses() == []
        assert len(link.to_hub.docs()) == before  # 답하지 않는다
        # 세션은 그대로 — 정상 실행은 된다
        result = await link.client.execute(BUTTONS, sequence_id="ok", appliance_id="microwave")
        assert result.success is True and link.presses() == BUTTONS
        await link.close()

    asyncio.run(_t())


def test_replayed_frame_is_dropped():
    async def _t():
        link = await _Link(KEY, KEY).start()
        await _ready(link)
        await link.client.execute(BUTTONS, sequence_id="a1", appliance_id="microwave")
        assert link.presses() == BUTTONS
        signed = next(line for line in link.to_act.lines if b'"execute"' in line)
        results_before = sum(1 for d in link.to_hub.docs() if d["type"] == "result")

        link.inject(signed)  # 같은 줄 그대로(seq 재사용)
        bumped = json.loads(signed)
        bumped["seq"] = 500  # seq만 올리면 MAC이 맞지 않는다
        link.inject(bumped)
        await asyncio.sleep(0.2)
        assert link.presses() == BUTTONS
        assert sum(1 for d in link.to_hub.docs() if d["type"] == "result") == results_before

        result = await link.client.execute(["시작"], sequence_id="a2", appliance_id="microwave")
        assert result.success is True and link.presses() == [*BUTTONS, "시작"]
        await link.close()

    asyncio.run(_t())


def test_replayed_hello_cannot_yield_accepted_follow_on_frames():
    async def _t():
        link = await _Link(KEY, KEY).start()
        await _ready(link)
        await link.client.execute(BUTTONS, sequence_id="a1", appliance_id="microwave")
        hello = link.to_act.lines[0]
        execute = next(line for line in link.to_act.lines if b'"execute"' in line)
        infos_before = sum(1 for d in link.to_hub.docs() if d["type"] == "act_info")

        # 살아 있는 RPi4: 이미 쓴 hello는 버린다 — 세션을 갈아엎지 못한다
        link.inject(hello)
        await asyncio.sleep(0.1)
        assert sum(1 for d in link.to_hub.docs() if d["type"] == "act_info") == infos_before
        result = await link.client.execute(["시작"], sequence_id="a2", appliance_id="microwave")
        assert result.success is True
        await link.close()

        # 다시 켜진 RPi4(쓴 hello를 모름): 옛 hello는 새 sn만 낳고, 옛 세션 프레임은 받아들여지지 않는다
        reader, hub = asyncio.StreamReader(), asyncio.StreamReader()
        out = _Pipe(hub)
        grbl = MockGrblClient()
        fresh = ActExecutor(reader=reader, writer=out, link_key=KEY,
                            controller=ClosedLoopController(grbl, MockVerifier([True] * 10), MockAlertSink(),
                                                            MockSafetyController()))
        task = asyncio.create_task(fresh.run())
        reader.feed_data(hello)
        await _until(lambda: any(d["type"] == "act_info" for d in out.docs()))
        assert out.docs()[0]["sn"] != link.to_hub.docs()[0]["sn"]
        reader.feed_data(execute)
        await asyncio.sleep(0.2)
        assert grbl.commands == []
        assert not any(d["type"] in ("result", "error") for d in out.docs())
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

    asyncio.run(_t())


def test_server_auth_rejects_replayed_hello_and_old_session_frames():
    from rpi.services.link_auth import LinkSession, compute_mac, new_nonce, session_key

    key = KEY.encode()
    cn = new_nonce()
    hello = {"type": "hello", "cn": cn}
    hello["mac"] = compute_mac(key, hello)
    server = ServerAuth(KEY)
    assert server.open(dict(hello)) == {"type": "hello"}
    reply = server.seal({"type": "act_info"})
    old = LinkSession(session_key(key, cn, reply["sn"]))
    frame = old.seal({"type": "abort"})
    assert server.open(dict(frame)) == {"type": "abort"}
    assert server.open(dict(frame)) is None           # seq 재사용
    assert server.open(dict(hello)) is None           # 쓴 hello
    restarted = ServerAuth(KEY)
    assert restarted.open(dict(hello)) is not None    # 다시 켜진 뒤 옛 hello → 새 sn
    restarted.seal({"type": "act_info"})
    assert restarted.open(dict(old.seal({"type": "abort"}))) is None  # 옛 세션 키로는 아무것도 못 한다


# ── 키 없음(명시적 모의)·짧은 키 ───────────────────────────────────────────────────


def test_mock_only_link_without_keys_is_unchanged_on_the_wire():
    """명시적 모의 설정(off_for_mock)으로 연 무인증 링크 — 봉투 없이 종전 줄 그대로. 운영 진입점의 거절은
    test_link_key_required.py."""
    async def _t():
        link = await _Link(None, None).start()
        await _ready(link)
        result = await link.client.execute(BUTTONS, sequence_id="n1", appliance_id="microwave")
        assert result.success is True
        assert link.to_act.docs()[0] == {"type": "hello"}
        for doc in [*link.to_act.docs(), *link.to_hub.docs()]:
            assert not {"seq", "mac", "cn", "sn"} & set(doc)
        await link.close()

    asyncio.run(_t())


def test_no_key_in_env_is_refused_unless_explicitly_mock_only(caplog):
    with pytest.raises(LinkKeyError):
        link_key_from_env({})
    with caplog.at_level(logging.WARNING):
        assert link_key_from_env({"SIMPLELAY_LINK_AUTH": "off_for_mock"}) is None
    warnings = [r for r in caplog.records if "SIMPLELAY_LINK_KEY" in r.getMessage()]
    assert len(warnings) == 1


def test_short_key_is_refused_everywhere():
    short = "x" * 15
    with pytest.raises(LinkKeyError):
        link_key_from_env({"SIMPLELAY_LINK_KEY": short})

    async def _t():
        with pytest.raises(LinkKeyError):
            ActClient(asyncio.StreamReader(), _Pipe(asyncio.StreamReader()), link_key=short)
        with pytest.raises(LinkKeyError):
            ActExecutor(reader=asyncio.StreamReader(), writer=_Pipe(asyncio.StreamReader()),
                        controller=ClosedLoopController(MockGrblClient(), MockVerifier([True]), MockAlertSink(),
                                                        MockSafetyController()), link_key=short)

    asyncio.run(_t())
    assert link_key_from_env({"SIMPLELAY_LINK_KEY": "y" * 16}) == b"y" * 16


def test_key_is_never_logged(caplog, fast_auth):
    async def _t():
        link = await _Link(KEY, OTHER_KEY).start()
        await _until(lambda: "인증 실패" in (link.client.link_down_reason or ""))
        link.inject({"type": "execute", "sequence_id": "evil", "buttons": BUTTONS, "appliance_id": "microwave"})
        await asyncio.sleep(0.1)
        await link.close()

    with caplog.at_level(logging.DEBUG):
        asyncio.run(_t())
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert KEY not in text and OTHER_KEY not in text
