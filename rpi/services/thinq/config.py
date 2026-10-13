"""ThinQ 설정 — 환경 변수·저장소 밖 파일로만. PAT는 기록·저장하지 않는다.

- ``SIMPLELAY_THINQ_MODE`` = ``off``(기본) | ``mock`` | ``fake_cloud`` | ``real``
  - ``mock``: 프로세스 안 모의 클라이언트(SDK 없음).
  - ``fake_cloud``: **공식 SDK**가 저장소 안 모의 ThinQ 클라우드(127.0.0.1)로 요청한다.
    실행 환경은 모의(mock)다. PAT는 쓰지 않는다(모의 클라우드 전용 토큰).
  - ``real``: 공식 SDK → 실제 ThinQ 클라우드. 실제 클라우드 성공 판정은 이 모드에서만 나온다.
- ``SIMPLELAY_THINQ_PAT`` 또는 ``SIMPLELAY_THINQ_PAT_FILE`` — 개인 액세스 토큰(real만).
  파일은 **저장소 밖**이어야 한다(안이면 기동 거절). 설정 객체는 **있는지만** 기억한다.
- ``SIMPLELAY_THINQ_CLIENT_ID`` 또는 ``SIMPLELAY_THINQ_CLIENT_ID_FILE`` — 클라이언트 ID(UUID4).
  ThinQ는 기기(설치)마다 하나를 고정해 쓰라고 한다 -- 파일이 없으면 한 번 만들어 저장하고
  다음부터 같은 값을 쓴다. 기본 파일은 ``~/.simplelay/thinq_client_id``(저장소 밖).
- ``SIMPLELAY_THINQ_COUNTRY`` — 국가 코드(기본 ``KR``).
- ``SIMPLELAY_THINQ_FAKE_CLOUD_URL`` — fake_cloud 모드의 모의 클라우드 주소(127.0.0.1·localhost만).
- ``SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE`` — 우리 쪽 호출 상한(기본 30, **추측** — 클라우드
  한도는 공개 문서에서 확인하지 못했다). 넘으면 보내지 않는다.
- ``SIMPLELAY_THINQ_CONFIRM_SECONDS`` — 상태 확인 대기 상한(기본 3초, **추측** —
  구형 기기는 5분 주기라 상한 안에 못 들어오는 것이 정상일 수 있다).
- ``SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER`` · ``..._WASHER`` · ``..._DEHUMIDIFIER`` —
  real 모드에서 가전 ID에 묶을 ThinQ 기기 ID(없으면 그 가전을 등록하지 않는다).
  실제 기기 ID는 저장소에 적지 않는다.

모르는 모드 값은 조용히 off로 떨어뜨리지 않고 기동 시 실패한다 -- 켰다고 믿는데
꺼져 있는 상태가 시연장에서 가장 찾기 어렵다(``SIMPLELAY_NODE_TRANSPORT``와 같은 원칙).
"""

from __future__ import annotations

import os
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from urllib.parse import urlsplit

MODE_ENV = "SIMPLELAY_THINQ_MODE"
PAT_ENV = "SIMPLELAY_THINQ_PAT"
PAT_FILE_ENV = "SIMPLELAY_THINQ_PAT_FILE"
CLIENT_ID_ENV = "SIMPLELAY_THINQ_CLIENT_ID"
CLIENT_ID_FILE_ENV = "SIMPLELAY_THINQ_CLIENT_ID_FILE"
COUNTRY_ENV = "SIMPLELAY_THINQ_COUNTRY"
CONFIRM_ENV = "SIMPLELAY_THINQ_CONFIRM_SECONDS"
FAKE_CLOUD_URL_ENV = "SIMPLELAY_THINQ_FAKE_CLOUD_URL"
MAX_CALLS_ENV = "SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE"
DEVICE_ENV_PREFIX = "SIMPLELAY_THINQ_DEVICE_"

DEFAULT_CONFIRM_SECONDS = 3.0
DEFAULT_MAX_CALLS_PER_MINUTE = 30
DEFAULT_CLIENT_ID_FILE = Path.home() / ".simplelay" / "thinq_client_id"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")

_REPO_ROOT = Path(__file__).resolve().parents[3]


class ThinqMode(str, Enum):
    OFF = "off"
    MOCK = "mock"
    FAKE_CLOUD = "fake_cloud"
    REAL = "real"

    @property
    def uses_sdk(self) -> bool:
        return self in (ThinqMode.FAKE_CLOUD, ThinqMode.REAL)


def is_loopback_url(url: str) -> bool:
    try:
        parts = urlsplit(url)
        return parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS and parts.port is not None
    except ValueError:
        return False


