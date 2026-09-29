"""RPi5↔RPi4 프레임 탭(rpi/services/link_tap.py) — 링 버퍼·JSONL 파일·회전·비밀값 가림."""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime

import pytest

from rpi.services import link_tap
from rpi.services.act_client import ActClient
from rpi.services.link_tap import REDACTED, LinkFrameTap, get_link_tap, replay_dir, reset_link_tap_for_tests


def _lines(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_ring_and_file_record_both_directions_with_sequence_ids(tmp_path):
    path = tmp_path / "session.jsonl"
    tap = LinkFrameTap(path, ring_size=3, transport="uart")
    tap.record("hub_to_act", {"type": "execute", "sequence_id": "s1", "buttons": ["시작"]})
    tap.record("act_to_hub", {"type": "progress", "sequence_id": "s1", "phase": "move", "button": "시작"})
    tap.record("act_to_hub", {"type": "result", "sequence_id": "s1", "success": True, "retry": 0})
    tap.record("act_to_hub", None, raw="garbage{")
    frames = tap.frames()
    assert len(frames) == 3  # 링은 최근 3개
    assert [f["n"] for f in frames] == [2, 3, 4]
    assert frames[-1]["raw"] == "garbage{" and frames[-1]["type"] is None
    # 링에서 밀려나도 마지막 execute는 쥔다.
    assert tap.last_execute()["sequence_id"] == "s1"
    rows = _lines(path)
    assert rows[0]["kind"] == "session_start" and rows[0]["transport"] == "uart"
    kinds = [(r["direction"], r["type"], r["sequence_id"]) for r in rows[1:]]
    assert kinds == [("hub_to_act", "execute", "s1"), ("act_to_hub", "progress", "s1"),
                     ("act_to_hub", "result", "s1"), ("act_to_hub", None, None)]
    assert all(isinstance(r["t_monotonic_ns"], int) and "T" in r["t_wall"] for r in rows)
    tap.close()


def test_size_cap_rotates_and_keeps_limited_backups(tmp_path):
    path = tmp_path / "s.jsonl"
    tap = LinkFrameTap(path, max_bytes=1024, backups=2)
    for i in range(60):
        tap.record("hub_to_act", {"type": "execute", "sequence_id": f"seq-{i:03d}", "buttons": ["x" * 40]})
    tap.close()
    assert path.exists() and (tmp_path / "s.jsonl.1").exists() and (tmp_path / "s.jsonl.2").exists()
    assert not (tmp_path / "s.jsonl.3").exists()
    for p in (path, tmp_path / "s.jsonl.1", tmp_path / "s.jsonl.2"):
        assert p.stat().st_size <= 1024
        assert _lines(p)[0]["kind"] == "session_start"  # 새 파일마다 머리 줄
    # 가장 최근 프레임은 현재 파일 끝에 있다.
    assert _lines(path)[-1]["sequence_id"] == "seq-059"


def test_date_template_splits_files_per_day(tmp_path):
    day = {"v": datetime(2026, 10, 1, 9, 0)}
    tap = LinkFrameTap(tmp_path / "session-{date}.jsonl", wall=lambda: day["v"])
    tap.record("hub_to_act", {"type": "abort"})
    day["v"] = datetime(2026, 10, 2, 0, 1)
    tap.record("hub_to_act", {"type": "abort"})
    tap.close()
    assert len(_lines(tmp_path / "session-20261001.jsonl")) == 2
    assert len(_lines(tmp_path / "session-20261002.jsonl")) == 2


def test_secrets_are_never_written(tmp_path, monkeypatch):
    monkeypatch.setenv("SIMPLELAY_API_KEY", "super-secret-key-123")
    monkeypatch.setenv("SIMPLELAY_DEV_TOKEN", "dev-token-xyz")
    path = tmp_path / "s.jsonl"
    tap = LinkFrameTap(path)
    tap.record("hub_to_act", {"type": "execute", "sequence_id": "s", "api_key": "abc",
                              "meta": {"Authorization": "Bearer q", "note": "key=super-secret-key-123"},
                              "list": [{"token": "t"}, "dev-token-xyz"]})
    tap.record("act_to_hub", None, raw='{"x-api-key": "super-secret-key-123"')
    tap.close()
    text = path.read_text(encoding="utf-8")
    for secret in ("super-secret-key-123", "dev-token-xyz", "Bearer q", '"abc"'):
        assert secret not in text
    msg = tap.frames()[0]["message"]
    assert msg["api_key"] == REDACTED and msg["meta"]["Authorization"] == REDACTED
    assert msg["list"][0]["token"] == REDACTED and msg["list"][1] == REDACTED
    assert msg["meta"]["note"] == f"key={REDACTED}"


def test_write_failure_never_breaks_recording(tmp_path):
    folder = tmp_path / "is_a_dir"
    folder.mkdir()
    tap = LinkFrameTap(folder)  # 파일 자리에 폴더 → 쓰기 실패
    entry = tap.record("hub_to_act", {"type": "abort"})
    assert entry is not None and tap.frames()[0]["type"] == "abort"
    assert tap.write_errors == 1


def test_env_default_off_and_startup_log_line(tmp_path, monkeypatch, caplog):
    monkeypatch.delenv("SIMPLELAY_SESSION_LOG_PATH", raising=False)
    reset_link_tap_for_tests()
    with caplog.at_level(logging.INFO, logger="rpi.services.link_tap"):
        tap = get_link_tap()
    assert not tap.enabled
    assert "session log off" in caplog.text
    assert replay_dir() is None
    reset_link_tap_for_tests()
    caplog.clear()
    monkeypatch.setenv("SIMPLELAY_SESSION_LOG_PATH", str(tmp_path / "logs" / "s.jsonl"))
    with caplog.at_level(logging.INFO, logger="rpi.services.link_tap"):
        tap = get_link_tap()
    assert tap.enabled and "session log ON" in caplog.text and str(tmp_path) in caplog.text
    assert get_link_tap() is tap
    assert replay_dir() == tmp_path / "logs"
    reset_link_tap_for_tests()
    with pytest.raises(ValueError):
        LinkFrameTap.from_env({"SIMPLELAY_SESSION_LOG_MAX_BYTES": "lots"})


class _PipeWriter:
    def __init__(self, peer: asyncio.StreamReader) -> None:
        self._peer = peer

    def write(self, data: bytes) -> None:
        self._peer.feed_data(data)

    async def drain(self) -> None:
        pass


def test_act_client_records_every_sent_and_received_line(tmp_path):
    tap = LinkFrameTap(tmp_path / "s.jsonl")

    async def _t():
        to_rpi4, to_rpi5 = asyncio.StreamReader(), asyncio.StreamReader()
        client = ActClient(to_rpi5, _PipeWriter(to_rpi4), tap=tap)
        await client.start()

        async def fake_rpi4():
            line = json.loads(await to_rpi4.readuntil(b"\n"))
            seq = line["sequence_id"]
            for doc in (b"not json\n",
                        json.dumps({"type": "progress", "sequence_id": seq, "phase": "move", "button": "a"}).encode() + b"\n",
                        json.dumps({"type": "result", "sequence_id": seq, "success": True, "retry": 0}).encode() + b"\n"):
                to_rpi5.feed_data(doc)

        rpi4 = asyncio.create_task(fake_rpi4())
        result = await client.execute(["a"], sequence_id="s-1")
        await rpi4
        await client.abort()
        await client.stop()
        return result

    result = asyncio.run(_t())
    assert result.success is True
    seen = [(f["direction"], f["type"]) for f in tap.frames()]
    assert seen == [("hub_to_act", "execute"), ("act_to_hub", None), ("act_to_hub", "progress"),
                    ("act_to_hub", "result"), ("hub_to_act", "abort")]
    tap.close()
    assert len(_lines(tmp_path / "s.jsonl")) == 6  # 머리 줄 + 5


def test_module_exposes_env_names():
    assert link_tap.PATH_ENV == "SIMPLELAY_SESSION_LOG_PATH"
