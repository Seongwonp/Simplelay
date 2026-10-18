"""가전 하나의 준비 판정(state·can_execute·reasons) — 가전 목록과 ``GET /readiness``가 함께 쓴다.

두 응답이 따로 계산하면 같은 대상이 한쪽에서는 '실행 가능', 다른 쪽에서는 '연결 안 됨'으로 나온다
(2026-10-13: 노드가 끊긴 내장 가전이 ``/readiness``에서 can_execute=true·빈 사유, 비상정지 걸림 사유 누락).
판정 순서는 실행 경로(``SimpleLayService._route_to``·``_require_ready``)와 같다:
ThinQ → 서버 구성 실행기 → 노드 → 로컬 갠트리(걸림 확인) → 작은 팔이 없는 기본 가전 → 누를 장치 없음.
"""

from __future__ import annotations

from rpi.commands import ControlRoute


def readiness_view(a, service, nodes) -> tuple[str, list[str], bool]:
    """``(state, reasons, can_execute)``. service가 없으면(저장 직후 응답 등) 종전처럼 로컬 실행으로 본다."""
    if service is None:
        return "operable", [], True
    if a.control_path is ControlRoute.THINQ:
        r = service.thinq_readiness(a.appliance_id)
        return r.state, list(r.reasons), r.can_execute
    readiness = service.readiness_of(a.appliance_id)
    system_mock = service.system_mock_ready(a.appliance_id)
    if system_mock is True:
        # 서버 구성 **모의** 실행기는 자기 준비를 스스로 선언한다(_require_ready와 같다).
        return "operable", [], True
    has_node = nodes is not None and nodes.get(a.appliance_id) is not None
    if system_mock is False or has_node:
        # 노드(또는 모의가 아닌 서버 구성 실행기)로 가는 실행은 그 노드의 준비 판정만 따른다.
        if readiness is None:
            return "disconnected", [], False
        return readiness.state.value, list(readiness.blocking_reasons), readiness.can_execute
    if service.runs_locally(a.appliance_id):
        blocked = service.estop_block_reason()
        if blocked is not None:
            # 로컬 갠트리(RPi4)가 걸림을 보고했거나 아직 상태를 모른다(평가 C1) — 막고 사유를 그대로 보인다.
            return "needs_setup", [blocked], False
        return "operable", [], True
    if service.gantry_absent(a.appliance_id):
        # 기본 가전인데 작은 팔이 그 위에 없다(갠트리 1대, SIMPLELAY_GANTRY_APPLIANCES — 2026-10-18).
        from rpi.api.service import GANTRY_ABSENT_REASON  # noqa: PLC0415

        return "needs_setup", [GANTRY_ABSENT_REASON], False
    # 노드도 없고 로컬 대상도 아니다 = 누를 액추에이터가 없다.
    if readiness is None:
        return "disconnected", [], False
    return readiness.state.value, list(readiness.blocking_reasons), False
