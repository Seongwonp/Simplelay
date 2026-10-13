"""Fault rehearsals run the real protocol peers and closed-loop controller."""

import asyncio

import pytest

from rpi4.simulator import SCENARIOS, run_scenario


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_rehearsal_contract(scenario):
    report = asyncio.run(run_scenario(scenario))
    assert report["passed"], report
    assert report["execution_mode"] == "mock"
    assert report["act_local"]["operation_confirmed"] is False


def test_lost_response_does_not_claim_success_or_resend():
    report = asyncio.run(run_scenario("lost_response"))
    assert report["act_local"]["status"] == "succeeded"
    assert report["hub"] == {"outcome": "timeout_result_unknown", "result": None}
    # 사건 신선도 기준점 탐침(clock_probe, 3차 평가 M1)은 연결 알림이라 실행 흐름 비교에서 뺀다.
    assert [f["type"] for f in report["wire"]["hub_to_act"] if f["type"] != "clock_probe"] == ["execute", "abort"]
    assert len(report["wire"]["dropped"]) == 1


def test_stop_consumed_before_second_button_but_not_proven_by_wire():
    report = asyncio.run(run_scenario("stop"))
    assert report["act_local"]["presses"] == ["즉석밥"]
    assert report["act_local"]["status"] == "safety_stopped"
    assert report["hub"]["result"]["success"] is False
    assert "status" not in report["wire"]["act_to_hub"][0]


def test_scenarios_do_not_leak_stop_or_failure_into_next_run():
    async def run():
        await run_scenario("press_failure")
        await run_scenario("stop")
        return await run_scenario("success")
    report = asyncio.run(run())
    assert report["passed"]
    assert report["act_local"]["safety_reasons"] == []


def test_unknown_scenario_is_rejected():
    with pytest.raises(ValueError, match="unknown scenario"):
        asyncio.run(run_scenario("real"))
