"""정지 확인 단계(2026-10-13) — `SerialMotionClient`가 MCU의 정지 응답을 읽어 단계를 나누는지.

docs/계획-정지-확인-2026-10-12.md 1단계. 단계는 ``sent``(정지 줄을 썼다) → ``mcu_ack``(같은 id의 ``ok:true``)
→ ``verified``(정지 뒤 status 두 번의 엔코더 a·b가 같다). 가짜 MCU(rpi/tools/fake_mcu.py)로 보는 것은 호스트
쪽 규약 처리까지다 — **실물 미검증**.
"""

from __future__ import annotations

import json
import threading
import time

import pytest

from rpi.controller.serial_motion import (
    STOP_MCU_ACK,
    STOP_SENT,
    STOP_VERIFIED,
    InMemoryLinePipe,
    MotionAlarm,
    MotionConfig,
    MotionStopped,
    SerialMotionClient,
)
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu


@pytest.fixture
def link():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    yield pipe, mcu
    mcu.close()


def _client(pipe, config: MotionConfig = REHEARSAL_CONFIG, **kwargs) -> SerialMotionClient:
    return SerialMotionClient(pipe.host, config, poll_s=0.01, **kwargs)


def _stop_ids(mcu: FakeMcu) -> list[int]:
    return [d["id"] for d in mcu.received if d.get("cmd") == "stop"]


