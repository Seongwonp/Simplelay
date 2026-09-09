"""GET /status가 **이 실행이 대상으로 삼은 가전**을 말한다.

지금까지 상태에는 진행(버튼·재시도·단계)만 있고 대상은 없었다. 그러면
화면은 버튼 코드를 자기가 아는 방법으로 읽을 수밖에 없다 -- 실제로 앱은
전역 하드코딩 표(전자레인지·에어컨)로 읽었고, 커스텀 가전의 버튼은
`custom_btn_1` 그대로 나왔다. 대상을 서버가 말하지 않으면 화면은 결국
"지금 고른 가전"으로 메우게 되는데, 실행 중에 다른 가전을 고르면 그 순간
화면이 틀린 버튼 이름을 말한다.

대상은 실행이 정한다. 화면이 정하지 않는다.
"""

import threading

from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import RuleBasedIntentResolver
from rpi.verifier import MockVerifier


def _service(grbl: MockGrblClient | None = None) -> SimpleLayService:
    return SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(
            grbl or MockGrblClient(),
            MockVerifier(outcomes=[True] * 20),
            MockAlertSink(),
            MockSafetyController(),
            retry_waiter=MockRetryWaiter(),
        ),
    )


def test_idle_status_has_no_target() -> None:
    """아무것도 실행한 적이 없으면 대상도 없다 -- 지어내지 않는다."""
    snap = _service().status()

    assert snap.appliance_id is None
    assert snap.last_appliance_id is None


def test_finished_run_reports_the_appliance_it_targeted() -> None:
    service = _service()

    service.execute_buttons(("BT-05",), appliance_id="custom_1")
    snap = service.status()

    # 끝난 실행의 대상은 last_ 쪽으로 옮겨간다(job_id와 같은 규칙).
    assert snap.appliance_id is None
    assert snap.last_appliance_id == "custom_1"


def test_running_status_reports_the_target_while_it_runs() -> None:
    """실행 중에 물어봐도 대상을 안다.

    화면이 진행을 그리는 바로 그 순간에 필요한 값이라, 끝난 뒤에만 알 수
    있으면 소용이 없다.
    """
    started = threading.Event()
    release = threading.Event()

    class _BlockingGrbl(MockGrblClient):
        def press(self, *args, **kwargs):  # type: ignore[override]
            started.set()
            release.wait(timeout=5)
            return super().press(*args, **kwargs)

    service = _service(_BlockingGrbl())
    job_id = service.submit_buttons(("BT-05",), appliance_id="거실_에어컨")
    try:
        assert started.wait(timeout=5)
        snap = service.status()

        assert snap.running is True
        assert snap.job_id == job_id
        assert snap.appliance_id == "거실_에어컨"
    finally:
        release.set()


def test_next_run_replaces_the_previous_target() -> None:
    """이전 실행의 대상이 다음 실행에 남지 않는다."""
    service = _service()

    service.execute_buttons(("BT-05",), appliance_id="a1")
    service.execute_buttons(("BT-05",), appliance_id="a2")

    assert service.status().last_appliance_id == "a2"


def test_target_less_run_reports_none_not_a_leftover() -> None:
    """대상 없이 도는 구성(가전 개념이 없는 브리지)에서는 None이다.

    앞 실행의 값이 남으면, 화면은 이번 실행이 그 가전을 눌렀다고 말하게
    된다 -- 지어낸 사실이다.
    """
    service = _service()

    service.execute_buttons(("BT-05",), appliance_id="a1")
    service.execute_buttons(("BT-05",))

    assert service.status().last_appliance_id is None


# ── HTTP 계층 ─────────────────────────────────────────────────────────────
#
# 스냅샷에만 값이 있고 응답 모델에 필드를 안 넣으면, 서버는 알고 있는데
# 클라이언트는 여전히 못 받는다 -- 실제로 여기서 한 번 끊길 수 있는 자리다.


def test_status_endpoint_carries_the_target() -> None:
    import pytest  # noqa: F401  (fixture 없이 직접 조립한다)
    from fastapi.testclient import TestClient

    from rpi.api.deps import get_service
    from rpi.main import app

    get_service.cache_clear()
    try:
        service = get_service()
        service.execute_buttons(("BT-05",), appliance_id="microwave")

        with TestClient(app) as client:
            body = client.get("/status").json()

        assert body["last_appliance_id"] == "microwave"
        assert body["appliance_id"] is None
    finally:
        get_service.cache_clear()
