"""메모리 파이프 위의 가짜 콘센트 모듈 — 시험과 리허설(``SIMPLELAY_OUTLET_PORT=fake``)이 같이 쓴다.

**실물 콘센트 모듈이 아니다.** ``firmware-outlet``의 줄 단위 JSON 규약(line-json/outlet-v0)을 흉내 낼
뿐, CT·ADC·릴레이·가전을 흉내 내지 않는다. 이것으로 통과한 것은 "호스트 쪽 규약 처리와 판정 배선"까지다.
여기서 나온 전력은 합성 값이라, 이것에 붙은 링크(`OutletLink(mock=True)`)의 판정은 모의로 표시된다.

흉내 내는 펌웨어 규칙:
- 부팅 기본 릴레이 꺼짐. ``relay_on``이 있어야 켜진다. 릴레이가 꺼져 있으면 전력은 0 W(전원 차단).
- 비상정지(``press_estop``)는 호스트와 무관하게 릴레이를 열고 ``estop`` 이벤트를 보낸다. 걸린 동안
  ``relay_on``은 ``estop_latched``로 거절, 버튼이 눌린 채면 ``estop_reset``은 ``estop_active``로 거절.
- ``ct_ok=False``면 ``fault``(ct_init)만 보내고 power 이벤트를 내지 않는다(0 W를 지어내지 않는다).
- 걸림은 재부팅을 넘어 남는다(펌웨어 RTC·NVS 보존, 2026-10-05): ``estop_latched=True``로 만들면 재부팅 전에
  걸린 모듈을 흉내 낸다 — ready·status의 ``estop``이 true, 릴레이는 꺼짐.
- ``silent=True``면 아무 줄도 보내지 않는다(응답도 없음) — 모듈 멈춤·USB 끊김 흉내.

가전 모형(합성, 실측 아님): 대기 ``idle_w`` → ``start_run`` 뒤 ``run_w``로 ``run_s`` 동안 →
``tail_w``로 ``tail_s`` 동안(잔여 전류 꼬리 흉내) → 대기. 수치는 리허설용 임의 값이다.

시각: 모듈 시각 ``t_ms``는 보고마다 ``1000/rate_hz``씩 늘고, 실제로는 ``(1/rate_hz)/speed``초마다
보낸다 — 시험은 ``speed``를 키워 빨리 돌린다.
"""

from __future__ import annotations

import json
import threading
import time

from rpi.controller.serial_motion import InMemoryLinePipe

FAKE_FW = "fake_outlet"
PROTOCOL = "line-json/outlet-v0"

#: 리허설용 임의 값 — 실측 아님.
REHEARSAL_IDLE_W = 3.0
REHEARSAL_RUN_W = 1200.0
REHEARSAL_RUN_S = 30.0
REHEARSAL_TAIL_W = 12.0
REHEARSAL_TAIL_S = 8.0


