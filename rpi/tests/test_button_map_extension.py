"""버튼맵 확장 — 다이얼·누름 시간·mm 좌표·목적별 시퀀스의 계약.

- 확장 필드는 모두 선택이고, 없는 요청·예전 DB 행은 종전대로 동작한다
- 다이얼은 딸깍 수가 있어야 하고, 누름 버튼은 돌릴 수 없다
- 목적별 시퀀스는 **등록 시점에** 이 조작부로 실행 가능한지 검증된다
- 폰 편집기 저장(격자만)이 보정으로 얻은 mm 좌표를 지우지 않는다
- 가전이 정의한 시퀀스는 규칙 해석보다 먼저 쓰이고, 다이얼 단계는 아직 실행하지 않는다
"""

import time

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.api.schemas import MAX_BUTTONS_PER_RUN
from rpi.main import app
from rpi.services.appliance_registry import (
    MAX_FUNCTION_STEPS,
    ApplianceButtonDef,
    ApplianceDef,
    ApplianceRegistry,
    ButtonKind,
    FunctionStep,
    parse_function_step,
    validate_functions,
)
from rpi.services.persistence import SimpleLayDb

FAN_BUTTONS = (
    ApplianceButtonDef("F-01", "전원", 0, 0, press_ms=150),
    ApplianceButtonDef("F-02", "약풍", 1, 0),
    ApplianceButtonDef("F-03", "타이머", 2, 0, kind=ButtonKind.DIAL, detents=8),
)


def _fan(**overrides) -> ApplianceDef:
    base = dict(
        appliance_id="custom_fan",
        name="거실 선풍기",
        rows=2,
        cols=3,
        buttons=FAN_BUTTONS,
        is_custom=True,
        functions=(("선풍기 약하게", ("전원", "약풍")), ("타이머 두 칸", ("타이머:+2",))),
    )
    base.update(overrides)
    return ApplianceDef(**base)


# ── 단계 문법·검증 ────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("시작", FunctionStep("시작")),
        ("1분", FunctionStep("1분")),
        ("출력:+2", FunctionStep("출력", 2)),
        ("출력:-3", FunctionStep("출력", -3)),
        ("시간 90초", FunctionStep("시간 90초")),
    ],
)
def test_function_step_syntax(raw, expected) -> None:
    assert parse_function_step(raw) == expected


def test_function_steps_limit_matches_execution_limit() -> None:
    assert MAX_FUNCTION_STEPS == MAX_BUTTONS_PER_RUN


@pytest.mark.parametrize(
    ("functions", "message"),
    [
        ({"x": ["없는버튼"]}, "unknown button"),
        ({"x": ["타이머"]}, "is a dial"),
        ({"x": ["약풍:+1"]}, "cannot be turned"),
        ({"x": ["타이머:+9"]}, "outside"),
        ({"x": ["타이머:+0"]}, "outside"),
        ({"x": []}, "no steps"),
        ({"  ": ["전원"]}, "blank"),
        ({"x": ["전원"] * (MAX_FUNCTION_STEPS + 1)}, "limit"),
    ],
)
def test_invalid_functions_are_rejected(functions, message) -> None:
    with pytest.raises(ValueError, match=message):
        validate_functions(FAN_BUTTONS, functions)


def test_unknown_button_kind_is_rejected_not_guessed() -> None:
    with pytest.raises(ValueError):
        ButtonKind.parse("slider")
    assert ButtonKind.parse(None) is ButtonKind.BUTTON


# ── 영속화 ────────────────────────────────────────────────────────────────


def test_extended_definition_survives_restart(tmp_path) -> None:
    path = str(tmp_path / "ext.db")
    calibrated = _fan(
        buttons=(
            ApplianceButtonDef("F-01", "전원", 0, 0, press_ms=150, x_mm=12.5, y_mm=30.0),
            *FAN_BUTTONS[1:],
        ),
        calibration_version="abc123def456",
    )
    ApplianceRegistry(store=SimpleLayDb(path)).register(calibrated)

    reloaded = ApplianceRegistry(store=SimpleLayDb(path)).get("custom_fan")

    assert reloaded.buttons[0].x_mm == 12.5 and reloaded.buttons[0].press_ms == 150
    assert reloaded.buttons[2].kind is ButtonKind.DIAL and reloaded.buttons[2].detents == 8
    assert reloaded.functions == calibrated.functions
    assert reloaded.calibration_version == "abc123def456"


def test_plain_definition_still_loads_with_defaults(tmp_path) -> None:
    path = str(tmp_path / "plain.db")
    plain = ApplianceDef(
        "custom_plain", "선풍기", 1, 1, (ApplianceButtonDef("P-1", "전원", 0, 0),), is_custom=True
    )
    ApplianceRegistry(store=SimpleLayDb(path)).register(plain)

    reloaded = ApplianceRegistry(store=SimpleLayDb(path)).get("custom_plain")

    button = reloaded.buttons[0]
    assert button.kind is ButtonKind.BUTTON
    assert (button.detents, button.press_ms, button.x_mm, button.y_mm) == (None,) * 4
    assert reloaded.functions == () and reloaded.calibration_version is None


# ── 보정 좌표 보존 ────────────────────────────────────────────────────────


def _calibrated_fan() -> ApplianceDef:
    return _fan(
        buttons=(
            ApplianceButtonDef("F-01", "전원", 0, 0, x_mm=10.0, y_mm=20.0),
            ApplianceButtonDef("F-02", "약풍", 1, 0, x_mm=40.0, y_mm=20.0),
            FAN_BUTTONS[2],
        ),
        calibration_version="v-cal-1",
    )


