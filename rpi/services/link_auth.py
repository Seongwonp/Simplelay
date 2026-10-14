"""RPi5↔RPi4 링크 인증(2026-10-12, 무선 전환 뒤) — 짝 키(``SIMPLELAY_LINK_KEY``) + 프레임마다 HMAC + 재전송 막기.

링크가 TCP(``socket://<RPi4>:7000``)가 되면서 같은 Wi-Fi의 누구나 RPi4에 ``execute``·``dev_motion``을 보낼 수
있었다. 두 보드가 같은 긴 키 K를 갖고 아래 봉투로만 주고받는다(docs/protocol.md "링크 인증").

  hello       {"type":"hello","cn":<16바이트 hex>,"mac":HMAC(K, 정규형)}                     RPi5 → RPi4
  hello 답    act_info {...,"cn":cn,"sn":<16바이트 hex>,"mac":HMAC(K, 정규형)}               RPi4 → RPi5
  그 뒤 전부  {...,"seq":n,"mac":HMAC(sk, 정규형)}  sk = HMAC(K, "simplelay-link-v1|cn|sn")   양방향

정규형은 ``mac``을 뺀 문서의 ``json.dumps(sort_keys=True, separators=(",",":"), ensure_ascii=False)``다.
``seq``는 방향마다 세션 안에서 1부터 엄격히 늘어난다. 받는 쪽은 서명 없음·MAC 틀림·``seq`` 되돌림을 버린다
(답하지 않는다). 정지(``abort``·``estop_ack``)도 같은 규칙이다 — 위조 정지도 공격 경로라 예외를 두지 않는다.

키는 로그·응답·기록에 남기지 않는다. 이 모듈은 이벤트 루프 스레드 하나에서만 부른다(``seq`` 순서 = 줄 순서).

**키는 필수다(2026-10-14 보안 1차 점검 HIGH).** 전에는 키가 없으면 경고만 남기고 인증 없이 돌았다. 이제 두 운영
진입점(RPi4 ``act_main._run``·RPi5 ``open_uart_act_controller``)은 키가 없으면 링크를 열기 전에 시작을 거절한다.
인증 없는 링크는 ``SIMPLELAY_LINK_AUTH=off_for_mock``을 **명시**하고 실물 경로(모션 serial·실물 콘센트 모듈·L3 real·
실센서·개발자 실물 조작)가 하나도 켜지지 않았을 때만 받는다 — 모의 허용 플래그 하나로 실물 장치까지 무인증이 되지 않게.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import time
from collections import deque

log = logging.getLogger(__name__)

LINK_KEY_ENV = "SIMPLELAY_LINK_KEY"
MIN_KEY_LENGTH = 16
#: 세션 키 파생 문맥 — 바꾸면 옛 보드와 짝이 맞지 않는다.
SESSION_CONTEXT = "simplelay-link-v1"
#: 봉투 필드(받은 뒤 본문에서 지운다).
AUTH_FIELDS = ("cn", "sn", "seq", "mac")

_NONCE = re.compile(r"[0-9a-f]{32}")
_MAC = re.compile(r"[0-9a-f]{64}")


class LinkKeyError(ValueError):
    """짝 키가 너무 짧거나 잘못됐다 — 링크를 열지 않는다."""


class LinkAuthRequiredError(LinkKeyError):
    """짝 키가 없다(또는 무인증 모의 설정이 실물 경로와 함께 켜졌다) — 링크를 열지 않고 시작을 거절한다."""


#: 인증 없는 링크를 여는 유일한 명시 설정(모의 개발 전용).
LINK_AUTH_ENV = "SIMPLELAY_LINK_AUTH"
LINK_AUTH_MOCK_ONLY = "off_for_mock"


def validate_key(key: "str | bytes") -> bytes:
    raw = key.encode("utf-8") if isinstance(key, str) else bytes(key)
    if len(raw) < MIN_KEY_LENGTH:
        raise LinkKeyError(f"{LINK_KEY_ENV}가 너무 짧아요 — {MIN_KEY_LENGTH}자 이상이어야 링크를 열어요")
    return raw


def link_key_from_env(environ: "dict[str, str] | None" = None, *, real_paths: "tuple[str, ...] | list[str]" = ()) -> bytes | None:
    """시작 때 짝 키를 정한다. 키가 있으면 검사한 키(짧으면 `LinkKeyError`).

    키가 없으면 `LinkAuthRequiredError`로 시작을 거절한다. 예외는 ``SIMPLELAY_LINK_AUTH=off_for_mock``을 명시하고
    ``real_paths``(이 보드에서 켜진 실물 경로 이름)가 비었을 때뿐이다 — 그때만 None(인증 없음, 경고 한 번)."""
    env = os.environ if environ is None else environ
    value = (env.get(LINK_KEY_ENV) or "").strip()
    if value:
        return validate_key(value)
    mode = (env.get(LINK_AUTH_ENV) or "").strip().lower()
    if mode != LINK_AUTH_MOCK_ONLY:
        raise LinkAuthRequiredError(
            f"{LINK_KEY_ENV}가 없어 링크를 열지 않아요 — 두 보드에 같은 키(16자 이상)를 두세요. "
            f"모의 개발에서만 {LINK_AUTH_ENV}={LINK_AUTH_MOCK_ONLY}로 인증 없이 열 수 있어요")
    real = [name for name in real_paths if name]
    if real:
        raise LinkAuthRequiredError(
            f"{LINK_AUTH_ENV}={LINK_AUTH_MOCK_ONLY}는 모의 구성에서만 받아요 — 실물 경로({', '.join(real)})가 "
            f"켜져 있어 시작하지 않아요. {LINK_KEY_ENV}를 설정하세요")
    log.warning("%s=%s — RPi5↔RPi4 링크에 인증이 없어요(모의 구성 전용). 같은 망의 누구나 실행 프레임을 보낼 수 "
                "있어요. 실물·시연 배포에서는 %s를 설정하세요", LINK_AUTH_ENV, LINK_AUTH_MOCK_ONLY, LINK_KEY_ENV)
    return None


def canonical(doc: dict) -> bytes:
    body = {k: v for k, v in doc.items() if k != "mac"}
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def compute_mac(key: bytes, doc: dict) -> str:
    return hmac.new(key, canonical(doc), hashlib.sha256).hexdigest()


def mac_ok(key: bytes, doc: dict) -> bool:
    mac = doc.get("mac")
    if not isinstance(mac, str) or not _MAC.fullmatch(mac):
        return False
    return hmac.compare_digest(mac, compute_mac(key, doc))


def new_nonce() -> str:
    return secrets.token_hex(16)


def is_nonce(value: object) -> bool:
    return isinstance(value, str) and _NONCE.fullmatch(value) is not None


def session_key(key: bytes, cn: str, sn: str) -> bytes:
    return hmac.new(key, f"{SESSION_CONTEXT}|{cn}|{sn}".encode("utf-8"), hashlib.sha256).digest()


def strip_auth(doc: dict) -> dict:
    return {k: v for k, v in doc.items() if k not in AUTH_FIELDS}


class LinkSession:
    """세션 하나 — 보낼 ``seq``와 마지막으로 받아들인 ``seq``."""

    def __init__(self, key: bytes) -> None:
        self._key = key
        self._tx_seq = 0
        self._rx_seq = 0

    def seal(self, doc: dict) -> dict:
        self._tx_seq += 1
        out = {**strip_auth(doc), "seq": self._tx_seq}
        out["mac"] = compute_mac(self._key, out)
        return out

    def accept(self, doc: dict) -> bool:
        seq = doc.get("seq")
        if type(seq) is not int or seq <= self._rx_seq or "cn" in doc or "sn" in doc:
            return False
        if not mac_ok(self._key, doc):
            return False
        self._rx_seq = seq
        return True


class DropLog:
    """버린 프레임·인증 실패 경고를 10초에 한 번으로 줄인다(공격·잘못된 키로 로그가 넘치지 않게)."""

    def __init__(self, interval_s: float = 10.0) -> None:
        self._interval = interval_s
        self._last = -1e9
        self.dropped = 0

    def warn(self, logger: logging.Logger, why: str, msg_type: object) -> None:
        self.dropped += 1
        now = time.monotonic()
        if now - self._last >= self._interval:
            self._last = now
            logger.warning("link auth: %s (type=%s) — %d so far", why, msg_type, self.dropped)


class ServerAuth:
    """RPi4 쪽: 올바른 hello마다 새 세션을 연다. 첫 답(act_info)에 ``cn``·``sn``을 싣고 K로 서명한다."""

    #: 이미 쓴 ``cn``을 기억하는 수 — 옛 hello를 다시 보내 세션을 갈아엎는 것을 막는다.
    SEEN_NONCES = 4096

    def __init__(self, key: "str | bytes") -> None:
        self._key = validate_key(key)
        self.session: LinkSession | None = None
        self._handshake: tuple[str, str] | None = None
        self._seen: deque[str] = deque(maxlen=self.SEEN_NONCES)
        self.drops = DropLog()

    def open(self, doc: dict) -> dict | None:
        """받은 문서를 확인한다. 받아들이면 봉투를 뗀 본문, 아니면 None(버린다)."""
        if doc.get("type") == "hello":
            cn = doc.get("cn")
            if not is_nonce(cn) or "seq" in doc or "sn" in doc or not mac_ok(self._key, doc):
                self.drops.warn(log, "bad or unsigned hello", "hello")
                return None
            if cn in self._seen:
                self.drops.warn(log, "replayed hello", "hello")
                return None
            self._seen.append(cn)
            sn = new_nonce()
            self.session = LinkSession(session_key(self._key, cn, sn))
            self._handshake = (cn, sn)
            log.info("link auth: new session")
            return strip_auth(doc)
        if self.session is None:
            self.drops.warn(log, "no session", doc.get("type"))
            return None
        if not self.session.accept(doc):
            self.drops.warn(log, "bad mac or seq", doc.get("type"))
            return None
        return strip_auth(doc)

    def seal(self, doc: dict) -> dict | None:
        """보낼 문서에 봉투를 씌운다. 세션이 없으면 None(보내지 않는다). 새 세션의 첫 프레임이 hello 답이다."""
        if self.session is None:
            return None
        if self._handshake is not None:
            cn, sn = self._handshake
            self._handshake = None
            out = {**strip_auth(doc), "cn": cn, "sn": sn}
            out["mac"] = compute_mac(self._key, out)
            return out
        return self.session.seal(doc)
