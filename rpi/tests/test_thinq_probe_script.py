"""실물 날 확인 스크립트 ``scripts/thinq_probe.py`` (2026-10-13, 단계 4).

모의 클라우드(``--fake-cloud``)로만 돌린다 -- 실제 클라우드·실가전은 부르지 않는다.
기본은 읽기 전용(목록·프로필·상태)이고, 제어는 ``--control`` + 확인 질문에 ``yes``일 때 1회뿐이다.
원본 응답은 저장소 밖 폴더에만 쓴다.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

pytest.importorskip("thinqconnect")

from rpi.tools.fake_thinq_cloud import FakeThinqCloud  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def _probe():
    spec = importlib.util.spec_from_file_location("thinq_probe", REPO / "scripts" / "thinq_probe.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def cloud():
    fake = FakeThinqCloud()
    fake.start()
    yield fake
    fake.stop()


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch, tmp_path):
    for key in ("SIMPLELAY_THINQ_PAT", "SIMPLELAY_THINQ_PAT_FILE", "SIMPLELAY_THINQ_CLIENT_ID"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("SIMPLELAY_THINQ_CLIENT_ID_FILE", str(tmp_path / "client_id"))


def _never(prompt):  # 읽기 전용 실행은 질문하지 않는다
    raise AssertionError(f"unexpected question: {prompt}")


def test_default_is_read_only_and_writes_raw_outside_repo(cloud, tmp_path, capsys):
    out = tmp_path / "probe"
    code = _probe().main(["--fake-cloud", cloud.base_url, "--out", str(out)], input_fn=_never)
    assert code == 0
    assert cloud.controls() == []
    paths = {r["path"] for r in cloud.requests()}
    assert "/devices" in paths
    assert any(p.endswith("/profile") for p in paths) and any(p.endswith("/state") for p in paths)
    devices = json.loads((out / "devices.json").read_text(encoding="utf-8"))
    assert len(devices) == 3
    assert any(p.name.endswith("_profile.json") for p in out.iterdir())
    summary = (out / "summary.txt").read_text(encoding="utf-8")
    assert "set_wind_strength" in summary and "모의 클라우드" in summary
    printed = capsys.readouterr().out
    assert "읽기 전용" in printed and str(out) in printed


def test_out_dir_inside_repo_is_refused(cloud):
    code = _probe().main(["--fake-cloud", cloud.base_url, "--out", str(REPO / "docs" / "probe")],
                         input_fn=_never)
    assert code == 2
    assert cloud.requests() == []


def test_real_mode_needs_pat(tmp_path, capsys):
    code = _probe().main(["--out", str(tmp_path / "p")], input_fn=_never)
    assert code == 2
    assert "PAT" in capsys.readouterr().err


def test_control_asks_and_does_nothing_without_yes(cloud, tmp_path):
    asked = []
    code = _probe().main(["--fake-cloud", cloud.base_url, "--out", str(tmp_path / "p"),
                          "--control", "air_purifier", "set_wind_strength", "HIGH"],
                         input_fn=lambda prompt: asked.append(prompt) or "no")
    assert code == 1
    assert len(asked) == 1 and "풍량" in asked[0]
    assert cloud.controls() == []


def test_control_once_after_yes_and_records_result(cloud, tmp_path, capsys):
    out = tmp_path / "p"
    code = _probe().main(["--fake-cloud", cloud.base_url, "--out", str(out),
                          "--control", "air_purifier", "set_wind_strength", "HIGH"],
                         input_fn=lambda prompt: "yes")
    assert code == 0
    assert len(cloud.controls()) == 1
    record = json.loads((out / "control.json").read_text(encoding="utf-8"))
    assert record["status"] == "succeeded" and record["confirmation"] == "state_confirmed"
    assert record["execution_mode"] == "mock"
    assert "state_confirmed" in capsys.readouterr().out


def test_washer_control_refused_when_remote_off(cloud, tmp_path):
    out = tmp_path / "p"
    code = _probe().main(["--fake-cloud", cloud.base_url, "--out", str(out),
                          "--control", "washer", "set_operation", "START"],
                         input_fn=lambda prompt: "yes")
    assert code == 1
    assert cloud.controls() == []
    record = json.loads((out / "control.json").read_text(encoding="utf-8"))
    assert record["receipt"] == "not_dispatched" and "원격" in record["detail"]
