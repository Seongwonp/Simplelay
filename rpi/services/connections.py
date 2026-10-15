"""키오스크 오른쪽 위 연결 상태 세 가지(와이파이·작은 팔 장치·가전 콘센트 장치) — 사용자 말로.

이름은 키오스크 용어표(docs/키오스크-문구-개선-계획-2026-10-15.md §1)를 따른다: 허브 → SimpleLay 본체,
누름 장치(RPi4) → 작은 팔 장치, 플러그(콘센트 모듈) → 가전 콘센트 장치.

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
    "공유기 전원이 켜져 있는지 확인해 주세요.",
    "SimpleLay 본체에 랜선을 쓰고 있다면 선이 끝까지 꽂혀 있는지 확인해 주세요.",
    "그래도 안 되면 SimpleLay 본체 전원을 껐다가 다시 켜 주세요.",
)
_NET_FIXES_INTERNET = (
    "공유기의 인터넷 표시등이 켜져 있는지 확인해 주세요.",
    "잠시 뒤 '다시 확인하기'를 눌러 주세요.",
)


def network_item(interface: str, internet: str = "unknown") -> ConnectionItem:
    """``interface``: up | down | unknown. ``internet``: ok | failed | unknown(날씨 받기 결과).

    이 응답을 받았다는 것 자체가 화면과 허브가 이어져 있다는 뜻이라, 인터페이스를
    읽을 수 없으면(윈도우 개발 PC 등) 정상으로 본다.
    """
    source = "sysfs" if interface in ("up", "down") else "server"
    if interface == "down":
        return ConnectionItem(
            "network",
            "error",
            "와이파이 연결이 끊겼어요",
            "SimpleLay 본체가 집 와이파이에 연결되지 않았어요. 휴대폰 앱에서 SimpleLay 본체를 찾지 못하고, "
            "날씨 안내도 볼 수 없어요.",
            _NET_FIXES_DOWN,
            source,
        )
    if internet == "failed":
        return ConnectionItem(
            "network",
            "warn",
            "인터넷 연결이 불안정해요",
            "SimpleLay 본체가 인터넷에 닿지 못하고 있어요. 날씨 안내가 보이지 않을 수 있어요. "
            "집 안에서 가전을 누르는 일은 그대로 할 수 있어요.",
            _NET_FIXES_INTERNET,
            source,
        )
    return ConnectionItem(
        "network", "ok", "와이파이에 연결돼 있어요", "SimpleLay 본체가 집 와이파이에 잘 연결돼 있어요.", (),
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
    "작은 팔 장치의 전원이 켜져 있는지 확인해 주세요.",
    "작은 팔 장치에 꽂힌 선(전원·연결)이 끝까지 꽂혀 있는지 확인해 주세요.",
    "그래도 안 되면 작은 팔 장치 전원을 껐다가 다시 켜 주세요.",
)


def press_item(act_mode: str, link: str = "ok") -> ConnectionItem:
    """``act_mode``: SIMPLELAY_ACT_MODE. uart만 실제 누름 장치이고 나머지는 연습용이다."""
    mode = (act_mode or "").strip().lower()
    if mode != "uart":
        return ConnectionItem(
            "press",
            "ok",
            "작은 팔 장치가 준비됐어요",
            "연습 중이에요 · 실제 가전은 누르지 않아요.",
            (),
            "mock",
        )
    if link == "down":
        return ConnectionItem(
            "press",
            "error",
            "작은 팔 장치와 연결 안 됨",
            "SimpleLay 본체가 작은 팔 장치에 다시 연결하는 중이에요. 연결되기 전에는 버튼을 대신 눌러 드릴 수 없어요.",
            _PRESS_FIXES,
            "real",
        )
    if link == "no_reply":
        return ConnectionItem(
            "press",
            "error",
            "작은 팔 장치가 답하지 않아요",
            "SimpleLay 본체가 보낸 명령에 작은 팔 장치가 답하지 않았어요. 지금은 버튼을 대신 눌러 드릴 수 없어요.",
            _PRESS_FIXES,
            "real",
        )
    if link == "error":
        return ConnectionItem(
            "press",
            "warn",
            "작은 팔 장치에 문제가 생겼어요",
            "작은 팔 장치가 마지막 명령을 끝내지 못했어요. 다음에 버튼을 누를 때 실패할 수 있어요.",
            _PRESS_FIXES,
            "real",
        )
    if link == "never":
        return ConnectionItem(
            "press",
            "unknown",
            "작은 팔 장치를 아직 확인하지 못했어요",
            "SimpleLay 본체를 켠 뒤 작은 팔 장치와 아직 주고받은 적이 없어요. 한 번 실행해 보면 연결을 확인할 수 있어요.",
            _PRESS_FIXES[:2],
            "real",
        )
    return ConnectionItem(
        "press", "ok", "작은 팔 장치가 연결돼 있어요", "버튼을 대신 눌러 드릴 수 있어요.", (), "real"
    )


# ── 플러그(콘센트 모듈 · L3 전력) ─────────────────────────────────────────────

_PLUG_FIXES = (
    "가전 콘센트 장치가 벽 콘센트에 끝까지 꽂혀 있는지 확인해 주세요.",
    "가전 콘센트 장치와 작은 팔 장치를 잇는 선이 끝까지 꽂혀 있는지 확인해 주세요.",
    "그래도 안 되면 가전 콘센트 장치를 뽑았다가 10초 뒤 다시 꽂아 주세요.",
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
            "가전 콘센트 장치 연결이 약해요",
            "가전이 끝났는지 알려 주는 가전 콘센트 장치와 연결이 약해요. 끝났다는 알림이 늦거나 오지 않을 수 있어요.",
            _PLUG_FIXES,
            "real",
        )
    if link == "lost":
        return ConnectionItem(
            "plug",
            "error",
            "가전 콘센트 장치와 연결이 끊겼어요",
            "가전이 끝났는지 알려 주는 가전 콘센트 장치와 연결이 끊겼어요. 끝났다는 알림을 드릴 수 없어요.",
            _PLUG_FIXES,
            "real",
        )
    if mode == "mock":
        return ConnectionItem(
            "plug",
            "ok",
            "가전 콘센트 장치가 연결돼 있어요",
            "가전이 끝나면 알려 드릴게요. 연습 중이라 실제로 잰 전력 값이 아니에요.",
            (),
            "mock",
        )
    if mode == "real":
        # 실물 전력 리더가 아직 없다(서버가 기동을 거절한다). 여기 닿으면 모른다고 답한다.
        return ConnectionItem(
            "plug",
            "unknown",
            "가전 콘센트 장치 상태를 확인할 수 없어요",
            "가전이 끝났는지 알려 주는 가전 콘센트 장치 상태를 아직 읽지 못했어요. 끝났다는 알림이 오지 않을 수 있어요.",
            _PLUG_FIXES[:1],
            "real",
        )
    return ConnectionItem(
        "plug",
        "not_installed",
        "가전 콘센트 장치가 아직 없어요",
        "가전이 끝났는지 알려 주는 가전 콘센트 장치를 연결하지 않았어요. 버튼은 눌러 드리지만, "
        "끝났다는 알림은 드릴 수 없어요.",
        ("가전 콘센트 장치를 쓰려면 가전의 전원선을 이 장치에 꽂고, 이 장치를 벽 콘센트에 꽂아 주세요.",),
        "none",
    )
