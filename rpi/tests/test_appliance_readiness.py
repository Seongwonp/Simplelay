"""F1 — 등록됐다는 것과 조작할 수 있다는 것은 다르다.

지금 `NodeRegistry`는 **주소만** 안다. 주소가 등록돼 있으면 `_controller_for`가
그 노드로 라우팅하고, 그걸로 끝이다. 그래서 구조가 사실상 이렇게 읽힌다:

    registered == operable

실기기가 붙는 순간 이 등식이 깨진다. 주소는 맞는데 시리얼선이 안 꽂혀 있고,
전송은 되는데 모터가 홈을 안 잡았고, 모터는 도는데 전류 센서가 아직 기준값을
안 잡았다. 그 상태에서 실행을 받으면 **갠트리가 엉뚱한 좌표를 누른다.**

heartbeat가 온다는 것은 **전송이 살아 있다**는 뜻일 뿐이다. 그걸로 '조작
가능'을 선언하면, 준비 안 된 기기에 물리 조작을 맡기게 된다.

그래서 넷을 따로 본다: transport · motion · sensor · calibration.
사용자에게는 셋으로 줄여 보여준다: 미연결 / 준비 필요 / 조작 가능.
"""

from datetime import datetime, timedelta, timezone

import pytest

from rpi.api import SimpleLayService
from rpi.api.service import ApplianceNotReadyError, UnknownApplianceError
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
from rpi.services.appliance_registry import ApplianceButtonDef, ApplianceDef
from rpi.services.history import InMemoryJobHistory
from rpi.services.readiness import (
    ApplianceReadiness,
    ReadinessCheck,
    ReadinessRegistry,
    ReadinessState,
)
from rpi.verifier import MockVerifier

KST = timezone(timedelta(hours=9))
_NOW = datetime(2026, 9, 9, 19, 0, tzinfo=KST)


class _CountingNode:
    """호출 횟수를 센다 — 거절의 기준은 '컨트롤러 호출 0회'다."""

    execution_mode = ExecutionMode.REAL

    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def execute(self, buttons):
        self.calls.append(tuple(buttons))
        return ExecutionResult(
            ExecutionStatus.SUCCEEDED,
            tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons),
        )


def _fan() -> ApplianceDef:
    return ApplianceDef(
        appliance_id="fan",
        name="선풍기",
        rows=1,
        cols=1,
        buttons=(ApplianceButtonDef("F-01", "전원", 0, 0),),
        is_custom=True,
    )


def _local_mock():
    return ClosedLoopController(
        MockGrblClient(),
        MockVerifier(outcomes=[True] * 20),
        MockAlertSink(),
        MockSafetyController(),
        retry_waiter=MockRetryWaiter(),
    )


def _setup(node=None, readiness=None, clock=None):
    """선풍기가 원격 노드에 등록된 서버."""
    appliances = ApplianceRegistry()
    appliances.register(_fan())
    node = node or _CountingNode()
    nodes = NodeRegistry(controller_factory=lambda _url: node)
    nodes.register("fan", "http://node.local")
    fixed = clock or FixedClock(_NOW)
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _local_mock(),
        clock=fixed,
        history_store=InMemoryJobHistory(),
        appliance_registry=appliances,
        node_registry=nodes,
        # **판정 저장소에도 같은 시계를 준다.** 실제 시계를 쓰면 이 파일의
        # 판정(checked_at = _NOW 고정)이 TTL 10분을 넘겨 만료되고, 테스트가
        # **실행 날짜를 타게 된다** -- 어제는 통과하고 오늘 깨진다.
        readiness_registry=readiness or ReadinessRegistry(clock=fixed),
    )
    return service, node, appliances


def _all_ready(**over) -> ApplianceReadiness:
    checks = {
        ReadinessCheck.TRANSPORT: True,
        ReadinessCheck.MOTION: True,
        ReadinessCheck.SENSOR: True,
        ReadinessCheck.CALIBRATION: True,
    }
    checks.update(over.pop("checks", {}))
    return ApplianceReadiness.of(
        "fan", checks, checked_at=over.pop("checked_at", _NOW), **over
    )


# ── 1. 등록만 됐고 readiness 없음 ─────────────────────────────────────────


def test_registered_without_readiness_is_refused():
    """주소를 적어 넣은 것은 '연결됐다'가 아니다. 아무도 확인한 적이 없다."""
    service, node, _ = _setup()

    with pytest.raises(ApplianceNotReadyError):
        service.execute_buttons(("전원",), appliance_id="fan")

    assert node.calls == [], "거절의 기준 — 컨트롤러를 한 번도 부르지 않는다"


