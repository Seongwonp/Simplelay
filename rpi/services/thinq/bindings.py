"""ThinQ 가전 등록 정보 — 가전 ID ↔ ThinQ 기기 ID·동작 대응표 (U1-b).

``NodeRegistry``(가전 ID → 노드 주소 → 컨트롤러)를 그대로 쓰지 않는다(§7). ThinQ는
주소가 아니라 **기기 ID + 동작별 프로필 속성**이 필요하다.

동작(capability) 하나 = ``(resource, property)`` 한 칸에 값 하나를 쓰는 일이다.
공식 SDK(pythinqconnect 1.0.14)의 ``async_post_device_control(device_id, payload)``
payload가 ``{resource: {property: value}}`` 모양이라는 가정 위에 있다.

아래 기본 표의 resource·property 이름(camelCase)은 공식 SDK 1.0.14 소스의 프로필
매핑(``AirPurifierProfile``·``DehumidifierProfile``·``WasherSubProfile``)에서 옮겼다(2026-10-13
설치본 확인). 허용값은 **우리가 보낼 수 있는 후보**일 뿐이다 -- 실행 직전에 실제 기기 프로필
(``async_get_device_profile``)을 읽어 그 속성이 있고 쓰기 모드이고 그 값이 쓰기 값 목록에 있을
때만 보낸다(``ThinqController``). 구매 예정 공기청정기(AS186HWWA)의 프로필은 **미확인**이라,
그 모델이 지원하지 않는 동작은 실행 전에 거절된다.
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
    #: 프로필에서 고를 속성 이름 후보(앞이 우선). 비면 ``property`` 하나. SDK
    #: ``_get_preferred_property_key``와 같은 규칙(예: airFlow의 windStrengthDetail → windStrength).
    property_keys: tuple[str, ...] = ()
    #: 위치가 있는 기기(세탁기 ``MAIN``)면 payload에 ``location``을 싣고 상태도 그 위치에서 읽는다.
    location: str | None = None
    #: 확인에 쓸 상태 칸(쓰기 전용 속성일 때). 비면 쓴 칸을 그대로 읽는다.
    confirm: tuple[str, str] | None = None
    #: 값 → 확인으로 칠 상태 값들. 비면 "쓴 값과 같으면 확인".
    confirm_values: tuple[tuple[str, tuple[str, ...]], ...] = ()
    #: 보내기 전에 True여야 하는 상태 칸(세탁기 원격 제어 허용).
    requires_remote: tuple[str, str] | None = None
    #: 결과 문장에 쓸 설정 이름(예: HIGH → "강풍", 2026-10-14). 없으면 "속성 이름 값 이름"(예: "운전 모드 청정").
    value_phrases: tuple[tuple[str, str], ...] = ()

    def value_label(self, value: str) -> str:
        return dict(self.value_labels).get(value, value)

    def setting_phrase(self, value: str) -> str:
        """결과 문장 속 설정 이름 — 어느 속성의 값인지 분명히("강풍으로 바꿨어요", "운전 모드 청정으로 …")."""
        phrase = dict(self.value_phrases).get(value)
        return phrase or f"{self.label} {self.value_label(value)}"

    @property
    def keys(self) -> tuple[str, ...]:
        return self.property_keys or (self.property,)

    def payload_for(self, value, prop: str | None = None) -> dict:
        """보낼 본문. 세탁기는 SDK ``WasherSubDevice``처럼 ``location``을 앞에 싣는다."""
        body = {self.resource: {prop or self.property: value}}
        if self.location is not None:
            return {"location": {"locationName": self.location}, **body}
        return body

    def confirmed_by(self, value, observed) -> bool:
        expected = dict(self.confirm_values).get(value)
        if expected is None:
            return observed == value
        return observed in expected

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
        return self.payload_for(value)


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
        # SDK AirPurifierProfile: windStrengthDetail이 프로필에 있으면 그것을 먼저 쓴다.
        property_keys=("windStrengthDetail", "windStrength"),
        arg="wind_strength",
        allowed=("LOW", "MID", "HIGH", "AUTO"),
        label="풍량",
        value_labels=(("LOW", "약"), ("MID", "중"), ("HIGH", "강"), ("AUTO", "자동")),
        value_phrases=(("LOW", "약풍"), ("HIGH", "강풍")),
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

WASHER_READABLE = (("runState", "currentState"), ("remoteControlEnable", "remoteControlEnabled"))

#: 세탁기 "시작"을 확인으로 칠 운전 상태(**추측** -- 실제 값 목록은 모델 프로필의
#: ``runState.currentState``에서 확인). STOP은 ``PAUSE``가 되면 확인.
WASHER_RUNNING_STATES = ("DETECTING", "RUNNING", "PREWASH", "SOAKING", "RINSING", "SPINNING",
                         "STEAM_SOFTENING", "DISPENSING", "REFRESHING")

# 세탁기 운전(2026-10-13). SDK WasherSubDevice.set_washer_operation_mode와 같은 모양으로
# ``{"location": {"locationName": "MAIN"}, "operation": {"washerOperationMode": 값}}``을 보낸다.
# washerOperationMode는 프로필상 쓰기 전용이라 확인은 runState.currentState로 한다.
# **원격 제어(원격 시작)가 꺼져 있으면 보내지 않는다** -- 세탁기 본체에서 켜야 한다(안전 설정).
# STOP의 실제 동작(일시정지인지)은 실물로 확인 전이다.
WASHER_CAPABILITIES = (
    ThinqCapability(
        action="set_operation",
        resource="operation",
        property="washerOperationMode",
        arg="operation",
        allowed=("START", "STOP"),
        label="운전",
        value_labels=(("START", "시작"), ("STOP", "일시정지")),
        location="MAIN",
        confirm=("runState", "currentState"),
        confirm_values=(("START", WASHER_RUNNING_STATES), ("STOP", ("PAUSE",))),
        requires_remote=("remoteControlEnable", "remoteControlEnabled"),
    ),
)

WASHER_FUNCTIONS = (
    ThinqFunction("세탁 시작해줘", "set_operation", (("operation", "START"),)),
    ThinqFunction("세탁 일시정지해줘", "set_operation", (("operation", "STOP"),)),
)

# 제습기(2026-09-29, G3 세탁 완료 시나리오의 대상). 속성 이름은 **추측** — 공기청정기와
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
    """세탁기 시작·일시정지. 원격 시작 허용·프로필 지원을 실행 직전에 확인한다(가정하지 않는다)."""
    return ThinqBinding(
        device_id=device_id, device_type=WASHER_DEVICE_TYPE, capabilities=WASHER_CAPABILITIES,
        functions=WASHER_FUNCTIONS, readable=WASHER_READABLE,
    )


def dehumidifier_binding(device_id: str) -> ThinqBinding:
    return ThinqBinding(
        device_id=device_id,
        device_type=DEHUMIDIFIER_DEVICE_TYPE,
        capabilities=DEHUMIDIFIER_CAPABILITIES,
        functions=DEHUMIDIFIER_FUNCTIONS,
        readable=(("operation", "dehumidifierOperationMode"),),
    )
