"""검토 10/19(클라우드) #7 — ``/thinq/power``·``/thinq/air``는 칸마다 그 가전의 실행 환경을 싣는다.

수리 전에는 맨 위에 서버 전체 실행 환경(``real``) 하나만 실어, 실제 모드 안의 연습 세탁기 전원 기억이 연습 값인지 화면이 알 수
없었다. 맨 위 값은 그대로 둔다(옛 화면 호환). 실제 클라우드는 부르지 않는다(저장소 안 모의 클라우드, 연습 세탁기 시험과 같은 방법).
"""

from __future__ import annotations

import pytest

pytest.importorskip("thinqconnect")

from rpi.tests.test_thinq_practice_washer import WASHER, _api, real_cloud  # noqa: E402,F401 -- 고정 장치


def test_power_and_air_entries_carry_per_appliance_execution_mode(real_cloud, monkeypatch):  # noqa: F811
    monkeypatch.setenv("SIMPLELAY_THINQ_PRACTICE_DEVICES", "washer")
    api = _api()
    assert api.get(f"/thinq/status/{WASHER}").status_code == 200
    assert api.get("/thinq/status/air_purifier").status_code == 200
    # 세탁기 대응표에는 전원 칸이 없어 조회로 기억이 생기지 않는다 — 연습 세탁기 전원 기억 한 칸을 직접 둔다.
    from rpi.api.thinq_wiring import get_power_cache

    cache = get_power_cache()
    with cache._lock:
        cache._entries[WASHER] = ("on", cache._monotonic())
        # 모의 클라우드 공기청정기는 센서 값을 주지 않는다 — 공기질 기억도 한 칸씩 둔다(연습·실제 각각).
        for appliance_id in (WASHER, "air_purifier"):
            cache._air[appliance_id] = ({"grade": "GOOD"}, "on", cache._monotonic())

    power = api.get("/thinq/power").json()
    assert power["execution_mode"] == "real"  # 서버 전체 값은 그대로
    by_id = {e["appliance_id"]: e for e in power["appliances"]}
    assert by_id[WASHER]["execution_mode"] == "mock"
    assert by_id["air_purifier"]["execution_mode"] == "real"

    air = api.get("/thinq/air").json()
    air_by_id = {e["appliance_id"]: e for e in air["appliances"]}
    assert air["execution_mode"] == "real"
    assert air_by_id[WASHER]["execution_mode"] == "mock"
    assert air_by_id["air_purifier"]["execution_mode"] == "real"
