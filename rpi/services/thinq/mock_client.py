"""모의 ThinQ 클라이언트 — 네트워크·PAT 없이 계약을 돌려 보는 대역 (U1-c).

기기 세 대:

- 공기청정기 ``mock-purifier-01`` -- 전원·풍량·운전 모드 쓰기 가능.
- 세탁기 ``mock-washer-01`` -- **읽기 전용.** ``inject_event("wash_complete")``로
  세탁 완료를 흉내 낸다(상태 ``runState.currentState`` → ``END``).
- 제습기 ``mock-dehumidifier-01`` -- 전원만 쓰기 가능(2026-09-29, 세탁 완료 시나리오 대상).

주입 가능한 장애(모두 다음 호출 1회에만 걸린다 — 연쇄 장애는 여러 번 주입):

- ``set_online(False)`` -- 클라우드 전체 미연결. 조회·전송 모두 ``ThinqOfflineError``.
- ``set_device_online(id, False)`` -- 기기 하나가 오프라인(목록에는 있음).
- ``fail_next_control("reject")`` -- 클라우드가 거절 응답(실행 안 됨).
- ``fail_next_control("timeout")`` -- 전송 뒤 응답 유실(받았는지 모름). 상태는 **바뀐다**
  -- 응답만 잃었을 뿐 가전은 받았을 수 있다는 것이 이 장애의 요점이다.
- ``state_delay_reads`` -- 명령 뒤 N번의 조회까지 옛 상태를 보여준다(상태 지연).
- ``drop_state_updates`` -- 접수는 하지만 상태가 끝내 바뀌지 않는다.
- ``latency_seconds`` -- 호출마다 지연(주입한 ``sleep``으로; 테스트는 0).

리허설용 **지속** 장애(G6, ``set_fault`` — ``POST /demo/thinq/fault``, mock 모드만):
``normal``으로 되돌릴 때까지 그 기기에 계속 걸린다.

- ``offline`` -- 기기 오프라인. 준비 상태 disconnected, 실행 요청은 412.
- ``unconfirmed`` -- 전송은 받지만 상태가 끝내 바뀌지 않는다 → ``접수됨``(accepted/none).
- ``lost`` -- 전송 뒤 응답을 매번 잃는다(가전은 받는다) → ``접수 불명``(unknown/none).
- ``latency_ms`` -- 그 기기 조회·전송마다 지연.

모든 결과는 **모의**다. ``execution_mode``는 MOCK이고, 여기서 확인한 상태 변경은
실제 가전의 동작 근거가 아니다.
"""

from __future__ import annotations

import copy
import itertools
import threading
import time
from collections import deque
from collections.abc import Callable
from datetime import datetime, timezone

from rpi.controller.models import ExecutionMode

from .bindings import (
    AIR_PURIFIER_CAPABILITIES,
    AIR_PURIFIER_DEVICE_TYPE,
    DEHUMIDIFIER_CAPABILITIES,
    DEHUMIDIFIER_DEVICE_TYPE,
    WASHER_DEVICE_TYPE,
)
from .client import (
    ThinqCommandRejected,
    ThinqDeviceInfo,
    ThinqOfflineError,
    ThinqTransportError,
)

#: 지속 장애 모드(G6).
FAULT_MODES = ("normal", "offline", "unconfirmed", "lost")

MOCK_PURIFIER_ID = "mock-purifier-01"
MOCK_WASHER_ID = "mock-washer-01"
#: 모의 제습기(2026-09-29, G3 세탁 완료 → 제습 시나리오의 대상).
MOCK_DEHUMIDIFIER_ID = "mock-dehumidifier-01"

#: 주입 가능한 이벤트 → (기기, 상태 변경). 세탁기만 둔다.
EVENTS = {
    "wash_complete": (MOCK_WASHER_ID, ("runState", "currentState", "END")),
    "wash_start": (MOCK_WASHER_ID, ("runState", "currentState", "RUNNING")),
}


_CAPABILITIES_BY_DEVICE = {
    MOCK_PURIFIER_ID: AIR_PURIFIER_CAPABILITIES,
    MOCK_DEHUMIDIFIER_ID: DEHUMIDIFIER_CAPABILITIES,
}


def _allowed_values(device_id: str = MOCK_PURIFIER_ID) -> dict[tuple[str, str], tuple[str, ...]]:
    caps = _CAPABILITIES_BY_DEVICE.get(device_id, ())
    return {(c.resource, c.property): c.allowed for c in caps}


