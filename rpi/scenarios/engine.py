"""시나리오 트리거 → 제안. **실행하지 않는다** — 승인 없는 자동 실행은 없다.

근거 규칙(기존 제안과 같다):

- 실제 실행(REAL)이 가열 확인(L3, ``operation_confirmed``)으로 끝났을 때만 일반 제안.
  L1(눌림)·보고만 받은 성공은 가열의 근거가 아니므로 제안하지 않는다. UART 경로에서는
  RPi4가 결과 프레임에 실은 ``execution_mode=real``과 ``operation_confirmed=true``
  (``operation_source=real``)가 이 근거다 -- 모의 전력 판정(``mock``)의 통과는 확인 수준이
  ``reported``로 남아 트리거가 되지 않는다(2026-09-29, G2).
- 모의 실행(MOCK)의 성공은 ``allow_mock_success``인 시나리오에서만, **시연 제안**
  (``is_demo``)으로 만들고 근거 문장에 모의라고 적는다.
- 실행 환경을 모르는(UNKNOWN) 결과는 트리거가 되지 않는다.
- 시나리오 단계로 실행된 결과(``scenario_id`` 있음)는 다시 트리거하지 않는다.
- ThinQ 쪽 준비가 안 됐으면(대상 미등록·오프라인) 카드를 만들지 않는다 -- 승인해도
  412로 막힐 제안을 띄우지 않는다.
"""

from __future__ import annotations

import logging

from rpi.commands import CommandStatus, Confirmation, ControlRoute
from rpi.controller.models import ExecutionMode

from .catalog import ScenarioCatalog, ScenarioDefinition

log = logging.getLogger(__name__)


class ScenarioUnavailableError(RuntimeError):
    """시나리오 대상이 지금 준비되지 않았다(등록·ThinQ 준비)."""


class ScenarioEngine:
    def __init__(self, catalog: ScenarioCatalog, suggestions, service) -> None:
        self._catalog = catalog
        self._suggestions = suggestions
        self._service = service
        suggestions.set_scenario_resolver(catalog.current_commands)

    @property
    def catalog(self) -> ScenarioCatalog:
        return self._catalog

    # ── 트리거 ────────────────────────────────────────────────────────────
    def on_job_finished(self, event) -> None:
        if event.scenario_id is not None or event.route is not ControlRoute.PHYSICAL:
            return
        if event.status != CommandStatus.SUCCEEDED.value:
            return
        for definition in self._catalog.list():
            trigger = definition.trigger
            if trigger.kind != "job_completed" or trigger.appliance_id != event.appliance_id:
                continue
            if (event.execution_mode is ExecutionMode.REAL
                    and event.confirmation is Confirmation.OPERATION_CONFIRMED):
                reason = "전자레인지 가열을 전류로 확인했어요(L3). 조리 냄새를 빨리 빼 볼까요?"
                is_demo = False
            elif event.execution_mode is ExecutionMode.MOCK and trigger.allow_mock_success:
                reason = ("시연: 모의 실행이 성공으로 끝났어요 — 실제 가열을 확인한 것은 "
                          "아니에요")
                is_demo = True
            else:
                continue
            self._offer(definition, reason, is_demo)

    def on_thinq_event(self, record: dict) -> None:
        for definition in self._catalog.list():
            trigger = definition.trigger
            if trigger.kind == "thinq_event" and trigger.event == record.get("event"):
                is_demo = record.get("execution_mode") != "real"
                base = definition.event_reason or f"ThinQ 이벤트 '{record.get('event')}'"
                reason = base + (" (시연: 모의 이벤트예요)" if is_demo else "")
                self._offer(definition, reason, is_demo)

    def on_appliance_done(self, record: dict, *, skip: frozenset = frozenset()) -> list:
        """RPi4 가전 끝 판정(``appliance_done``, 검증한 기록) → ``appliance_done`` 트리거 카드(v4 2026-10-13).

        조리 완료의 근거는 **CT 전력 끝**이다 — 입력에 ``power``가 없으면(종료음만) 카드를 만들지 않는다.
        버튼 누름 완료(``on_job_finished``)는 이 트리거를 깨우지 않는다. ``skip``의 시나리오는 건너뛴다
        (자동 실행 허용 규칙이 이미 맡은 것). 모의·주입 입력이면 시연 카드다."""
        if "power" not in (record.get("inputs") or []):
            return []
        source = record.get("source")
        offered = []
        for definition in self._catalog.list():
            trigger = definition.trigger
            if (trigger.kind != "appliance_done" or definition.scenario_id in skip
                    or trigger.appliance_id != record.get("appliance_id")
                    or trigger.event != record.get("event")):
                continue
            reason = definition.event_reason or f"'{trigger.appliance_id}' 끝을 확인했어요"
            if source == "injected":
                reason += " (시연 주입)"
            elif source != "real":
                reason += " (모의 입력)"
            card = self._offer(definition, reason, source != "real")
            if card is not None:
                offered.append(card)
        return offered

    def trigger_manual(self, scenario_id: str):
        """수동(시연) 트리거. 항상 시연 제안이다."""
        definition = self._catalog.get(scenario_id)
        if definition is None:
            raise KeyError(scenario_id)
        # 부재 중이면 만들지 않는다(G10). 만들어 두면 다음 조회에서 곧바로
        # 철회돼 이벤트에 created → withdrawn 두 줄이 남고, 그 사이 화면에
        # 잠깐 뜬다. 판정은 제안 서비스의 것을 그대로 쓴다 -- 게이트를 켜고
        # 끄는 조건이 두 군데로 갈리면 안 된다.
        absent = getattr(self._suggestions, "presence_absent", None)
        if absent is not None and absent():
            raise ScenarioUnavailableError(
                "지금은 자리에 안 계셔서 제안을 만들지 않았어요"
            )
        return self._offer(definition, definition.manual_reason or "시연 트리거", True,
                           raise_unavailable=True)

    # ── 제안 만들기 ───────────────────────────────────────────────────────
    def _offer(self, definition: ScenarioDefinition, reason: str, is_demo: bool,
               *, raise_unavailable: bool = False):
        try:
            commands = definition.commands()
            problems = self._unavailable(commands)
            if problems:
                if raise_unavailable:
                    raise ScenarioUnavailableError(" · ".join(problems))
                log.info("scenario %s not offered: %s", definition.scenario_id, problems)
                return None
            summaries = tuple(self._service.summary_of(c) for c in commands)
            return self._suggestions.create_scenario_suggestion(
                scenario_id=definition.scenario_id, purpose=definition.question,
                commands=commands, summaries=summaries, reason=reason, is_demo=is_demo,
                valid_minutes=definition.valid_minutes,
            )
        except ScenarioUnavailableError:
            raise
        except Exception:
            log.exception("scenario %s offer failed", definition.scenario_id)
            if raise_unavailable:
                raise
            return None

    def _unavailable(self, commands) -> list[str]:
        problems = []
        registry = self._service._appliance_registry
        for command in commands:
            appliance = registry.get(command.target_id) if registry is not None else None
            if appliance is None:
                problems.append(f"'{command.target_id}' 가전이 등록되지 않았어요")
                continue
            if appliance.control_path is not command.route:
                problems.append(f"'{appliance.name}'의 제어 경로가 달라요")
                continue
            if command.route is ControlRoute.THINQ:
                readiness = self._service.thinq_readiness(command.target_id)
                if not readiness.can_execute:
                    problems.extend(readiness.reasons or ("ThinQ 가전이 준비되지 않았어요",))
        return problems