def test_registered_without_readiness_shows_as_disconnected():
    service, _, _ = _setup()

    assert service.readiness_of("fan").state is ReadinessState.DISCONNECTED


# ── 2. heartbeat는 살아 있는데 센서·모션이 아직 ──────────────────────────


@pytest.mark.parametrize("missing", [ReadinessCheck.MOTION, ReadinessCheck.SENSOR])
def test_transport_alone_is_not_operable(missing):
    """heartbeat가 온다는 것은 전송이 살아 있다는 뜻일 뿐이다."""
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    readiness.report(_all_ready(checks={missing: False}))
    service, node, _ = _setup(readiness=readiness)

    with pytest.raises(ApplianceNotReadyError):
        service.execute_buttons(("전원",), appliance_id="fan")

    assert node.calls == []
    # 사용자에게는 '미연결'이 아니라 '준비 필요'다 — 선은 살아 있다
    assert service.readiness_of("fan").state is ReadinessState.NEEDS_SETUP


def test_refusal_carries_the_reason():
    """왜 안 되는지 말하지 않으면 사용자가 할 수 있는 일이 없다."""
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    readiness.report(
        _all_ready(
            checks={ReadinessCheck.CALIBRATION: False},
            reasons={ReadinessCheck.CALIBRATION: "버튼 좌표를 아직 맞추지 않았어요"},
        )
    )
    service, _, _ = _setup(readiness=readiness)

    with pytest.raises(ApplianceNotReadyError) as raised:
        service.execute_buttons(("전원",), appliance_id="fan")

    assert "좌표" in str(raised.value)


# ── 3. 전부 준비되면 그 가전의 노드만 실행 ────────────────────────────────


def test_fully_ready_runs_on_that_node_only():
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    readiness.report(_all_ready())
    service, node, _ = _setup(readiness=readiness)

    service.execute_buttons(("전원",), appliance_id="fan")

    assert node.calls == [("전원",)]
    assert service.readiness_of("fan").state is ReadinessState.OPERABLE


# ── 4. 오래된 확인 / 서버 재시작 ─────────────────────────────────────────


def test_stale_readiness_is_refused():
    """한참 전에 한 번 확인했다는 것은 지금 조작해도 된다는 뜻이 아니다."""
    # 시간을 쥐지 않으면 이 테스트는 실행 시각에 따라 흔들린다.
    readiness = ReadinessRegistry(
        ttl=timedelta(minutes=5), clock=FixedClock(_NOW)
    )
    readiness.report(_all_ready(checked_at=_NOW - timedelta(hours=2)))
    service, node, _ = _setup(readiness=readiness)

    with pytest.raises(ApplianceNotReadyError):
        service.execute_buttons(("전원",), appliance_id="fan")

    assert node.calls == []


def test_readiness_does_not_survive_restart():
    """주소와 보정 프로파일은 남기지만 **살아 있는 준비 상태는 남기지
    않는다.** 재시작 후에도 '조작 가능'이면, 그 사이 선이 빠졌는지 아무도
    확인하지 않은 채로 물리 조작을 받는다."""
    first = ReadinessRegistry(clock=FixedClock(_NOW))
    first.report(_all_ready())
    assert first.get("fan").can_execute

    restarted = ReadinessRegistry(clock=FixedClock(_NOW))  # 새 프로세스
    service, node, _ = _setup(readiness=restarted)

    with pytest.raises(ApplianceNotReadyError):
        service.execute_buttons(("전원",), appliance_id="fan")
    assert node.calls == []


# ── 5. 원격 실행의 실제/모의 모드가 이력에 그대로 ─────────────────────────


def test_ready_remote_execution_records_its_own_mode():
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    readiness.report(_all_ready(calibration_profile_version="fan-cal-3"))
    service, _, _ = _setup(readiness=readiness)

    service.execute_buttons(("전원",), appliance_id="fan")

    (entry,) = service._history_store.recent()
    assert entry.execution_mode is ExecutionMode.REAL
    # 보정 프로파일 버전도 실험 기록에 스냅샷으로 남는다 — 어떤 보정에서
    # 나온 성공률인지 모르면 그 숫자를 나중에 해석할 수 없다.
    assert entry.calibration_profile_version == "fan-cal-3"


# ── 6. 승인과 실행 사이에 가전이 사라진다 ─────────────────────────────────


def test_deleted_appliance_is_refused_not_routed_to_local():
    """readiness가 붙어도 R1의 계약은 그대로다 — 삭제된 가전이 로컬
    컨트롤러로 흘러 전자레인지 갠트리를 움직이면 안 된다."""
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    readiness.report(_all_ready())
    service, node, appliances = _setup(readiness=readiness)

    appliances.delete("fan")

    with pytest.raises(UnknownApplianceError):
        service.execute_buttons(("전원",), appliance_id="fan")
    assert node.calls == []


