"""rpi 테스트 공통 설정.

TestClient의 기본 피어 주소는 ``testclient``(루프백 아님)라, API 키 미설정 시
루프백만 허용하는 인증 규칙(rpi/api/auth.py, 2026-09-29)을 그대로 두면 키를
다루지 않는 모든 라우터 테스트가 401을 받는다. 인증과 무관한 테스트는 종전처럼
개방 상태에서 돌도록 **명시적 개방 플래그**를 기본으로 켠다. 인증 규칙 자체는
test_auth.py가 이 플래그를 지우고 검증한다.
"""

import pytest


@pytest.fixture(autouse=True)
def _allow_unauthenticated_api_by_default(monkeypatch):
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
