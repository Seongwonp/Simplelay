"""외부 검토 2026-10-19 (5): 루틴 맨 앞의 안내 단계가 첫 장치 구간을 보낸 **뒤에** 알림함에 남았다.

동기 실행(``execute_approved``)이면 첫 구간이 다 끝난 뒤에야 '먼저 알려 드릴 말'이 남았다. 이제 첫 구간을 보내기 전에
남긴다(루틴 기록의 단계 순서도 안내 → 장치).
"""

from __future__ import annotations

import pytest

from rpi.tests.test_routines import HEAT, _result, _runner_setup

ANNOUNCE = {"kind": "announce", "text": "곧 데울게요"}


@pytest.mark.parametrize("path", ["execute", "submit"])
def test_leading_announcement_is_recorded_before_the_first_segment_is_sent(path):
    runner, routine, approved, service, care = _runner_setup([lambda c: _result(c)], [ANNOUNCE, HEAT])
    order: list[str] = []
    care.on_append = lambda: order.append("announce")
    original = service._run

    def run(batch):
        order.append("dispatch")
        return original(batch)

    service._run = run
    if path == "execute":
        result = runner.execute_approved(approved, scenario_id=routine.scenario_key())
    else:
        runner.submit_approved(approved, scenario_id=routine.scenario_key())
        result = runner.runs()[0]
    assert order[:2] == ["announce", "dispatch"]
    assert result.steps[0]["kind"] == "announce"


def test_refused_first_segment_still_records_no_run():
    """첫 구간이 거절되면(바쁨 등) 루틴 실행 기록은 생기지 않는다 — 예외는 그대로 승인 응답으로 올라간다."""
    runner, routine, approved, service, care = _runner_setup([lambda c: _result(c)], [ANNOUNCE, HEAT])

    def busy(batch):
        raise RuntimeError("다른 일을 하고 있어요")

    service._run = busy
    with pytest.raises(RuntimeError):
        runner.execute_approved(approved, scenario_id=routine.scenario_key())
    assert runner.runs() == ()
