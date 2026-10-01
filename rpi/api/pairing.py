"""5분짜리 한 폰 연결 창. 생성·승인은 같은 허브의 화면에서만 한다."""

import base64
import hmac
import io
import ipaddress
import math
import os
import secrets
import socket
import threading
import time
from urllib.parse import urlencode, urlsplit

import qrcode
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from rpi.api.auth import is_loopback_host


def _local_screen(request: Request) -> None:
    if not request.client or not is_loopback_host(request.client.host):
        raise HTTPException(403, "허브 화면에서 연결을 승인해 주세요.")
    origin = request.headers.get("origin")
    if origin and (
        origin != str(request.base_url).rstrip("/")
        or not is_loopback_host(urlsplit(origin).hostname)
    ):
        raise HTTPException(403, "허브 화면을 다시 열어 주세요.")


def _no_cache(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"


def _public_host(request: Request) -> str:
    configured = os.getenv("SIMPLELAY_PAIR_HOST", "").strip()
    if configured:
        uri = urlsplit(configured)
        if uri.scheme not in {"http", "https"} or not uri.hostname or uri.username or uri.password or uri.query or uri.fragment or uri.path not in {"", "/"}:
            raise HTTPException(503, "허브 연결 주소를 확인해 주세요.")
        return configured.rstrip("/")
    # 포트는 화면이 접속한 서버와 같다. 다중 네트워크는 명시 설정으로 고른다.
    try:
        addresses = socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
        for info in addresses:
            address = ipaddress.ip_address(info[4][0])
            if address.is_private and not address.is_loopback and not address.is_link_local:
                return f"http://{address}:{request.url.port or 8000}"
    except OSError:
        pass
    raise HTTPException(503, "허브 주소를 찾지 못했어요. 와이파이 연결과 허브 연결 주소를 확인해 주세요.")


class PairingWindow:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.RLock()
        self.session = None

    def _active(self):
        s = self.session
        if s is None or self.clock() >= s["deadline"] or s["key"] != os.getenv("SIMPLELAY_API_KEY", "").strip():
            self.session = None
            raise HTTPException(410, "연결 시간이 지났어요. 허브에서 새 코드를 받아 주세요.")
        return s

    def open(self, host):
        with self.lock:
            key = os.getenv("SIMPLELAY_API_KEY", "").strip()
            if not key:
                raise HTTPException(503, "허브 키를 먼저 설정해 주세요.")
            self.session = {"code": f"{secrets.randbelow(1000000):06d}", "key": key,
                "host": host, "deadline": self.clock() + 300, "attempts": 0,
                "request_id": None, "token": None, "state": "open", "phone": None}
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            s = self._active()
            return {k: s[k] for k in ("code", "host", "request_id", "state", "phone")} | {
                "expires_in": max(0, math.ceil(s["deadline"] - self.clock()))}

    def claim(self, code, phone):
        with self.lock:
            s = self._active()
            if s["attempts"] >= 5:
                raise HTTPException(429, "코드를 여러 번 확인했어요. 허브에서 새 코드를 받아 주세요.")
            s["attempts"] += 1
            if not hmac.compare_digest(s["code"], code):
                raise HTTPException(400, "코드가 맞지 않아요. 허브 화면의 여섯 자리를 확인해 주세요.")
            if s["state"] != "open":
                raise HTTPException(409, "이미 사용한 코드예요. 허브에서 새 코드를 받아 주세요.")
            s.update(request_id=secrets.token_urlsafe(24), token=secrets.token_urlsafe(32), state="pending", phone=phone)
            return {"token": s["token"], "request_id": s["request_id"], "state": "pending", "expires_in": self.snapshot()["expires_in"]}

    def decide(self, request_id, approved):
        with self.lock:
            s = self._active()
            if s["state"] != "pending" or not hmac.compare_digest(s["request_id"] or "", request_id):
                raise HTTPException(409, "연결 요청이 바뀌었어요. 화면을 다시 확인해 주세요.")
            s["state"] = "approved" if approved else "denied"
            return {"state": s["state"]}

    def result(self, token):
        with self.lock:
            s = self._active()
            if not hmac.compare_digest(s["token"] or "", token):
                raise HTTPException(404, "연결 요청을 찾지 못했어요.")
            result = {"state": s["state"]}
            if s["state"] == "approved":
                result["api_key"] = s["key"]
                s["state"] = "consumed"
                s["token"] = None
            return result

    def cancel(self):
        with self.lock:
            self.session = None


pairing_window = PairingWindow()
pairing_router = APIRouter(prefix="/pair", dependencies=[Depends(_no_cache)])


class Claim(BaseModel):
    code: str = Field(pattern=r"^[0-9]{6}$")
    phone: str = Field(default="내 폰", min_length=1, max_length=40)


class Decision(BaseModel):
    request_id: str = Field(min_length=20, max_length=100)
    approved: bool


class Receipt(BaseModel):
    token: str = Field(min_length=20, max_length=100)


@pairing_router.post("/session", dependencies=[Depends(_local_screen)])
def open_session(request: Request):
    result = pairing_window.open(_public_host(request))
    uri = "simplelay://pair?" + urlencode({"host": result["host"], "code": result["code"]})
    buffer = io.BytesIO()
    qrcode.make(uri).save(buffer, format="PNG")
    return result | {"uri": uri, "qr_png": base64.b64encode(buffer.getvalue()).decode("ascii")}


@pairing_router.get("/session", dependencies=[Depends(_local_screen)])
def session():
    return pairing_window.snapshot()


@pairing_router.delete("/session", dependencies=[Depends(_local_screen)])
def cancel_session():
    pairing_window.cancel()
    return {"state": "closed"}


@pairing_router.post("")
def claim(body: Claim):
    return pairing_window.claim(body.code, body.phone)


@pairing_router.post("/approve", dependencies=[Depends(_local_screen)])
def approve(body: Decision):
    return pairing_window.decide(body.request_id, body.approved)


@pairing_router.post("/result")
def result(body: Receipt):
    return pairing_window.result(body.token)
