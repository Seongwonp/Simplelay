"""모의 ThinQ 클라우드 — 공식 SDK가 보내는 요청을 받아 흉내 내는 로컬 HTTP 서버.

**실제 ThinQ 클라우드가 아니다.** 이 기기 안(127.0.0.1)에서만 열린다. 공식 SDK
(``thinqconnect`` 1.0.14)의 ``ThinQApi``가 만드는 요청 -- 경로(``devices``,
``devices/{id}/profile``, ``devices/{id}/state``, ``devices/{id}/control``), 머리글,
JSON 본문 -- 을 그대로 받고, 응답은 SDK가 읽는 봉투(성공 ``{"response": ...}``, 실패
``{"error": {"code", "message"}}``)로 돌려준다. 프로필·상태 샘플은
``rpi/services/thinq/profiles_sample.py``(공개 SDK 형식의 예시)다.

받은 요청은 ``requests()``에 남긴다: 방법·경로·**머리글 이름**·본문, 그리고 비밀이 아닌 값
몇 개(``x-country``·``x-service-phase``·``x-conditional-control``)와 판정값(토큰 일치·클라이언트
ID가 UUID인지). 토큰·API 키 값은 기록하지 않는다.

장애 주입(``set_fault``, 또는 HTTP ``POST /__fake__/fault``):

- ``invalid_token`` · ``terms`` · ``not_allowed`` · ``country`` · ``rate_limit`` · ``internal_error``
  -- 모든 요청을 그 오류 코드로 거절(공식 SDK 오류 코드 값).
- ``offline`` -- 그 기기 조회·제어에 ``NOT_CONNECTED_DEVICE``.
- ``drop_control_response`` -- 제어를 **받아 상태를 바꾼 뒤** 응답 없이 연결을 끊는다(응답 유실).
- ``freeze_state`` -- 제어를 접수(성공 응답)하지만 상태는 바꾸지 않는다(접수 후 상태 미확인).

세탁기는 ``remoteControlEnable.remoteControlEnabled``가 꺼져 있으면(기본 꺼짐) 제어를
``COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF``로 거절한다. 프로필에 없는 속성·값도 거절한다.

실행::

    python -m rpi.tools.fake_thinq_cloud --port 8790
    # 다른 창에서
    SIMPLELAY_THINQ_MODE=fake_cloud SIMPLELAY_THINQ_FAKE_CLOUD_URL=http://127.0.0.1:8790 \\
        SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER=fake-ap-0001 ... uvicorn rpi.main:app
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from rpi.services.thinq.errors import API_ERROR_CODES
from rpi.services.thinq.profile import DeviceProfile
from rpi.services.thinq.profiles_sample import (
    air_purifier_profile,
    air_purifier_state,
    dehumidifier_profile,
    dehumidifier_state,
    washer_profile,
    washer_state,
)

#: 모의 클라우드 전용 토큰 -- fake_cloud 모드는 실제 PAT를 쓰지 않는다.
FAKE_CLOUD_TOKEN = "fake-cloud-token"
LOOPBACK = ("127.0.0.1", "localhost", "::1")

#: 장애 이름 → (HTTP 상태, 오류 이름). 모든 요청에 걸린다.
GLOBAL_FAULTS = {
    "invalid_token": (401, "INVALID_TOKEN"),
    "terms": (400, "NOT_ACCEPTABLE_TERMS"),
    "not_allowed": (403, "NOT_ALLOWED_API_AGAIN"),
    "country": (400, "NOT_SUPPORTED_COUNTRY"),
    "rate_limit": (429, "EXCEEDED_API_CALLS"),
    "internal_error": (500, "INTERNAL_SERVER_ERROR"),
}
DEVICE_FAULTS = ("offline", "drop_control_response", "freeze_state")
FAULTS = tuple(GLOBAL_FAULTS) + DEVICE_FAULTS

_PUBLIC_HEADERS = ("x-country", "x-service-phase", "x-conditional-control")
_PATH = re.compile(r"^/devices(?:/([^/]+)/(profile|state|control))?$")

#: 세탁기 운전 명령 → 바뀌는 운전 상태(모의 규칙).
_WASHER_RUN = {"START": "RUNNING", "STOP": "PAUSE", "POWER_OFF": "POWER_OFF", "WAKE_UP": "INITIAL"}


def default_devices() -> dict[str, dict]:
    return {
        "fake-ap-0001": {"kind": "air_purifier", "type": "DEVICE_AIR_PURIFIER", "model": "FAKE-AP",
                         "alias": "공기청정기(모의 클라우드)", "profile": air_purifier_profile(),
                         "state": air_purifier_state()},
        "fake-dh-0001": {"kind": "dehumidifier", "type": "DEVICE_DEHUMIDIFIER", "model": "FAKE-DH",
                         "alias": "제습기(모의 클라우드)", "profile": dehumidifier_profile(),
                         "state": dehumidifier_state()},
        "fake-wm-0001": {"kind": "washer", "type": "DEVICE_WASHER", "model": "FAKE-WM",
                         "alias": "세탁기(모의 클라우드)", "profile": washer_profile(),
                         "state": washer_state()},
    }


class FakeThinqCloud:
    def __init__(self, *, token: str = FAKE_CLOUD_TOKEN, devices: dict[str, dict] | None = None) -> None:
        self._token = token
        self._lock = threading.Lock()
        self._devices = devices or default_devices()
        self._requests: list[dict] = []
        self._global_fault: str | None = None
        self._device_faults: dict[str, str] = {}
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    # ── 수명 ──────────────────────────────────────────────────────────────
    def start(self, host: str = "127.0.0.1", port: int = 0) -> str:
        if host not in LOOPBACK:
            raise ValueError("모의 클라우드는 이 기기 안 주소(127.0.0.1·localhost)에서만 엽니다")
        cloud = self

        class Handler(_Handler):
            fake = cloud

        self._server = ThreadingHTTPServer((host, port), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, name="fake-thinq-cloud",
                                        daemon=True)
        self._thread.start()
        return self.base_url

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None

    @property
    def base_url(self) -> str:
        assert self._server is not None, "start() first"
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    # ── 시험·리허설 조작 ───────────────────────────────────────────────────
    def device_id(self, kind: str) -> str:
        return next(d for d, info in self._devices.items() if info["kind"] == kind)

    def set_fault(self, kind: str | None, *, device_id: str | None = None) -> None:
        if kind is not None and kind not in FAULTS:
            raise ValueError(f"fault must be one of {', '.join(FAULTS)}")
        with self._lock:
            if kind in DEVICE_FAULTS or (kind is None and device_id is not None):
                if device_id not in self._devices:
                    raise KeyError(device_id)
                if kind is None:
                    self._device_faults.pop(device_id, None)
                else:
                    self._device_faults[device_id] = kind
            elif kind is None:
                self._global_fault = None
                self._device_faults.clear()
            else:
                self._global_fault = kind

    def set_remote_control(self, device_id: str, enabled: bool) -> None:
        with self._lock:
            state = self._devices[device_id]["state"]
            for entry in state if isinstance(state, list) else [state]:
                entry.setdefault("remoteControlEnable", {})["remoteControlEnabled"] = bool(enabled)

    def state(self, device_id: str):
        with self._lock:
            return copy.deepcopy(self._devices[device_id]["state"])

    def requests(self) -> list[dict]:
        with self._lock:
            return copy.deepcopy(self._requests)

    def controls(self) -> list[dict]:
        return [r for r in self.requests() if r["method"] == "POST"]

    # ── 요청 처리 ──────────────────────────────────────────────────────────
    def _record(self, method: str, path: str, headers, body) -> None:
        auth = headers.get("Authorization", "")
        scheme, _, credential = auth.partition(" ")
        client_id = headers.get("x-client-id", "")
        try:
            client_id_is_uuid = uuid.UUID(client_id).version == 4
        except ValueError:
            client_id_is_uuid = False
        entry = {
            "at": time.time(),
            "method": method,
            "path": path,
            "header_names": sorted({k.lower() for k in headers.keys()}),
            "public_headers": {k: headers.get(k) for k in _PUBLIC_HEADERS if headers.get(k) is not None},
            "auth_scheme": scheme or None,
            "token_ok": scheme == "Bearer" and credential == self._token,
            "client_id_is_uuid": client_id_is_uuid,
            "body": body,
        }
        with self._lock:
            self._requests.append(entry)

    def handle(self, method: str, path: str, headers, body) -> tuple[int, dict] | None:
        """(HTTP 상태, 응답 봉투). None이면 응답 없이 연결을 끊는다."""
        self._record(method, path, headers, body)
        match = _PATH.match(path)
        if match is None:
            return 404, _error("NOT_EXIST_DEVICE", "unknown path")
        with self._lock:
            fault = self._global_fault
        auth = headers.get("Authorization", "")
        if fault is None and auth != f"Bearer {self._token}":
            fault = "invalid_token"
        if fault is not None:
            status, name = GLOBAL_FAULTS[fault]
            return status, _error(name, f"fake cloud: {fault}")
        device_id, what = match.group(1), match.group(2)
        if device_id is None:
            if method != "GET":
                return 405, _error("BAD_REQUEST", "method")
            return 200, _ok(self._device_list())
        with self._lock:
            device = self._devices.get(device_id)
            device_fault = self._device_faults.get(device_id)
        if device is None:
            return 400, _error("NOT_EXIST_DEVICE", "no such device")
        if what == "profile" and method == "GET":
            return 200, _ok(copy.deepcopy(device["profile"]))
        if device_fault == "offline":
            return 400, _error("NOT_CONNECTED_DEVICE", "device offline")
        if what == "state" and method == "GET":
            with self._lock:
                return 200, _ok(copy.deepcopy(device["state"]))
        if what == "control" and method == "POST":
            return self._control(device_id, device, device_fault, body)
        return 405, _error("BAD_REQUEST", "method")

    def _device_list(self) -> list[dict]:
        return [
            {"deviceId": device_id,
             "deviceInfo": {"deviceType": info["type"], "modelName": info["model"],
                            "alias": info["alias"], "reportable": True}}
            for device_id, info in self._devices.items()
        ]

    def _control(self, device_id: str, device: dict, fault: str | None, body) -> tuple[int, dict] | None:
        if not isinstance(body, dict):
            return 400, _error("MISSING_PARAMETERS", "body must be an object")
        body = dict(body)
        location = None
        if isinstance(body.get("location"), dict):
            location = body.pop("location").get("locationName")
        profile = DeviceProfile(device["profile"])
        if profile.locations and location is None:
            return 400, _error("MISSING_PARAMETERS", "location required")
        changes = []
        for resource, props in body.items():
            if not isinstance(props, dict) or not props:
                return 400, _error("MISSING_PARAMETERS", "resource must hold properties")
            for prop, value in props.items():
                spec = profile.spec(resource, prop, location=location)
                if spec is None or not spec.accepts(value):
                    return 400, _error("NOT_PROVIDED_FEATURE", f"{resource}.{prop} not writable")
                changes.append((resource, prop, value))
        with self._lock:
            state = device["state"]
            entry = _location_entry(state, location)
            if device["kind"] == "washer":
                remote = (entry.get("remoteControlEnable") or {}).get("remoteControlEnabled")
                if remote is not True:
                    return 400, _error("COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF", "remote control off")
            if fault != "freeze_state":
                for resource, prop, value in changes:
                    if device["kind"] == "washer" and (resource, prop) == ("operation", "washerOperationMode"):
                        entry.setdefault("runState", {})["currentState"] = _WASHER_RUN.get(value, value)
                    else:
                        entry.setdefault(resource, {})[prop] = value
        if fault == "drop_control_response":
            return None
        return 200, _ok({})


def _location_entry(state, location):
    if isinstance(state, list):
        return next(e for e in state if (e.get("location") or {}).get("locationName") == location)
    return state


def _ok(response) -> dict:
    return {"messageId": uuid.uuid4().hex[:22], "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "response": response}


def _error(name: str, message: str) -> dict:
    return {"messageId": uuid.uuid4().hex[:22], "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "error": {"code": API_ERROR_CODES[name], "message": message}}


class _Handler(BaseHTTPRequestHandler):
    fake: FakeThinqCloud
    protocol_version = "HTTP/1.1"

    def log_message(self, *args) -> None:  # 머리글·토큰이 섞일 수 있는 기본 접근 로그를 끈다
        return

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return None
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {"_unparsed": True}

    def _admin(self, method: str) -> bool:
        if not self.path.startswith("/__fake__/"):
            return False
        body = self._body() if method == "POST" else None
        try:
            if self.path == "/__fake__/requests" and method == "GET":
                self._send(200, {"requests": self.fake.requests()})
            elif self.path == "/__fake__/fault" and method == "POST":
                self.fake.set_fault((body or {}).get("kind"), device_id=(body or {}).get("device_id"))
                self._send(200, {"ok": True})
            elif self.path == "/__fake__/remote" and method == "POST":
                self.fake.set_remote_control(body["device_id"], bool(body["enabled"]))
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "unknown admin path"})
        except (KeyError, ValueError, TypeError) as exc:
            self._send(400, {"error": str(exc)})
        return True

    def _dispatch(self, method: str) -> None:
        if self._admin(method):
            return
        body = self._body() if method == "POST" else None
        result = self.fake.handle(method, self.path.split("?", 1)[0], self.headers, body)
        if result is None:
            self.close_connection = True
            try:
                self.connection.shutdown(2)
            except OSError:
                pass
            return
        self._send(*result)

    def _send(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="모의 ThinQ 클라우드(로컬 전용, 실제 클라우드 아님)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8790)
    args = parser.parse_args(argv)
    cloud = FakeThinqCloud()
    url = cloud.start(args.host, args.port)
    print(f"모의 ThinQ 클라우드: {url} (실제 클라우드 아님)")
    for device_id, info in cloud._devices.items():
        print(f"  {device_id}  {info['type']}  {info['alias']}")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        cloud.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
