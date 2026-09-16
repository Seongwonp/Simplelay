"""POST /panel-scan — 사진 → 초안(저장 없음). 인식 서비스는 가짜로 바꿔 끼운다(크레딧 0)."""

import base64
import json

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
import rpi.api.router as router_module
import rpi.api.schemas as schemas
from rpi.main import app
from rpi.vision import HttpVisionClient, VisionUnavailable

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
PNG_B64 = base64.b64encode(PNG).decode("ascii")

REPLY = json.dumps(
    {
        "buttons": [
            {"label": "해동", "kind": "button", "box": [100, 100, 250, 180]},
            {"label": "시간", "kind": "button", "box": [400, 105, 550, 185]},
            {"label": "", "kind": "button", "box": [700, 98, 850, 178]},
            {"label": "취소", "kind": "button", "box": [102, 400, 252, 480]},
            {"label": "출력", "kind": "dial", "box": [398, 395, 548, 475]},
            {"label": "시작", "kind": "button", "box": [703, 402, 853, 482]},
            {"label": "레버", "kind": "lever", "box": [0, 900, 50, 950]},
        ]
    },
    ensure_ascii=False,
)


def _pt(sx, sy):
    return {"source": [sx, sy], "target": [0.2 * sx + 30, 0.15 * sy + 40]}


CORNERS = [_pt(0, 0), _pt(1000, 0), _pt(0, 1000), _pt(1000, 1000)]


class FakeScanner:
    model = "fake-vision"

    def __init__(self, reply=REPLY, error=None):
        self.reply = reply
        self.error = error
        self.calls = []

    def describe_panel(self, image, mime):
        self.calls.append((image, mime))
        if self.error is not None:
            raise self.error
        return self.reply


@pytest.fixture(autouse=True)
def _fresh_gate():
    """게이트는 모듈 전역이라 테스트끼리 시간당 한도를 나눠 쓰지 않게 비운다."""
    router_module._panel_scan_gate.reset()
    yield
    router_module._panel_scan_gate.reset()


@pytest.fixture()
def serve(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)

    def install(scanner):
        app.dependency_overrides[deps.get_panel_scanner] = lambda: scanner
        return TestClient(app)

    yield install
    app.dependency_overrides.pop(deps.get_panel_scanner, None)


def test_scan_returns_a_draft_and_saves_nothing(serve) -> None:
    scanner = FakeScanner()
    client = serve(scanner)
    before = len(client.get("/appliances").json())

    res = client.post("/panel-scan", json={"image_base64": PNG_B64})

    assert res.status_code == 200, res.text
    body = res.json()
    assert (body["rows"], body["cols"]) == (2, 3)
    assert [b["label"] for b in body["buttons"]] == ["해동", "시간", "버튼 3", "취소", "출력", "시작"]
    assert body["buttons"][2]["label_from_model"] is False
    assert body["buttons"][4]["kind"] == "dial"
    assert all(b["x_mm"] is None for b in body["buttons"])
    assert body["calibration"] is None
    assert body["model"] == "fake-vision"
    assert len(body["dropped"]) == 1
    notes = " ".join(body["notes"])
    assert "초안" in notes and "임시 이름" in notes and "딸깍 수" in notes and "mm" in notes
    assert scanner.calls == [(PNG, "image/png")]
    assert len(client.get("/appliances").json()) == before


def test_data_uri_and_line_breaks_are_accepted(serve) -> None:
    scanner = FakeScanner()
    wrapped = "data:image/png;base64," + "\n".join(PNG_B64[i : i + 10] for i in range(0, len(PNG_B64), 10))

    res = serve(scanner).post("/panel-scan", json={"image_base64": wrapped})

    assert res.status_code == 200, res.text
    assert scanner.calls[0][0] == PNG


def test_disabled_scanner_is_503(serve) -> None:
    res = serve(None).post("/panel-scan", json={"image_base64": PNG_B64})
    assert res.status_code == 503
    assert "꺼져" in res.json()["detail"]


@pytest.mark.parametrize(
    "image",
    ["@@@not-base64@@@", "", base64.b64encode(b"GIF89a" + b"\x00" * 20).decode(), base64.b64encode(b"%PDF-1.7").decode()],
)
def test_bad_images_are_422_and_never_sent(serve, image) -> None:
    scanner = FakeScanner()
    res = serve(scanner).post("/panel-scan", json={"image_base64": image})
    assert res.status_code == 422
    assert scanner.calls == []


def test_oversized_image_is_422_and_never_sent(serve, monkeypatch) -> None:
    monkeypatch.setattr(schemas, "PANEL_SCAN_MAX_IMAGE_BYTES", 16)
    scanner = FakeScanner()
    res = serve(scanner).post("/panel-scan", json={"image_base64": PNG_B64})
    assert res.status_code == 422
    assert "너무 커요" in res.text
    assert scanner.calls == []


@pytest.mark.parametrize(
    ("status", "expected"),
    [(402, 503), (429, 503), (None, 503), (401, 502), (403, 502), (500, 502)],
)
def test_service_failures_keep_the_user_sentence(serve, status, expected) -> None:
    error = VisionUnavailable("인식 서비스 크레딧이 부족해요", status=status)
    res = serve(FakeScanner(error=error)).post("/panel-scan", json={"image_base64": PNG_B64})
    assert res.status_code == expected
    assert res.json()["detail"] == "인식 서비스 크레딧이 부족해요"


def test_unusable_model_output_is_422(serve) -> None:
    res = serve(FakeScanner(reply="죄송하지만 버튼을 찾을 수 없습니다")).post(
        "/panel-scan", json={"image_base64": PNG_B64}
    )
    assert res.status_code == 422
    assert "다시 촬영" in res.json()["detail"]


