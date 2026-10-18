"""키오스크 오른쪽 위 연결 상태 세 가지(와이파이·누름 장치·전기 플러그) — 사용자 말로.

이름은 쉬운 말 사전(docs/UI-개편안-2026-10-17.md §3)을 따른다: 허브 → 본체,
누름 장치(RPi4)는 그대로 누름 장치(10/18 사용자 결정), 플러그(콘센트 모듈) → 전기 플러그(10/18 사전 변경: 가족은 '콘센트'를 벽 콘센트로 읽는다).
문장은 결과 한 줄 + 할 일 한 줄.

UI 확정 §1-5: 부품 이름 대신 사용자가 아는 이름을 쓰고, 무엇을 못 하게
되는지와 해결 방법을 함께 적는다. 이 모듈의 ``title``·``message``·``fixes``는
화면에 그대로 나간다. ``source``(real | mock | none | …)는 개발·시연 확인용이며
화면 문구로 쓰지 않는다.

state: ok | warn | error | not_installed | unknown
"""

from __future__ import annotations

import os
import pathlib
from dataclasses import dataclass, field
from typing import Iterable

from .link_tap import ACT_TO_HUB, HUB_TO_ACT

STATES = ("ok", "warn", "error", "not_installed", "unknown")

#: 명령을 보낸 뒤 이만큼 답이 없으면 '답하지 않아요'. 가장 긴 시퀀스 응답
#: 기한보다 넉넉하게 잡는다(추측 -- 실기기 연결 뒤 조정).
PRESS_REPLY_TIMEOUT_SECONDS = 90.0


@dataclass(frozen=True)
class ConnectionItem:
    id: str
    state: str
    title: str
    message: str
    fixes: tuple[str, ...] = field(default_factory=tuple)
    source: str = "none"

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "state": self.state,
            "title": self.title,
            "message": self.message,
            "fixes": list(self.fixes),
            "source": self.source,
        }


# ── 와이파이(허브 네트워크) ────────────────────────────────────────────────────


def read_interface_state(root: str | os.PathLike = "/sys/class/net") -> str:
    """리눅스 sysfs로 루프백 밖 인터페이스 중 하나라도 올라와 있나: up | down | unknown."""
    base = pathlib.Path(root)
    try:
        entries = [p for p in base.iterdir() if p.name != "lo"]
    except OSError:
        return "unknown"
    if not entries:
        return "unknown"
    seen = False
    for entry in entries:
        try:
            state = (entry / "operstate").read_text(encoding="ascii").strip().lower()
        except OSError:
            continue
        seen = True
        if state == "up":
            return "up"
    return "down" if seen else "unknown"


_NET_FIXES_DOWN = (
    "공유기 전원이 켜져 있는지 봐 주세요.",
    "랜선을 쓰면 선이 끝까지 꽂혀 있는지 봐 주세요.",
    "그래도 안 되면 본체를 껐다가 다시 켜 주세요.",
)
_NET_FIXES_INTERNET = (
    "공유기의 인터넷 표시등이 켜져 있는지 봐 주세요.",
    "잠시 뒤 '다시 확인하기'를 눌러 주세요.",
)


def network_item(interface: str, internet: str = "unknown") -> ConnectionItem:
    """``interface``: up | down | unknown. ``internet``: ok | failed | unknown(날씨 받기 결과).

    이 응답을 받았다는 것 자체가 화면과 본체가 이어져 있다는 뜻이라, 인터페이스를
    읽을 수 없으면(윈도우 개발 PC 등) 정상으로 본다.
    """
    source = "sysfs" if interface in ("up", "down") else "server"
    if interface == "down":
        return ConnectionItem(
            "network",
            "error",
            "와이파이 연결이 끊겼어요",
            "본체가 와이파이에 연결되지 않았어요. 폰 앱과 날씨 안내를 쓸 수 없어요.",
            _NET_FIXES_DOWN,
            source,
        )
    if internet == "failed":
        return ConnectionItem(
            "network",
            "warn",
            "인터넷 연결이 불안정해요",
            "날씨 안내가 보이지 않을 수 있어요. 가전 버튼 누르기는 그대로 돼요.",
            _NET_FIXES_INTERNET,
            source,
        )
    return ConnectionItem(
        "network", "ok", "와이파이에 연결돼 있어요", "본체가 집 와이파이에 잘 연결돼 있어요.", (),
        source
    )


# ── 누름 장치(RPi4 링크) ──────────────────────────────────────────────────────


def press_link_from_frames(
    frames: Iterable[dict], now_ns: int, reply_timeout_s: float = PRESS_REPLY_TIMEOUT_SECONDS
) -> str:
    """통신 프레임 탭으로 본 링크: ok | no_reply | error | never. (``down``=링크 끊김·첫 연결 전은
    호출하는 쪽이 컨트롤러의 ``link_status``로 먼저 가른다.)

    - never: 허브를 켠 뒤 누름 장치에서 온 줄이 하나도 없다.
    - no_reply: 마지막으로 보낸 실행 명령 뒤로 기한이 지나도록 답이 없다.
    - error: 누름 장치가 보낸 마지막 줄이 오류다.
    """
    last_in = None
    last_exec = None
    for frame in frames:
        if frame.get("kind", "frame") != "frame":
            continue
        direction = frame.get("direction")
        if direction == ACT_TO_HUB:
            last_in = frame
        elif direction == HUB_TO_ACT and frame.get("type") == "execute":
            last_exec = frame
    if last_exec is not None:
        exec_ns = last_exec.get("t_monotonic_ns") or 0
        pending = last_in is None or (last_in.get("t_monotonic_ns") or 0) < exec_ns
        if pending and now_ns - exec_ns > reply_timeout_s * 1e9:
            return "no_reply"
    if last_in is None:
        return "never"
    if last_in.get("type") == "error":
        return "error"
    return "ok"


