"""G11(안전 계약 적용 보고 2026-10-15 §2) — 엔코더가 죽어 있으면 '멈춤 확인(verified)'을 내지 않는다.

수리 전: 정지 뒤 status 두 번의 엔코더 a·b가 같기만 하면 ``verified``였다. 10/13 보드 날 엔코더 선이 빠져 늘 0을 읽는
상태에서도 "멈춘 것을 확인했어요"가 떴다 — '값이 안 변함'은 멈춤과 죽은 엔코더를 가르지 못한다.

수리 뒤(결정): ``verified``는 **이번 실행(``reset_stop`` 뒤)에 이동을 명령한 축마다 엔코더 값이 실제로 바뀐 것을 본 경우**에만
낸다. 근거가 없으면 ``mcu_ack``에 머물고 "엔코더 움직임을 확인할 수 없어 멈춤은 확인하지 못했어요"를 남긴다.
- 쉬는 중 정지(이번 실행에 이동 명령 없음): 확인할 움직임이 없다 → ``mcu_ack``(예전에는 ``verified``).
- 버튼 사이 대기 중 정지(이번 실행에 이동이 있었고 엔코더가 바뀌는 것을 봤음): ``verified`` 그대로.
- 원점 복귀·MCU 재시작의 카운트 초기화는 근거로 치지 않는다(죽은 엔코더도 0으로 바뀐다).

가짜 MCU(rpi/tools/fake_mcu.py) — 호스트 쪽 판정까지. **실물 미검증**(엔코더 선을 뽑은 실물 시험 필요).
"""

from __future__ import annotations

import threading
import time

import pytest

from rpi.controller.serial_motion import (
    STOP_MCU_ACK,
    STOP_VERIFIED,
    InMemoryLinePipe,
    SerialMotionClient,
)
from rpi.tools.fake_mcu import REHEARSAL_CONFIG, FakeMcu

DETAIL = "엔코더 움직임을 확인할 수 없어 멈춤은 확인하지 못했어요"


@pytest.fixture
def link():
    pipe = InMemoryLinePipe()
    mcu = FakeMcu(pipe)
    yield pipe, mcu
    mcu.close()


def _client(pipe) -> SerialMotionClient:
    return SerialMotionClient(pipe.host, REHEARSAL_CONFIG, poll_s=0.01)


def _dead(mcu: FakeMcu, *, axis_a_dead: bool = True, axis_b_dead: bool = True) -> None:
    """엔코더 선이 빠진 축: 모터는 명령대로 돌지만 카운트가 그대로다(보고 값이 바뀌지 않는다)."""
    def move(doc: dict) -> list:
        if not axis_a_dead:
            mcu.a = doc["a"]
        if not axis_b_dead:
            mcu.b = doc["b"]
        return [*mcu._positions(), mcu._ok(doc)]  # noqa: SLF001 - 가짜 MCU 응답 모양 그대로

    mcu.handlers["move"] = move


def _stop_and_confirm(client: SerialMotionClient):
    client.request_stop()
    return client.confirm_stop(ack_timeout_s=0.5, verify_interval_s=0.02)


def test_detail_constant_is_the_agreed_sentence():
    from rpi.controller.serial_motion import ENCODER_UNPROVEN_DETAIL

    assert ENCODER_UNPROVEN_DETAIL == DETAIL


def test_dead_encoders_through_a_move_are_not_verified(link):
    pipe, mcu = link
    _dead(mcu)
    client = _client(pipe)
    client.home()
    client.reset_stop()  # 새 실행
    client.move_to(30.0, 10.0)
    client.move_to(60.0, 20.0)
    report = _stop_and_confirm(client)
    assert report.level == STOP_MCU_ACK
    assert report.detail == DETAIL


def test_one_dead_encoder_is_enough_to_withhold_verified(link):
    """10/14 보드 날처럼 한 축의 엔코더 단자만 빠져도 — 그 축이 멈췄는지는 모른다."""
    pipe, mcu = link
    _dead(mcu, axis_a_dead=True, axis_b_dead=False)
    client = _client(pipe)
    client.home()
    client.reset_stop()
    client.move_to(30.0, 10.0)
    client.move_to(60.0, 20.0)
    report = _stop_and_confirm(client)
    assert report.level == STOP_MCU_ACK and report.detail == DETAIL


def test_live_encoders_that_stop_between_buttons_are_verified(link):
    pipe, _mcu = link
    client = _client(pipe)
    client.home()
    client.reset_stop()
    client.move_to(30.0, 10.0)
    client.move_to(60.0, 20.0)
    report = _stop_and_confirm(client)
    assert report.level == STOP_VERIFIED
    assert report.detail is None


def test_live_encoders_stopped_mid_move_are_verified(link):
    pipe, mcu = link
    client = _client(pipe)
    client.home()
    client.reset_stop()
    client.move_to(30.0, 10.0)
    mcu.delays["move"] = 0.5  # 다음 이동은 오래 걸린다 — 도중에 멈춘다
    errors: list[BaseException] = []

    def move() -> None:
        try:
            client.move_to(60.0, 20.0)
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    worker = threading.Thread(target=move)
    worker.start()
    time.sleep(0.1)
    report = _stop_and_confirm(client)
    worker.join(2)
    assert errors  # 이동은 끝나지 않았다(정지)
    assert report.level == STOP_VERIFIED


def test_idle_stop_with_no_motion_in_this_run_is_not_verified(link):
    """결정: 쉬는 중 정지는 확인할 움직임이 없다 — 정적인 값만으로는 ``verified``를 내지 않는다(종전은 verified)."""
    pipe, _mcu = link
    client = _client(pipe)
    client.home()
    client.reset_stop()
    report = _stop_and_confirm(client)
    assert report.level == STOP_MCU_ACK and report.detail == DETAIL


def test_evidence_from_an_earlier_run_does_not_carry_over(link):
    pipe, _mcu = link
    client = _client(pipe)
    client.home()
    client.reset_stop()
    client.move_to(30.0, 10.0)
    client.move_to(60.0, 20.0)
    assert _stop_and_confirm(client).level == STOP_VERIFIED
    client.reset_stop()  # 다음 실행 — 엔코더가 그사이 빠졌을 수 있다
    report = _stop_and_confirm(client)
    assert report.level == STOP_MCU_ACK and report.detail == DETAIL


def test_count_reset_by_homing_is_not_evidence(link):
    """원점 복귀가 카운트를 0으로 되돌리는 것은 엔코더가 살아 있다는 근거가 아니다."""
    pipe, mcu = link
    mcu.a = mcu.b = 700  # 지난 실행이 끝난 자리
    _dead(mcu)
    client = _client(pipe)
    client.status()  # 700·700을 본다
    client.home()  # 가짜 MCU가 0으로 되돌린다
    client.move_to(30.0, 10.0)  # 죽은 엔코더 — 0 그대로
    report = _stop_and_confirm(client)
    assert report.level == STOP_MCU_ACK and report.detail == DETAIL
