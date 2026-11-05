"""확인 주행 시작의 정지 표시 지우기가 실제 모션 어댑터까지 닿는지."""

import threading

from rpi4.services.stop_hold import GrblHoldMotion


class _Client:
    def __init__(self) -> None:
        self.stopped = threading.Event()
        self.moves: list[tuple[float, float]] = []

    def request_stop(self) -> None:
        self.stopped.set()

    def reset_stop(self) -> None:
        self.stopped.clear()

    def move_to(self, x_mm: float, y_mm: float) -> None:
        if self.stopped.is_set():
            raise RuntimeError("전송 전에 중단 요청이 왔어요")
        self.moves.append((x_mm, y_mm))


def test_reset_stop_clears_stale_stop_on_adapter():
    client = _Client()
    motion = GrblHoldMotion(client)
    motion.request_stop()  # 개발자 조작 종료 때 남은 정지

    motion.reset_stop()
    motion.move_to(2.0, 3.0)

    assert client.moves == [(2.0, 3.0)]


def test_reset_stop_reaches_separate_press_and_move_clients():
    press, move = _Client(), _Client()
    press.request_stop()
    move.request_stop()

    GrblHoldMotion(press, move).reset_stop()

    assert not press.stopped.is_set() and not move.stopped.is_set()