_PRESS_FIXES = (
    "누름 장치 전원이 켜져 있는지 봐 주세요.",
    "누름 장치에 꽂힌 선이 끝까지 꽂혀 있는지 봐 주세요.",
    "그래도 안 되면 누름 장치 전원을 껐다가 다시 켜 주세요.",
)


def press_item(act_mode: str, link: str = "ok") -> ConnectionItem:
    """``act_mode``: SIMPLELAY_ACT_MODE. uart만 실제 누름 장치고 나머지는 연습용이다."""
    mode = (act_mode or "").strip().lower()
    if mode != "uart":
        return ConnectionItem(
            "press",
            "ok",
            # 연습 구성에는 실제 누름 장치가 없을 수 있다 — '준비됐어요'는 실물이 준비된 것처럼 읽혔다(10/18 §3-5).
            "누름 장치는 연습 중이에요",
            "실제 가전은 누르지 않아요.",
            (),
            "mock",
        )
    if link == "down":
        return ConnectionItem(
            "press",
            "error",
            "누름 장치와 연결이 끊겼어요",
            "본체가 다시 연결하는 중이에요. 그동안은 버튼을 누를 수 없어요.",
            _PRESS_FIXES,
            "real",
        )
    if link == "no_reply":
        return ConnectionItem(
            "press",
            "error",
            "누름 장치가 답하지 않아요",
            "누르라고 했는데 답이 없었어요. 지금은 버튼을 누를 수 없어요.",
            _PRESS_FIXES,
            "real",
        )
    if link == "error":
        return ConnectionItem(
            "press",
            "warn",
            "누름 장치에 문제가 생겼어요",
            "마지막 누르기를 끝내지 못했어요. 다음 누르기가 실패할 수 있어요.",
            _PRESS_FIXES,
            "real",
        )
    if link == "never":
        return ConnectionItem(
            "press",
            "unknown",
            "누름 장치를 아직 확인하지 못했어요",
            "본체를 켠 뒤 아직 주고받은 적이 없어요. 한 번 실행하면 확인돼요.",
            _PRESS_FIXES[:2],
            "real",
        )
    return ConnectionItem(
        "press", "ok", "누름 장치가 연결돼 있어요", "버튼을 대신 눌러 드릴 수 있어요.", (), "real"
    )


# ── 플러그(콘센트 모듈 · L3 전력) ─────────────────────────────────────────────

_PLUG_FIXES = (
    "전기 플러그가 벽에 끝까지 꽂혀 있는지 봐 주세요.",
    "전기 플러그와 누름 장치를 잇는 선이 끝까지 꽂혀 있는지 봐 주세요.",
    "그래도 안 되면 전기 플러그를 뽑았다가 10초 뒤 다시 꽂아 주세요.",
)


def plug_item(l3_mode: str, link: str | None = None) -> ConnectionItem:
    """``l3_mode``: SIMPLELAY_L3_MODE(off | mock | real). ``link``: 플러그가 생기면
    그 연결 상태(ok | weak | lost)를 넘긴다. 지금은 실물 플러그가 없어 off면
    '설치 안 됨', mock이면 연습용 정상이다."""
    mode = (l3_mode or "off").strip().lower() or "off"
    if link == "weak":
        return ConnectionItem(
            "plug",
            "warn",
            "전기 플러그 연결이 약해요",
            "가전이 끝났다는 알림이 늦거나 오지 않을 수 있어요.",
            _PLUG_FIXES,
            "real",
        )
    if link == "lost":
        return ConnectionItem(
            "plug",
            "error",
            "전기 플러그와 연결이 끊겼어요",
            "가전이 끝났다는 알림을 드릴 수 없어요.",
            _PLUG_FIXES,
            "real",
        )
    if mode == "mock":
        return ConnectionItem(
            "plug",
            "ok",
            # 연습 구성에는 실제 전기 플러그가 없다 — '연결돼 있어요'라고 하지 않는다(10/18 §3-5).
            "전기 플러그는 연습 중이에요",
            "실제로 재지 않아요. 가전이 끝났다는 알림도 연습 값이에요.",
            (),
            "mock",
        )
    if mode == "real":
        # 실물 전력 리더가 아직 없다(서버가 기동을 거절한다). 여기 닿으면 모른다고 답한다.
        return ConnectionItem(
            "plug",
            "unknown",
            "전기 플러그 상태를 알 수 없어요",
            "가전이 끝났다는 알림이 오지 않을 수 있어요.",
            _PLUG_FIXES[:1],
            "real",
        )
    return ConnectionItem(
        "plug",
        "not_installed",
        "전기 플러그가 아직 없어요",
        "버튼은 눌러 드리지만, 가전이 끝났다는 알림은 드릴 수 없어요.",
        ("쓰려면 가전 전원선을 전기 플러그에 꽂고, 전기 플러그를 벽에 꽂아 주세요.",),
        "none",
    )
