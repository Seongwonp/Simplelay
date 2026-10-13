"""ThinQ 계정 가전 발견 — 지원 판정과 '사용자가 추가한 가전' 보관 (2026-10-13).

흐름: 계정의 기기 목록(``list_devices``)과 기기마다 프로필(``get_profile``)을 읽어 **발견된 기기**를
만든다. 기기마다 우리 동작 표(``bindings.py``)와 프로필 판정(``profile.py``)으로 지원 여부를 정한다.

| 판정            | 뜻                                                                   | 추가 |
|-----------------|----------------------------------------------------------------------|------|
| ``controllable``| 우리 동작 중 하나 이상을 이 모델 프로필이 쓰기로 허용한다             | 가능 |
| ``status_only`` | 우리가 읽는 상태 칸은 있지만 쓸 수 있는 동작이 없다                   | 불가 |
| ``unsupported`` | 우리가 다루지 않는 종류이거나, 프로필에 우리 속성이 하나도 없다       | 불가 |
| ``unknown``     | 프로필을 읽지 못했다(이유를 함께 싣는다)                              | 불가 |

**추가는 사용자가 누를 때만 한다.** 발견만으로는 아무것도 등록하지 않는다. 추가한 기기는
``ThinqAddedStore``에 남는다(서버 DB 설정 칸, 없으면 메모리). **기기 ID 원문은 이 보관소와
서버 DB에만** 있다 -- 화면·API에는 ID 대신 ``device_key``(SHA-256 앞 16자)를 쓰고, 로그에는 쓰지 않는다.
"""

from __future__ import annotations

import hashlib
import json
import logging
import threading
from collections.abc import Callable
from dataclasses import asdict, dataclass

from .bindings import (
    AIR_PURIFIER_DEVICE_TYPE,
    DEHUMIDIFIER_DEVICE_TYPE,
    WASHER_DEVICE_TYPE,
    ThinqBinding,
    ThinqCapability,
    air_purifier_binding,
    dehumidifier_binding,
    washer_binding,
)
from .profile import DeviceProfile

log = logging.getLogger(__name__)

CONTROLLABLE = "controllable"
STATUS_ONLY = "status_only"
UNSUPPORTED = "unsupported"
UNKNOWN = "unknown"


@dataclass(frozen=True)
class ThinqKind:
    """우리가 다루는 기기 종류 하나."""

    kind: str
    label: str
    binding: Callable[[str], ThinqBinding]


#: SDK 기기 종류 → 우리 종류. 여기 없는 종류는 '지원 안 함'이다(새 종류는 넓히지 않는다).
KINDS: dict[str, ThinqKind] = {
    AIR_PURIFIER_DEVICE_TYPE: ThinqKind("air_purifier", "공기청정기", air_purifier_binding),
    WASHER_DEVICE_TYPE: ThinqKind("washer", "세탁기", washer_binding),
    DEHUMIDIFIER_DEVICE_TYPE: ThinqKind("dehumidifier", "제습기", dehumidifier_binding),
}

#: 지원하지 않는 종류의 보여 주기용 이름(목록에 무엇이 있는지는 알려 준다).
OTHER_LABELS = {
    "DEVICE_REFRIGERATOR": "냉장고",
    "DEVICE_AIR_CONDITIONER": "에어컨",
    "DEVICE_ROBOT_CLEANER": "로봇청소기",
    "DEVICE_DRYER": "건조기",
    "DEVICE_STYLER": "스타일러",
    "DEVICE_DISH_WASHER": "식기세척기",
    "DEVICE_OVEN": "오븐",
    "DEVICE_COOKTOP": "쿡탑",
    "DEVICE_WATER_PURIFIER": "정수기",
    "DEVICE_HUMIDIFIER": "가습기",
    "DEVICE_CEILING_FAN": "선풍기",
}


def device_key(device_id: str) -> str:
    """화면·API에서 쓰는 기기 이름표. 기기 ID 원문을 내보내지 않는다."""
    return hashlib.sha256(device_id.encode("utf-8")).hexdigest()[:16]


def kind_label(device_type: str) -> str:
    kind = KINDS.get(device_type)
    if kind is not None:
        return kind.label
    return OTHER_LABELS.get(device_type, "기타 가전")


