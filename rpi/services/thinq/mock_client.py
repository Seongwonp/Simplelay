"""모의 ThinQ 클라이언트 — 네트워크·PAT 없이 계약을 돌려 보는 대역 (U1-c).

기기 세 대:

- 공기청정기 ``mock-purifier-01`` -- 전원·풍량·운전 모드 쓰기 가능. 센서 칸(``airQualitySensor``, 기본 좋음)은 기본으로
  **전원이 켜져 있을 때만** 상태에 싣는다(ThinQ 앱 공기질 센서 설정 '운전 중에만' — 꺼져 있으면 칸이 없다). ``air_sensor_always``
  (허브는 ``SIMPLELAY_THINQ_MOCK_AIR_SENSOR_ALWAYS``)를 켜면 꺼져 있어도 싣는다(설정 '항상' — 2026-10-15 저녁 실물 조회와 같다).
  ``set_air_quality``로 모의 센서 값을 바꾼다(리허설 ``POST /demo/thinq/air-quality``, mock 모드만). ``None``이면 칸을 지운다
  (켠 직후 센서 준비 중 흉내).
- 세탁기 ``mock-washer-01`` -- 시작·일시정지(``operation.washerOperationMode``, 위치 ``MAIN``).
  **원격 제어는 기본 꺼짐**(``set_remote_control(True)``로 켠다) -- 꺼져 있으면 제어를 거절한다.
  ``inject_event("wash_complete")``로 세탁 완료를 흉내 낸다(상태 ``runState.currentState`` → ``END``).

프로필은 ``profiles_sample``의 예시(공개 SDK 형식)이고 ``set_profile``로 바꿀 수 있다 --
제어는 그 프로필로 검사한다(프로필에 없는 속성·값은 거절).
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
import os
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from datetime import datetime, timezone

from rpi.controller.models import ExecutionMode

from .bindings import (
    AIR_PURIFIER_DEVICE_TYPE,
    DEHUMIDIFIER_DEVICE_TYPE,
    WASHER_DEVICE_TYPE,
)
from .client import (
    ThinqCommandRejected,
    ThinqDeviceInfo,
    ThinqOfflineError,
    ThinqTransportError,
)
from .errors import API_ERROR_CODES, error_from_api
from .profile import DeviceProfile
from .profiles_sample import air_purifier_profile, air_sensor_sample, dehumidifier_profile, washer_profile

#: 지속 장애 모드(G6).
FAULT_MODES = ("normal", "offline", "unconfirmed", "lost")

MOCK_PURIFIER_ID = "mock-purifier-01"
MOCK_WASHER_ID = "mock-washer-01"
#: 모의 제습기(2026-09-29, G3 세탁 완료 → 제습 시나리오의 대상).
MOCK_DEHUMIDIFIER_ID = "mock-dehumidifier-01"

#: 모의 공기청정기 센서를 꺼져 있을 때도 싣는가(ThinQ 앱 공기질 센서 '항상' 흉내). 기본 꺼짐('운전 중에만').
AIR_SENSOR_ALWAYS_ENV = "SIMPLELAY_THINQ_MOCK_AIR_SENSOR_ALWAYS"


def air_sensor_always_from_env(env: Mapping[str, str] | None = None) -> bool:
    """``1``·``true``·``yes``·``on``이면 참. 그 밖(비움 포함)은 거짓(예전 설정 '운전 중에만')."""
    env = os.environ if env is None else env
    return (env.get(AIR_SENSOR_ALWAYS_ENV) or "").strip().lower() in {"1", "true", "yes", "on"}


#: 주입 가능한 이벤트 → (기기, 상태 변경). 세탁기만 둔다.
EVENTS = {
    "wash_complete": (MOCK_WASHER_ID, ("runState", "currentState", "END")),
    "wash_start": (MOCK_WASHER_ID, ("runState", "currentState", "RUNNING")),
}


#: 세탁기 운전 명령 → 바뀌는 운전 상태(모의 규칙).
_WASHER_RUN = {"START": "RUNNING", "STOP": "PAUSE", "POWER_OFF": "POWER_OFF", "WAKE_UP": "INITIAL"}


def _api_error(name: str):
    return error_from_api(API_ERROR_CODES[name], name)


class MockThinqClient:
    execution_mode = ExecutionMode.MOCK

    def __init__(
        self,
        *,
        latency_seconds: float = 0.0,
        sleep: Callable[[float], None] | None = None,
        now: Callable[[], datetime] | None = None,
        air_sensor_always: bool = False,
    ) -> None:
        self._lock = threading.Lock()
        #: 참이면 센서 칸을 전원과 상관없이 싣는다(설정 '항상'). 거짓이면 켜져 있을 때만('운전 중에만').
        self.air_sensor_always = bool(air_sensor_always)
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
            MOCK_WASHER_ID: {"runState": {"currentState": "RUNNING"},
                             "remoteControlEnable": {"remoteControlEnabled": False}},
            MOCK_DEHUMIDIFIER_ID: {"operation": {"dehumidifierOperationMode": "POWER_OFF"}},
        }
        self._profiles = {
            MOCK_PURIFIER_ID: air_purifier_profile(),
            MOCK_WASHER_ID: washer_profile(),
            MOCK_DEHUMIDIFIER_ID: dehumidifier_profile(),
        }
        #: 모의 공기청정기 센서 칸 — 전원이 켜져 있을 때만(``air_sensor_always``면 늘) 조회에 싣는다. None이면 칸 없음.
        self._air_sensor: dict | None = air_sensor_sample("GOOD")
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

    def set_profile(self, device_id: str, profile: dict) -> None:
        """그 기기의 프로필을 바꾼다(모델마다 다른 프로필 흉내)."""
        with self._lock:
            if device_id not in self._devices:
                raise KeyError(device_id)
            self._profiles[device_id] = copy.deepcopy(profile)

    def set_remote_control(self, enabled: bool) -> None:
        """세탁기 본체의 원격 제어(원격 시작) 허용 스위치."""
        with self._lock:
            self._state[MOCK_WASHER_ID].setdefault("remoteControlEnable", {})[
                "remoteControlEnabled"] = bool(enabled)

    def set_air_quality(self, sensor: dict | None) -> dict | None:
        """모의 공기청정기 센서 칸을 바꾼다(모의). None이면 칸을 지운다. 전원이 꺼져 있으면 ``air_sensor_always``일 때만 실린다."""
        with self._lock:
            self._air_sensor = copy.deepcopy(sensor) if sensor else None
            return copy.deepcopy(self._air_sensor)

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

    def get_profile(self, device_id: str) -> dict:
        self._delay()
        with self._lock:
            self._require_cloud()
            if device_id not in self._devices:
                raise _api_error("NOT_EXIST_DEVICE")
            return copy.deepcopy(self._profiles[device_id])

    def get_status(self, device_id: str) -> dict:
        self._delay()
        self._device_delay(device_id)
        with self._lock:
            self._require_cloud()
            if device_id not in self._devices:
                raise _api_error("NOT_EXIST_DEVICE")
            if not self._device_online[device_id]:
                raise ThinqOfflineError("기기가 오프라인이에요(모의)")
            self._apply_due_locked(device_id)
            state = copy.deepcopy(self._state[device_id])
            if (device_id == MOCK_PURIFIER_ID and self._air_sensor
                    and (self.air_sensor_always
                         or state.get("operation", {}).get("airPurifierOperationMode") == "POWER_ON")):
                state["airQualitySensor"] = copy.deepcopy(self._air_sensor)
            return state

    def post_control(self, device_id: str, payload: dict) -> dict:
        self._delay()
        self._device_delay(device_id)
        with self._lock:
            self._require_cloud()
            if device_id not in self._devices:
                raise _api_error("NOT_EXIST_DEVICE")
            if not self._device_online[device_id]:
                raise ThinqOfflineError("기기가 오프라인이에요(모의)")
            failure, self._next_failure = self._next_failure, None
            if failure == "reject":
                raise _api_error("COMMAND_NOT_SUPPORTED_IN_MODE")
            changes = self._validate_locked(device_id, payload)
            if device_id == MOCK_WASHER_ID:
                remote = self._state[device_id].get("remoteControlEnable", {}).get("remoteControlEnabled")
                if remote is not True:
                    raise _api_error("COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF")
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
        """그 기기 프로필로 검사한다 -- 프로필에 없는 속성·쓰기 아닌 속성·목록 밖 값은 거절."""
        profile = DeviceProfile(self._profiles[device_id])
        changes = []
        if not isinstance(payload, dict):
            raise _api_error("MISSING_PARAMETERS")
        body = dict(payload)
        location = None
        if isinstance(body.get("location"), dict):
            location = body.pop("location").get("locationName")
        if len(body) != 1:
            raise ThinqCommandRejected(API_ERROR_CODES["MISSING_PARAMETERS"],
                                       "payload must hold one resource")
        for resource, props in body.items():
            if not isinstance(props, dict) or len(props) != 1:
                raise ThinqCommandRejected(API_ERROR_CODES["MISSING_PARAMETERS"],
                                           "resource must hold one property")
            for prop, value in props.items():
                spec = profile.spec(resource, prop, location=location)
                if spec is None or not spec.accepts(value):
                    raise _api_error("NOT_PROVIDED_FEATURE")
                if device_id == MOCK_WASHER_ID and (resource, prop) == ("operation", "washerOperationMode"):
                    changes.append(("runState", "currentState", _WASHER_RUN.get(value, value)))
                else:
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
