"""ThinQ 설정 — 환경 변수로만. PAT는 기록·저장하지 않는다.

- ``SIMPLELAY_THINQ_MODE`` = ``off``(기본) | ``mock`` | ``real``
- ``SIMPLELAY_THINQ_PAT`` — 개인 액세스 토큰. **있는지만** 기억한다.
- ``SIMPLELAY_THINQ_COUNTRY`` — 국가 코드(기본 ``KR``).
- ``SIMPLELAY_THINQ_CONFIRM_SECONDS`` — 상태 확인 대기 상한(기본 3초, **추측** —
  구형 기기는 5분 주기라 상한 안에 못 들어오는 것이 정상일 수 있다).
- ``SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER`` · ``..._WASHER`` · ``..._DEHUMIDIFIER`` —
  real 모드에서 가전 ID에 묶을 ThinQ 기기 ID(없으면 그 가전을 등록하지 않는다).

모르는 모드 값은 조용히 off로 떨어뜨리지 않고 기동 시 실패한다 -- 켰다고 믿는데
꺼져 있는 상태가 시연장에서 가장 찾기 어렵다(``SIMPLELAY_NODE_TRANSPORT``와 같은 원칙).
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum

MODE_ENV = "SIMPLELAY_THINQ_MODE"
PAT_ENV = "SIMPLELAY_THINQ_PAT"
COUNTRY_ENV = "SIMPLELAY_THINQ_COUNTRY"
CONFIRM_ENV = "SIMPLELAY_THINQ_CONFIRM_SECONDS"
DEVICE_ENV_PREFIX = "SIMPLELAY_THINQ_DEVICE_"

DEFAULT_CONFIRM_SECONDS = 3.0


class ThinqMode(str, Enum):
    OFF = "off"
    MOCK = "mock"
    REAL = "real"


@dataclass(frozen=True)
class ThinqConfig:
    mode: ThinqMode = ThinqMode.OFF
    country: str = "KR"
    #: PAT가 설정돼 있는가. **값은 담지 않는다.**
    has_pat: bool = False
    confirm_seconds: float = DEFAULT_CONFIRM_SECONDS
    #: real 모드의 가전 ID → ThinQ 기기 ID.
    device_ids: tuple[tuple[str, str], ...] = ()

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "ThinqConfig":
        env = os.environ if env is None else env
        raw = env.get(MODE_ENV, "off").strip().lower() or "off"
        try:
            mode = ThinqMode(raw)
        except ValueError:
            raise RuntimeError(
                f"{MODE_ENV}는 off, mock, real 중 하나여야 합니다 (받은 값: {raw!r})"
            ) from None
        try:
            confirm = float(env.get(CONFIRM_ENV, "") or DEFAULT_CONFIRM_SECONDS)
        except ValueError:
            confirm = DEFAULT_CONFIRM_SECONDS
        if not 0 < confirm <= 60:
            confirm = DEFAULT_CONFIRM_SECONDS
        devices = tuple(
            (key[len(DEVICE_ENV_PREFIX):].lower(), value.strip())
            for key, value in sorted(env.items())
            if key.startswith(DEVICE_ENV_PREFIX) and value.strip()
        )
        return cls(
            mode=mode,
            country=(env.get(COUNTRY_ENV, "KR").strip().upper() or "KR"),
            has_pat=bool(env.get(PAT_ENV, "").strip()),
            confirm_seconds=confirm,
            device_ids=devices,
        )
