"""deploy/run_act.sh·이미지 의존성 — RPi4 컨테이너가 콘센트·모션 USB 시리얼과 마이크를 볼 수 있어야 한다(2026-10-06 평가).

보드에서 도는 셸 스크립트라 docker를 가짜 명령으로 바꿔 넘기는 인자만 본다(실기기 미검증). busybox sh에서 도는
POSIX 문법, LF 줄 끝을 고정한다.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "deploy" / "run_act.sh"


def test_script_stays_lf_and_posix_sh():
    raw = SCRIPT.read_bytes()
    assert b"\r\n" not in raw
    text = raw.decode("utf-8")
    assert text.startswith("#!/bin/sh\n")
    for bashism in ("[[ ", "function ", "<<<", "source ", "pipefail", "${!"):
        assert bashism not in text, bashism


def test_image_has_the_microphone_runtime():
    """마이크 경로(rpi/verifier/audio_sensor.py)는 sounddevice + PortAudio 공유 라이브러리를 연다."""
    for path in ("deploy/backend.Dockerfile", "deploy/build_on_device.sh"):
        text = (ROOT / path).read_text(encoding="utf-8")
        assert '"sounddevice' in text, path
        assert "libportaudio2" in text, path
    assert b"\r\n" not in (ROOT / "deploy" / "build_on_device.sh").read_bytes()


def _posix(path: Path) -> str:
    """Git Bash(Windows 시험 기기)의 sh가 보는 경로(/c/…). 보드에서는 그대로 /dev/…다."""
    text = str(path).replace("\\", "/")
    if len(text) > 1 and text[1] == ":":
        text = "/" + text[0].lower() + text[2:]
    return text


def _run(tmp_path: Path, env_lines: list[str], link: str = "lan") -> list[str]:
    sh = shutil.which("sh")
    if sh is None:
        pytest.skip("sh 없음")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls.txt"
    docker = bin_dir / "docker"
    docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n', encoding="utf-8", newline="\n")
    docker.chmod(0o755)
    data = tmp_path / "data"
    data.mkdir()
    (data / "env").write_text("\n".join(env_lines) + "\n", encoding="utf-8", newline="\n")
    env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "CALLS": str(calls),
           "DATA_DIR": _posix(data), "SETTLE_S": "0", "LINK": link}
    proc = subprocess.run([sh, str(SCRIPT).replace("\\", "/")], env=env, capture_output=True, text=True,
                          timeout=30)
    run = [line for line in calls.read_text(encoding="utf-8").splitlines() if line.startswith("run ")] \
        if calls.exists() else []
    return [proc.returncode, proc.stdout + proc.stderr, run]  # type: ignore[list-item]


def test_outlet_motion_and_sound_devices_are_passed_through(tmp_path):
    outlet = tmp_path / "ttyUSB0"
    motion = tmp_path / "ttyACM0"
    snd = tmp_path / "snd"
    for dev in (outlet, motion):
        dev.write_text("")
    snd.mkdir()
    p = _posix
    code, out, run = _run(tmp_path, [
        f"SIMPLELAY_OUTLET_PORT={p(outlet)}",
        "SIMPLELAY_OUTLET_BAUD=115200",
        f"SIMPLELAY_MOTION_PORT={p(motion)}",
        f"SIMPLELAY_ACT_DEVICES={p(snd)}",
    ])
    assert code == 0, out
    assert len(run) == 1, out
    for dev in (outlet, motion, snd):
        assert f"--device {p(dev)}" in run[0], run[0]


def test_fake_outlet_is_not_a_device_and_a_missing_device_refuses(tmp_path):
    code, out, run = _run(tmp_path, ["SIMPLELAY_OUTLET_PORT=fake",
                                     f"SIMPLELAY_ACT_DEVICES={_posix(tmp_path)}/missing0"])
    assert code != 0 and run == []  # 없는 장치로 컨테이너를 세우지 않는다(조용히 빠진 채 돌지 않게)
    assert "missing0" in out


def test_lan_link_detects_a_dead_hub_with_tcp_keepalive():
    """무선(2026-10-12): 죽은 RPi5 연결을 붙잡고 새 연결을 못 받던 결함 — socat에 keepalive가 있어야 한다."""
    text = SCRIPT.read_text(encoding="utf-8")
    line = next(l for l in text.splitlines() if "TCP-LISTEN:7000" in l)
    for opt in ("keepalive", "keepidle=", "keepintvl=", "keepcnt="):
        assert opt in line, line
