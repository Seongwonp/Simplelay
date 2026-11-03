"""발표 슬라이드 로컬 서버 — 정적 파일 + 본체 읽기 전용 프록시(파이썬 표준 라이브러리만).

- ``/``·``/index.html`` 등: 이 폴더의 정적 파일.
- ``/api/<경로>``: ``SIMPLELAY_HUB_URL``의 ``/<경로>``로 전달하고, 서버 쪽에서 ``X-API-Key``(``SIMPLELAY_API_KEY``)를 붙인다.
  키는 브라우저로 가지 않는다(HTML·JS에 키를 두지 않기 위해 프록시를 둔다).

**GET만, 정해 둔 경로만 전달한다.** 이번 판의 슬라이드는 기기를 움직이는 요청을 보내지 않는다. POST·PUT 등은 405로 거절하고,
GET이라도 아래 목록에 없는 경로는 404로 거절한다(본체에는 GET이라도 연습용 상태를 보여 주는 경로가 있어, 열어 둘 이유가 없다).
요청을 새로 만들어 보내므로 브라우저의 Origin·Cookie 같은 헤더는 본체로 넘어가지 않는다.

실행: ``python serve.py`` (기본 http://localhost:8765, 포트는 ``DECK_PORT``).
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from functools import partial
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DECK_DIR = Path(__file__).resolve().parent
HUB_URL_ENV = "SIMPLELAY_HUB_URL"
API_KEY_ENV = "SIMPLELAY_API_KEY"
PORT_ENV = "DECK_PORT"
DEFAULT_PORT = 8765
HUB_TIMEOUT_S = 4.0
MAX_BODY = 2 * 1024 * 1024

#: 슬라이드가 읽는 본체 경로(/api 뒤). 새 장이 다른 값을 읽게 되면 여기에 더한다.
ALLOWED_PATHS = (
    re.compile(r"^/health$"),
    re.compile(r"^/status$"),
    re.compile(r"^/presence/room$"),
    re.compile(r"^/learning$"),
    re.compile(r"^/history$"),  # 모은 기록 장(실행 기록, 쿼리 limit만 쓴다)
    re.compile(r"^/jobs/[A-Za-z0-9._:-]{1,128}$"),
)


def hub_base() -> str | None:
    raw = os.environ.get(HUB_URL_ENV, "").strip().rstrip("/")
    if not raw:
        return None
    parsed = urllib.parse.urlsplit(raw)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
        return None
    return raw


class DeckHandler(SimpleHTTPRequestHandler):
    server_version = "SimpleLayDeck/1"

    # 정적 파일 캐시 끄기 — 발표 직전에 고친 파일이 바로 보이게.
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def do_GET(self) -> None:  # noqa: N802 - http.server 규약
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api" or path.startswith("/api/"):
            self._proxy()
            return
        if path.lower().endswith(".py"):
            self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        super().do_GET()

    def do_HEAD(self) -> None:  # noqa: N802
        if urllib.parse.urlsplit(self.path).path.startswith("/api"):
            self._reject_method()
            return
        super().do_HEAD()

    def _reject_method(self) -> None:
        self._json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "read_only", "detail": "발표 프록시는 GET만 전달합니다"},
                   extra={"Allow": "GET"})

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _reject_method  # noqa: N815

    def _proxy(self) -> None:
        split = urllib.parse.urlsplit(self.path)
        sub = split.path[len("/api"):] or "/"
        if not any(p.match(sub) for p in ALLOWED_PATHS):
            self._json(HTTPStatus.NOT_FOUND, {"error": "not_allowed", "detail": "슬라이드가 읽는 경로가 아닙니다"})
            return
        base = hub_base()
        if base is None:
            self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "hub_not_configured"})
            return
        url = base + sub + (("?" + split.query) if split.query else "")
        req = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
        key = os.environ.get(API_KEY_ENV, "").strip()
        if key:
            req.add_header("X-API-Key", key)
        try:
            with urllib.request.urlopen(req, timeout=HUB_TIMEOUT_S) as res:  # noqa: S310 - 주소는 운영자가 env로 정한다
                body = res.read(MAX_BODY + 1)
                status = res.status
                ctype = res.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as exc:
            # 본체의 거절(401 등)은 상태 코드만 넘긴다 — 본문에 설정 안내가 있어도 무대 화면에는 필요 없다.
            self._json(exc.code, {"error": "hub_error", "status": exc.code})
            return
        except (urllib.error.URLError, TimeoutError, OSError):
            self._json(HTTPStatus.BAD_GATEWAY, {"error": "hub_unreachable"})
            return
        if len(body) > MAX_BODY:
            self._json(HTTPStatus.BAD_GATEWAY, {"error": "hub_response_too_large"})
            return
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, doc: dict, extra: dict | None = None) -> None:
        body = json.dumps(doc, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        # 요청 줄만 남긴다(헤더·키는 찍지 않는다).
        sys.stderr.write("[deck] " + (fmt % args) + "\n")


def main() -> int:
    port = int(os.environ.get(PORT_ENV, DEFAULT_PORT))
    base = hub_base()
    if base is None:
        print(f"[deck] {HUB_URL_ENV}가 없거나 잘못됐습니다 — 본체 없이 미리보기로만 엽니다.")
    elif not os.environ.get(API_KEY_ENV, "").strip():
        print(f"[deck] {API_KEY_ENV}가 없습니다 — 본체가 키를 요구하면 실시간 값이 401로 막힙니다.")
    else:
        print("[deck] 본체 프록시 켜짐(GET만, 키는 서버 쪽에서만 붙임).")
    handler = partial(DeckHandler, directory=str(DECK_DIR))
    server = ThreadingHTTPServer(("localhost", port), handler)
    print(f"[deck] http://localhost:{port}/  — 브라우저로 열고 P로 발표자 창, F로 전체 화면")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
