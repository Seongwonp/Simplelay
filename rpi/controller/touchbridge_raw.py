"""개발자 모드 보드 명령 바로 보내기 — Touch Bridge 원본 텍스트 명령의 허용 목록.

조정 중에는 위치 확인·원점 확인 같은 우리 쪽 관문 없이 HW 담당의 원본 명령(``T``·``Z``·``G`` …)을 그대로
보내 보드 답을 봐야 한다. 그래도 임의의 줄은 보내지 않는다: 아래 모양만 받고, 키 재설정·PID 값·버튼 격자처럼
보드 설정을 바꾸는 명령은 뺀다. 정지는 이 경로와 상관없이 늘 JSON ``stop``으로 간다.

RPi5(명령 모양 확인)와 RPi4(보내기 직전 다시 확인)가 같은 함수를 쓴다.
"""

from __future__ import annotations

import re

#: 한 줄 상한(보드 줄 버퍼보다 충분히 짧게).
MAX_RAW_LEN = 40

_NUM = r"-?\d{1,4}(?:\.\d{1,3})?"
_PATTERNS = (
    re.compile(r"T(?: \d{1,4})?"),
    re.compile(r"Z|H|S|!|P|\?|\$\$|STOP"),
    re.compile(rf"GT? {_NUM} {_NUM}(?: {_NUM})?"),
    re.compile(rf"M {_NUM} {_NUM} \d{{1,4}}"),
)
#: ``M a b ms``의 출력 비율 상한과 시간 상한(ms). 출력은 -1..1 비율이다(HW 시험 ``M ±0.5 ±0.5 500``).
MAX_RAW_PWM = 1.0
MAX_RAW_MS = 2000

#: 이 줄이 오면 그 명령의 답이 끝난 것으로 본다(원본 스케치의 텍스트 답).
_END_PREFIXES = {
    "T": ("PRESSED", "FAULT", "ERR", "STOPPED"),
    "G": ("DONE", "FAULT", "ERR", "STOPPED"),
    "GT": ("PRESSED", "FAULT", "ERR", "STOPPED"),
    "H": ("HOMED", "FAULT", "ERR", "STOPPED"),
}


def normalize_raw_command(text: object) -> str | None:
    """허용 목록에 맞으면 보낼 줄(대문자·공백 하나), 아니면 None."""
    if not isinstance(text, str) or len(text) > MAX_RAW_LEN:
        return None
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in text):
        return None
    line = " ".join(text.strip().upper().split())
    if not line or not any(p.fullmatch(line) for p in _PATTERNS):
        return None
    parts = line.split()
    if parts[0] == "M":
        a, b, ms = float(parts[1]), float(parts[2]), int(parts[3])
        if abs(a) > MAX_RAW_PWM or abs(b) > MAX_RAW_PWM or not 0 < ms <= MAX_RAW_MS:
            return None
    if parts[0] == "T" and len(parts) == 2 and not 30 <= int(parts[1]) <= MAX_RAW_MS:
        return None
    return line


def raw_listen_s(line: str, home_timeout_s: float = 80.0) -> float:
    """보낸 뒤 보드 답을 기다릴 최대 시간(s). 끝 줄이 오면 그보다 일찍 끝난다."""
    head = line.split()[0]
    if head == "H":
        return home_timeout_s
    if head in ("G", "GT"):
        return 15.0
    if head == "T":
        return 6.0
    if head == "M":
        return int(line.split()[3]) / 1000.0 + 1.0
    return 1.0


def raw_is_end(line: str, reply: str) -> bool:
    """``reply``가 ``line`` 명령의 마지막 답인가. 끝 줄이 따로 없는 명령은 첫 답(``OK``·``STATE`` 등)에서 끝낸다."""
    head = line.split()[0]
    ends = _END_PREFIXES.get(head)
    if ends is None:
        return head not in ("?",)  # 도움말은 두 줄 — 기다림 시간으로 끝낸다
    return reply.startswith(ends)