class FakeOutlet:
    def __init__(
        self,
        pipe: InMemoryLinePipe,
        *,
        rate_hz: int = 10,
        speed: float = 1.0,
        idle_w: float = REHEARSAL_IDLE_W,
        relay_on: bool = False,
        ct_ok: bool = True,
        ready_banner: bool = True,
        estop_latched: bool = False,
    ) -> None:
        self._end = pipe.device
        self.rate_hz = rate_hz
        self.speed = speed
        self.idle_w = idle_w
        self.relay_on = relay_on
        self.ct_ok = ct_ok
        self.estop_latched = estop_latched
        if estop_latched:
            self.relay_on = False  # 걸림이 남아 있으면 부팅 뒤에도 꺼짐
        #: True면 아무 줄도 보내지 않는다(멈춤·끊김 흉내).
        self.silent = False
        self.button_active = False
        self.received: list[dict] = []
        self.t_ms = 0
        self.seq = 0
        #: 이 시각(모듈 ms)부터의 가전 동작 구간 [(끝 ms, W), ...]. 비면 대기.
        self._segments: list[tuple[int, float]] = []
        #: None이 아니면 이 값을 그대로 보낸다(시험용 고정 출력).
        self.override_w: float | None = None
        #: False면 power 이벤트를 멈춘다(끊김 시험). 명령에는 계속 답한다.
        self.emit_power = True
        self._lock = threading.Lock()
        self._stop = threading.Event()
        if ready_banner:
            self._send({"event": "ready", "fw": FAKE_FW, "protocol": PROTOCOL, "reset": "poweron",
                        "relay": "on" if self.relay_on else "off", "ct": "fake", "ct_ok": ct_ok,
                        "estop": self.estop_latched})
        if not ct_ok:
            self._send({"event": "fault", "reason": "ct_init"})
        self._threads = [
            threading.Thread(target=self._rx_loop, daemon=True, name="fake-outlet-rx"),
            threading.Thread(target=self._tx_loop, daemon=True, name="fake-outlet-tx"),
        ]
        for thread in self._threads:
            thread.start()

    # ── 시험·리허설 조작 ───────────────────────────────────────────────────────

    def start_run(self, run_s: float = REHEARSAL_RUN_S, run_w: float = REHEARSAL_RUN_W,
                  tail_s: float = REHEARSAL_TAIL_S, tail_w: float = REHEARSAL_TAIL_W) -> None:
        """가전이 지금 동작을 시작한 것처럼 전력 구간을 건다(릴레이가 켜져 있어야 보인다)."""
        with self._lock:
            t0 = self.t_ms
            end_run = t0 + int(run_s * 1000)
            self._segments = [(end_run, run_w), (end_run + int(tail_s * 1000), tail_w)]

    def press_estop(self) -> None:
        """비상정지 버튼 — 펌웨어처럼 그 자리에서 릴레이를 열고 이벤트를 보낸다."""
        with self._lock:
            self.button_active = True
            if self.estop_latched:
                return
            self.estop_latched = True
            self.relay_on = False
            self._segments = []
            t = self.t_ms
        self._send({"event": "estop", "source": "button", "t_ms": t, "relay": "off"})

    def release_estop_button(self) -> None:
        with self._lock:
            self.button_active = False

    def latch_silently(self) -> None:
        """이벤트 줄 없이 걸린 상태로 둔다 — estop 이벤트를 잃은 경우(주기 status로만 알 수 있다)."""
        with self._lock:
            self.estop_latched = True
            self.relay_on = False
            self._segments = []

    def close(self) -> None:
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=2.0)

    # ── 내부 ─────────────────────────────────────────────────────────────────

    def _send(self, doc: dict) -> None:
        if self.silent:
            return
        self._end.write_line(json.dumps(doc, separators=(",", ":")))

    def _watts_locked(self) -> float:
        if not self.relay_on:
            return 0.0  # 릴레이가 열리면 가전 전원이 없다
        if self.override_w is not None:
            return self.override_w
        while self._segments and self.t_ms >= self._segments[0][0]:
            self._segments.pop(0)
        return self._segments[0][1] if self._segments else self.idle_w

    def _tx_loop(self) -> None:
        while not self._stop.is_set():
            period = 1.0 / self.rate_hz
            if self._stop.wait(period / max(self.speed, 1e-6)):
                return
            with self._lock:
                self.t_ms += int(round(1000 / self.rate_hz))
                if not (self.ct_ok and self.emit_power):
                    continue
                watts = self._watts_locked()
                doc = {"event": "power", "t_ms": self.t_ms, "seq": self.seq, "watts": round(watts, 1),
                       "irms_a": round(watts / 220.0, 3), "vrms_est": 220.0, "ct_mv": round(watts / 220.0 / 30.0 * 1000, 2),
                       "n": 80, "err": 0, "relay": "on" if self.relay_on else "off"}
                self.seq += 1
            self._send(doc)

    def _rx_loop(self) -> None:
        while not self._stop.is_set():
            line = self._end.read_line(0.05)
            if line is None:
                continue
            try:
                doc = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(doc, dict):
                continue
            self.received.append(doc)
            self._send(self._handle(doc))

    def _handle(self, doc: dict) -> dict:
        req_id = doc.get("id") if isinstance(doc.get("id"), int) else None
        cmd = doc.get("cmd")

        def ok(**fields: object) -> dict:
            return {"id": req_id, "ok": True, **fields}

        def err(code: str) -> dict:
            return {"id": req_id, "ok": False, "error": code}

        with self._lock:
            if cmd == "relay_off":
                self.relay_on = False
                self._segments = []
                return ok()
            if cmd == "relay_on":
                if self.estop_latched:
                    return err("estop_latched")
                self.relay_on = True
                return ok()
            if cmd == "estop_reset":
                if self.button_active:
                    return err("estop_active")
                self.estop_latched = False
                return ok()
            if cmd == "status":
                return ok(relay="on" if self.relay_on else "off", estop=self.estop_latched,
                          button=self.button_active, rate_hz=self.rate_hz, ct="fake", cal="placeholder",
                          uptime_ms=self.t_ms)
            if cmd == "ping":
                return ok()
            if cmd == "rate":
                hz = doc.get("hz")
                if isinstance(hz, bool) or not isinstance(hz, int) or not 1 <= hz <= 20:
                    return err("bad_args")
                self.rate_hz = hz
                return ok()
        return err("unknown_cmd")


def open_fake_outlet(**kwargs: object) -> tuple[InMemoryLinePipe, FakeOutlet]:
    """리허설용: 파이프와 가짜 모듈을 함께 만든다. 호스트는 ``pipe.host``를 전송으로 쓴다."""
    pipe = InMemoryLinePipe()
    return pipe, FakeOutlet(pipe, **kwargs)  # type: ignore[arg-type]


def _main() -> int:  # pragma: no cover - 수동 확인용
    pipe, fake = open_fake_outlet(relay_on=True)
    end = time.monotonic() + 2.0
    while time.monotonic() < end:
        line = pipe.host.read_line(0.2)
        if line:
            print(line)
    fake.close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(_main())