# ── 노드가 없는 가전(내장)은 종전대로 ────────────────────────────────────


def test_builtin_without_a_node_still_runs_on_the_local_controller():
    """readiness 게이트는 **노드로 라우팅되는 가전**의 계약이다. 노드가
    없는 내장 가전은 예전처럼 로컬 컨트롤러로 간다 — 여기까지 막으면
    하드웨어 없이 도는 개발·데모 경로가 통째로 죽는다."""
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    service, _, _ = _setup(readiness=readiness)

    result = service.execute_purpose("즉석밥 데워줘", appliance_id="microwave")

    assert result.status is ExecutionStatus.SUCCEEDED


# ── 사용자에게 보이는 상태 ────────────────────────────────────────────────


def test_state_names_are_the_three_the_user_sees():
    assert [s.value for s in ReadinessState] == [
        "disconnected",
        "needs_setup",
        "operable",
    ]


def test_unregistered_appliance_is_disconnected_not_operable():
    """노드가 없는 가전의 상태를 물으면 '조작 가능'이라고 하지 않는다 --
    로컬 폴백은 개발 편의지 준비 완료 선언이 아니다."""
    service, _, _ = _setup()

    assert service.readiness_of("microwave").state is ReadinessState.DISCONNECTED


# ── HTTP: 폰과 키오스크가 같은 값을 본다 ─────────────────────────────────


@pytest.fixture()
def client(monkeypatch):
    import rpi.api.deps as deps
    from fastapi.testclient import TestClient
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    caches = (
        deps.get_appliance_registry,
        deps.get_node_registry,
        deps.get_readiness_registry,
        deps.get_service,
    )
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def _register_fan(client):
    client.put(
        "/appliances/fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "F-01", "label": "전원", "x": 0, "y": 0}],
        },
    )
    client.post("/nodes/fan", json={"base_url": "http://node.local"})


def _fan_row(client):
    return next(a for a in client.get("/appliances").json() if a["id"] == "fan")


def test_http_node_registered_but_unverified_is_not_operable(client):
    _register_fan(client)

    row = _fan_row(client)
    assert row["readiness"] == "disconnected"
    assert row["can_execute"] is False
    assert row["readiness_reasons"], "왜 안 되는지 말해야 한다"


def test_http_transport_only_is_needs_setup_not_operable(client):
    """heartbeat만 왔다 — 선은 살아 있지만 맡길 수는 없다."""
    _register_fan(client)
    client.post(
        "/readiness/fan",
        json={"transport": True, "motion": False, "sensor": False,
              "calibration": False},
    )

    row = _fan_row(client)
    assert row["readiness"] == "needs_setup"
    assert row["can_execute"] is False


def test_http_execution_is_refused_until_ready(client):
    _register_fan(client)
    client.post("/readiness/fan", json={"transport": True})

    res = client.post(
        "/execute-buttons", json={"buttons": ["전원"], "appliance_id": "fan"}
    )

    # 412 — 404는 '없는 가전'이고(이건 있다), 409는 이 API에서 '다른 작업
    # 실행 중'이라 "잠시 후 다시"로 안내된다. 여기서 필요한 것은
    # 기다림이 아니라 설치를 마치는 일이다.
    assert res.status_code == 412
    assert "센서" in res.json()["detail"]


def test_http_fully_ready_is_operable_and_executes(client):
    _register_fan(client)
    client.post(
        "/readiness/fan",
        json={
            "transport": True,
            "motion": True,
            "sensor": True,
            "calibration": True,
            "calibration_profile_version": "fan-cal-1",
        },
    )

    row = _fan_row(client)
    assert row["readiness"] == "operable"
    assert row["can_execute"] is True
    assert row["readiness_reasons"] == []


def test_http_builtin_without_a_node_stays_executable(client):
    """노드가 없는 내장 가전까지 막으면 하드웨어 없이 도는 데모가 죽는다."""
    row = next(a for a in client.get("/appliances").json() if a["id"] == "microwave")

    assert row["can_execute"] is True
    res = client.post("/execute", json={"text": "즉석밥 데워줘", "appliance_id": "microwave"})
    assert res.status_code == 200


def test_http_readiness_report_rejects_unknown_appliance(client):
    res = client.post("/readiness/ghost", json={"transport": True})
    assert res.status_code == 404


