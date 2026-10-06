"""보정 좌표(mm)가 실행기까지 흐르는 길 — PressCommand·폐루프·UART 계약·서비스.

좌표 수치는 시험용 임의 값이다(실물 값 아님).
"""

from __future__ import annotations

import asyncio
import json
import math
import time
from datetime import datetime

import pytest

from rpi.api.service import SimpleLayService
from rpi.controller import (
    ButtonTarget,
    ClosedLoopController,
    Correction,
    PressCommand,
)
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent.rules import RuleBasedIntentResolver
from rpi.services.act_client import ActClient
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.verifier import MockVerifier
from rpi4.models.act_messages import ExecuteMsg, parse_act_message
from rpi4.services.act_executor import ActExecutor


class _FixedClock:
    def now(self) -> datetime:
        return datetime(2026, 9, 28, 12, 0, 0)


def _controller(grbl=None, verifier_outcomes=None) -> ClosedLoopController:
    return ClosedLoopController(
        grbl or MockGrblClient(),
        MockVerifier(outcomes=verifier_outcomes or [True] * 20),
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
    )


# ── PressCommand ─────────────────────────────────────────────────────────


def test_press_command_without_coordinates_is_unchanged():
    command = PressCommand("시작")
    assert command == PressCommand("시작", None)
    assert (command.x_mm, command.y_mm, command.press_ms) == (None, None, None)
    assert command.has_coordinates is False


@pytest.mark.parametrize(
    "kwargs",
    [
        {"x_mm": 1.0},
        {"y_mm": 1.0},
        {"x_mm": math.nan, "y_mm": 1.0},
        {"x_mm": 1.0, "y_mm": math.inf},
        {"x_mm": True, "y_mm": 1.0},
        {"press_ms": 0},
        {"press_ms": 1.5},
    ],
)
def test_press_command_rejects_half_or_invalid_coordinates(kwargs):
    with pytest.raises(ValueError):
        PressCommand("시작", **kwargs)


def test_button_target_requires_both_coordinates():
    with pytest.raises(ValueError):
        ButtonTarget(None, None)  # type: ignore[arg-type]


# ── 폐루프 ───────────────────────────────────────────────────────────────


def test_closed_loop_without_targets_sends_legacy_commands():
    grbl = MockGrblClient()
    _controller(grbl).execute(["해동", "시작"])
    assert grbl.commands == [PressCommand("해동"), PressCommand("시작")]


def test_closed_loop_attaches_targets_including_on_retries():
    grbl = MockGrblClient()
    controller = _controller(grbl, verifier_outcomes=[False, True, True])
    controller.execute(
        ["해동", "시작"],
        {"해동": ButtonTarget(12.5, 30.0, press_ms=120)},
    )
    first, retry, start = grbl.commands
    assert (first.x_mm, first.y_mm, first.press_ms) == (12.5, 30.0, 120)
    assert retry.correction == Correction(1, True, True)
    assert (retry.x_mm, retry.y_mm) == (12.5, 30.0)  # 보정 폭은 어댑터가 정한다
    assert start == PressCommand("시작")  # 좌표 없는 버튼은 mock에서 종전대로


def test_mock_client_does_not_require_coordinates():
    assert getattr(MockGrblClient(), "requires_coordinates", False) is False


def test_request_stop_is_forwarded_to_an_adapter_that_supports_it():
    class _Adapter(MockGrblClient):
        def __init__(self):
            super().__init__()
            self.stops = 0
            self.resets = 0

        def request_stop(self):
            self.stops += 1

        def reset_stop(self):
            self.resets += 1

    adapter = _Adapter()
    controller = _controller(adapter)
    controller.request_stop()
    controller.reset_stop()
    assert (adapter.stops, adapter.resets) == (1, 1)


# ── UART 계약 (RPi5 → RPi4) ────────────────────────────────────────────────


def test_execute_without_targets_parses_as_before():
    msg = parse_act_message('{"type":"execute","sequence_id":"s1","buttons":["시작"],"appliance_id":"microwave"}')
    assert msg == ExecuteMsg("s1", ("시작",), "microwave")
    assert msg.targets == {}


def test_execute_with_targets_parses_coordinates():
    msg = parse_act_message(
        json.dumps(
            {
                "type": "execute",
                "sequence_id": "s1",
                "appliance_id": "microwave",
                "buttons": ["해동", "시작"],
                "targets": {"해동": {"x_mm": 10, "y_mm": 20.5, "press_ms": 150}},
            },
            ensure_ascii=False,
        )
    )
    assert msg.targets == {"해동": ButtonTarget(10.0, 20.5, 150)}


@pytest.mark.parametrize(
    "targets",
    [
        [],
        {"없는버튼": {"x_mm": 1, "y_mm": 2}},
        {"시작": {"x_mm": 1}},
        {"시작": {"x_mm": "1", "y_mm": 2}},
        {"시작": {"x_mm": True, "y_mm": 2}},
        {"시작": {"x_mm": 1, "y_mm": 2, "press_ms": 0}},
        {"시작": [1, 2]},
    ],
)
def test_malformed_targets_drop_the_whole_message(targets):
    raw = json.dumps(
        {"type": "execute", "sequence_id": "s1", "buttons": ["시작"], "targets": targets},
        ensure_ascii=False,
    )
    assert parse_act_message(raw) is None


