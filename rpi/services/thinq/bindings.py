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
from functools import lru_cache

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
    #: 사용자에게 보일 이름(예: "바람 세기"). 값별 이름은 ``value_labels``.
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
    #: 결과 문장에 쓸 설정 이름(값 → 이름, 2026-10-14). 없으면 "속성 이름 값 이름"(예: "바람 세기 강", "운전 모드 청정").
    value_phrases: tuple[tuple[str, str], ...] = ()

    def value_label(self, value: str) -> str:
        return dict(self.value_labels).get(value, value)

    def setting_phrase(self, value: str) -> str:
        """결과 문장 속 설정 이름 — 어느 속성의 값인지 분명히("바람 세기 강으로 바꿨어요", "운전 모드 청정으로 …")."""
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

    def command_for_purpose(self, target_id: str, purpose: str, *, names: tuple[str, ...] = ()) -> Command | None:
        """목적 문장 → 명령. 등록된 목적 문장과 **다듬은 키**가 같을 때만(2026-10-19 말 다듬기·같은 뜻 사전).

        음성 인식은 띄어쓰기를 제멋대로 넣고('공기 청정기 켜 줘' — 10/19 실기기) 사람은 '좀'·'해 주세요'·'공청기'처럼
        말한다. 다듬기·별칭 표(`rpi/intent/voice_lexicon.py`)에 있는 차이만 무시하고, 없으면 None(뜻을 짐작하지 않는다).
        부정('켜지 마')·다듬은 결과가 정지어인 말은 일치시키지 않는다. 두 동작이 같은 키가 되면 어느 쪽도 고르지 않는다.
        ``names``: 사용자가 붙인 가전 이름(예: '거실 공기청정기') — 말 앞의 그 이름은 가전 종류 이름으로 본다."""
        fn = self._match_function(purpose, names)
        if fn is None:
            return None
        return self.command(target_id, fn.action, dict(fn.args))

    # ── 말 다듬기 비교(2026-10-19) ─────────────────────────────────────────
    def _device_names(self) -> tuple[str, ...]:
        from rpi.intent.voice_lexicon import DEVICE_NAMES  # noqa: PLC0415

        return DEVICE_NAMES.get(self.device_type, ())

    def _function_keys(self, fn: ThinqFunction) -> tuple[str, ...]:
        """등록 목적 문장 하나의 비교 키들 — 다듬은 문장·사전 별칭, 그리고 각각 앞에 가전 종류 이름을 붙인 꼴."""
        return _function_keys(self.device_type, fn)

    def _utterance_keys(self, purpose: str, names: tuple[str, ...]) -> tuple[str, ...]:
        """말의 비교 키들. 첫째가 대표 키 — 사용자가 붙인 가전 이름으로 시작하면 그 이름을 종류 이름으로 바꾼 꼴이
        대표, 다듬기만 한 꼴·이름을 뺀 꼴이 뒤에 붙는다."""
        from rpi.intent.normalize import normalize_utterance  # noqa: PLC0415

        key = normalize_utterance(purpose)
        if not key:
            return ()
        out = [key]
        device = self._device_names()
        for name in sorted({normalize_utterance(n) for n in names if n}, key=len, reverse=True):
            if name and key.startswith(name) and len(key) > len(name):
                rest = key[len(name):]
                renamed = device[0] + rest if device and not rest.startswith(device[0]) else rest
                out = [renamed, *(v for v in (key, rest) if v != renamed)]
                break
        return tuple(out)

    def _match_function(self, purpose: str, names: tuple[str, ...] = ()) -> ThinqFunction | None:
        from rpi.intent.normalize import refuses_matching  # noqa: PLC0415

        if refuses_matching(purpose):
            return None
        table = _purpose_table(self.device_type, self.functions)
        found = {table[k] for k in self._utterance_keys(purpose, names) if k in table}
        if len(found) != 1 or None in found:
            return None
        return next(iter(found))

    def function_label(self, fn: ThinqFunction, name: str | None = None) -> str:
        """동작 하나를 사람이 볼 이름으로('공기청정기 전원 켜기'·'공기청정기 바람 세기 강')."""
        cap = self.capability(fn.action)
        text = f"{cap.label} {cap.value_label(str(dict(fn.args).get(cap.arg)))}"
        return f"{name} {text}" if name else text

    def choices(self, name: str | None = None) -> tuple[tuple[str, str], ...]:
        """이 가전이 할 수 있는 동작 목록 — (등록 목적 문장, 이름). 못 알아들었을 때 버튼으로 고르게 응답에 싣는다."""
        out = []
        for fn in self.functions:
            try:
                out.append((fn.purpose, self.function_label(fn, name)))
            except CapabilityError:
                continue
        return tuple(out)

    def suggestion_for(self, purpose: str, name: str | None = None,
                       names: tuple[str, ...] = ()) -> tuple[str, str] | None:
        """'혹시 이것인가요?' 후보 하나 — (등록 목적 문장, 이름). **실행하지 않는다.** 일치가 없을 때만 부른다."""
        from rpi.intent.normalize import Candidate, suggest  # noqa: PLC0415

        keys = self._utterance_keys(purpose, names)
        if not keys:
            return None
        candidates = []
        for fn in self.functions:
            try:
                label = self.function_label(fn, name)
            except CapabilityError:
                continue
            candidates.append(Candidate(fn.purpose, label, self._function_keys(fn)))
        hit = suggest(purpose, candidates, utterance_key=keys[0])
        return (hit.purpose, hit.label) if hit is not None else None

    def purpose_for(self, command: Command) -> str | None:
        """명령과 동작·인자가 똑같은 목적 문장(예: "공기청정기 켜줘"). 대응표에 없으면 None(2026-10-16).

        직접 명령(``POST /thinq/command``)을 사용 기록에 남길 때 쓴다 — 목적 문장이 없으면 기록하지 않는다."""
        args = command.args_dict()
        for fn in self.functions:
            if fn.action == command.action and dict(fn.args) == args:
                return fn.purpose
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
        # 10/18 쉬운 말 3차: '풍량' 대신 '바람 세기', 값은 폰·키오스크 버튼과 같은 '약·중·강'(앱 93805fc). 결과 문장은
        # "바람 세기 강으로 바꿨어요"처럼 속성 이름을 붙인다('강풍'·'약풍' 따로 이름을 두지 않는다).
        label="바람 세기",
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