def test_grid_only_save_keeps_calibrated_mm() -> None:
    registry = ApplianceRegistry()
    registry.register(_calibrated_fan())

    saved = registry.register(_fan(name="안방 선풍기"))  # 폰 편집기: 격자만

    assert [(b.x_mm, b.y_mm) for b in saved.buttons[:2]] == [(10.0, 20.0), (40.0, 20.0)]
    assert saved.calibration_version == "v-cal-1"


def test_moved_button_loses_mm_and_invalidates_version() -> None:
    registry = ApplianceRegistry()
    registry.register(_calibrated_fan())
    moved = _fan(
        buttons=(
            ApplianceButtonDef("F-01", "전원", 0, 1),  # 칸을 옮겼다
            ApplianceButtonDef("F-02", "약풍", 1, 0),
            FAN_BUTTONS[2],
        )
    )

    saved = registry.register(moved)

    assert saved.buttons[0].x_mm is None  # 옛 좌표로 누르면 엉뚱한 곳이다
    assert saved.buttons[1].x_mm == 40.0
    assert saved.calibration_version is None


def test_explicit_mm_in_request_wins() -> None:
    registry = ApplianceRegistry()
    registry.register(_calibrated_fan())
    taught = _fan(
        buttons=(
            ApplianceButtonDef("F-01", "전원", 0, 0, x_mm=11.0, y_mm=21.0),
            ApplianceButtonDef("F-02", "약풍", 1, 0),
            FAN_BUTTONS[2],
        )
    )

    saved = registry.register(taught)

    assert (saved.buttons[0].x_mm, saved.buttons[0].y_mm) == (11.0, 21.0)


# ── API ───────────────────────────────────────────────────────────────────

FAN_JSON = {
    "name": "거실 선풍기",
    "category": "other",
    "rows": 2,
    "cols": 3,
    "buttons": [
        {"id": "F-01", "label": "전원", "x": 0, "y": 0, "press_ms": 150},
        {"id": "F-02", "label": "약풍", "x": 1, "y": 0},
        {"id": "F-03", "label": "타이머", "x": 2, "y": 0, "kind": "dial", "detents": 8},
    ],
    "functions": {"선풍기 약하게": ["전원", "약풍"], "타이머 두 칸": ["타이머:+2"]},
}


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    # 노드 없는 커스텀 가전을 로컬 모의 갠트리로 실행하도록 명시한다.
    monkeypatch.setenv("SIMPLELAY_LOCAL_APPLIANCES", "custom_fan")
    caches = (deps.get_appliance_registry, deps.get_service, deps.get_readiness_registry)
    for dep in caches:
        dep.cache_clear()
    yield TestClient(app)
    for dep in caches:
        dep.cache_clear()


def _wait_done(client, job_id, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = client.get("/status").json()
        if not body["running"] and body["last_job_id"] == job_id:
            return body
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def test_put_and_get_expose_extended_fields(client) -> None:
    res = client.put("/appliances/custom_fan", json=FAN_JSON)
    assert res.status_code == 200, res.text
    body = res.json()
    dial = next(b for b in body["buttons"] if b["id"] == "F-03")
    assert dial["kind"] == "dial" and dial["detents"] == 8
    assert body["buttons"][0]["press_ms"] == 150
    assert body["functions"]["선풍기 약하게"] == ["전원", "약풍"]
    assert body["calibration_version"] is None

    listed = next(a for a in client.get("/appliances").json() if a["id"] == "custom_fan")
    assert listed["functions"] == FAN_JSON["functions"]


def test_legacy_client_payload_still_works(client) -> None:
    legacy = {
        "name": "선풍기",
        "rows": 1,
        "cols": 1,
        "buttons": [{"id": "L-1", "label": "전원", "x": 0, "y": 0}],
    }
    res = client.put("/appliances/custom_legacy", json=legacy)
    assert res.status_code == 200
    assert res.json()["buttons"][0]["kind"] == "button"
    assert res.json()["functions"] == {}


@pytest.mark.parametrize(
    "mutate",
    [
        lambda d: d["buttons"][2].pop("detents"),  # 다이얼인데 딸깍 수 없음
        lambda d: d["buttons"][1].update(detents=4),  # 누름 버튼에 딸깍 수
        lambda d: d["buttons"][0].update(press_ms=5),  # 너무 짧은 누름
        lambda d: d["buttons"][0].update(x_mm=10.0),  # y_mm 없이 x_mm만
        lambda d: d["buttons"][0].update(x_mm=-1.0, y_mm=3.0),  # 프레임 밖
        lambda d: d["buttons"][0].update(kind="slider"),  # 모르는 종류
        lambda d: d["functions"].update(잘못=["없는버튼"]),  # 없는 라벨
        lambda d: d["functions"].update(잘못=["약풍:+1"]),  # 버튼을 돌림
    ],
)
def test_invalid_extended_payloads_are_rejected(client, mutate) -> None:
    import copy

    payload = copy.deepcopy(FAN_JSON)
    mutate(payload)
    assert client.put("/appliances/custom_fan", json=payload).status_code == 422


def test_defined_function_is_used_before_rules(client) -> None:
    assert client.put("/appliances/custom_fan", json=FAN_JSON).status_code == 200

    accepted = client.post(
        "/execute", json={"text": "선풍기 약하게", "appliance_id": "custom_fan"}
    )

    assert accepted.status_code == 200, accepted.text
    status = _wait_done(client, accepted.json()["job_id"])
    assert [s["button"] for s in status["last_buttons"]] == ["전원", "약풍"]


def test_dial_function_is_refused_until_dial_drive_exists(client) -> None:
    assert client.put("/appliances/custom_fan", json=FAN_JSON).status_code == 200

    res = client.post("/execute", json={"text": "타이머 두 칸", "appliance_id": "custom_fan"})

    assert res.status_code == 422
    assert "다이얼" in res.json()["detail"]
