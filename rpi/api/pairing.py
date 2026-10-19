"""5분짜리 한 폰 연결 창. 생성·승인은 같은 허브의 화면에서만 한다.

계약(검토 10/19 — 키 응답을 잃은 폰 복구, 옛 폰은 그대로 동작):

- ``POST /pair/session``(허브 화면) → 6자리 코드·QR. 새 창을 열면 앞 창의 요청·토큰은 모두 무효.
- ``POST /pair`` ``{code, phone}`` → ``{token, request_id, state: "pending"}``. 창 하나에 폰 하나(두 번째는 409), 코드 확인은
  창마다 5번까지(429).
- ``POST /pair/approve``(허브 화면) → 허락·거절.
- ``POST /pair/result`` ``{token}`` → ``{"state": "pending"|"denied"}`` 또는 허락됐으면 ``{"state": "approved", "api_key"}``.
  **허락된 뒤에는 받았음 알림 전까지(창이 열려 있는 5분 안) 같은 토큰으로 몇 번이고 같은 키를 돌려준다** — 예전에는 첫
  응답에서 토큰을 지워, 그 응답을 잃은 폰은 영영 404였다. 허브 화면 상태는 키를 한 번 보냈으면 ``consumed``.
- ``POST /pair/ack`` ``{token}``(선택) → ``{"state": "consumed"}``. 폰이 키를 저장한 뒤 보내면 그 토큰으로는 더 받을 수 없다
  (결과 조회는 404). 다시 보내도 같은 답, 허락 전이면 409, 모르는 토큰 404.
- 창이 끝나면(5분·닫기·새 창·허브 키 변경) 결과·알림 모두 410 — 받았음 알림을 보내지 않은 옛 폰도 키 재조회는 창 안에서만.
"""

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

from rpi.api.auth import is_loopback_host, loopback_origin_problem


def _local_screen(request: Request) -> None:
    if not request.client or not is_loopback_host(request.client.host):
        raise HTTPException(403, "허브 화면에서 연결을 승인해 주세요.")
    # 출처는 요청 Host가 아니라 설정된 키오스크 주소로 본다(2026-10-14, auth.py 머리말). Origin: null·다른 사이트 거절.
    if loopback_origin_problem(request) is not None:
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
                "request_id": None, "token": None, "state": "open", "phone": None, "delivered": False}
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            s = self._active()
            # 허브 화면에는 키를 한 번 보냈으면 'consumed'(옛 화면 문구 '폰에 연결 정보를 보냈어요' 그대로).
            state = "consumed" if s["state"] == "approved" and s.get("delivered") else s["state"]
            return {k: s[k] for k in ("code", "host", "request_id", "phone")} | {
                "state": state, "expires_in": max(0, math.ceil(s["deadline"] - self.clock()))}

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

    def _owned(self, token):
        s = self._active()
        if not hmac.compare_digest(s["token"] or "", token):
            raise HTTPException(404, "연결 요청을 찾지 못했어요.")
        return s

    def result(self, token):
        with self.lock:
            s = self._owned(token)
            if s["state"] == "consumed":
                raise HTTPException(404, "연결 요청을 찾지 못했어요.")
            if s["state"] == "approved":
                # 응답을 잃은 폰이 다시 물어도 같은 키를 준다(검토 10/19) — 받았음 알림(ack)이나 창 만료까지.
                s["delivered"] = True
                return {"state": "approved", "api_key": s["key"]}
            return {"state": s["state"]}

    def ack(self, token):
        with self.lock:
            s = self._owned(token)
            if s["state"] == "consumed":
                return {"state": "consumed"}
            if s["state"] != "approved":
                raise HTTPException(409, "아직 허브에서 연결을 허락하지 않았어요.")
            # 토큰은 지우지 않고 상태만 끝낸다 — 받았음 알림을 다시 보내도 같은 답(결과 조회는 이제 404).
            s["state"] = "consumed"
            return {"state": "consumed"}

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


@pairing_router.post("/ack")
def ack(body: Receipt):
    return pairing_window.ack(body.token)
