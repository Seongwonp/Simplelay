"""외부 검토 2026-10-19 (6): 완료 사건 키가 RPi4 단조 시계 식별자(``clock_id``)를 보지 않았다.

``at_s``는 RPi4 프로세스의 단조 시각이라 RPi4가 다시 켜지면 0부터 다시 센다. 키가 가전·이벤트·출처·``at_s``뿐이면 재시작
뒤의 진짜 새 사건이 같은 ``at_s``로 오는 순간 '이미 처리한 사건'으로 막혔다. 같은 시계의 재전송만 같은 사건이다.
"""

from __future__ import annotations

from rpi.routines.auto_rules import event_key


def _record(clock_id):
    return {"appliance_id": "microwave", "event": "cook_done", "source": "real", "at_s": 812.5,
            "clock_id": clock_id}


def test_same_at_s_from_a_restarted_rpi4_is_a_different_event():
    assert event_key(_record("rpi4-a")) != event_key(_record("rpi4-b"))


def test_resend_on_the_same_clock_is_the_same_event():
    assert event_key(_record("rpi4-a")) == event_key(_record("rpi4-a"))


def test_record_without_clock_id_keeps_the_old_key():
    # 옛 RPi4(clock_id 없음)의 키는 예전과 같다 — 이미 저장한 처리 기록과 그대로 맞는다.
    import hashlib

    raw = "microwave|cook_done|real|812.500"
    assert event_key(_record(None)) == hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]