@dataclass(frozen=True)
class ThinqConfig:
    mode: ThinqMode = ThinqMode.OFF
    country: str = "KR"
    #: PAT가 설정돼 있는가. **값은 담지 않는다.**
    has_pat: bool = False
    confirm_seconds: float = DEFAULT_CONFIRM_SECONDS
    #: real 모드의 가전 ID → ThinQ 기기 ID.
    device_ids: tuple[tuple[str, str], ...] = ()
    fake_cloud_url: str | None = None
    max_calls_per_minute: int = DEFAULT_MAX_CALLS_PER_MINUTE

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "ThinqConfig":
        env = os.environ if env is None else env
        raw = env.get(MODE_ENV, "off").strip().lower() or "off"
        try:
            mode = ThinqMode(raw)
        except ValueError:
            raise RuntimeError(
                f"{MODE_ENV}는 off, mock, fake_cloud, real 중 하나여야 합니다 (받은 값: {raw!r})"
            ) from None
        try:
            confirm = float(env.get(CONFIRM_ENV, "") or DEFAULT_CONFIRM_SECONDS)
        except ValueError:
            confirm = DEFAULT_CONFIRM_SECONDS
        if not 0 < confirm <= 60:
            confirm = DEFAULT_CONFIRM_SECONDS
        try:
            max_calls = int(env.get(MAX_CALLS_ENV, "") or DEFAULT_MAX_CALLS_PER_MINUTE)
        except ValueError:
            max_calls = DEFAULT_MAX_CALLS_PER_MINUTE
        if not 1 <= max_calls <= 600:
            max_calls = DEFAULT_MAX_CALLS_PER_MINUTE
        fake_url = env.get(FAKE_CLOUD_URL_ENV, "").strip() or None
        if mode is ThinqMode.FAKE_CLOUD:
            if fake_url is None:
                raise RuntimeError(f"{MODE_ENV}=fake_cloud에는 {FAKE_CLOUD_URL_ENV}(모의 클라우드 주소)가 필요합니다")
            if not is_loopback_url(fake_url):
                raise RuntimeError(
                    f"{FAKE_CLOUD_URL_ENV}는 http://127.0.0.1:<포트> 같은 이 기기 안 주소만 받습니다")
        elif fake_url is not None and mode is ThinqMode.REAL:
            raise RuntimeError(
                f"{MODE_ENV}=real에서는 {FAKE_CLOUD_URL_ENV}를 쓸 수 없습니다 — 실제 클라우드 판정이 "
                "모의와 섞이지 않게 real은 언제나 실제 클라우드로 갑니다")
        devices = tuple(
            (key[len(DEVICE_ENV_PREFIX):].lower(), value.strip())
            for key, value in sorted(env.items())
            if key.startswith(DEVICE_ENV_PREFIX) and value.strip()
        )
        return cls(
            mode=mode,
            country=(env.get(COUNTRY_ENV, "KR").strip().upper() or "KR"),
            has_pat=bool(env.get(PAT_ENV, "").strip() or env.get(PAT_FILE_ENV, "").strip()),
            confirm_seconds=confirm,
            device_ids=devices,
            fake_cloud_url=fake_url if mode is ThinqMode.FAKE_CLOUD else None,
            max_calls_per_minute=max_calls,
        )


def _outside_repo(path: Path, what: str) -> Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(_REPO_ROOT)
    except ValueError:
        return resolved
    raise RuntimeError(f"{what} 파일은 저장소 밖에 두어야 합니다 — 저장소 안 경로는 거절합니다")


def load_access_token(env: Mapping[str, str] | None = None) -> str | None:
    """PAT를 읽어 **돌려주기만** 한다. 호출한 쪽은 SDK에 넘기고 보관하지 않는다."""
    env = os.environ if env is None else env
    value = env.get(PAT_ENV, "").strip()
    if value:
        return value
    file_value = env.get(PAT_FILE_ENV, "").strip()
    if not file_value:
        return None
    path = _outside_repo(Path(file_value), "PAT")
    try:
        token = path.read_text(encoding="utf-8").strip()
    except OSError:
        raise RuntimeError(f"{PAT_FILE_ENV}에 적은 PAT 파일을 읽지 못했습니다") from None
    return token or None


def load_or_create_client_id(env: Mapping[str, str] | None = None) -> str:
    """설치마다 하나 고정하는 클라이언트 ID. 파일이 없으면 UUID4를 만들어 저장한다."""
    env = os.environ if env is None else env
    fixed = env.get(CLIENT_ID_ENV, "").strip()
    if fixed:
        return _valid_uuid(fixed, CLIENT_ID_ENV)
    path = _outside_repo(Path(env.get(CLIENT_ID_FILE_ENV, "").strip() or DEFAULT_CLIENT_ID_FILE),
                         "클라이언트 ID")
    if path.exists():
        return _valid_uuid(path.read_text(encoding="utf-8").strip(), str(path.name))
    path.parent.mkdir(parents=True, exist_ok=True)
    value = str(uuid.uuid4())
    path.write_text(value + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:  # pragma: no cover -- Windows 등
        pass
    return value


def _valid_uuid(value: str, where: str) -> str:
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise RuntimeError(f"ThinQ 클라이언트 ID({where})가 UUID 형식이 아닙니다") from None