def test_reference_points_fill_mm_and_report_calibration(serve) -> None:
    res = serve(FakeScanner()).post(
        "/panel-scan", json={"image_base64": PNG_B64, "reference_points": CORNERS}
    )

    assert res.status_code == 200, res.text
    body = res.json()
    start = next(b for b in body["buttons"] if b["label"] == "시작")
    assert start["x_mm"] == pytest.approx(0.2 * start["center"][0] + 30)
    assert start["y_mm"] == pytest.approx(0.15 * start["center"][1] + 40)
    assert len(body["calibration"]["version"]) == 12
    assert body["calibration"]["redundant_points"] == 1
    assert not any("mm" in note for note in body["notes"])


@pytest.mark.parametrize(
    "points",
    [
        [_pt(0, 0), _pt(500, 500), _pt(1000, 1000)],
        [{"source": p["source"], "target": [p["target"][0] * 20, p["target"][1] * 20]} for p in CORNERS],
        [_pt(0, 0), _pt(1000, 0)],
    ],
)
def test_bad_reference_points_are_422(serve, points) -> None:
    res = serve(FakeScanner()).post(
        "/panel-scan", json={"image_base64": PNG_B64, "reference_points": points}
    )
    assert res.status_code == 422


def test_second_scan_while_busy_is_409_and_not_sent(serve, monkeypatch) -> None:
    scanner = FakeScanner()
    monkeypatch.setattr(router_module._panel_scan_gate, "busy", True)

    res = serve(scanner).post("/panel-scan", json={"image_base64": PNG_B64})

    assert res.status_code == 409
    assert scanner.calls == []


def test_gate_is_released_after_a_failure(serve) -> None:
    scanner = FakeScanner(error=VisionUnavailable("연결 실패"))
    client = serve(scanner)
    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 503

    scanner.error = None
    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 200


def test_hourly_cap_refuses_without_sending(serve, monkeypatch) -> None:
    """같은 망의 누구든 반복 호출로 공유 크레딧을 소진시키지 못하게 한다."""
    monkeypatch.setenv("SIMPLELAY_VISION_MAX_PER_HOUR", "2")
    now = [1000.0]
    monkeypatch.setattr(router_module._panel_scan_gate, "clock", lambda: now[0])
    scanner = FakeScanner()
    client = serve(scanner)

    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 200
    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 200
    third = client.post("/panel-scan", json={"image_base64": PNG_B64})

    assert third.status_code == 429
    assert "2번까지" in third.json()["detail"]
    assert len(scanner.calls) == 2


def test_hourly_cap_window_slides(serve, monkeypatch) -> None:
    monkeypatch.setenv("SIMPLELAY_VISION_MAX_PER_HOUR", "1")
    now = [1000.0]
    monkeypatch.setattr(router_module._panel_scan_gate, "clock", lambda: now[0])
    scanner = FakeScanner()
    client = serve(scanner)

    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 200
    now[0] += 3599.0
    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 429
    now[0] += 2.0  # 첫 요청이 한 시간 창 밖으로 나간다
    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 200
    assert len(scanner.calls) == 2


def test_failed_requests_count_toward_the_cap(serve, monkeypatch) -> None:
    """실패한 요청도 크레딧·한도를 쓸 수 있다 -- 실패를 반복해 상한을 우회하지 못한다."""
    monkeypatch.setenv("SIMPLELAY_VISION_MAX_PER_HOUR", "1")
    monkeypatch.setattr(router_module._panel_scan_gate, "clock", lambda: 1000.0)
    scanner = FakeScanner(error=VisionUnavailable("연결 실패"))
    client = serve(scanner)

    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 503
    scanner.error = None
    assert client.post("/panel-scan", json={"image_base64": PNG_B64}).status_code == 429


@pytest.mark.parametrize("raw", ["", "abc", "0", "-5"])
def test_invalid_cap_setting_falls_back_to_default(monkeypatch, raw) -> None:
    monkeypatch.setenv("SIMPLELAY_VISION_MAX_PER_HOUR", raw)
    gate = router_module._PanelScanGate()
    assert gate.max_per_hour() == router_module._PanelScanGate.DEFAULT_MAX_PER_HOUR


# ── 설정: 셋 다 있어야 켜진다 ────────────────────────────────────────────────


@pytest.fixture()
def vision_env(monkeypatch):
    for key in (
        "SIMPLELAY_VISION_BASE_URL",
        "SIMPLELAY_VISION_API_KEY",
        "SIMPLELAY_VISION_MODEL",
        "SIMPLELAY_VISION_TIMEOUT_SECONDS",
    ):
        monkeypatch.delenv(key, raising=False)
    deps.get_panel_scanner.cache_clear()
    yield monkeypatch
    deps.get_panel_scanner.cache_clear()


@pytest.mark.parametrize(
    "present",
    [(), ("SIMPLELAY_VISION_BASE_URL",), ("SIMPLELAY_VISION_BASE_URL", "SIMPLELAY_VISION_API_KEY")],
)
def test_scanner_stays_off_unless_fully_configured(vision_env, present) -> None:
    for key in present:
        vision_env.setenv(key, "x")
    assert deps.get_panel_scanner() is None


def test_scanner_is_built_from_env(vision_env) -> None:
    vision_env.setenv("SIMPLELAY_VISION_BASE_URL", "https://gateway.example.invalid/v1")
    vision_env.setenv("SIMPLELAY_VISION_API_KEY", "k")
    vision_env.setenv("SIMPLELAY_VISION_MODEL", "vision-model-x")
    vision_env.setenv("SIMPLELAY_VISION_TIMEOUT_SECONDS", "oops")

    scanner = deps.get_panel_scanner()

    assert isinstance(scanner, HttpVisionClient)
    assert scanner.model == "vision-model-x"