@lru_cache(maxsize=256)
def _function_keys(device_type: str, fn: ThinqFunction) -> tuple[str, ...]:
    """:meth:`ThinqBinding._function_keys` — 표가 바뀌지 않으므로 기기 종류·목적 문장별로 한 번만 만든다."""
    from rpi.intent import voice_lexicon as lex  # noqa: PLC0415
    from rpi.intent.normalize import normalize_utterance  # noqa: PLC0415

    raw = [fn.purpose, *lex.PHRASE_ALIASES.get(device_type, {}).get(fn.purpose, ())]
    for value in lex.SETTING_VALUES.get(device_type, {}).get(fn.purpose, ()):
        raw.extend(value + tail for tail in lex.SETTING_TAILS)
    names = lex.DEVICE_NAMES.get(device_type, ())
    keys: list[str] = []
    for text in raw:
        key = normalize_utterance(text)
        if not key:
            continue
        for variant in (key, *(name + key for name in names if not key.startswith(name))):
            if variant not in keys:
                keys.append(variant)
    return tuple(keys)


@lru_cache(maxsize=64)
def _purpose_table(device_type: str, functions: tuple[ThinqFunction, ...]) -> dict[str, ThinqFunction | None]:
    """비교 키 → 목적. 두 동작이 같은 키가 되면(사전 실수) 그 키는 None — 그 키로는 고르지 않는다."""
    table: dict[str, ThinqFunction | None] = {}
    for fn in functions:
        for key in _function_keys(device_type, fn):
            prev = table.get(key, fn)
            table[key] = fn if prev is not None and (prev.action, prev.args) == (fn.action, fn.args) else None
    return table


def _purpose_key(text: str) -> str:
    """목적 문장 비교 키 — 본체 공통 말 다듬기(`rpi/intent/normalize.py`)와 같다(2026-10-19)."""
    from rpi.intent.normalize import normalize_utterance  # noqa: PLC0415

    return normalize_utterance(text)
