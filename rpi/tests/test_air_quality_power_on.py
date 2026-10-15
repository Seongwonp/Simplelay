"""공기청정기가 꺼져 있어도 센서 값이 오면 '공기가 나빠요' → 켜기 제안(2026-10-15 저녁, 사용자 결정 '가').

실물(10/15 저녁, 읽기 전용 조회): ThinQ 앱의 공기질 센서 설정을 '운전 중에만' → '항상'으로 바꾼 뒤에는 공기청정기가
**꺼져 있어도** ``airQualitySensor``(PM1·PM2·PM10 값·등급, 종합 등급)가 왔다. 꺼진 공기청정기는 전원 밖의 명령을
클라우드가 거절하므로(2304) 꺼져 있을 때의 제안은 **전원 켜기 한 단계**(``set_power POWER_ON``)뿐이다 — 풍량은 바꾸지 않는다.
켜져 있을 때의 강풍 제안(``air_quality_high``)은 그대로다.

- 꺼짐 + 센서 값 + 나쁨 → 시나리오 ``air_quality_power_on`` '공기청정기를 켤까요?' (근거 문장 모양은 강풍 카드와 같다).
- 꺼짐 + 센서 칸 없음 → 값 없음(제안 없음) — 종전과 같다('운전 중에만' 설정).
- 두 카드는 재알림 기억을 함께 쓴다 — 나쁜 공기 한 번에 카드 하나. 켜기를 승인해 켜진 뒤에도 나쁘면 강풍 카드는
  곧바로 뒤따르지 않고 종전 재알림 규칙(좋음·보통을 한 번 본 뒤 + 45분)을 따른다.

전부 **모의**다(모의 클라이언트·저장소 안 모의 클라우드). 실제 공기청정기에서 이 켜기 제안을 띄워 승인한 적은 아직 없다.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from rpi.api import deps
from rpi.services.air_quality import AirQualityMonitor, read_air
from rpi.tests.test_air_quality_suggestion import _bad_state, _Clock, _client, _command, _env, _reset, _wait_done

POWER_SCENARIO = "air_quality_power_on"
HIGH_SCENARIO = "air_quality_high"
POWER_QUESTION = "공기청정기를 켤까요?"
HIGH_QUESTION = "공기청정기를 강풍으로 바꿀까요?"
ALWAYS_ENV = "SIMPLELAY_THINQ_MOCK_AIR_SENSOR_ALWAYS"


@pytest.fixture()
def api(monkeypatch):
    """모의 ThinQ + 센서 '항상'(꺼져 있어도 센서 칸을 싣는다)."""
    _env(monkeypatch, "mock")
    monkeypatch.setenv(ALWAYS_ENV, "1")
    _reset()
    from rpi.main import app

    yield TestClient(app)
    _reset()


def _inject(api, level, **extra):
    res = api.post("/demo/thinq/air-quality", json={"level": level, **extra})
    assert res.status_code == 200, res.text
    return res.json()


def _air_cards(api):
    return [s for s in api.get("/suggestions").json() if s.get("scenario_id") in (POWER_SCENARIO, HIGH_SCENARIO)]


def _commands(card):
    return [(c["target_id"], c["route"], c["action"], c["args"]) for c in card["commands"]]


def _power(api):
    return api.get("/thinq/status/air_purifier").json()["state"]["operation"]["airPurifierOperationMode"]


# ── 판정(단위) ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("level", ["BAD", "VERY_BAD"])
def test_off_with_sensor_values_is_a_reading(level):
    reading = read_air(_bad_state(level, power="POWER_OFF"))
    assert reading is not None and reading.is_bad and reading.power_off
    word = "나쁨" if level == "BAD" else "매우 나쁨"
    assert reading.reason() == f"공기청정기 센서: 초미세먼지 42 · {word}"  # 강풍 카드와 같은 근거 모양


def test_off_without_sensor_block_is_still_no_data():
    assert read_air({"operation": {"airPurifierOperationMode": "POWER_OFF"}, "airFlow": {"windStrength": "AUTO"}}) is None
    assert read_air({"operation": {"airPurifierOperationMode": "POWER_OFF"}, "airQualitySensor": {}}) is None


def test_on_reading_is_not_marked_off():
    assert read_air(_bad_state()).power_off is False


def _recording_monitor(states, clock):
    offers = []

    def offer(reason, *, power_off=False):
        offers.append((reason, power_off))
        return object()

    return AirQualityMonitor(lambda: states[0], offer, monotonic=clock), offers


def test_off_bad_offers_power_on_even_if_the_stored_wind_is_high():
    """꺼져 있으면 풍량 값(마지막 설정)은 '이미 강풍'의 근거가 아니다 — 켜기를 제안한다."""
    states = [_bad_state(power="POWER_OFF", wind="HIGH")]
    monitor, offers = _recording_monitor(states, _Clock())
    assert monitor.check_once() == "offered"
    assert offers == [("공기청정기 센서: 초미세먼지 42 · 나쁨", True)]


def test_off_good_rearms_like_on_good():
    clock = _Clock()
    states = [_bad_state(power="POWER_OFF")]
    monitor, offers = _recording_monitor(states, clock)
    assert monitor.check_once() == "offered"
    states[0] = _bad_state("GOOD", power="POWER_OFF")
    assert monitor.check_once() == "ok"
    assert monitor.armed


def test_power_on_and_high_share_one_rearm_memory():
    """나쁜 공기 한 번에 카드 하나 — 켜기 카드 뒤 켜졌는데도 나쁘면 강풍 카드는 재알림 규칙을 기다린다."""
    clock = _Clock()
    states = [_bad_state(power="POWER_OFF")]
    monitor, offers = _recording_monitor(states, clock)
    assert monitor.check_once() == "offered"
    states[0] = _bad_state()  # 켜졌다, 여전히 나쁨
    assert monitor.check_once() == "waiting_rearm"
    clock.t += 3 * 3600
    assert monitor.check_once() == "waiting_rearm"
    states[0] = _bad_state("NORMAL")
    assert monitor.check_once() == "ok"
    states[0] = _bad_state()
    assert monitor.check_once() == "offered"  # 다시 준비 + 45분 지남 → 이제 강풍
    assert [p for _, p in offers] == [True, False]


def test_power_on_card_keeps_the_card_quiet_time():
    clock = _Clock()
    states = [_bad_state(power="POWER_OFF")]
    monitor, offers = _recording_monitor(states, clock)
    assert monitor.check_once() == "offered"
    states[0] = _bad_state("GOOD", power="POWER_OFF")
    assert monitor.check_once() == "ok"
    states[0] = _bad_state(power="POWER_OFF")
    clock.t += 20 * 60
    assert monitor.check_once() == "card_quiet"
    clock.t += 25 * 60
    assert monitor.check_once() == "offered"
    assert len(offers) == 2


# ── 모의 클라이언트·모의 클라우드: 센서 '항상' ───────────────────────────────────────


def test_mock_client_sensor_always_mode():
    from rpi.services.thinq.mock_client import MOCK_PURIFIER_ID, MockThinqClient

    default = MockThinqClient()
    assert "airQualitySensor" not in default.get_status(MOCK_PURIFIER_ID)  # 기본은 예전 설정('운전 중에만')
    always = MockThinqClient(air_sensor_always=True)
    state = always.get_status(MOCK_PURIFIER_ID)
    assert state["operation"]["airPurifierOperationMode"] == "POWER_OFF"
    assert state["airQualitySensor"]["PM2Level"] == "GOOD"
    always.set_air_quality(None)
    assert "airQualitySensor" not in always.get_status(MOCK_PURIFIER_ID)  # 칸 없음은 그대로 없음


@pytest.mark.parametrize(("raw", "expected"), [("1", True), ("true", True), ("on", True), ("yes", True),
                                               ("", False), ("0", False), ("off", False), ("x", False)])
def test_mock_sensor_always_env(raw, expected):
    from rpi.services.thinq.mock_client import air_sensor_always_from_env

    assert air_sensor_always_from_env({ALWAYS_ENV: raw}) is expected
    assert air_sensor_always_from_env({}) is False


def test_hub_mock_client_follows_the_env(api):
    assert _client().air_sensor_always is True


def _fake_state(cloud, device_id):
    from rpi.tools.fake_thinq_cloud import FAKE_CLOUD_TOKEN

    status, body = cloud.handle("GET", f"/devices/{device_id}/state",
                                {"Authorization": f"Bearer {FAKE_CLOUD_TOKEN}"}, None)
    assert status == 200
    return body["response"]


def test_fake_cloud_sensor_follows_power_unless_always():
    from rpi.tools.fake_thinq_cloud import FakeThinqCloud

    cloud = FakeThinqCloud()
    device = cloud.device_id("air_purifier")
    assert "airQualitySensor" not in _fake_state(cloud, device)  # 기본은 꺼짐 + '운전 중에만'
    always = FakeThinqCloud(air_sensor_always=True)
    device = always.device_id("air_purifier")
    assert _fake_state(always, device)["airQualitySensor"]["totalPollutionLevel"] == "GOOD"


# ── 서버 경로(mock, 센서 '항상') ────────────────────────────────────────────────


@pytest.mark.parametrize("level", ["BAD", "VERY_BAD"])
def test_off_bad_offers_one_power_on_card(api, level):
    assert _power(api) == "POWER_OFF"
    body = _inject(api, level, pm2=42)
    assert body["check"] == "offered"
    cards = _air_cards(api)
    assert len(cards) == 1
    card = cards[0]
    assert card["scenario_id"] == POWER_SCENARIO
    assert card["purpose"] == POWER_QUESTION
    word = "나쁨" if level == "BAD" else "매우 나쁨"
    assert card["reason"] == f"공기청정기 센서: 초미세먼지 42 · {word} (시연: 모의 센서 값이에요)"
    assert card["is_demo"] is True
    # 정확히 한 단계 — 전원 켜기만(풍량은 바꾸지 않는다).
    assert _commands(card) == [("air_purifier", "thinq", "set_power", {"power": "POWER_ON"})]
    assert card["commands"][0]["summary"] == "공기청정기(모의) 전원 켜기"
    assert card.get("auto_rule_offer") is None
    assert body["suggestion"]["id"] == card["id"]
    names = {s["scenario_id"]: s["name"] for s in api.get("/scenarios").json()}
    assert names[POWER_SCENARIO] == "공기가 나빠요"
    assert _client().controls == []  # 카드는 제안일 뿐


@pytest.mark.parametrize("level", ["GOOD", "NORMAL"])
def test_off_good_offers_nothing(api, level):
    assert _inject(api, level)["check"] == "ok"
    assert _air_cards(api) == []


def test_off_with_sensor_missing_offers_nothing(api):
    assert _inject(api, "NONE")["check"] == "no_data"
    assert _air_cards(api) == []


def test_off_without_always_mode_still_offers_nothing(monkeypatch):
    """예전 설정('운전 중에만') — 꺼져 있으면 센서 칸이 없으니 제안도 없다."""
    _env(monkeypatch, "mock")
    monkeypatch.delenv(ALWAYS_ENV, raising=False)
    _reset()
    from rpi.main import app

    try:
        client = TestClient(app)
        assert _inject(client, "VERY_BAD")["check"] == "no_data"
        assert _air_cards(client) == []
    finally:
        _reset()


def test_approving_power_on_sends_exactly_one_power_step(api):
    _inject(api, "BAD")
    card = _air_cards(api)[0]
    res = api.post(f"/suggestions/{card['id']}/approve")
    assert res.status_code == 200, res.text
    job_id = res.json()["job_id"]
    assert _wait_done(api, job_id)["last_status"] == "succeeded"
    assert _client().controls == [("mock-purifier-01", {"operation": {"airPurifierOperationMode": "POWER_ON"}})]
    run = api.get("/scenarios/last-run").json()["run"]
    assert run["job_id"] == job_id and run["scenario_id"] == POWER_SCENARIO
    assert [(s["action"], s["args"], s["confirmation"], s["execution_mode"]) for s in run["steps"]] == [
        ("set_power", {"power": "POWER_ON"}, "state_confirmed", "mock")]
    assert _power(api) == "POWER_ON"
    assert _air_cards(api) == []
    # 켜졌는데 여전히 나쁨 — 강풍 카드가 곧바로 뒤따르지 않는다(재알림 기억을 함께 쓴다).
    assert _inject(api, "BAD")["check"] == "waiting_rearm"
    assert _air_cards(api) == []


def test_on_bad_still_offers_high_unchanged(api):
    _command(api, "set_power", {"power": "POWER_ON"})
    _client().controls.clear()
    assert _inject(api, "BAD")["check"] == "offered"
    cards = _air_cards(api)
    assert [c["scenario_id"] for c in cards] == [HIGH_SCENARIO]
    assert cards[0]["purpose"] == HIGH_QUESTION
    assert _commands(cards[0]) == [("air_purifier", "thinq", "set_wind_strength", {"wind_strength": "HIGH"})]


def test_on_bad_with_high_wind_offers_nothing(api):
    _command(api, "set_power", {"power": "POWER_ON"})
    _command(api, "set_wind_strength", {"wind_strength": "HIGH"})
    assert _inject(api, "VERY_BAD")["check"] == "already_strong"
    assert _air_cards(api) == []


def test_power_on_card_dedup_and_rearm(api):
    assert _inject(api, "BAD")["check"] == "offered"
    assert _inject(api, "VERY_BAD")["check"] == "waiting_rearm"
    assert len(_air_cards(api)) == 1
    card = _air_cards(api)[0]
    assert api.post(f"/suggestions/{card['id']}/reject").status_code == 200
    assert _inject(api, "BAD")["check"] == "waiting_rearm"
    assert _inject(api, "NORMAL")["check"] == "ok"
    assert _inject(api, "BAD")["check"] == "card_quiet"
    assert _air_cards(api) == []
    body = _inject(api, "BAD", forget_recent=True)
    assert body["check"] == "offered" and body["suggestion"]["purpose"] == POWER_QUESTION


def test_quiet_hours_block_the_power_on_card(api):
    now = time.localtime()
    window = {"enabled": True, "start": f"{(now.tm_hour - 1) % 24:02d}:00", "end": f"{(now.tm_hour + 2) % 24:02d}:00"}
    assert api.put("/quiet-hours", json=window).status_code == 200
    assert _inject(api, "BAD")["check"] == "not_offered"
    assert _air_cards(api) == []
    assert api.put("/quiet-hours", json={"enabled": False}).status_code == 200
    body = _inject(api, "BAD")
    assert body["check"] == "offered" and body["suggestion"]["scenario_id"] == POWER_SCENARIO


def test_pause_blocks_the_power_on_card(api):
    assert api.post("/dnd", json={"duration_minutes": 30}).status_code == 200
    assert _inject(api, "BAD")["check"] == "not_offered"
    assert _air_cards(api) == []


def test_power_on_card_never_offers_auto_allow(api):
    _inject(api, "BAD")
    card = _air_cards(api)[0]
    res = api.post(f"/suggestions/{card['id']}/approve-and-allow", json={"offer_fingerprint": "x"})
    assert res.status_code == 422
    from rpi.routines.wiring import get_auto_rule_engine

    assert get_auto_rule_engine().store.list() == ()
    assert _client().controls == []


def test_power_on_card_is_not_sent_while_estop_latched(api, monkeypatch):
    _inject(api, "BAD")
    card = _air_cards(api)[0]
    monkeypatch.setattr(deps.get_service(), "estop_latched", lambda: True)
    res = api.post(f"/suggestions/{card['id']}/approve", json={})
    assert res.status_code == 412, res.text
    assert "비상 버튼이 눌려" in res.text
    assert _client().controls == []


def test_manual_trigger_cannot_make_a_power_on_card(api):
    assert api.post(f"/demo/scenario/{POWER_SCENARIO}").status_code == 409
    assert _air_cards(api) == []


def test_fake_cloud_off_bad_offers_power_on_with_always(monkeypatch, tmp_path):
    pytest.importorskip("thinqconnect")
    from rpi.tools.fake_thinq_cloud import FakeThinqCloud

    cloud = FakeThinqCloud(air_sensor_always=True)
    cloud.start()
    _env(monkeypatch, "fake_cloud")
    monkeypatch.setenv("SIMPLELAY_THINQ_FAKE_CLOUD_URL", cloud.base_url)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "thinq_client_id"))
    monkeypatch.setenv("SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER", cloud.device_id("air_purifier"))
    monkeypatch.delenv("SIMPLELAY_THINQ_MAX_CALLS_PER_MINUTE", raising=False)
    _reset()
    from rpi.main import app

    try:
        client = TestClient(app)
        body = _inject(client, "BAD")
        assert body["check"] == "offered"
        card = _air_cards(client)[0]
        assert card["scenario_id"] == POWER_SCENARIO
        assert _commands(card) == [("air_purifier", "thinq", "set_power", {"power": "POWER_ON"})]
        res = client.post(f"/suggestions/{card['id']}/approve")
        assert _wait_done(client, res.json()["job_id"], timeout=10)["last_status"] == "succeeded"
        assert [r["body"] for r in cloud.controls()] == [{"operation": {"airPurifierOperationMode": "POWER_ON"}}]
    finally:
        _reset()
        cloud.stop()
