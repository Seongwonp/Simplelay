"""잔여 전류 꼬리(피드백 ③) 계산 — 합성 파형으로 정의를 고정한다. 수치 기준은 전부 측정 필요."""

from __future__ import annotations

import pytest

from rpi.verifier.power import PowerSample
from rpi.verifier.power_tail import PowerTailTracker, TailConfig, measure_tail

CFG = TailConfig(off_max_w=30.0, off_confirm_s=2.0, band_abs_w=5.0, band_ratio=0.5, settle_s=3.0,
                 max_wait_s=10.0, max_run_s=60.0)


def _wave(parts: list[tuple[float, float]], hz: float = 10.0) -> list[PowerSample]:
    """[(지속 초, W), ...] → 10 Hz 샘플. 시각은 0부터."""
    out, t = [], 0.0
    for duration, watts in parts:
        n = int(round(duration * hz))
        for _ in range(n):
            out.append(PowerSample(round(t, 6), watts))
            t += 1.0 / hz
    return out


def test_tail_returns_to_baseline():
    # 조리 5초(1200W) → 잔여 12W 4초 → 대기 3W
    samples = _wave([(5.0, 1200.0), (4.0, 12.0), (10.0, 3.0)])
    m = measure_tail(samples, pre_baseline_w=3.0, config=CFG)
    assert m.status == "returned"
    assert m.finished_at_s == pytest.approx(7.0)  # 5.0에 30W 이하 → 2초 유지
    assert m.returned_at_s == pytest.approx(9.0)  # 3W(띠 ±5W)가 시작된 시각
    assert m.tail_s == pytest.approx(2.0)
    assert m.tail_mean_w == pytest.approx(12.0) and m.tail_max_w == pytest.approx(12.0)
    assert m.pre_baseline_w == 3.0 and m.post_baseline_w == pytest.approx(3.0)
    assert m.band_w == 5.0
    doc = m.as_dict()
    assert doc["status"] == "returned" and "2.0초" in doc["detail"]


def test_tail_mean_and_max_cover_only_the_tail():
    samples = _wave([(5.0, 1200.0), (2.0, 20.0), (1.0, 25.0), (1.0, 15.0), (10.0, 4.0)])
    m = measure_tail(samples, pre_baseline_w=3.0, config=CFG)
    assert m.status == "returned"
    # 완료 판정(7.0) 뒤 ~ 복귀(9.0) 직전: 25W 9개(7.1~7.9) + 15W 10개(8.0~8.9)
    assert m.tail_max_w == pytest.approx(25.0)
    assert m.tail_mean_w == pytest.approx((9 * 25.0 + 10 * 15.0) / 19)
    assert m.post_baseline_w == pytest.approx(4.0)


def test_tail_that_never_returns_times_out():
    samples = _wave([(5.0, 1200.0), (30.0, 12.0)])
    m = measure_tail(samples, pre_baseline_w=3.0, config=CFG)
    assert m.status == "timeout"
    assert m.tail_s is None and m.returned_at_s is None
    assert m.post_baseline_w == pytest.approx(12.0)  # 마지막 settle 구간의 중앙값
    assert m.tail_max_w == pytest.approx(12.0)
    assert "돌아오지 않음" in m.detail


def test_dip_shorter_than_off_confirm_is_not_completion():
    # 인버터 출력 주기처럼 1초 꺼졌다 다시 켜지는 것은 완료가 아니다
    samples = _wave([(3.0, 1200.0), (1.0, 5.0), (3.0, 1200.0), (12.0, 3.0)])
    m = measure_tail(samples, pre_baseline_w=3.0, config=CFG)
    assert m.status == "returned"
    assert m.finished_at_s == pytest.approx(9.0)  # 두 번째 하강(7.0)에서 2초


def test_no_baseline_and_no_finish_are_reported_not_invented():
    samples = _wave([(3.0, 1200.0), (10.0, 3.0)])
    m = measure_tail(samples, pre_baseline_w=None, config=CFG)
    assert m.status == "no_baseline" and m.tail_s is None and m.tail_mean_w is None
    running = _wave([(80.0, 1200.0)])
    m = measure_tail(running, pre_baseline_w=3.0, config=CFG)
    assert m.status == "no_finish" and m.finished_at_s is None


