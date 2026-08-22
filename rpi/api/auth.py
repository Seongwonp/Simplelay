"""고정 API 키 인증 — 시연장 공유 Wi-Fi 방어선.

무인증 상태에서는 같은 Wi-Fi의 누구든 물리 액추에이터를 구동하거나
(POST /execute-buttons) 노드 등록을 바꿔 실행 트래픽을 임의 서버로 돌릴 수
있었다(POST /nodes). ``SIMPLELAY_API_KEY``를 설정하면 라우터 전체가
``X-API-Key`` 헤더를 요구한다.

의도적 예외 두 가지:
- 환경변수 미설정 → 전부 개방 (개발 PC 기본, 기존 동작 불변)
- 루프백(127.0.0.1/::1) 클라이언트 → 면제. 같은 보드에서 도는 키오스크
  (Flutter localhost / Chromium /ui)가 키 배포 없이 동작해야 하고,
  루프백에 도달했다는 것 자체가 이미 보드 접근 권한이 있다는 뜻이다.

/health는 라우터 밖(main.py)이라 키 없이도 응답한다 — 폰 앱이 키 입력 전에
연결 상태를 확인하는 ping 용도.
"""

import hmac
import os

from fastapi import HTTPException, Request

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


def require_api_key(request: Request) -> None:
    expected = os.environ.get("SIMPLELAY_API_KEY", "").strip()
    if not expected:
        return
    client = request.client
    if client is not None and client.host in _LOOPBACK_HOSTS:
        return
    provided = request.headers.get("x-api-key", "")
    if provided and hmac.compare_digest(provided, expected):
        return
    raise HTTPException(status_code=401, detail="invalid or missing API key")