class MockThinqClient:
    execution_mode = ExecutionMode.MOCK

    def __init__(
        self,
        *,
        latency_seconds: float = 0.0,
        sleep: Callable[[float], None] | None = None,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self._lock = threading.Lock()
        self._sleep = sleep or time.sleep
        self._now = now or (lambda: datetime.now(timezone.utc))
        self.latency_seconds = latency_seconds
        self.state_delay_reads = 0
        self.drop_state_updates = False
        self._online = True
        self._device_online = {MOCK_PURIFIER_ID: True, MOCK_WASHER_ID: True,
                               MOCK_DEHUMIDIFIER_ID: True}
        self._next_failure: str | None = None
        self._pending: list[tuple[str, str, str, str, int]] = []
        self._ids = itertools.count(1)
        self._devices = {
            MOCK_PURIFIER_ID: ThinqDeviceInfo(
                MOCK_PURIFIER_ID, AIR_PURIFIER_DEVICE_TYPE, "거실 공기청정기(모의)", "MOCK-AP", True
            ),
            MOCK_WASHER_ID: ThinqDeviceInfo(
                MOCK_WASHER_ID, WASHER_DEVICE_TYPE, "세탁기(모의)", "MOCK-WM", True
            ),
            MOCK_DEHUMIDIFIER_ID: ThinqDeviceInfo(
                MOCK_DEHUMIDIFIER_ID, DEHUMIDIFIER_DEVICE_TYPE, "제습기(모의)", "MOCK-DH", True
            ),
        }
        self._state = {
            MOCK_PURIFIER_ID: {
                "operation": {"airPurifierOperationMode": "POWER_OFF"},
                "airFlow": {"windStrength": "LOW"},
                "airPurifierJobMode": {"currentJobMode": "CLEAN"},
            },
            MOCK_WASHER_ID: {"runState": {"currentState": "RUNNING"}},
            MOCK_DEHUMIDIFIER_ID: {"operation": {"dehumidifierOperationMode": "POWER_OFF"}},
        }
        self._faults: dict[str, str] = {}
        self._device_latency: dict[str, float] = {}
        self.controls: list[tuple[str, dict]] = []
        self._events: deque[dict] = deque(maxlen=50)
        self._listeners: list[Callable[[dict], None]] = []

    # ── 장애 주입 ──────────────────────────────────────────────────────────
    def set_online(self, online: bool) -> None:
        with self._lock:
            self._online = online

    def set_device_online(self, device_id: str, online: bool) -> None:
        with self._lock:
            if device_id not in self._devices:
                raise KeyError(device_id)
            self._device_online[device_id] = online

    def fail_next_control(self, kind: str | None) -> None:
        if kind not in (None, "reject", "timeout"):
            raise ValueError("kind must be reject | timeout | None")
        with self._lock:
            self._next_failure = kind

    def set_fault(self, device_id: str, mode: str, latency_ms: int | None = None) -> dict:
        """리허설용 지속 장애(G6). ``normal``이면 장애·지연을 모두 걷어 낸다.

        ``latency_ms``를 주지 않으면 지연은 그대로 둔다(normal은 0으로 되돌림).
        """
        if mode not in FAULT_MODES:
            raise ValueError(f"mode must be one of {', '.join(FAULT_MODES)}")
        if latency_ms is not None and not 0 <= latency_ms <= 30_000:
            raise ValueError("latency_ms must be between 0 and 30000")
        with self._lock:
            if device_id not in self._devices:
                raise KeyError(device_id)
            self._device_online[device_id] = mode != "offline"
            if mode == "normal":
                self._faults.pop(device_id, None)
                self._device_latency.pop(device_id, None)
            else:
                self._faults[device_id] = mode
            if latency_ms is not None:
                if latency_ms:
                    self._device_latency[device_id] = latency_ms / 1000.0
                else:
                    self._device_latency.pop(device_id, None)
            return self._fault_view_locked(device_id)

    def faults(self) -> dict[str, dict]:
        with self._lock:
            return {d: self._fault_view_locked(d) for d in self._devices}

    def _fault_view_locked(self, device_id: str) -> dict:
        return {
            "device_id": device_id,
            "mode": self._faults.get(device_id, "normal"),
            "online": self._device_online[device_id],
            "latency_ms": int(round(self._device_latency.get(device_id, 0.0) * 1000)),
            "execution_mode": "mock",
        }

    def _device_delay(self, device_id: str) -> None:
        with self._lock:
            extra = self._device_latency.get(device_id, 0.0)
        if extra > 0:
            self._sleep(extra)

    @property
    def online(self) -> bool:
        return self._online

    # ── 포트 ──────────────────────────────────────────────────────────────
    def _delay(self) -> None:
        if self.latency_seconds > 0:
            self._sleep(self.latency_seconds)

    def _require_cloud(self) -> None:
        if not self._online:
            raise ThinqOfflineError("ThinQ 클라우드에 연결되지 않았어요(모의)")

    def list_devices(self) -> tuple[ThinqDeviceInfo, ...]:
        self._delay()
        with self._lock:
            self._require_cloud()
            return tuple(
                ThinqDeviceInfo(d.device_id, d.device_type, d.alias, d.model_name,
                                self._device_online[d.device_id])
                for d in self._devices.values()
            )

    def get_status(self, device_id: str) -> dict:
        self._delay()
        self._device_delay(device_id)
        with self._lock:
            self._require_cloud()
            if device_id not in self._devices:
                raise ThinqCommandRejected("1222", "unknown device")
            if not self._device_online[device_id]:
                raise ThinqOfflineError("기기가 오프라인이에요(모의)")
            self._apply_due_locked(device_id)
            return copy.deepcopy(self._state[device_id])

    def post_control(self, device_id: str, payload: dict) -> dict:
        self._delay()
        self._device_delay(device_id)
        with self._lock:
            self._require_cloud()
            if device_id not in self._devices:
                raise ThinqCommandRejected("1222", "unknown device")
            if not self._device_online[device_id]:
                raise ThinqOfflineError("기기가 오프라인이에요(모의)")
            failure, self._next_failure = self._next_failure, None
            if failure == "reject":
                raise ThinqCommandRejected("2305", "command not supported in mode (mock)")
            if device_id == MOCK_WASHER_ID:
                raise ThinqCommandRejected("2201", "read-only device (mock)")
            changes = self._validate_locked(device_id, payload)
            self.controls.append((device_id, copy.deepcopy(payload)))
            fault = self._faults.get(device_id)
            if fault == "lost":
                failure = "timeout"  # 지속 장애: 매번 응답을 잃는다(가전은 받는다)
            if not self.drop_state_updates and fault != "unconfirmed":
                for resource, prop, value in changes:
                    self._pending.append(
                        (device_id, resource, prop, value, self.state_delay_reads)
                    )
                if self.state_delay_reads == 0:
                    self._apply_due_locked(device_id)
            if failure == "timeout":
                # 가전은 받았지만 응답이 사라졌다.
                raise ThinqTransportError("응답을 받지 못했어요(모의)")
            return {"messageId": f"mock-msg-{next(self._ids)}"}

    def _validate_locked(self, device_id: str, payload: dict) -> list[tuple[str, str, str]]:
        allowed = _allowed_values(device_id)
        changes = []
        if not isinstance(payload, dict) or len(payload) != 1:
            raise ThinqCommandRejected("1101", "payload must hold one resource")
        for resource, props in payload.items():
            if not isinstance(props, dict) or len(props) != 1:
                raise ThinqCommandRejected("1101", "resource must hold one property")
            for prop, value in props.items():
                values = allowed.get((resource, prop))
                if values is None or value not in values:
                    raise ThinqCommandRejected("2305", f"{resource}.{prop}={value!r} not supported")
                changes.append((resource, prop, value))
        return changes

    def _apply_due_locked(self, device_id: str) -> None:
        kept = []
        for dev, resource, prop, value, reads_left in self._pending:
            if dev != device_id:
                kept.append((dev, resource, prop, value, reads_left))
            elif reads_left <= 0:
                self._state[dev].setdefault(resource, {})[prop] = value
            else:
                kept.append((dev, resource, prop, value, reads_left - 1))
        self._pending = kept

    # ── 이벤트(세탁 완료 등) ───────────────────────────────────────────────
    def subscribe(self, listener: Callable[[dict], None]) -> None:
        with self._lock:
            self._listeners.append(listener)

    def inject_event(self, event: str) -> dict:
        if event not in EVENTS:
            raise ValueError(f"unknown event '{event}' ({', '.join(EVENTS)})")
        device_id, (resource, prop, value) = EVENTS[event]
        with self._lock:
            self._state[device_id].setdefault(resource, {})[prop] = value
            record = {
                "event": event,
                "device_id": device_id,
                "state": {resource: {prop: value}},
                "at": self._now().isoformat(),
                "execution_mode": "mock",
            }
            self._events.append(record)
            listeners = list(self._listeners)
        for listener in listeners:
            try:
                listener(dict(record))
            except Exception:  # noqa: BLE001 -- 구독자 실패가 주입을 막지 않는다
                import logging  # noqa: PLC0415

                logging.getLogger(__name__).exception("thinq event listener failed")
        return record

    def events(self) -> tuple[dict, ...]:
        with self._lock:
            return tuple(reversed(self._events))
