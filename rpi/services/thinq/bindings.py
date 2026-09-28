"""ThinQ 가전 등록 정보 — 가전 ID ↔ ThinQ 기기 ID·동작 대응표 (U1-b).

``NodeRegistry``(가전 ID → 노드 주소 → 컨트롤러)를 그대로 쓰지 않는다(§7). ThinQ는
주소가 아니라 **기기 ID + 동작별 프로필 속성**이 필요하다.

동작(capability) 하나 = ``(resource, property)`` 한 칸에 값 하나를 쓰는 일이다.
공식 SDK(pythinqconnect 1.0.14)의 ``async_post_device_control(device_id, payload)``
payload가 ``{resource: {property: value}}`` 모양이라는 가정 위에 있다.

**추측/확인 필요:** 아래 기본 표의 resource·property 이름(camelCase)과 허용값은
SDK 소스의 속성 목록(AirPurifierDevice: ``operation``·``airFlow``·
``airPurifierJobMode``)에서 옮긴 것이다. 실제 보유 모델의 프로필(U0 스파이크,
``async_get_device_profile``)로 확인하기 전에는 사실로 쓰지 않는다. 그래서
대응표를 코드 한가운데가 아니라 등록 정보에 둔다 -- 모델 확인 뒤 표만 바꾼다.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from rpi.commands import Command
from rpi.commands.args import ArgumentError


class CapabilityError(ValueError):
    """이 가전이 지원하지 않는 동작이거나 인자가 허용 범위 밖이다."""


@dataclass(frozen=True)
class ThinqCapability:
    """동작 하나 → 프로필 속성 한 칸.

    ``arg``는 값을 싣는 인자 이름이다(예: ``wind_strength``). 허용값은 명시 목록만 --
    범위 밖 값을 그대로 클라우드에 보내 거절을 받는 것보다 여기서 거절하는 편이
    "보냈는지 모르는" 상태를 만들지 않는다.
    """

    action: str
    resource: str
    property: str
    arg: str
    allowed: tuple[str, ...]
    #: 사용자에게 보일 이름(예: "풍량"). 값별 이름은 ``value_labels``.
    label: str
    value_labels: tuple[tuple[str, str], ...] = ()

    def value_label(self, value: str) -> str:
        return dict(self.value_labels).get(value, value)

    def validate(self, args: dict[str, object]) -> str:
        """인자를 검사하고 보낼 값을 돌려준다."""
        if set(args) != {self.arg}:
            raise CapabilityError(
                f"'{self.action}'에는 인자 '{self.arg}' 하나만 필요해요 (받은 인자: {sorted(args)})"
            )
        value = args[self.arg]
        if not isinstance(value, str) or value not in self.allowed:
            raise CapabilityError(
                f"'{self.label}' 값 {value!r}은 허용 범위 밖이에요 (허용: {', '.join(self.allowed)})"
            )
        return value

    def payload(self, value: str) -> dict:
        return {self.resource: {self.property: value}}


@dataclass(frozen=True)
class ThinqFunction:
    """목적 문장 → 동작 + 인자. 음성·직접 명령을 ThinQ 명령으로 바꾸는 표."""

    purpose: str
    action: str
    args: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class ThinqBinding:
    device_id: str
    #: SDK의 기기 종류 문자열(예: ``DEVICE_AIR_PURIFIER``).
    device_type: str
    capabilities: tuple[ThinqCapability, ...] = ()
    functions: tuple[ThinqFunction, ...] = ()
    #: 읽기만 하는 상태 칸(예: 세탁기 ``runState.currentState``).
    readable: tuple[tuple[str, str], ...] = field(default_factory=tuple)

    @property
    def read_only(self) -> bool:
        return not self.capabilities

    def capability(self, action: str) -> ThinqCapability:
        for cap in self.capabilities:
            if cap.action == action:
                return cap
        raise CapabilityError(f"이 가전은 '{action}' 동작을 지원하지 않아요")

    def command(self, target_id: str, action: str, args: dict[str, object]) -> Command:
        """동작·인자를 검사해 명령을 만든다. 검사를 통과한 명령만 존재한다."""
        cap = self.capability(action)
        cap.validate(dict(args))
        try:
            return Command.thinq(target_id, action, args)
        except (ArgumentError, ValueError) as exc:
            raise CapabilityError(str(exc)) from exc

    def validate_command(self, command: Command) -> ThinqCapability:
        cap = self.capability(command.action)
        cap.validate(command.args_dict())
        return cap

    def command_for_purpose(self, target_id: str, purpose: str) -> Command | None:
        key = purpose.strip()
        for fn in self.functions:
            if fn.purpose == key:
                return self.command(target_id, fn.action, dict(fn.args))
        return None

    def summary(self, name: str, command: Command) -> str:
        """사용자가 볼 한 줄(승인에 묶이는 문장)."""
        cap = self.capability(command.action)
        value = command.args_dict().get(cap.arg)
        return f"{name} {cap.label} {cap.value_label(str(value))}"


# ── 기본 대응표 (추측/확인 필요 — 모델 프로필 확인 전) ───────────────────────

AIR_PURIFIER_DEVICE_TYPE = "DEVICE_AIR_PURIFIER"
WASHER_DEVICE_TYPE = "DEVICE_WASHER"
DEHUMIDIFIER_DEVICE_TYPE = "DEVICE_DEHUMIDIFIER"

AIR_PURIFIER_CAPABILITIES = (
    ThinqCapability(
        action="set_power",
        resource="operation",
        property="airPurifierOperationMode",
        arg="power",
        allowed=("POWER_ON", "POWER_OFF"),
        label="전원",
        value_labels=(("POWER_ON", "켜기"), ("POWER_OFF", "끄기")),
    ),
    ThinqCapability(
        action="set_wind_strength",
        resource="airFlow",
        property="windStrength",
        arg="wind_strength",
        allowed=("LOW", "MID", "HIGH", "AUTO"),
        label="풍량",
        value_labels=(("LOW", "약"), ("MID", "중"), ("HIGH", "강"), ("AUTO", "자동")),
    ),
    ThinqCapability(
        action="set_job_mode",
        resource="airPurifierJobMode",
        property="currentJobMode",
        arg="job_mode",
        allowed=("CLEAN", "SLEEP", "SILENT", "AUTO"),
        label="운전 모드",
        value_labels=(("CLEAN", "청정"), ("SLEEP", "수면"), ("SILENT", "저소음"), ("AUTO", "자동")),
    ),
)

AIR_PURIFIER_FUNCTIONS = (
    ThinqFunction("공기청정기 켜줘", "set_power", (("power", "POWER_ON"),)),
    ThinqFunction("공기청정기 꺼줘", "set_power", (("power", "POWER_OFF"),)),
    ThinqFunction("강풍으로 바꿔줘", "set_wind_strength", (("wind_strength", "HIGH"),)),
    ThinqFunction("약풍으로 바꿔줘", "set_wind_strength", (("wind_strength", "LOW"),)),
    ThinqFunction("자동으로 바꿔줘", "set_wind_strength", (("wind_strength", "AUTO"),)),
)

WASHER_READABLE = (("runState", "currentState"),)

# 제습기(2026-09-30, G3 세탁 완료 시나리오의 대상). 속성 이름은 **추측** — 공기청정기와
# 같은 모양(operation.<기기>OperationMode)으로 두었고, 실물 프로필 확인 전까지 모의 전용이다.
DEHUMIDIFIER_CAPABILITIES = (
    ThinqCapability(
        action="set_power",
        resource="operation",
        property="dehumidifierOperationMode",
        arg="power",
        allowed=("POWER_ON", "POWER_OFF"),
        label="전원",
        value_labels=(("POWER_ON", "켜기"), ("POWER_OFF", "끄기")),
    ),
)

DEHUMIDIFIER_FUNCTIONS = (
    ThinqFunction("제습기 켜줘", "set_power", (("power", "POWER_ON"),)),
    ThinqFunction("제습기 꺼줘", "set_power", (("power", "POWER_OFF"),)),
)


def air_purifier_binding(device_id: str) -> ThinqBinding:
    return ThinqBinding(
        device_id=device_id,
        device_type=AIR_PURIFIER_DEVICE_TYPE,
        capabilities=AIR_PURIFIER_CAPABILITIES,
        functions=AIR_PURIFIER_FUNCTIONS,
        readable=(("operation", "airPurifierOperationMode"), ("airFlow", "windStrength")),
    )


def washer_binding(device_id: str) -> ThinqBinding:
    """세탁기는 **읽기 전용**으로만 둔다 — 원격 시작은 모델·안전 설정에 달려 가정하지 않는다."""
    return ThinqBinding(
        device_id=device_id, device_type=WASHER_DEVICE_TYPE, readable=WASHER_READABLE
    )


def dehumidifier_binding(device_id: str) -> ThinqBinding:
    return ThinqBinding(
        device_id=device_id,
        device_type=DEHUMIDIFIER_DEVICE_TYPE,
        capabilities=DEHUMIDIFIER_CAPABILITIES,
        functions=DEHUMIDIFIER_FUNCTIONS,
        readable=(("operation", "dehumidifierOperationMode"),),
    )
