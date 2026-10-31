"""누름 장치 세트 연결 — 어느 세트(``kit_id``)가 어느 가전을 맡았나, 일대일로 기억한다.

세트는 RPi4·모션 ESP32·콘센트 ESP32가 묶인 한 제품이고 한 번에 가전 하나만 맡는다.

- 저장값이 없으면 env(``SIMPLELAY_GANTRY_APPLIANCES``·``SIMPLELAY_LOCAL_APPLIANCES``)가 정한 가전을 그대로 쓴다 — 설치된
  전자레인지는 아무 설정 없이 계속 돈다. 사람이 처음 연결하는 순간부터 저장값만 본다.
- 저장값이 있는데 다른 세트가 답하면 그 세트는 아무 가전도 맡지 않은 것이다(엉뚱한 기계로 저장된 좌표를 누르지 않는다).
  세트 ID를 말하지 않는 옛 RPi4면 마지막 연결을 따른다.
- 새로 연결한 가전은 자리 확인(``verified``)을 마칠 때까지 실행하지 않는다. 세트를 옮겼으니 저장된 좌표를 믿을 근거가 없다.

읽기는 잠금 없이 불변 문서를 본다 — 실행 시작 게이트가 서비스 잠금 안에서 읽으므로, 여기서 DB 쓰기를 기다리면 정지가 묶인다.
"""

from __future__ import annotations

import json
import logging
import threading
from dataclasses import dataclass

log = logging.getLogger(__name__)

SETTING_KEY = "kit_binding"


@dataclass(frozen=True)
class KitBound:
    appliance_id: str | None
    #: 자리 확인을 마쳤나. env로 쓰던 가전은 이미 설치된 것이라 True.
    verified: bool
    #: 사람이 연결한 저장값인가(False면 env 값).
    explicit: bool


class KitBindingStore:
    def __init__(self, db=None, env_ids: tuple[str, ...] = ()) -> None:
        self._db = db
        self._env_ids = tuple(env_ids)
        self._write_lock = threading.Lock()
        self._doc = self._load()

    def _load(self) -> dict | None:
        raw = None
        if self._db is not None:
            raw = self._db.load_setting(SETTING_KEY)
        if raw is None:
            return None
        try:
            doc = json.loads(raw)
            kits = doc["kits"]
            if not isinstance(kits, dict):
                raise TypeError("kits")
            current = doc.get("current")
            return {"kits": {str(k): {"appliance_id": v.get("appliance_id"), "verified": v.get("verified") is True}
                             for k, v in kits.items()},
                    "current": current if isinstance(current, str) else None}
        except (ValueError, KeyError, TypeError, AttributeError):
            # 깨진 기록을 env로 되돌리면 옮겨 둔 세트로 옛 가전을 누를 수 있다 — 아무것도 맡지 않은 상태로 두고 다시 연결하게 한다.
            log.exception("kit binding record is unreadable — no appliance is connected until it is bound again")
            return {"kits": {}, "current": None}

    def _publish(self, doc: dict) -> None:
        if self._db is not None:
            self._db.save_setting(SETTING_KEY, json.dumps(doc, ensure_ascii=False))
        self._doc = doc

    def bound(self, kit_id: str | None) -> KitBound:
        doc = self._doc
        if doc is None:
            return KitBound(self._env_ids[0] if self._env_ids else None, True, False)
        key = kit_id if kit_id is not None else doc.get("current")
        row = doc["kits"].get(key) if key is not None else None
        if row is None:
            return KitBound(None, False, True)
        return KitBound(row["appliance_id"], row["verified"], True)

    def bind(self, kit_id: str, appliance_id: str, *, verified: bool = False) -> None:
        """이 세트를 이 가전에 잇는다. 같은 가전을 맡던 다른 세트 기록은 지운다(일대일)."""
        with self._write_lock:
            old = self._doc or {"kits": {}, "current": None}
            kits = {k: dict(v) for k, v in old["kits"].items() if v["appliance_id"] != appliance_id or k == kit_id}
            kits[kit_id] = {"appliance_id": appliance_id, "verified": verified}
            self._publish({"kits": kits, "current": kit_id})

    def _rewrite(self, appliance_id: str, change: dict) -> None:
        with self._write_lock:
            old = self._doc
            if old is None or not any(v["appliance_id"] == appliance_id for v in old["kits"].values()):
                return
            kits = {k: ({**v, **change} if v["appliance_id"] == appliance_id else dict(v))
                    for k, v in old["kits"].items()}
            self._publish({"kits": kits, "current": old.get("current")})

    def mark_verified(self, appliance_id: str) -> None:
        self._rewrite(appliance_id, {"verified": True})

    def mark_unverified(self, appliance_id: str) -> None:
        """버튼 자리가 바뀌었다 — 지난 자리 확인은 옛 좌표의 것이다."""
        self._rewrite(appliance_id, {"verified": False})

    def forget_appliance(self, appliance_id: str) -> None:
        """가전이 지워졌다. 저장값 없음으로 돌아가면 env의 옛 가전이 되살아나므로 세트는 '비어 있음'으로 남긴다."""
        self._rewrite(appliance_id, {"appliance_id": None, "verified": False})
