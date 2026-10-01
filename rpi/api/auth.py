"""고정 API 키 인증 — 시연장 공유 Wi-Fi 방어선.

무인증 상태에서는 같은 Wi-Fi의 누구든 물리 액추에이터를 구동하거나
(POST /execute-buttons) 노드 등록을 바꿔 실행 트래픽을 임의 서버로 돌릴 수
있었다(POST /nodes). 서버는 ``0.0.0.0``에 바인딩되므로 **키가 없을 때 열어 두는
기본값은 위험하다**(본선 준비 평가 9/21 P1).

규칙(2026-09-29부터):

- ``SIMPLELAY_API_KEY`` 설정 → 루프백이 아닌 요청은 ``X-API-Key`` 헤더가 맞아야 한다.
- 키 미설정 → **루프백만 허용**. LAN(폰 등) 요청은 401과 함께 무엇을 설정해야
  하는지 알려준다. 예전처럼 전부 열려면 ``SIMPLELAY_ALLOW_UNAUTHENTICATED=1``을
  **명시**해야 하고, 그 경우 기동 로그에 경고를 남긴다(`log_auth_mode`).
- 루프백(127.0.0.0/8·::1) 클라이언트 → 항상 면제. 같은 보드에서 도는 키오스크
  (Chromium /kiosk/·/ui)가 키 배포 없이 동작해야 하고, 루프백에 도달했다는 것
  자체가 이미 보드 접근 권한이 있다는 뜻이다.

/health는 라우터 밖(main.py)이라 키 없이도 응답한다 — 기동 진단용이다.
폰의 조작 가능 연결 확인은 인증이 필요한 /status를 쓴다.
/pair는 짧은 연결 창과 허브 화면 승인을 따로 검사한다.
"""

import hmac
import ipaddress
import logging
import os

from fastapi import HTTPException, Request

log = logging.getLogger(__name__)

API_KEY_ENV = "SIMPLELAY_API_KEY"
ALLOW_UNAUTHENTICATED_ENV = "SIMPLELAY_ALLOW_UNAUTHENTICATED"

#: 키 미설정 상태에서 LAN 요청을 거절할 때의 안내. 폰 앱이 detail을 그대로
#: 보여줄 수 있으므로 무엇을 해야 하는지까지 적는다.
NO_KEY_CONFIGURED_DETAIL = (
    "서버에 API 키(SIMPLELAY_API_KEY)가 설정되지 않아 이 기기(localhost)의 요청만 받아요. "
    "서버에 키를 설정하고 앱 설정에 같은 키를 입력해 주세요. "
    "(개발용으로 전부 열려면 SIMPLELAY_ALLOW_UNAUTHENTICATED=1)"
)
INVALID_KEY_DETAIL = "invalid or missing API key"


def _configured_key() -> str:
    return os.environ.get(API_KEY_ENV, "").strip()


def unauthenticated_allowed() -> bool:
    """키 없이 LAN 요청까지 받도록 **명시적으로** 연 상태인가."""
    return os.environ.get(ALLOW_UNAUTHENTICATED_ENV, "").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def is_loopback_host(host: str | None) -> bool:
    """루프백 주소인가. IPv4-mapped IPv6(::ffff:127.0.0.1)도 루프백으로 본다.

    ``localhost``라는 이름은 소켓 피어 주소로 오지 않지만 종전 동작과 맞춰 둔다.
    IP로 해석되지 않는 값(예: 테스트 클라이언트의 ``testclient``)은 루프백이 아니다.
    """
    if not host:
        return False
    if host == "localhost":
        return True
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    mapped = getattr(addr, "ipv4_mapped", None)
    if mapped is not None:
        addr = mapped
    return addr.is_loopback


def require_api_key(request: Request) -> None:
    client = request.client
    if client is not None and is_loopback_host(client.host):
        return
    expected = _configured_key()
    if not expected:
        if unauthenticated_allowed():
            return
        raise HTTPException(status_code=401, detail=NO_KEY_CONFIGURED_DETAIL)
    provided = request.headers.get("x-api-key", "")
    if provided and hmac.compare_digest(provided, expected):
        return
    raise HTTPException(status_code=401, detail=INVALID_KEY_DETAIL)


def log_auth_mode(logger: logging.Logger | None = None) -> str:
    """기동 시 현재 인증 방식을 로그로 남기고 그 이름을 돌려준다.

    반환값: ``"api_key"`` | ``"unauthenticated"``(명시적 개방, 경고) | ``"loopback_only"``.
    """
    logger = logger or log
    if _configured_key():
        logger.info("API 인증: LAN 요청에 X-API-Key 요구 (루프백 면제)")
        return "api_key"
    if unauthenticated_allowed():
        logger.warning(
            "API 인증 꺼짐: %s=1 — 같은 네트워크의 누구나 실행·설정 API를 호출할 수 "
            "있습니다. 개발 PC에서만 쓰고 시연·실기기에서는 %s를 설정하세요.",
            ALLOW_UNAUTHENTICATED_ENV,
            API_KEY_ENV,
        )
        return "unauthenticated"
    logger.warning(
        "API 인증: %s 미설정 — 이 기기(localhost) 요청만 받습니다. "
        "폰 등 LAN 클라이언트는 401을 받습니다. 키를 설정하세요.",
        API_KEY_ENV,
    )
    return "loopback_only"