def test_band_uses_ratio_for_larger_baselines():
    tracker = PowerTailTracker(40.0, CFG)
    assert tracker.band_w == 20.0  # max(5, 0.5×40)


def test_tracker_ignores_bad_and_out_of_order_samples():
    tracker = PowerTailTracker(3.0, CFG)
    tracker.feed(PowerSample(1.0, 1200.0))
    tracker.feed(PowerSample(0.5, 0.0))  # 시각 역행
    tracker.feed(PowerSample(1.1, float("nan")))
    tracker.feed(PowerSample(1.2, -3.0))
    assert tracker.phase == "running"


def test_stopped_status_keeps_partial_numbers():
    tracker = PowerTailTracker(3.0, CFG)
    for s in _wave([(3.0, 1200.0), (3.0, 12.0)]):
        tracker.feed(s)
    m = tracker.metrics("stopped")
    assert m.status == "stopped" and m.tail_max_w == pytest.approx(12.0) and m.tail_s is None


def test_config_from_env_and_validation():
    cfg = TailConfig.from_env({"SIMPLELAY_TAIL_SETTLE_S": "5", "SIMPLELAY_TAIL_BAND_W": "8"})
    assert cfg.settle_s == 5.0 and cfg.band_abs_w == 8.0
    with pytest.raises(RuntimeError):
        TailConfig.from_env({"SIMPLELAY_TAIL_MAX_WAIT_S": "0"})
    with pytest.raises(RuntimeError):
        TailConfig.from_env({"SIMPLELAY_TAIL_OFF_MAX_W": "many"})


# ── 원시 기록기 열(피드백 ③) ─────────────────────────────────────────────────


def test_recorder_power_tail_row_has_tail_columns():
    import csv
    import io

    from rpi.verifier.recorder import COLUMNS, CsvSink, PressWindowRecorder

    buffer = io.StringIO()
    rec = PressWindowRecorder(CsvSink(buffer), clock=lambda: 123, pre_s=0.5, post_s=0.5)
    m = measure_tail(_wave([(5.0, 1200.0), (4.0, 12.0), (10.0, 3.0)]), 3.0, CFG, source="mock")
    rec.record_power_tail(m.as_dict(), note="sequence_id=s1")  # 창 모드여도 남는다
    rows = list(csv.DictReader(io.StringIO(buffer.getvalue())))
    assert list(rows[0]) == list(COLUMNS)
    (row,) = rows
    assert row["event"] == "power_tail" and row["source"] == "mock_power_tail"
    assert row["tail_status"] == "returned" and float(row["tail_s"]) == pytest.approx(2.0)
    assert float(row["tail_mean_w"]) == pytest.approx(12.0) and float(row["tail_max_w"]) == pytest.approx(12.0)
    assert float(row["pre_baseline_w"]) == 3.0 and float(row["post_baseline_w"]) == pytest.approx(3.0)
    assert row["note"] == "sequence_id=s1"


def test_live_recorder_reads_outlet_power_as_real_or_mock(tmp_path):
    import time

    from rpi.tools.fake_outlet import open_fake_outlet
    from rpi.verifier.outlet import OutletConfig, OutletLink
    from rpi.verifier.recorder import LiveRecorder

    pipe, fake = open_fake_outlet(speed=50.0, relay_on=True)
    link = OutletLink(pipe.host, OutletConfig(heartbeat_s=None), mock=True).start()
    try:
        live = LiveRecorder(tmp_path / "rec.jsonl", power_sensor=link.sensor(), power_mock=True,
                            power_reason="콘센트 모듈(가짜 출력)")
        assert [c.label for c in live.sources if c.kind == "power"] == ["mock_power"]
        live.start()
        time.sleep(0.2)
        live.close()
        import json

        rows = [json.loads(line) for line in (tmp_path / "rec.jsonl").read_text(encoding="utf-8").splitlines()]
        power_rows = [r for r in rows if r.get("source") == "mock_power"]
        assert len(power_rows) >= 5 and all(r["power_watts"] == 3.0 for r in power_rows)
        times = [r["power_sensor_t_s"] for r in power_rows]
        assert times == sorted(times)
    finally:
        link.close()
        fake.close()
