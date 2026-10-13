"""ThinQ 기기 프로필 판정 — 어떤 속성을 읽고 쓸 수 있고, 쓸 수 있는 값이 무엇인가.

공식 SDK(``thinqconnect`` 1.0.14)의 ``ConnectDeviceProfile`` 규칙을 그대로 옮겼다
(``devices/connect_device.py``: ``_is_readable_property``·``_is_writable_property``·
``check_enum_attribute_writable``·``check_range_attribute_writable``·
``_get_preferred_property_key``). SDK를 import하지 않는 이유는 기본 설치·기본 시험이 SDK
없이 돌아야 하기 때문이다. SDK가 있으면 ``test_thinq_sdk_profile``이 같은 샘플로 두 판정을
대조한다.

프로필 모양(GET ``devices/{id}/profile``의 ``response``)::

    {"property": {<resource>: {<prop>: {"type": "enum", "mode": ["r", "w"],
                                        "value": {"r": [...], "w": [...]}}}}}

세탁기처럼 위치가 있는 기기는 ``property``가 위치별 목록이다(``location.locationName``).

**판정은 보수적이다.** 프로필에 없는 속성, 쓰기 모드가 없는 속성, 값 목록에 없는 값은
모두 "쓸 수 없음"이다. 값 목록을 모르는 형식(string·number 등)도 쓸 수 없음으로 본다 --
모르는 것을 보내 거절받는 것보다 보내기 전에 멈추는 편이 "보냈는지 모름"을 만들지 않는다.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

READ = "r"
WRITE = "w"


@dataclass(frozen=True)
class PropertySpec:
    type: str | None
    readable: bool
    writable: bool
    read_values: Any = None
    write_values: Any = None

    def accepts(self, value: Any) -> bool:
        """이 값을 쓸 수 있는가(SDK ``check_*_attribute_writable``과 같은 판정)."""
        if not self.writable:
            return False
        values = self.write_values
        if self.type == "range":
            if not isinstance(values, dict) or isinstance(value, bool) or not isinstance(value, (int, float)):
                return False
            try:
                v_min, v_max = values["min"], values["max"]
            except KeyError:
                return False
            step = values.get("step", 1) or 1
            excepted = values.get("except", []) or []
            return v_min <= value <= v_max and (value - v_min) % step == 0 and value not in excepted
        if self.type in ("enum", "list", "boolean"):
            return isinstance(values, list) and value in values and (
                self.type != "boolean" or isinstance(value, bool))
        return False

    def as_dict(self) -> dict:
        return {"type": self.type, "readable": self.readable, "writable": self.writable,
                "read_values": self.read_values, "write_values": self.write_values}


def _spec(raw: Any) -> PropertySpec:
    if isinstance(raw, str):
        # SDK: 문자열 속성은 읽기 전용 고정값이다.
        return PropertySpec("string", True, False, [raw], [])
    if not isinstance(raw, dict):
        return PropertySpec(None, True, False)
    mode = raw.get("mode") or []
    readable = READ in mode
    writable = WRITE in mode
    values = raw.get("value") if isinstance(raw.get("value"), dict) else {}
    kind = raw.get("type")
    empty: Any = {} if kind == "range" else []
    return PropertySpec(
        kind, readable, writable,
        values.get(READ, empty) if readable else empty,
        values.get(WRITE, empty) if writable else empty,
    )


class DeviceProfile:
    def __init__(self, raw: Any) -> None:
        self._raw = raw if isinstance(raw, dict) else {}

    @property
    def raw(self) -> dict:
        return self._raw

    def _properties(self, location: str | None) -> dict:
        props = self._raw.get("property")
        if isinstance(props, list):
            if location is None:
                return {}
            for entry in props:
                if isinstance(entry, dict) and _location_name(entry) == location:
                    return entry
            return {}
        return props if isinstance(props, dict) else {}

    @property
    def locations(self) -> tuple[str, ...]:
        props = self._raw.get("property")
        if not isinstance(props, list):
            return ()
        return tuple(name for entry in props if isinstance(entry, dict)
                     and (name := _location_name(entry)))

    def spec(self, resource: str, prop: str, *, location: str | None = None) -> PropertySpec | None:
        section = self._properties(location).get(resource)
        if not isinstance(section, dict) or prop not in section:
            return None
        return _spec(section[prop])

    def resolve_key(self, resource: str, keys: tuple[str, ...], *, location: str | None = None) -> str | None:
        """SDK ``_get_preferred_property_key``처럼 앞의 키부터 있는 것을 고른다(없으면 None)."""
        section = self._properties(location).get(resource)
        if not isinstance(section, dict):
            return None
        return next((k for k in keys if k in section), None)


def _location_name(entry: dict) -> str | None:
    location = entry.get("location")
    if isinstance(location, dict):
        name = location.get("locationName")
        return name if isinstance(name, str) else None
    return None


def read_state(state: Any, resource: str, prop: str, *, location: str | None = None) -> Any:
    """상태(GET ``devices/{id}/state``)에서 값 하나. 세탁기처럼 위치별 목록이면 그 위치를 찾는다."""
    if isinstance(state, list):
        if location is None:
            return None
        state = next((e for e in state if isinstance(e, dict) and _location_name(e) == location), None)
    section = state.get(resource) if isinstance(state, dict) else None
    return section.get(prop) if isinstance(section, dict) else None
