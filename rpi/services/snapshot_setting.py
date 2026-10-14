"""판정용 메모리 사본과 영속 쓰기를 나눈 설정 하나(2026-10-14 HIGH 재확인 H-R1·H-R2·M-R1).

실행 게이트(서비스 잠금 안)·전송권 확인(실행기 잠금 안)이 읽는 설정은 **DB 대기를 가진 잠금을 기다리면 안 된다** —
그 잠금 안에서 기다리면 같은 잠금을 잡아야 하는 정지(``request_stop``)가 DB 대기만큼 늦는다.

- 읽기(``value``): 잠금 없음. 값은 불변 사본이고 통째로 바꿔 끼운다(속성 읽기 한 번).
- 바꾸기(``change``): 짧은 메모리 잠금 안에서 새 사본을 만들고 판 번호를 올린다. 입출력 없음. **메모리에 먼저 적용한다.**
- 저장(``persist``): 따로 저장 잠금을 잡고, 그때의 **가장 새** 사본을 쓴다(이미 쓴 판이면 쓰지 않음). 메모리 잠금은
  사본·판 번호를 읽는 순간만 — DB를 기다리는 동안 메모리 잠금을 잡지 않는다. 늦게 끝난 옛 쓰기가 새 값을 덮지 않는다.
- 저장 실패: 메모리 값은 그대로(이번 세션에는 적용), ``persist``가 False. 다음 변경의 저장이 그때의 가장 새 값을 다시 쓴다.
  재시작하면 **마지막으로 저장에 성공한 값**으로 시작한다.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from typing import Generic, TypeVar

log = logging.getLogger(__name__)

T = TypeVar("T")


class SnapshotSetting(Generic[T]):
    def __init__(self, value: T, save: Callable[[str], None] | None = None,
                 encode: Callable[[T], str] | None = None, name: str = "setting") -> None:
        self._value = value
        self._save = save
        self._encode = encode or str
        self._name = name
        self._mem_lock = threading.Lock()
        self._persist_lock = threading.Lock()
        self._version = 0
        self._persisted_version = 0

    @property
    def value(self) -> T:
        """지금 사본 — 잠금 없음(판정용)."""
        return self._value

    def set_save(self, save: Callable[[str], None] | None) -> None:
        self._save = save

    def load(self, value: T) -> None:
        """기동 때 DB에서 읽은 값으로 시작한다(저장할 변경으로 세지 않는다)."""
        with self._mem_lock:
            self._value = value

    def change(self, fn: Callable[[T], T]) -> tuple[T, int]:
        """메모리에 바로 적용한다(입출력 없음). ``fn``이 예외를 올리면 아무것도 바뀌지 않는다. (새 값, 판 번호)."""
        with self._mem_lock:
            new = fn(self._value)
            self._value = new
            self._version += 1
            return new, self._version

    def persist(self, version: int | None = None) -> bool | None:
        """지금 메모리 사본을 저장한다. True: ``version``(없으면 지금 판)까지 저장됨 · False: 저장 실패(이번 세션만 적용) ·
        None: 저장소가 없는 구성(메모리 전용)."""
        save = self._save
        if save is None:
            return None
        with self._persist_lock:
            with self._mem_lock:
                value, current = self._value, self._version
            wanted = current if version is None else version
            if self._persisted_version >= max(wanted, current):
                return True
            try:
                save(self._encode(value))
            except Exception:  # noqa: BLE001 -- 저장 실패는 메모리 판정만 남는다(재시작하면 마지막 저장값)
                log.exception("%s save failed — applied for this session only", self._name)
                return False
            self._persisted_version = current
            return True