def test_non_finite_coordinates_are_rejected():
    raw = '{"type":"execute","sequence_id":"s1","buttons":["시작"],"appliance_id":"microwave","targets":{"시작":{"x_mm":NaN,"y_mm":1}}}'
    assert parse_act_message(raw) is None


class _PipeWriter:
    def __init__(self, peer_reader: asyncio.StreamReader) -> None:
        self._peer_reader = peer_reader
        self.lines: list[dict] = []

    def write(self, data: bytes) -> None:
        self.lines.append(json.loads(data.decode("utf-8")))
        self._peer_reader.feed_data(data)

    async def drain(self) -> None:
        pass


def test_targets_travel_from_act_client_to_the_rpi4_adapter():
    async def _t():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        rpi4_writer, rpi5_writer = _PipeWriter(rpi5_reader), _PipeWriter(rpi4_reader)
        grbl = MockGrblClient()
        executor = ActExecutor(rpi4_reader, rpi4_writer, _controller(grbl))
        client = ActClient(rpi5_reader, rpi5_writer)
        await client.start()
        task = asyncio.create_task(executor.run_once())
        result = await client.execute(
            ["해동", "시작"],
            sequence_id="c1",
            targets={"시작": ButtonTarget(40.0, 5.0)}, appliance_id="microwave")
        await task
        await executor.wait_idle()
        await client.stop()
        return result, grbl, rpi5_writer.lines

    result, grbl, sent = asyncio.run(_t())
    assert result.success is True
    assert sent[0]["targets"] == {"시작": {"x_mm": 40.0, "y_mm": 5.0}}
    assert grbl.commands == [PressCommand("해동"), PressCommand("시작", x_mm=40.0, y_mm=5.0)]


def test_act_client_without_targets_sends_the_legacy_line():
    async def _t():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        rpi5_writer = _PipeWriter(rpi4_reader)
        client = ActClient(rpi5_reader, rpi5_writer)
        await client.start()
        task = asyncio.create_task(client.execute(["시작"], sequence_id="c2", appliance_id="microwave"))
        await asyncio.sleep(0.01)
        rpi5_reader.feed_data(b'{"type":"result","sequence_id":"c2","success":true,"retry":0}\n')
        await task
        await client.stop()
        return rpi5_writer.lines

    (line,) = asyncio.run(_t())
    # 좌표 키는 없고, 대상(appliance_id)은 2026-10-07부터 늘 싣는다(평가 H3).
    assert line == {"type": "execute", "sequence_id": "c2", "buttons": ["시작"], "appliance_id": "microwave"}


# ── 서비스(RPi5): 레지스트리의 보정 좌표 → 실행 대상 ─────────────────────────


def _service(controller, registry):
    return SimpleLayService(
        RuleBasedIntentResolver(),
        controller,
        clock=_FixedClock(),
        appliance_registry=registry,
    )


def test_service_passes_calibrated_coordinates_to_the_controller():
    registry = ApplianceRegistry()
    registry.apply_calibration("microwave", version="v-test", coords={"BT-05": (60.0, 120.0)})
    grbl = MockGrblClient()
    _service(_controller(grbl), registry).execute_buttons(("즉석밥", "시작"), appliance_id="microwave")
    assert grbl.commands == [
        PressCommand("즉석밥"),
        PressCommand("시작", x_mm=60.0, y_mm=120.0),
    ]


def test_service_without_calibration_keeps_the_legacy_call():
    grbl = MockGrblClient()
    _service(_controller(grbl), ApplianceRegistry()).execute_buttons(
        ("즉석밥", "시작"), appliance_id="microwave"
    )
    assert grbl.commands == [PressCommand("즉석밥"), PressCommand("시작")]


def test_service_does_not_pass_targets_to_controllers_that_do_not_declare_support():
    class _LegacyController:
        def __init__(self):
            self.calls = []

        def execute(self, buttons):  # targets 인자를 모른다
            self.calls.append(tuple(buttons))
            return _controller().execute(buttons)

    registry = ApplianceRegistry()
    registry.apply_calibration("microwave", version="v-test", coords={"BT-05": (60.0, 120.0)})
    legacy = _LegacyController()
    _service(legacy, registry).execute_buttons(("시작",), appliance_id="microwave")
    assert legacy.calls == [("시작",)]


def test_async_job_path_also_carries_coordinates():
    registry = ApplianceRegistry()
    registry.apply_calibration("microwave", version="v-test", coords={"BT-05": (60.0, 120.0)})
    grbl = MockGrblClient()
    service = _service(_controller(grbl), registry)
    job_id = service.submit_buttons(("시작",), appliance_id="microwave")
    deadline = time.monotonic() + 5.0
    while service.status().last_job_id != job_id and time.monotonic() < deadline:
        time.sleep(0.01)
    assert service.status().last_job_id == job_id
    assert grbl.commands == [PressCommand("시작", x_mm=60.0, y_mm=120.0)]
