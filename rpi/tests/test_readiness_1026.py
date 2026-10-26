"""시연 전 준비 상태 API — 외부·하드웨어는 모두 가짜 판독이다."""

from rpi.api import readiness_checks
from rpi.tests.test_auto_rules import api  # noqa: F401 -- 공통 격리 fixture


def _fake_checks(monkeypatch):
    monkeypatch.setattr(readiness_checks, "internet_probe", lambda: (True, "인터넷 가짜 정상", None))
    monkeypatch.setattr(readiness_checks, "thinq_check", lambda: (True, "ThinQ 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "actuator_link_check", lambda service: (True, "링크 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "motion_homed_check", lambda service, actuator: (True, "원점 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "camera_check", lambda: (True, "카메라 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "clock_check", lambda remote: (True, "시계 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "daily_cap_check", lambda service: (True, "상한 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "auto_rule_check", lambda: (True, "규칙 가짜 정상"))
    monkeypatch.setattr(readiness_checks, "quiet_check", lambda: (True, "조용한 시간 가짜 정상"))


def test_readiness_returns_all_isolated_checks(api, monkeypatch):
    _fake_checks(monkeypatch)
    response = api.get("/readiness")
    assert response.status_code == 200
    body = response.json()
    assert [item["key"] for item in body] == [
        "internet", "thinq", "actuator_link", "motion_homed", "room_camera",
        "clock", "daily_ask_cap", "auto_rules", "quiet_hours",
    ]
    assert all(set(item) == {"key", "ok", "label", "detail"} and item["ok"] for item in body)


def test_one_readiness_failure_does_not_hide_other_items(api, monkeypatch):
    _fake_checks(monkeypatch)
    monkeypatch.setattr(readiness_checks, "internet_probe", lambda: (False, "연결 안 됨", None))
    monkeypatch.setattr(readiness_checks, "thinq_check", lambda: (_ for _ in ()).throw(RuntimeError("broken")))
    body = api.get("/readiness").json()
    assert len(body) == 9
    assert body[0]["ok"] is False and body[1]["ok"] is False and body[2]["ok"] is True
