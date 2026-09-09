"""F4 이음매 — 실행 모드는 **실제로 실행한 대상**이 말한다.

F4의 첫 구현은 서비스 생성 시 `SIMPLELAY_ACT_MODE` 하나로 모드를 정해
두고 모든 이력에 그 값을 찍었다. 그런데 실행 대상은 `_controller_for()`
에서 가전별 원격 노드로 바뀐다. 그래서 이런 일이 성립했다:

    SIMPLELAY_ACT_MODE 미설정(=mock) + 선풍기는 원격 노드에 등록
    → 실제 원격 액추에이터가 버튼을 누름
    → CSV에는 **mock** 으로 기록

반대로 "원격이니까 real"이라고 추측하는 것도 똑같이 틀렸다. 원격 RPi4가
자기 안에서 `MockGrblClient`를 돌리고 있을 수 있다. 전송이 원격이라는
사실은 **물리적으로 눌렸는지에 대해 아무것도 말해주지 않는다.**

그래서 규칙은 하나다: **최종 선택된 실행 대상이 자기 모드를 명시한다.**
명시하지 않으면 `unknown`이다 — 지어내지 않는다.

여기서 지나는 경로: 실행 대상 결정 → 그 대상의 real/mock → history 기록.
"""

from datetime import datetime, timedelta, timezone

from rpi.api import SimpleLayService
from rpi.controller import (
    ButtonResult,
    ButtonStatus,
    ClosedLoopController,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
)
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.services import ApplianceRegistry, NodeRegistry
from rpi.services.history import InMemoryJobHistory
from rpi.verifier import MockVerifier

KST = timezone(timedelta(hours=9))
_NOW = datetime(2026, 9, 9, 19, 0, tzinfo=KST)


class _Node:
    """원격 노드 컨트롤러 흉내 — 자기 실행 모드를 스스로 말한다."""

    def __init__(self, mode: ExecutionMode) -> None:
        self.execution_mode = mode
        self.calls: list[tuple[str, ...]] = []

    def execute(self, buttons):
        self.calls.append(tuple(buttons))
        return ExecutionResult(
            ExecutionStatus.SUCCEEDED,
            tuple(
                ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons
            ),
        )


class _SilentNode(_Node):
    """모드를 말하지 않는 컨트롤러 — 옛 구현·서드파티 어댑터."""

    def __init__(self) -> None:
        super().__init__(ExecutionMode.UNKNOWN)
        del self.execution_mode


def _local_mock():
    return ClosedLoopController(
        MockGrblClient(),
        MockVerifier(outcomes=[True] * 20),
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
    )


def _service(history, nodes=None, controller=None):
    return SimpleLayService(
        RuleBasedIntentResolver(),
        controller or _local_mock(),
        clock=FixedClock(_NOW),
        history_store=history,
        node_registry=nodes,
        appliance_registry=ApplianceRegistry(),
    )


def _registry_with(appliance_id: str, node) -> NodeRegistry:
    registry = NodeRegistry(controller_factory=lambda _url: node)
    registry.register(appliance_id, "http://node.local")
    return registry


# ── 이음매 ────────────────────────────────────────────────────────────────


def test_remote_node_execution_is_not_recorded_as_the_local_mode():
    """이 테스트가 F4 첫 구현의 결함을 그대로 재현한다.

    로컬은 mock인데 실행은 원격 노드가 했다. mock으로 기록되면 실제 실행이
    성공률 통계에서 mock 쪽 분모에 들어간다.
    """
    history = InMemoryJobHistory()
    node = _Node(ExecutionMode.REAL)
    service = _service(history, nodes=_registry_with("microwave", node))

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    assert node.calls, "원격 노드가 실제로 실행했다"
    (entry,) = history.recent()
    assert entry.execution_mode is ExecutionMode.REAL


def test_remote_node_running_mocks_is_recorded_as_mock():
    """원격이라는 사실만으로 real이라고 추측하면 안 된다 — 저쪽 RPi4가
    아직 MockGrblClient일 수 있다."""
    history = InMemoryJobHistory()
    node = _Node(ExecutionMode.MOCK)
    service = _service(history, nodes=_registry_with("microwave", node))

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    (entry,) = history.recent()
    assert entry.execution_mode is ExecutionMode.MOCK


def test_local_mock_controller_says_mock_without_being_told():
    """서비스 밖에서 주입하는 전역 플래그가 아니라 컨트롤러 자신이 안다."""
    history = InMemoryJobHistory()
    service = _service(history)

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    (entry,) = history.recent()
    assert entry.execution_mode is ExecutionMode.MOCK


def test_controller_that_declares_nothing_is_unknown():
    """모르면 모른다고 한다. 기본값을 real이나 mock으로 두면 그 순간
    통계가 조용히 한쪽으로 기운다."""
    history = InMemoryJobHistory()
    node = _SilentNode()
    service = _service(history, nodes=_registry_with("microwave", node))

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    (entry,) = history.recent()
    assert entry.execution_mode is ExecutionMode.UNKNOWN


def test_two_appliances_two_modes_in_one_server():
    """한 서버가 실제 노드와 mock 로컬을 동시에 쓰는 상황 — 실기기 통합
    기간의 실제 모습이다. 이력이 둘을 섞으면 그 기간 데이터가 통째로
    쓸모없어진다."""
    from rpi.services.appliance_registry import ApplianceButtonDef, ApplianceDef

    history = InMemoryJobHistory()
    node = _Node(ExecutionMode.REAL)
    appliances = ApplianceRegistry()
    appliances.register(
        ApplianceDef(
            appliance_id="aircon",
            name="에어컨",
            rows=1,
            cols=1,
            buttons=(ApplianceButtonDef("AC-01", "전원", 0, 0),),
            is_custom=True,
        )
    )
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _local_mock(),
        clock=FixedClock(_NOW),
        history_store=history,
        node_registry=_registry_with("aircon", node),
        appliance_registry=appliances,
    )

    service.execute_purpose("우유 데워줘", appliance_id="microwave")  # 로컬 mock
    service.execute_buttons(("전원",), appliance_id="aircon")  # 원격 real

    modes = {
        e.appliance_id: e.execution_mode for e in history.recent()
    }
    assert modes == {
        "microwave": ExecutionMode.MOCK,
        "aircon": ExecutionMode.REAL,
    }


def test_async_job_path_records_the_target_mode_too():
    """비동기 job은 실행이 별도 스레드로 넘어간다 — 그 사이 대상이 바뀌지
    않는지까지 확인한다."""
    from time import sleep

    history = InMemoryJobHistory()
    node = _Node(ExecutionMode.REAL)
    service = _service(history, nodes=_registry_with("microwave", node))

    service.submit_purpose("우유 데워줘", appliance_id="microwave")
    for _ in range(200):
        if history.recent():
            break
        sleep(0.01)

    (entry,) = history.recent()
    assert entry.execution_mode is ExecutionMode.REAL


# ── HTTP까지 이어지는지 ───────────────────────────────────────────────────


def test_csv_export_reflects_the_target_mode(tmp_path):
    """CSV는 실험의 최종 산출물이다. 여기까지 와서 틀리면 그 기간 데이터를
    다시 만들 방법이 없다."""
    from rpi.services.history import history_csv

    history = InMemoryJobHistory()
    node = _Node(ExecutionMode.REAL)
    service = _service(history, nodes=_registry_with("microwave", node))

    service.execute_purpose("우유 데워줘", appliance_id="microwave")

    line = history_csv(history.recent()).splitlines()[1]
    assert ",real," in line
    assert ",mock," not in line
