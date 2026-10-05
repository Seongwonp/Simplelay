"""deploy/run_backend.sh — 시연 페이싱을 강제하지 않고 기기 env 파일을 따른다(2026-10-06 시연 v3 갭 S9).

보드에서 돌리는 셸 스크립트라 실행하지 않고 내용만 고정한다: busybox sh에서 도는 POSIX 문법, LF 줄 끝.
"""

from __future__ import annotations

from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "deploy" / "run_backend.sh"


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
    for bashism in ("[[ ", "function ", "<<<", "source ", "pipefail"):
        assert bashism not in text, bashism
