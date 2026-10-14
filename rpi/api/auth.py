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

**루프백 면제의 출처 확인(2026-10-14 보안 1차 점검 MEDIUM).** 루프백이라도 그 보드의 브라우저가 다른 사이트
페이지의 요청(``fetch('http://localhost:8000/stop', {method:'POST'})``)을 보낼 수 있다. 그래서 면제는 다음일 때만 준다:

- ``Origin`` 헤더가 있으면 **설정된 키오스크 출처**(``SIMPLELAY_KIOSK_ORIGINS``, 기본 ``http://localhost:8000``·
  ``http://127.0.0.1:8000``·``http://[::1]:8000``)와 정확히 같아야 한다. 허용 출처를 요청의 ``Host``로 만들지 않는다
  (DNS 재바인딩 페이지는 Host·Origin을 자기 이름으로 맞출 수 있다). ``Origin: null``은 헤더 없음과 다르게 **거절**한다.
- ``Origin``이 없어도 ``Sec-Fetch-Site``가 ``same-origin``·``none``이 아니면(``cross-site``·``same-site``) 거절한다.
  ``same-origin``이면 ``Host``가 설정된 키오스크 주소 중 하나여야 한다(재바인딩된 이름의 같은 출처 GET 막기).
- 둘 다 없으면 브라우저가 아닌 로컬 프로세스(키오스크 네이티브 앱의 Dart HTTP, ``curl`` 진단)로 보고 면제한다.
  **신뢰 경계:** 보드의 루프백에 직접 연결을 여는 프로세스는 이미 그 보드를 실행할 권한이 있다(백엔드 env·DB를 읽을
  수 있는 위치). 최신 브라우저는 다른 출처 요청에 ``Origin``(POST)·``Sec-Fetch-Site``(모든 요청)를 붙이므로 이 경로로
  들어오지 못한다. 이 헤더를 보내지 않는 옛 브라우저는 신뢰 경계 밖이다(키오스크 기기에 쓰지 않는다).

거절은 403이고 컨트롤러에 닿지 않는다. 키오스크(같은 출처 웹 빌드·네이티브 앱)의 정지 요청은 그대로 통과한다.

/health는 라우터 밖(main.py)이라 키 없이도 응답한다 — 생존·버전만(2026-10-14). 준비 상태·잠시 쉬기·조용한 시간은
인증 경로 ``/health/detail``이다.
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
FOREIGN_ORIGIN_DETAIL = "이 기기 화면이 아닌 곳에서 온 요청이라 받지 않았어요."

#: 루프백 면제를 받는 키오스크 출처(쉼표 목록). 요청의 Host로 만들지 않는다.
KIOSK_ORIGINS_ENV = "SIMPLELAY_KIOSK_ORIGINS"
DEFAULT_KIOSK_ORIGINS = ("http://localhost:8000", "http://127.0.0.1:8000", "http://[::1]:8000")
#: 브라우저가 출처를 보증한 값 중 루프백 면제를 받는 것. ``none``은 사용자가 주소창에 친 이동이다.
_TRUSTED_FETCH_SITES = {"same-origin", "none"}


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


def kiosk_origins() -> frozenset[str]:
    raw = os.environ.get(KIOSK_ORIGINS_ENV, "")
    values = [v.strip().rstrip("/").lower() for v in raw.split(",") if v.strip()]
    return frozenset(values or DEFAULT_KIOSK_ORIGINS)


def _host_of(origin: str) -> str:
    return origin.split("://", 1)[-1]


def loopback_origin_problem(request: Request) -> str | None:
    """루프백 요청이 다른 사이트에서 왔다는 표시가 있으면 그 이유, 아니면 None(면제해도 된다)."""
    allowed = kiosk_origins()
    origin = request.headers.get("origin")
    if origin is not None:
        value = origin.strip().rstrip("/").lower()
        if value == "null" or not value:
            return "origin_null"
        if value not in allowed:
            return "origin_not_kiosk"
        return None
    site = (request.headers.get("sec-fetch-site") or "").strip().lower()
    if not site:
        return None  # 브라우저가 아닌 로컬 프로세스(키오스크 네이티브 앱·진단 도구) — 신뢰 경계는 모듈 머리말
    if site not in _TRUSTED_FETCH_SITES:
        return f"fetch_site_{site}"
    host = (request.headers.get("host") or "").strip().lower()
    if site == "same-origin" and host not in {_host_of(o) for o in allowed}:
        return "host_not_kiosk"
    return None


async def require_api_key(request: Request) -> None:
    """``async``인 이유(2026-10-14 HIGH 재확인 2차 H-RR1): 이 검사는 헤더·환경 변수만 보는 메모리 일이다. ``def``면 FastAPI가
    공유 스레드 풀(AnyIO 기본 토큰)에서 돌려, DB를 기다리는 요청이 그 풀을 채운 동안 ``/stop``의 인증부터 줄을 섰다.
    여기에 입출력을 넣지 않는다."""
    client = request.client
    if client is not None and is_loopback_host(client.host):
        problem = loopback_origin_problem(request)
        if problem is not None:
            log.warning("루프백 요청 거절(%s): %s %s", problem, request.method, request.url.path)
            raise HTTPException(status_code=403, detail=FOREIGN_ORIGIN_DETAIL)
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