def writable_values(profile: DeviceProfile, cap: ThinqCapability) -> list[str]:
    """우리 후보 값 중 이 프로필이 쓰기로 허용하는 것(``ThinqController._resolve``와 같은 판정)."""
    key = profile.resolve_key(cap.resource, cap.keys, location=cap.location)
    if key is None:
        return []
    spec = profile.spec(cap.resource, key, location=cap.location)
    if spec is None or not spec.writable:
        return []
    return [v for v in cap.allowed if spec.accepts(v)]


def _readable(profile: DeviceProfile, resource: str, prop: str) -> bool:
    for location in (None, *profile.locations):
        spec = profile.spec(resource, prop, location=location)
        if spec is not None and spec.readable:
            return True
    return False


@dataclass(frozen=True)
class Support:
    support: str
    reason: str
    actions: tuple[str, ...] = ()


def classify(device_type: str, profile_raw) -> Support:
    """종류와 프로필로 지원 여부를 정한다. 보수적이다(모르면 지원 안 함)."""
    kind = KINDS.get(device_type)
    if kind is None:
        return Support(UNSUPPORTED, "지원하지 않아요 — SimpleLay가 아직 다루지 않는 가전 종류예요")
    profile = DeviceProfile(profile_raw)
    binding = kind.binding("-")
    actions = tuple(cap.label for cap in binding.capabilities if writable_values(profile, cap))
    if actions:
        return Support(CONTROLLABLE, f"제어할 수 있어요 — {' · '.join(actions)}", actions)
    readable = list(binding.readable) + [
        cap.confirm or (cap.resource, cap.property) for cap in binding.capabilities]
    if any(_readable(profile, resource, prop) for resource, prop in readable):
        return Support(STATUS_ONLY,
                       "상태만 볼 수 있어요 — 이 모델 프로필에서 SimpleLay가 바꿀 수 있는 동작이 없어요")
    return Support(UNSUPPORTED, "지원하지 않아요 — 이 모델 프로필에 SimpleLay가 쓰는 속성이 없어요")


# ── 사용자가 추가한 기기 ───────────────────────────────────────────────────


@dataclass(frozen=True)
class AddedDevice:
    device_id: str
    device_type: str
    alias: str = ""
    model_name: str = ""

    @property
    def key(self) -> str:
        return device_key(self.device_id)


class ThinqAddedStore:
    """추가한 기기 목록. ``load``·``save``(JSON 문자열)가 없으면 메모리에만 둔다.

    모드마다 따로 둔다(호출하는 쪽이 설정 칸 이름에 모드를 넣는다) -- 모의 클라우드에서 추가한
    가짜 ID가 real 모드에 섞이지 않게.
    """

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None) -> None:
        self._save = save
        self._lock = threading.Lock()
        self._entries: dict[str, AddedDevice] = {}
        raw = load() if load is not None else None
        if raw:
            try:
                for item in json.loads(raw):
                    entry = AddedDevice(**{k: str(item.get(k) or "") for k in
                                           ("device_id", "device_type", "alias", "model_name")})
                    if entry.device_id:
                        self._entries[entry.device_id] = entry
            except (ValueError, TypeError, AttributeError):
                # 기기 ID가 섞일 수 있어 원문은 남기지 않는다.
                log.warning("ThinQ 추가 가전 기록을 읽지 못해 빈 목록으로 시작해요")
                self._entries = {}

    def entries(self) -> tuple[AddedDevice, ...]:
        with self._lock:
            return tuple(self._entries.values())

    def by_key(self, key: str) -> AddedDevice | None:
        with self._lock:
            return next((e for e in self._entries.values() if e.key == key), None)

    def contains(self, device_id: str) -> bool:
        with self._lock:
            return device_id in self._entries

    def add(self, entry: AddedDevice) -> None:
        with self._lock:
            self._entries[entry.device_id] = entry
            self._persist_locked()

    def remove(self, device_id: str) -> bool:
        with self._lock:
            removed = self._entries.pop(device_id, None) is not None
            if removed:
                self._persist_locked()
            return removed

    def _persist_locked(self) -> None:
        if self._save is not None:
            self._save(json.dumps([asdict(e) for e in self._entries.values()], ensure_ascii=False))
