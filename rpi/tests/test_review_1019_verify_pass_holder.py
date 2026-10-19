"""검토 2026-10-19: 확인 주행(자리 확인)이 기계 제어권을 잡고 있을 때의 안내.

확인 주행은 중재자에 ``verify_pass``라는 이름으로 제어권을 잡는다. 개발자 세션 시작은 그 거절을 '이전 세션의 정지를
정리하는 중'(code ``stopping``)으로 잘못 알렸고 상태도 '쉬는 중'으로 보였다 — 실제로는 기계가 움직이는 일반 실행과
같은 상황이다.
"""

from __future__ import annotations

import pytest

from rpi.services.developer_session import PHASE_EXECUTION_BUSY, DevSessionConflict
from rpi.services.verify_pass import VERIFY_PASS_HOLDER
from rpi.tests.test_developer_session import _manager


def test_dev_session_start_during_verify_pass_is_execution_busy_not_stopping():
    manager, _, _, _, arbiter = _manager()
    arbiter.acquire(VERIFY_PASS_HOLDER)

    with pytest.raises(DevSessionConflict) as info:
        manager.start("microwave", "node-1")
    assert info.value.code == "execution_busy"
    assert "정지를 정리" not in str(info.value)
    assert manager.state().phase == PHASE_EXECUTION_BUSY
    assert arbiter.holder == VERIFY_PASS_HOLDER  # 거절된 시작이 확인 주행의 제어권을 건드리지 않는다
