"""누름 장치 세트의 정체(``kit_id``)와 지금 상태 보고.

세트는 RPi4 실행기 + 모션 ESP32 + 콘센트 ESP32를 묶은 한 제품이고, 허브는 이 ``kit_id``로 어느 가전에 연결했는지 기억한다.
그래서 ``kit_id``는 실행기를 다시 시작해도 같아야 한다 — 데이터 폴더(컨테이너의 ``/data``, 재시작·이미지 교체에도 남는다)에
한 번 만들어 둔다. ``SIMPLELAY_KIT_ID``가 있으면 그 값을 쓴다.

상태 값은 **보고 시점의 캐시**만 읽는다. 시리얼을 건드리면 링크 수신 루프가 묶여 뒤따르는 abort가 늦어진다.
"""

from __future__ import annotations

import logging
import os
import re
import socket
import uuid
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

KIT_ID_ENV = "SIMPLELAY_KIT_ID"
DATA_DIR_ENV = "SIMPLELAY_ACT_DATA_DIR"
DEFAULT_DATA_DIR = "/data"
KIT_ID_FILE = "kit_id"
#: ``act_info.kit_protocol`` — 허브는 이 값을 본 RPi4에만 ``kit_query``·``press_appliance``를 쓴다.
KIT_PROTOCOL = 1

_KIT_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


def load_kit_id(env: "Mapping[str, str] | None" = None) -> str:
    """이 세트의 ``kit_id``. 파일을 쓸 수 없으면 호스트 이름에서 만든 값으로 돌아간다(새 난수는 재시작마다 세트가 바뀐 것처럼 보인다)."""
    src = os.environ if env is None else env
    override = (src.get(KIT_ID_ENV) or "").strip()
    if override:
        if not _KIT_ID.fullmatch(override):
            raise RuntimeError(f"{KIT_ID_ENV}에는 영문·숫자·-·_ 64자 이내만 쓸 수 있습니다")
        return override
    folder = Path(src.get(DATA_DIR_ENV) or DEFAULT_DATA_DIR)
    path = folder / KIT_ID_FILE
    try:
        saved = path.read_text(encoding="ascii").strip()
        if _KIT_ID.fullmatch(saved):
            return saved
        log.warning("kit id file is malformed — generating a new one")
    except FileNotFoundError:
        pass
    except (OSError, UnicodeError):
        log.exception("kit id file unreadable")
    if folder.is_dir():
        fresh = f"kit-{uuid.uuid4().hex[:12]}"
        temp = path.with_suffix(".tmp")
        try:
            temp.write_text(fresh + "\n", encoding="ascii")
            os.replace(temp, path)
            return fresh
        except OSError:
            log.exception("kit id could not be saved")
    fallback = f"kit-{uuid.uuid5(uuid.NAMESPACE_DNS, socket.gethostname()).hex[:12]}"
    log.warning("kit id is not persisted (%s missing or read-only) — using a host-derived id", folder)
    return fallback


def _motion_present(motion: Any) -> bool:
    """모션 보드가 지금 말이 통하나. 원점 상태는 따로 보고한다(``not_ready_reason``은 원점 전이어도 이유를 돌려준다)."""
    if motion is None:
        return False
    link_reason = getattr(motion, "link_not_ready_reason", None)
    if callable(link_reason) and link_reason() is not None:
        return False
    return getattr(motion, "needs_reconnect", False) is not True


def kit_reporter(kit_id: str, *, motion_kind: str, outlet_kind: str, motion: Any, outlet: Any,
                 estop_ignored: bool) -> "Callable[[], dict]":
    """``act_info``·``kit_status`` 공용 보고 한 장을 만드는 함수."""

    def report() -> dict:
        mock = motion_kind == "mock"  # 모의는 보드가 없는 구성이고 ``motion`` 값이 mock이라고 말한다
        homed = True if mock else getattr(motion, "homed", None)
        ready = getattr(outlet, "not_ready_reason", None)
        return {
            "kit_id": kit_id,
            "kit_protocol": KIT_PROTOCOL,
            "motion": motion_kind,
            "motion_present": mock or _motion_present(motion),
            "motion_homed": homed if isinstance(homed, bool) else None,
            "outlet": outlet_kind,
            "outlet_present": outlet is not None and (not callable(ready) or ready() is None),
            # 버튼을 무시하는 구성은 '걸림 없음'이 안전하다는 뜻이 아니다 — 허브가 그대로 말하게 따로 알린다.
            "estop_button": "none" if outlet is None else ("not_used" if estop_ignored else "in_use"),
        }

    return report
