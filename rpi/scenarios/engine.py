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

from .catalog import ScenarioCatalog, ScenarioDefinition, same_question

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
                reason = "전자레인지가 돌아가는 것을 확인했어요. 냄새를 빨리 빼 볼까요?"
                is_demo = False
            elif event.execution_mode is ExecutionMode.MOCK and trigger.allow_mock_success:
                reason = "연습 실행이 끝났어요. 실제로 데운 것은 아니에요."
                is_demo = True
            else:
                continue
            self._offer(definition, reason, is_demo)

    def on_thinq_event(self, record: dict) -> None:
        for definition in self._catalog.list():
            trigger = definition.trigger
            if trigger.kind == "thinq_event" and trigger.event == record.get("event"):
                is_demo = record.get("execution_mode") != "real"
                # 이벤트 ID는 화면에 내지 않는다(10/17 쉬운 말).
                base = definition.event_reason or "LG 가전이 알려 왔어요."
                reason = base + (" 연습 알림이에요." if is_demo else "")
                self._offer(definition, reason, is_demo)

    def on_appliance_done(self, record: dict, *, skip: frozenset = frozenset()) -> list:
        """RPi4 가전 끝 판정(``appliance_done``, 검증한 기록) → ``appliance_done`` 트리거 카드(v4 2026-10-13).

        가열 종료의 근거는 **CT 전력 끝**이다(취소·문 열림 종료와 구분하지 못한다 — 문구로 밝힌다) — 입력에 ``power``가 없으면(종료음만) 카드를 만들지 않는다.
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
            # 가전 ID는 화면에 내지 않는다. 출처 표시는 괄호 대신 짧은 한 문장(10/17 쉬운 말).
            reason = definition.event_reason or "가전이 멈춘 것 같아요."
            if source == "injected":
                reason += " 연습으로 넣은 신호예요."
            elif source != "real":
                reason += " 연습 신호예요."
            # 3차 평가 M4: 사용자의 습관은 실제 기록을 센 근거가 있을 때만 말한다. 없으면 제안·감지 근거만.
            approvals = self._approval_count(definition)
            if approvals:
                # 누가 눌렀는지는 모른다(가족·시연자) — 사람을 단정하지 않고 기록 숫자만 말한다(2026-10-16 결함 ④).
                reason += f" 지금까지 {approvals}번 허락받은 제안이에요."
            card = self._offer(definition, reason, source != "real")
            if card is not None:
                offered.append(card)
        return offered

    def on_air_quality(self, appliance_id: str, reason: str, is_demo: bool, *, power_off: bool = False):
        """공기청정기 센서 나쁨 판독(``rpi/services/air_quality.py``) → ``air_quality`` 트리거 카드(2026-10-15).

        근거 문장은 판독이 만든 그대로(가전 등급·값). 판정·재알림은 판독 쪽이 하고, 여기서는 종전 시나리오 카드처럼
        준비 상태를 보고 만든다 — 조용한 시간·잠시 쉬기·다시 받지 않기·부재는 제안 서비스가 막는다. 판독 때 전원 상태로
        카드를 고른다: 켜져 있으면 트리거 이벤트 ``purifier_on``(강풍), 꺼져 있으면 ``purifier_off``(켜기). 만든(또는
        이미 떠 있던) 카드, 막혔으면 None."""
        event = "purifier_off" if power_off else "purifier_on"
        card = None
        for definition in self._catalog.list():
            trigger = definition.trigger
            if (trigger.kind != "air_quality" or trigger.appliance_id != appliance_id
                    or trigger.event != event):
                continue
            card = self._offer(definition, reason, is_demo) or card
        return card

    def _approval_count(self, definition: ScenarioDefinition) -> int:
        """같은 제안(질문 문장)을 승인한 횟수 — 제안 기록(``feedback_events``, 최근 200건)에서 센 그대로. 모르면 0."""
        reader = getattr(self._suggestions, "feedback_events", None)
        if reader is None:
            return 0
        try:
            events = reader(200).get("events", [])
        except Exception:  # noqa: BLE001 -- 근거를 못 읽으면 근거 문장을 붙이지 않는다
            log.exception("suggestion history unreadable")
            return 0
        # 옛 질문 문장으로 남은 승인도 같은 제안으로 센다(10/18 쉬운 말 3차 — 문장을 바꿔도 횟수가 0으로 돌아가지 않게).
        return sum(1 for e in events if same_question(e.get("purpose"), definition.question)
                   and e.get("action") in ("submitted", "execution_returned"))

    def trigger_manual(self, scenario_id: str):
        """수동(시연) 트리거. 항상 시연 제안이다."""
        definition = self._catalog.get(scenario_id)
        if definition is None:
            raise KeyError(scenario_id)
        if definition.trigger.kind == "air_quality":
            # 공기질 카드는 센서 판독으로만 만든다 — 값 없이 '공기가 나빠요'라고 하지 않는다(2026-10-15).
            # 리허설은 모의 센서 값 주입(POST /demo/thinq/air-quality)으로 한다.
            raise ScenarioUnavailableError(
                "공기질 제안은 공기청정기 센서 값으로만 만들어요. 연습은 센서 값 넣기로 해 주세요.")
        # 부재 중이면 만들지 않는다(G10). 만들어 두면 다음 조회에서 곧바로
        # 철회돼 이벤트에 created → withdrawn 두 줄이 남고, 그 사이 화면에
        # 잠깐 뜬다. 판정은 제안 서비스의 것을 그대로 쓴다 -- 게이트를 켜고
        # 끄는 조건이 두 군데로 갈리면 안 된다.
        absent = getattr(self._suggestions, "presence_absent", None)
        if absent is not None and absent():
            raise ScenarioUnavailableError(
                "지금은 자리에 안 계셔서 제안을 만들지 않았어요"
            )
        return self._offer(definition, definition.manual_reason or "연습으로 띄운 제안이에요.", True,
                           raise_unavailable=True)

    # ── 제안 만들기 ───────────────────────────────────────────────────────
    def _offer(self, definition: ScenarioDefinition, reason: str, is_demo: bool,
               *, raise_unavailable: bool = False):
        try:
            commands = definition.commands()
            problems = self._unavailable(commands)
            if problems:
                if raise_unavailable:
                    raise ScenarioUnavailableError(" ".join(problems))
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
                # 가전 ID는 화면에 내지 않는다(10/17 쉬운 말).
                problems.append("필요한 가전이 아직 등록되지 않았어요.")
                continue
            if appliance.control_path is not command.route:
                problems.append(f"'{appliance.name}'은 이 방법으로 움직일 수 없어요.")
                continue
            if command.route is ControlRoute.THINQ:
                readiness = self._service.thinq_readiness(command.target_id)
                if not readiness.can_execute:
                    problems.extend(readiness.reasons or ("LG 가전이 준비되지 않았어요.",))
        return problems
