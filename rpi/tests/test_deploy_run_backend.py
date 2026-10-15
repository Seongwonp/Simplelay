"""deploy/run_backend.sh — 시연 페이싱을 강제하지 않고 기기 env 파일을 따른다(2026-10-06 시연 v3 갭 S9),
업데이트 전 서버의 잠시 쉬기 끝 시각 이어받기(2026-10-14 마감 2번).

busybox sh에서 도는 POSIX 문법, LF 줄 끝을 고정한다.

업데이트 전 배포본(``568f995``)은 잠시 쉬기를 메모리에만 두고 공개 ``/health``의 ``dnd_until``으로 알린다.
스크립트는 옛 컨테이너를 지우기 **전에** 그 값을 읽어 새 컨테이너에 ``SIMPLELAY_PAUSE_CARRYOVER_UNTIL``로 넘긴다.
읽지 못하면 넘기지 않고 '업데이트 뒤 잠시 쉬기 재설정 필요'를 알린다. docker·curl은 가짜 명령(실기기 미검증).
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "deploy" / "run_backend.sh"


def _posix(path: Path) -> str:
    text = str(path).replace("\\", "/")
    if len(text) > 1 and text[1] == ":":
        text = "/" + text[0].lower() + text[2:]
    return text


def _run(tmp_path: Path, health: str | None, *, via_wget: bool = False, prepare=None):
    sh = shutil.which("sh")
    if sh is None:
        pytest.skip("sh 없음")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls.txt"
    docker = bin_dir / "docker"
    docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n', encoding="utf-8", newline="\n")
    docker.chmod(0o755)
    curl = bin_dir / "curl"
    wget = bin_dir / "wget"
    # RPi5 기기에는 curl이 없고 busybox wget만 있다(2026-10-14 확인) — 그 경우를 흉내 낸다.
    wget.write_text('#!/bin/sh\nprintf "wget %s\\n" "$*" >> "$CALLS"\nexit 4\n', encoding="utf-8", newline="\n")
    wget.chmod(0o755)
    if via_wget:
        (tmp_path / "health.json").write_text(health, encoding="utf-8", newline="\n")
        curl.write_text('#!/bin/sh\nexit 127\n', encoding="utf-8", newline="\n")
        wget.write_text('#!/bin/sh\nprintf "wget %s\\n" "$*" >> "$CALLS"\ncat "$HEALTH"\n',
                        encoding="utf-8", newline="\n")
    elif health is None:
        curl.write_text('#!/bin/sh\nprintf "curl %s\\n" "$*" >> "$CALLS"\nexit 7\n', encoding="utf-8", newline="\n")
    else:
        (tmp_path / "health.json").write_text(health, encoding="utf-8", newline="\n")
        curl.write_text('#!/bin/sh\nprintf "curl %s\\n" "$*" >> "$CALLS"\ncat "$HEALTH"\n',
                        encoding="utf-8", newline="\n")
    curl.chmod(0o755)
    data = tmp_path / "data"
    data.mkdir()
    if prepare is not None:
        prepare(data)
    env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "CALLS": str(calls),
           "HEALTH": str(tmp_path / "health.json"), "DATA_DIR": _posix(data), "SETTLE_S": "0"}
    proc = subprocess.run([sh, str(SCRIPT).replace("\\", "/")], env=env, capture_output=True, text=True,
                          timeout=30)
    lines = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
    return proc.returncode, proc.stdout + proc.stderr, lines


def _index(lines, prefix):
    return next(i for i, line in enumerate(lines) if line.startswith(prefix))


def test_pacing_is_not_forced_and_follows_the_env_file():
    text = SCRIPT.read_text(encoding="utf-8")
    assert "-e SIMPLELAY_DEMO_PACING" not in text  # docker run이 env 파일 값을 덮어쓰지 않는다
    assert '--env-file "$ENV_FILE"' in text
    assert "PACING=off" in text  # 줄이 없으면 꺼짐(실물 기본)
    assert "시연 페이싱: $PACING" in text  # 운영자가 기동 출력으로 확인한다


def test_script_stays_lf_and_posix_sh():
    raw = SCRIPT.read_bytes()
    assert b"\r\n" not in raw
    text = raw.decode("utf-8")
    assert text.startswith("#!/bin/sh\n")
    for bashism in ("[[ ", "function ", "<<<", "source ", "pipefail", "${!"):
        assert bashism not in text, bashism


def test_old_server_pause_end_is_read_before_removal_and_passed_on(tmp_path):
    old = '{"ok":true,"actuator_ready":true,"dnd_until":"2026-10-14T23:30:00+09:00","act_mode":"uart"}'
    code, out, lines = _run(tmp_path, old)
    assert code == 0, out
    assert _index(lines, "curl ") < _index(lines, "rm -f simplelay-backend")  # 지우기 전에 읽는다
    run = lines[_index(lines, "run ")]
    assert "-e SIMPLELAY_PAUSE_CARRYOVER_UNTIL=2026-10-14T23:30:00+09:00" in run, run
    assert "23:30" in out and "새 제안만" in out


@pytest.mark.parametrize("health,notice", [
    ('{"ok":true,"actuator_ready":true,"dnd_until":null,"act_mode":"uart"}', "이어받을 잠시 쉬기 없음"),
    ('{"ok":true,"version":"0.1.0"}', "서버 DB"),  # 이미 영속하는 새 서버 — 공개 /health에 값이 없다
    (None, "재설정 필요"),  # 실행 중 서버에서 읽지 못함
    ('{"ok":true,"dnd_until":"2026-10-14T23:30:00+09:00; rm -rf /","act_mode":"uart"}', "재설정 필요"),
])
def test_nothing_is_passed_when_no_verifiable_value(tmp_path, health, notice):
    code, out, lines = _run(tmp_path, health)
    assert code == 0, out
    run = lines[_index(lines, "run ")]
    assert "SIMPLELAY_PAUSE_CARRYOVER_UNTIL" not in run, run
    assert notice in out, out


def test_board_without_curl_reads_the_old_pause_with_wget(tmp_path):
    """RPi5 기기에는 curl이 없다 — busybox wget으로 읽어 같은 값을 넘긴다(못 읽으면 이어받기가 늘 빠진다)."""
    old = '{"ok":true,"actuator_ready":true,"dnd_until":"2026-10-14T23:30:00+09:00","act_mode":"uart"}'
    code, out, lines = _run(tmp_path, old, via_wget=True)
    assert code == 0, out
    assert _index(lines, "wget ") < _index(lines, "rm -f simplelay-backend")
    run = lines[_index(lines, "run ")]
    assert "-e SIMPLELAY_PAUSE_CARRYOVER_UNTIL=2026-10-14T23:30:00+09:00" in run, run


_NEW_HEALTH = '{"ok":true,"version":"0.1.0"}'


def test_thinq_client_id_persists_in_data_dir_and_no_pat_is_reported(tmp_path):
    """ThinQ(2026-10-15 검토 H2): 클라이언트 ID는 데이터 폴더(/data/thinq)에 남겨 컨테이너를 다시 만들어도 같다.
    PAT 파일이 없으면 PAT 경로를 넘기지 않고 '없음'을 알린다."""
    code, out, lines = _run(tmp_path, _NEW_HEALTH)
    assert code == 0, out
    run = lines[_index(lines, "run ")]
    assert "-e SIMPLELAY_THINQ_CLIENT_ID_FILE=/data/thinq/thinq_client_id" in run, run
    assert "SIMPLELAY_THINQ_PAT_FILE" not in run, run
    assert (tmp_path / "data" / "thinq").is_dir()
    assert "ThinQ PAT: 없음" in out, out


def test_thinq_pat_file_in_data_dir_is_mounted_path_without_printing_it(tmp_path):
    secret = "pat-value-must-not-be-printed"

    def prepare(data: Path) -> None:
        (data / "thinq").mkdir()
        (data / "thinq" / "thinq_pat").write_text(secret, encoding="utf-8")

    code, out, lines = _run(tmp_path, _NEW_HEALTH, prepare=prepare)
    assert code == 0, out
    run = lines[_index(lines, "run ")]
    assert "-e SIMPLELAY_THINQ_PAT_FILE=/data/thinq/thinq_pat" in run, run
    assert "ThinQ PAT: 파일 있음" in out, out
    assert secret not in out and all(secret not in line for line in lines)


def test_thinq_settings_in_env_file_are_not_overridden(tmp_path):
    def prepare(data: Path) -> None:
        (data / "env").write_text("SIMPLELAY_THINQ_PAT_FILE=/data/other_pat\n"
                                  "SIMPLELAY_THINQ_CLIENT_ID_FILE=/data/other_id\n",
                                  encoding="utf-8", newline="\n")
        (data / "thinq").mkdir()
        (data / "thinq" / "thinq_pat").write_text("x", encoding="utf-8")

    code, out, lines = _run(tmp_path, _NEW_HEALTH, prepare=prepare)
    assert code == 0, out
    run = lines[_index(lines, "run ")]
    assert "SIMPLELAY_THINQ_PAT_FILE" not in run and "SIMPLELAY_THINQ_CLIENT_ID_FILE" not in run, run
    assert "ThinQ PAT: env 파일 설정" in out, out


def test_backend_image_installs_the_pinned_thinq_sdk():
    """이미지에 SDK가 없으면 real·fake_cloud 모드에서 RPi5 서버가 기동을 거절한다(2026-10-15 검토 H2)."""
    dockerfile = (ROOT / "deploy" / "backend.Dockerfile").read_text(encoding="utf-8")
    pyproject = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert '"thinqconnect==1.0.14"' in pyproject
    assert '"thinqconnect==1.0.14"' in dockerfile


def test_old_server_utc_z_form_is_passed_on(tmp_path):
    """보드의 업데이트 전 서버(568f995)는 dnd_until을 UTC 'Z' 꼴로 낸다(2026-10-14 RPi5에서 읽은 실제 모양).
    그 꼴도 그대로 넘겨야 한다 — 빠지면 이어받기가 기기에서 늘 '확인하지 못함'이 된다."""
    old = '{"ok":true,"actuator_ready":false,"dnd_until":"2026-10-14T11:13:36.620005Z","act_mode":"uart"}'
    code, out, lines = _run(tmp_path, old, via_wget=True)
    assert code == 0, out
    run = lines[_index(lines, "run ")]
    assert "-e SIMPLELAY_PAUSE_CARRYOVER_UNTIL=2026-10-14T11:13:36.620005Z" in run, run
