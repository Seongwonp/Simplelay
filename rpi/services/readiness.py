"""가전이 **조작할 수 있는 상태인가** — 등록됐는가와 다른 질문이다.

`NodeRegistry`는 주소만 안다. 주소가 등록돼 있으면 실행이 그 노드로 가고,
그걸로 끝이었다. 구조가 사실상 ``registered == operable`` 로 읽힌다.

실기기가 붙는 순간 그 등식이 깨진다:

- 주소는 맞는데 시리얼선이 안 꽂혀 있다 (transport)
- 전송은 되는데 모터가 홈을 안 잡았다 (motion)
- 모터는 도는데 전류 센서가 기준값을 아직 안 잡았다 (sensor)
- 다 되는데 이 가전의 버튼 좌표를 아직 안 맞췄다 (calibration)

그 상태에서 실행을 받으면 **갠트리가 엉뚱한 좌표를 누른다.** heartbeat가
온다는 것은 *전송이 살아 있다*는 뜻일 뿐이라, 그걸로 '조작 가능'을 선언하면
준비 안 된 기기에 물리 조작을 맡기게 된다.

그래서 넷을 따로 본다. 사용자에게는 셋으로 줄여 보여준다 —
**미연결 / 준비 필요 / 조작 가능**. 무엇이 안 됐는지는 사유 문장으로.

**영속화 경계**: 주소(NodeRegistry)와 보정 프로파일 버전은 남긴다. 살아
있는 준비 상태는 남기지 않는다 — 재시작 후에도 '조작 가능'이면, 그 사이
선이 빠졌는지 아무도 확인하지 않은 채로 물리 조작을 받게 된다.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Mapping, Protocol


class ReadinessCheck(str, Enum):
    """내부에서 따로 보는 축. 실기기 판정은 하드웨어 도착 후 붙인다."""

    #: 노드와 말이 통하는가 (heartbeat/HTTP 응답). **이것만으로는 부족하다.**
    TRANSPORT = "transport"
    #: 모션이 원점을 잡고 명령을 받을 수 있는가.
    MOTION = "motion"
    #: 눌림을 확인할 센서가 기준값을 잡았는가. 없으면 폐루프가 성립하지 않는다.
    SENSOR = "sensor"
    #: 이 가전의 버튼 좌표를 맞췄는가.
    CALIBRATION = "calibration"


class ReadinessState(str, Enum):
    """사용자에게 보이는 세 상태."""

    #: 말이 안 통한다. 선·전원·주소를 확인할 자리.
    DISCONNECTED = "disconnected"
    #: 연결은 됐는데 아직 맡길 수 없다. 무엇이 남았는지 사유로 말한다.
    NEEDS_SETUP = "needs_setup"
    OPERABLE = "operable"


@dataclass(frozen=True)
class CheckResult:
    ready: bool
    #: 안 된 이유. 사용자에게 그대로 보일 수 있는 문장으로 쓴다.
    reason: str = ""


@dataclass(frozen=True)
class ApplianceReadiness:
    appliance_id: str
    checks: Mapping[ReadinessCheck, CheckResult]
    #: 이 판정을 **언제** 했나. 오래된 판정은 지금의 사실이 아니다.
    checked_at: datetime | None = None
    #: 어떤 보정으로 맞춘 좌표인가. 실험 기록에 스냅샷으로 함께 남긴다 --
    #: 어떤 보정에서 나온 성공률인지 모르면 그 숫자를 해석할 수 없다.
    calibration_profile_version: str | None = None

    @classmethod
    def of(
        cls,
        appliance_id: str,
        ready: Mapping[ReadinessCheck, bool],
        *,
        reasons: Mapping[ReadinessCheck, str] | None = None,
        checked_at: datetime | None = None,
        calibration_profile_version: str | None = None,
    ) -> "ApplianceReadiness":
        reasons = reasons or {}
        return cls(
            appliance_id=appliance_id,
            checks={
                check: CheckResult(
                    ready=ready.get(check, False),
                    reason="" if ready.get(check, False) else reasons.get(check, ""),
                )
                for check in ReadinessCheck
            },
            checked_at=checked_at,
            calibration_profile_version=calibration_profile_version,
        )

    @classmethod
    def unknown(cls, appliance_id: str) -> "ApplianceReadiness":
        """아무도 확인한 적이 없다. 등록만 된 상태가 여기다."""
        return cls.of(appliance_id, {})

    def is_ready(self, check: ReadinessCheck) -> bool:
        result = self.checks.get(check)
        return result is not None and result.ready

    @property
    def can_execute(self) -> bool:
        return all(self.is_ready(check) for check in ReadinessCheck)

    @property
    def state(self) -> ReadinessState:
        if not self.is_ready(ReadinessCheck.TRANSPORT):
            return ReadinessState.DISCONNECTED
        return (
            ReadinessState.OPERABLE
            if self.can_execute
            else ReadinessState.NEEDS_SETUP
        )

    @property
    def blocking_reasons(self) -> tuple[str, ...]:
        """맡길 수 없는 이유들. 사유가 비어 있으면 축 이름을 대신 쓴다 --
        '안 됩니다'만 말하고 끝내지 않기 위해서다."""
        return tuple(
            (self.checks[check].reason or _DEFAULT_REASON[check])
            for check in ReadinessCheck
            if not self.is_ready(check)
        )


_DEFAULT_REASON = {
    ReadinessCheck.TRANSPORT: "기기와 연결되지 않았어요",
    ReadinessCheck.MOTION: "모터가 아직 준비되지 않았어요",
    ReadinessCheck.SENSOR: "눌림을 확인할 센서가 아직 준비되지 않았어요",
    ReadinessCheck.CALIBRATION: "버튼 좌표를 아직 맞추지 않았어요",
}


class ReadinessProbe(Protocol):
    """실제 판정의 자리 — 하드웨어가 오면 여기에 붙인다.

    지금은 구현이 없다. 없는 판정을 흉내내서 '조작 가능'을 만들면 이 모듈이
    존재하는 이유가 사라지므로, 인터페이스와 fake까지만 둔다.
    """

    def probe(self, appliance_id: str, base_url: str) -> ApplianceReadiness: ...


@dataclass
class FakeReadinessProbe:
    """개발·테스트용. 미리 정해둔 답을 돌려준다."""

    answers: dict[str, ApplianceReadiness] = field(default_factory=dict)

    def probe(self, appliance_id: str, base_url: str) -> ApplianceReadiness:
        return self.answers.get(
            appliance_id, ApplianceReadiness.unknown(appliance_id)
        )


class ReadinessRegistry:
    """가전별 준비 상태 — **메모리에만** 산다.

    영속화하지 않는 것이 설계다. 재시작 후에도 '조작 가능'이 남아 있으면,
    그 사이 선이 빠졌는지 아무도 확인하지 않은 채로 물리 조작을 받는다.
    남겨도 되는 것(주소·보정 프로파일 버전)은 각자의 저장소에 있다.
    """

    #: 이보다 오래된 판정은 지금의 사실로 치지 않는다. 실기기 통합 때
    #: 실제 heartbeat 주기를 보고 조정한다.
    DEFAULT_TTL = timedelta(minutes=10)

    def __init__(self, ttl: timedelta | None = None, clock=None) -> None:
        self._ttl = ttl or self.DEFAULT_TTL
        self._clock = clock
        self._lock = threading.Lock()
        self._entries: dict[str, ApplianceReadiness] = {}

    def report(self, readiness: ApplianceReadiness) -> None:
        with self._lock:
            self._entries[readiness.appliance_id] = readiness

    def forget(self, appliance_id: str) -> None:
        """가전이 삭제되거나 주소가 바뀌면 판정도 무효다."""
        with self._lock:
            self._entries.pop(appliance_id, None)

    def get(self, appliance_id: str) -> ApplianceReadiness:
        """확인한 적이 없거나 오래됐으면 **모른다**를 돌려준다."""
        with self._lock:
            entry = self._entries.get(appliance_id)
        if entry is None:
            return ApplianceReadiness.unknown(appliance_id)
        if self._is_stale(entry):
            # 오래된 판정은 지우지 않고 '준비 안 됨'으로만 답한다 --
            # 보정 프로파일 버전 같은 사실은 여전히 쓸모가 있다.
            return ApplianceReadiness(
                appliance_id=entry.appliance_id,
                checks={
                    check: CheckResult(False, "확인한 지 오래돼 다시 확인해야 해요")
                    for check in ReadinessCheck
                },
                checked_at=entry.checked_at,
                calibration_profile_version=entry.calibration_profile_version,
            )
        return entry

    def _is_stale(self, entry: ApplianceReadiness) -> bool:
        if entry.checked_at is None:
            return True
        now = self._clock.now() if self._clock else datetime.now(timezone.utc)
        if entry.checked_at.tzinfo is None:
            return True
        return now - entry.checked_at > self._ttl
