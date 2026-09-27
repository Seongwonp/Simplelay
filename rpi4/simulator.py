"""Run the existing Act protocol on in-memory streams, without hardware.

Usage: python -m rpi4.simulator --scenario all
No serial ports, cloud credentials, API database or usage history are opened.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import threading
from collections import deque
from dataclasses import asdict

from rpi.controller import ClosedLoopController, ExecutionResult
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.services.act_client import ActClient, ActClientConfig, ActLinkTimeoutError
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor

SCENARIOS = (
    "success", "retry", "press_failure", "stop", "lost_response",
    "fragmented", "noise",
)


class _Wire:
    def __init__(self, peer: asyncio.StreamReader, *, fragment: bool = False,
                 drop_result: bool = False) -> None:
        self.peer = peer
        self.fragment = fragment
        self.drop_result = drop_result
        self.frames: list[dict] = []
        self.dropped: list[dict] = []
        self.fragments: deque[bytes] = deque()

    def write(self, data: bytes) -> None:
        # Production writers emit one complete JSON line per write.
        doc = json.loads(data)
        self.frames.append(doc)
        if self.drop_result and doc.get("type") == "result":
            self.dropped.append(doc)
            return
        if self.fragment:
            # Split inside UTF-8 characters as well as JSON tokens.
            for byte in data:
                self.fragments.append(bytes([byte]))
        else:
            self.peer.feed_data(data)

    async def drain(self) -> None:
        while self.fragments:
            self.peer.feed_data(self.fragments.popleft())
            await asyncio.sleep(0)
        await asyncio.sleep(0)


class _ObservedController(ClosedLoopController):
    """Observe local facts without adding them to the production wire format."""

    result: ExecutionResult | None = None

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.stop_received = threading.Event()

    def request_stop(self) -> None:
        super().request_stop()
        self.stop_received.set()

    def execute(self, buttons):
        self.result = super().execute(buttons)
        return self.result


async def run_scenario(name: str) -> dict:
    """Run one isolated rehearsal and return JSON-safe evidence.

    ``passed`` concerns this fault scenario's expectations, not appliance success.
    All timing limits here are test budgets, never hardware measurements.
    """
    if name not in SCENARIOS:
        raise ValueError(f"unknown scenario: {name}")
    act_reader, hub_reader = asyncio.StreamReader(), asyncio.StreamReader()
    outbound = _Wire(act_reader, fragment=name == "fragmented")
    inbound = _Wire(hub_reader, fragment=name == "fragmented",
                    drop_result=name == "lost_response")
    grbl, safety = MockGrblClient(), MockSafetyController()
    entered, release = threading.Event(), threading.Event()

    def pace(button: str, completed: int) -> None:
        if name == "stop" and not entered.is_set():
            entered.set()
            if not release.wait(5):
                raise RuntimeError("simulator stop rendezvous timed out")

    outcomes = ([False, False, True, True] if name == "retry" else
                [False] * 20 if name == "press_failure" else [True] * 20)
    controller = _ObservedController(
        grbl=grbl, verifier=MockVerifier(outcomes), alerts=MockAlertSink(),
        safety=safety, step_pacer=pace,
    )
    executor = ActExecutor(act_reader, inbound, controller)
    client = ActClient(hub_reader, outbound, ActClientConfig(
        response_timeout_seconds=0.1 if name == "lost_response" else 5,
        per_button_timeout_seconds=0,
    ))
    task = asyncio.create_task(executor.run())
    await client.start()
    pending = None
    hub_result = None
    hub_outcome = "result"
    try:
        if name == "noise":
            act_reader.feed_data(b'not-json\n{"type":"unknown"}\n')
            hub_reader.feed_data(b'not-json\n{"type":"result",'
                                 b'"sequence_id":"unrelated","success":true,"retry":99}\n')
        pending = asyncio.create_task(client.execute(
            ["즉석밥", "시작"], sequence_id=f"sim-{name}",
        ))
        if name == "stop":
            if not await asyncio.to_thread(entered.wait, 3):
                raise RuntimeError("simulator did not reach first button")
            await client.abort()
            if not await asyncio.to_thread(controller.stop_received.wait, 3):
                raise RuntimeError("executor did not consume abort")
            release.set()
        try:
            hub_result = asdict(await pending)
        except ActLinkTimeoutError:
            hub_outcome = "timeout_result_unknown"
        await executor.wait_idle()
    finally:
        release.set()
        # EOF mirrors the production entry point's cooperative shutdown path.
        act_reader.feed_eof()
        try:
            await task
        finally:
            await executor.shutdown()
            if pending is not None and not pending.done():
                pending.cancel()
                await asyncio.gather(pending, return_exceptions=True)
            await client.stop()

    local = controller.result
    presses = [command.button for command in grbl.commands]
    expected_status = "safety_stopped" if name in ("press_failure", "stop") else "succeeded"
    expected_presses = {"retry": 4, "press_failure": 3, "stop": 1}.get(name, 2)
    checks = {
        "mock_only": controller.execution_mode.value == "mock",
        "local_status": local is not None and local.status.value == expected_status,
        "press_count": len(presses) == expected_presses,
        "one_execute_only": sum(f["type"] == "execute" for f in outbound.frames) == 1,
        "hub_evidence": (
            hub_result is None and hub_outcome == "timeout_result_unknown"
            if name == "lost_response" else
            hub_result is not None
            and hub_result["sequence_id"] == f"sim-{name}"
            and hub_result["success"] == (expected_status == "succeeded")
            and hub_result["retry"] == (2 if name in ("retry", "press_failure") else 0)
        ),
    }
    if name in ("lost_response", "stop"):
        checks["abort_sent"] = any(f["type"] == "abort" for f in outbound.frames)
    return {
        "scenario": name, "execution_mode": "mock", "transport": "in_memory",
        "passed": all(checks.values()), "checks": checks,
        "hub": {"outcome": hub_outcome, "result": hub_result},
        "act_local": {
            "status": local.status.value if local else None,
            "failed_layer": local.failed_layer.value if local and local.failed_layer else None,
            "operation_confirmed": False,
            "presses": presses, "safety_reasons": safety.reasons,
        },
        "wire": {"hub_to_act": outbound.frames, "act_to_hub": inbound.frames,
                 "dropped": inbound.dropped},
        "limitations": [
            "Synthetic L1 only; no actual appliance, sensor, motor or UART verification.",
            "Current wire result carries success/retry only; local stop/layer evidence is not received by the hub.",
        ],
    }


async def _run_selected(name: str) -> list[dict]:
    return [await run_scenario(item) for item in (SCENARIOS if name == "all" else (name,))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=("all", *SCENARIOS), default="all")
    args = parser.parse_args()
    reports = asyncio.run(_run_selected(args.scenario))
    # ASCII escapes keep redirected output portable on Windows consoles.
    print(json.dumps(reports, ensure_ascii=True, indent=2))
    return 0 if all(report["passed"] for report in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
