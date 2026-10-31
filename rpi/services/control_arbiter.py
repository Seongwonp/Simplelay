"""일반 실행과 개발자 세션의 기계 제어권을 원자적으로 중재한다.

중재자 락은 항상 가장 안쪽에서 잡고 외부 콜백을 호출하지 않는다.
정지 미확인 fault가 걸리면 ``clear_fault()`` 전까지 새 제어권을 내주지 않는다.
"""

from __future__ import annotations

import threading


class ControlConflictError(RuntimeError):
    """다른 주체가 이미 기계 제어권을 갖고 있다. (HTTP 409로 매핑된다)"""

    def __init__(self, holder: str) -> None:
        self.holder = holder
        if holder == ControlArbiter.DEVELOPER:
            message = "개발자 세션이 기기를 점유하고 있습니다 — 세션이 끝난 뒤에 실행할 수 있습니다"
        elif holder == ControlArbiter.VERIFY_PASS:
            # 확인 주행 점유는 일반 실행과 구분해 알린다.
            message = "자리 확인이 진행 중입니다 — 끝난 뒤에 시작할 수 있습니다"
        elif holder == ControlArbiter.KIT_BIND:
            message = "누름 장치 세트 연결을 바꾸는 중입니다 — 잠시 뒤 다시 시도해 주세요"
        else:
            message = "일반 실행이 진행 중입니다 — 끝난 뒤에 시작할 수 있습니다"
        super().__init__(message)


class ControlFaultedError(RuntimeError):
    """정지 미확인(fault) 상태 — 기계가 멈췄는지 확인될 때까지 아무도 못 움직인다."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(
            "기기 정지가 확인되지 않아 잠겨 있습니다 — 긴급 정지로 정지를 "
            f"확인한 뒤 다시 시도해 주세요 (사유: {reason})"
        )


class ControlArbiter:
    """제어권은 한 번에 한 주체(holder)만 갖는다.

    holder는 문자열 상수 둘뿐이다 — 열거형까지 만들지 않는 이유는 이 값이
    저장·전송되지 않고 이 프로세스의 두 호출부에서만 쓰이기 때문이다.
    """

    EXECUTION = "execution"
    DEVELOPER = "developer"
    #: 확인 주행(자리 확인) — 일반 실행처럼 기계를 움직인다. 일반 실행의 반납과 섞이지 않게 이름을 따로 둔다(10/19).
    VERIFY_PASS = "verify_pass"
    #: 세트 연결을 바꾸는 짧은 순간 — 판정(어느 가전을 맡았나)이 바뀌는 동안 실행이 시작되지 않게 잡는다.
    KIT_BIND = "kit_bind"

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._holder: str | None = None
        self._fault_reason: str | None = None
        # fault 세대 번호 -- trip마다 증가. "내 정지가 시작된 뒤 새 fault가
        # 걸렸는가"를 가리는 근거다: 오래 걸린 정지의 성공 응답이 그 사이
        # 다른 주체가 건 **새** fault를 해제하면 안 된다(clear 호출자가
        # 시작 시점의 seq와 대조한다).
        self._fault_seq = 0

    # 획득/반납

    def acquire(self, holder: str) -> None:
        """확인과 점유를 한 임계구역에서. 실패는 예외로 — 반환값 확인을
        빠뜨린 호출부가 조용히 통과하는 것보다 시끄럽게 죽는 쪽이 안전하다."""
        with self._lock:
            if self._fault_reason is not None:
                raise ControlFaultedError(self._fault_reason)
            if self._holder is not None:
                raise ControlConflictError(self._holder)
            self._holder = holder

    def release(self, holder: str) -> None:
        """자기가 가진 제어권만 반납한다. 안 가진 쪽의 release는 무해한
        no-op — 정지 경로는 여러 갈래라 이중 반납이 자연스럽게 생긴다."""
        with self._lock:
            if self._holder == holder:
                self._holder = None

    # fault

    def trip_fault(self, reason: str) -> None:
        """정지 미확인 잠금. 이후 acquire는 전부 ControlFaultedError."""
        with self._lock:
            self._fault_reason = reason
            self._fault_seq += 1

    def clear_fault(self) -> None:
        """무조건 해제 -- 운영자 수동 개입·테스트 정리용. 정지 확인 경로는
        비교와 해제가 원자적인 clear_fault_if_matches를 써야 한다."""
        with self._lock:
            self._fault_reason = None

    def clear_fault_if_matches(self, expected_seq: int) -> bool:
        """**같은 락 안에서** 세대를 대조하고 해제한다 (후속 리뷰 1.4-#1).

        비교(fault_seq 읽기)와 해제(clear)를 따로 하면, 그 사이에 걸린 새
        fault를 오래된 정지의 성공 응답이 지워 버릴 수 있다. 시작 시점에
        fault_snapshot()으로 캡처한 seq를 넘기면, 정확히 그 세대의 fault만
        지워진다. 해제했으면 True.
        """
        with self._lock:
            if self._fault_reason is None or self._fault_seq != expected_seq:
                return False
            self._fault_reason = None
            return True

    def fault_snapshot(self) -> tuple[str | None, int]:
        """(fault_reason, fault_seq)를 한 락에서 함께 읽는다 -- 따로 읽으면
        둘이 서로 다른 세대를 가리킬 수 있다."""
        with self._lock:
            return self._fault_reason, self._fault_seq

    # 조회(표시용 — 판정에 쓰지 말 것: 판정은 acquire가 원자적으로 한다)

    @property
    def holder(self) -> str | None:
        with self._lock:
            return self._holder

    @property
    def fault_reason(self) -> str | None:
        with self._lock:
            return self._fault_reason

    @property
    def fault_seq(self) -> int:
        with self._lock:
            return self._fault_seq