def test_idle_stop_records_mcu_ack_with_latency(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    assert client.request_stop() is True
    report = client.wait_stop_ack(0.5)
    assert report.level == STOP_MCU_ACK
    assert report.sent is True
    assert report.stop_id == _stop_ids(mcu)[-1]
    assert isinstance(report.ack_ms, int) and 0 <= report.ack_ms < 500


def test_request_stop_returns_before_the_mcu_answers(link):
    pipe, mcu = link
    client = _client(pipe)
    mcu.handlers["stop"] = lambda d: None  # 답하지 않는 MCU
    started = time.monotonic()
    assert client.request_stop() is True
    assert time.monotonic() - started < 0.05  # 정지 경로를 막지 않는다
    report = client.wait_stop_ack(0.1)
    assert report.level == STOP_SENT
    assert report.ack_ms is None
    assert report.sent is True


def test_stop_reply_during_an_inflight_request_is_recorded_not_dropped(link):
    """진행 중 요청의 읽기 루프가 정지 응답을 버리지 않고 기록한다(읽는 쪽은 하나)."""
    pipe, mcu = link
    client = _client(pipe)
    mcu.handlers["limits"] = lambda d: None  # 기한(1 s)까지 읽기 루프가 op 잠금을 쥔다
    def _query() -> None:
        try:
            client.limits()
        except Exception:  # noqa: BLE001 - 기한 초과가 정상
            pass

    worker = threading.Thread(target=_query, daemon=True)
    worker.start()
    time.sleep(0.05)
    client.request_stop()
    started = time.monotonic()
    report = client.wait_stop_ack(0.5)
    assert report.level == STOP_MCU_ACK
    assert time.monotonic() - started < 0.4  # 잠금을 기다리지 않고 진행 루프의 기록으로 끝났다
    worker.join(timeout=2.0)


def test_stop_during_move_ends_stopped_and_ack_is_read_after(link):
    pipe, mcu = link
    config = MotionConfig(**{**REHEARSAL_CONFIG.__dict__, "move_timeout_s": 5.0})
    client = _client(pipe, config)
    client.home()
    mcu.delays["move"] = 5.0  # 이동이 끝나지 않는 동안 정지
    errors: list[BaseException] = []

    def _run() -> None:
        try:
            client.move_to(10.0, 10.0)
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    worker = threading.Thread(target=_run, daemon=True)
    worker.start()
    time.sleep(0.1)
    client.request_stop()
    report = client.wait_stop_ack(0.5)
    worker.join(timeout=2.0)
    # 정지 표시를 먼저 보면 MotionStopped, MCU의 'stopped' 거절을 먼저 읽으면 MotionAlarm — 둘 다 이동은 끝났다.
    assert isinstance(errors[0], (MotionStopped, MotionAlarm))
    assert report.level == STOP_MCU_ACK


def test_stop_reply_read_by_the_next_request_is_not_its_answer(link):
    """정지 응답이 다음 명령의 응답으로 오인되지 않고(ID), 그 명령의 루프가 확인으로 기록한다."""
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    mcu.handlers["stop"] = lambda d: [{"id": d["id"], "ok": True, "state": "alarm", "a": 999, "b": 999}]
    client.request_stop()
    status = client.status()
    assert status.a_counts == 0 and status.state == "idle"
    assert client.wait_stop_ack(0.0).level == STOP_MCU_ACK


def test_ack_of_an_older_stop_does_not_confirm_a_newer_one(link):
    pipe, mcu = link
    client = _client(pipe)
    replies: list[dict] = []
    mcu.handlers["stop"] = lambda d: (replies.append(d), None)[1]  # 기록만, 답 없음
    client.request_stop()
    client.request_stop()
    deadline = time.monotonic() + 1.0
    while len(replies) < 2 and time.monotonic() < deadline:
        time.sleep(0.01)
    first, second = replies[0]["id"], replies[1]["id"]
    pipe.device.write_line(json.dumps({"id": first, "ok": True}))  # 옛 정지의 늦은 답
    assert client.wait_stop_ack(0.2).level == STOP_SENT
    pipe.device.write_line(json.dumps({"id": second, "ok": True}))
    assert client.wait_stop_ack(0.5).level == STOP_MCU_ACK


def test_confirm_with_a_stop_id_returns_only_that_stops_record(link):
    """2차 평가 M-N2: 보낼 때 얻은 id로 확인하면, 그 뒤 다른 정지가 나가도 최신 기록으로 바꿔 답하지 않는다."""
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    answered: list[int] = []

    def first_only(doc: dict):
        answered.append(doc["id"])
        return [{"id": doc["id"], "ok": True}] if len(answered) == 1 else None

    mcu.handlers["stop"] = first_only
    client.request_stop()
    first = client.last_stop_id
    assert client.wait_stop_ack(0.5, stop_id=first).level == STOP_MCU_ACK
    client.request_stop()  # 답이 없는 두 번째 정지
    second = client.last_stop_id
    assert second is not None and second != first
    report = client.confirm_stop(ack_timeout_s=0.1, verify_interval_s=0.02, stop_id=first)
    assert report.stop_id == first and report.level == STOP_VERIFIED and report.ack_ms is not None
    later = client.confirm_stop(ack_timeout_s=0.05, verify_interval_s=0.02, stop_id=second)
    assert later.stop_id == second and later.level == STOP_SENT and later.ack_ms is None
    # 기록이 없는 id는 다른 정지의 기록으로 대신하지 않는다.
    missing = client.wait_stop_ack(0.0, stop_id=9999)
    assert missing.stop_id == 9999 and missing.level is None


def test_failed_stop_ack_reply_is_not_a_confirmation(link):
    pipe, mcu = link
    client = _client(pipe)
    mcu.handlers["stop"] = lambda d: [{"id": d["id"], "ok": False, "error": "alarm"}]
    client.request_stop()
    assert client.wait_stop_ack(0.2).level == STOP_SENT


def test_write_failure_reports_no_level(link, monkeypatch):
    pipe, _mcu = link
    client = _client(pipe)

    def boom(line: str) -> None:
        raise OSError("port gone")

    monkeypatch.setattr(pipe.host, "write_line", boom)
    assert client.request_stop() is False
    report = client.wait_stop_ack(0.05)
    assert report.sent is False
    assert report.level is None


def test_confirm_stop_verifies_with_two_equal_encoder_reads(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    client.request_stop()
    report = client.confirm_stop(ack_timeout_s=0.5, verify_interval_s=0.02)
    assert report.level == STOP_VERIFIED
    assert report.ack_ms is not None
    assert [d["cmd"] for d in mcu.received].count("status") >= 2


def test_confirm_stop_stays_at_mcu_ack_when_encoders_still_change(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    original = mcu.handlers["status"]

    def drifting(doc: dict) -> list:
        mcu.a += 5  # 아직 움직이는 축
        return original(doc)

    mcu.handlers["status"] = drifting
    client.request_stop()
    report = client.confirm_stop(ack_timeout_s=0.5, verify_interval_s=0.02)
    assert report.level == STOP_MCU_ACK
    assert report.detail and "움직" in report.detail


def test_confirm_stop_verifies_after_the_axis_coasts_to_rest(link):
    """10/13 실물: 이동 중 정지 뒤 첫 status(약 +27 ms)와 0.1 s 뒤 status의 엔코더가 달랐다(관성 1~7카운트).
    엔코더는 약 0.15 s 안에 멈췄다. 같은 값이 두 번 연속 나올 때까지 다시 물어 ``verified``로 올린다."""
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    original = mcu.handlers["status"]
    coasting = {"left": 2}

    def coast(doc: dict) -> list:
        if coasting["left"] > 0:
            coasting["left"] -= 1
            mcu.a += 3  # 정지 응답 뒤에도 잠깐 더 도는 축
        return original(doc)

    mcu.handlers["status"] = coast
    client.request_stop()
    report = client.confirm_stop(ack_timeout_s=0.5, verify_interval_s=0.02, verify_deadline_s=0.5)
    assert report.level == STOP_VERIFIED
    assert [d["cmd"] for d in mcu.received].count("status") >= 3


def test_confirm_stop_gives_up_at_the_deadline_while_still_moving(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    original = mcu.handlers["status"]

    def drifting(doc: dict) -> list:
        mcu.a += 5
        return original(doc)

    mcu.handlers["status"] = drifting
    client.request_stop()
    started = time.monotonic()
    report = client.confirm_stop(ack_timeout_s=0.5, verify_interval_s=0.02, verify_deadline_s=0.2)
    assert report.level == STOP_MCU_ACK
    assert report.detail and "움직" in report.detail
    assert time.monotonic() - started < 1.0  # 기한에서 멈춘다(status 응답 기한 하나만큼 여유)


def test_confirm_stop_without_ack_does_not_verify(link):
    pipe, mcu = link
    client = _client(pipe)
    mcu.handlers["stop"] = lambda d: None
    client.request_stop()
    report = client.confirm_stop(ack_timeout_s=0.05, verify_interval_s=0.02)
    assert report.level == STOP_SENT
    assert "status" not in [d["cmd"] for d in mcu.received]


def test_stop_ack_is_emitted_for_the_line_log(link):
    pipe, _mcu = link
    events: list[tuple[str, dict]] = []
    client = _client(pipe, on_event=lambda name, doc: events.append((name, doc)))
    client.request_stop()
    client.wait_stop_ack(0.5)
    acks = [doc for name, doc in events if name == "stop_ack"]
    assert len(acks) == 1 and isinstance(acks[0].get("ack_ms"), int)