# ── F1 마감 감사 ───────────────────────────────────────────────────────────
#
# 게이트를 "노드로 라우팅되는 가전"으로만 걸어 두니, **노드가 없는 커스텀
# 가전**이 그 사이로 빠져나갔다. 그건 로컬 폴백으로 가는데, 로컬 컨트롤러는
# 내장 가전(전자레인지) 위에 얹힌 갠트리다 -- R1이 막았던 물리 오라우팅이
# 다른 문으로 되돌아온 것이다.


def _setup_nodeless_custom(local_ids=frozenset()):
    """선풍기가 등록만 돼 있고 노드는 없는 서버."""
    appliances = ApplianceRegistry()
    appliances.register(_fan())
    local = _local_mock()
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        local,
        clock=FixedClock(_NOW),
        history_store=InMemoryJobHistory(),
        appliance_registry=appliances,
        node_registry=NodeRegistry(controller_factory=lambda _u: _CountingNode()),
        readiness_registry=ReadinessRegistry(clock=FixedClock(_NOW)),
        local_appliance_ids=local_ids,
    )
    return service, local


def test_custom_appliance_without_a_node_is_refused_not_run_locally():
    """액추에이터가 없는 가전은 실행할 수 없다.

    로컬 폴백은 '아무 가전이나 여기서 눌러도 된다'는 뜻이 아니다 -- 로컬
    컨트롤러는 전자레인지 위의 갠트리다. 선풍기 시퀀스를 거기서 돌리면
    전자레인지의 엉뚱한 버튼이 눌린다.
    """
    service, local = _setup_nodeless_custom()

    with pytest.raises(ApplianceNotReadyError):
        service.execute_buttons(("전원",), appliance_id="fan")

    assert local._grbl.commands == [], "컨트롤러를 한 번도 부르지 않는다"


def test_builtin_without_a_node_is_still_allowed():
    """내장 가전은 로컬 컨트롤러가 **자기 액추에이터**다."""
    service, local = _setup_nodeless_custom()

    service.execute_purpose("즉석밥 데워줘", appliance_id="microwave")

    assert local._grbl.commands != []


def test_explicit_local_mapping_allows_a_custom_appliance():
    """데모용으로 로컬 갠트리에 물린 커스텀 가전은 **명시적으로** 밝힌다.
    암묵적 폴백과 달리 '이건 의도한 배선'이라고 적어야 통과한다."""
    service, local = _setup_nodeless_custom(local_ids={"fan"})

    service.execute_buttons(("전원",), appliance_id="fan")

    assert local._grbl.commands != []


def test_http_can_execute_uses_the_same_rule(client):
    """화면이 보는 값과 서버가 실제로 거절하는 기준이 어긋나면, 누를 수
    있는데 안 되는 버튼이 생긴다."""
    client.put(
        "/appliances/fan",
        json={
            "name": "선풍기",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "F-01", "label": "전원", "x": 0, "y": 0}],
        },
    )
    # 노드 등록 없음

    row = next(a for a in client.get("/appliances").json() if a["id"] == "fan")
    assert row["can_execute"] is False

    res = client.post(
        "/execute-buttons", json={"buttons": ["전원"], "appliance_id": "fan"}
    )
    assert res.status_code == 412


# ── 보정 버전은 '실행 시작' 시점의 값이어야 한다 ─────────────────────────


def test_calibration_version_is_captured_at_start_not_at_finish():
    """20초짜리 실행 도중 보정 보고가 갱신되면, 끝나고 읽은 값은 그 실행이
    쓴 좌표가 아니다. 그 숫자로 성공률을 해석하면 v1의 결과가 v2의 성적표에
    들어간다 -- 실험 데이터가 조용히 오염된다.
    """
    readiness = ReadinessRegistry(clock=FixedClock(_NOW))
    readiness.report(_all_ready(calibration_profile_version="cal-v1"))

    holder = {}

    class _RebumpsMidRun:
        execution_mode = ExecutionMode.REAL

        def execute(self, buttons):
            # 실행 중에 노드가 새 보정을 보고한다
            readiness.report(_all_ready(calibration_profile_version="cal-v2"))
            return ExecutionResult(
                ExecutionStatus.SUCCEEDED,
                tuple(
                    ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None)
                    for b in buttons
                ),
            )

    appliances = ApplianceRegistry()
    appliances.register(_fan())
    nodes = NodeRegistry(controller_factory=lambda _u: _RebumpsMidRun())
    nodes.register("fan", "http://node.local")
    history = InMemoryJobHistory()
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        _local_mock(),
        clock=FixedClock(_NOW),
        history_store=history,
        appliance_registry=appliances,
        node_registry=nodes,
        readiness_registry=readiness,
    )
    holder["service"] = service

    service.execute_buttons(("전원",), appliance_id="fan")

    (entry,) = history.recent()
    assert entry.calibration_profile_version == "cal-v1"
