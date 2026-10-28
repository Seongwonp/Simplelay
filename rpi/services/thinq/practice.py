"""연습 기기 섞기 — 실제 ThinQ 클라이언트 옆에 모의 기기 몇 대를 함께 둔다 (2026-10-18, 사용자 요청).

실제(real) 모드에서 실제 공기청정기를 쓰면서 **다른 LG 가전 예시**(세탁기)를 함께 보이려는 것이다. 기기 ID로 갈라
연습 기기는 :class:`MockThinqClient`로, 나머지는 실제 클라이언트로 보낸다. 연습 기기 호출은 실제 클라우드에 닿지 않는다.

- 실행 환경은 **기기마다** 다르다: ``execution_mode_for(device_id)`` — 연습 기기는 MOCK. 서버 전체의 ``execution_mode``
  (자동 실행 규칙·공기질 판정이 보는 값)는 실제 클라이언트 것 그대로다.
- ``list_devices``는 **계정 기기(실제)만** 돌려준다 — 발견 목록에 연습 기기를 계정 기기처럼 섞지 않는다. 연습 기기의
  준비 판정은 실행기가 ``client_for``로 연습 클라이언트에게 직접 묻는다.
"""

from __future__ import annotations

from rpi.controller.models import ExecutionMode

from .client import ThinqDeviceInfo
from .mock_client import MOCK_WASHER_ID, MockThinqClient

#: 연습 종류 → 모의 기기 ID.
PRACTICE_DEVICE_IDS = {"washer": MOCK_WASHER_ID}


def practice_washer_client() -> MockThinqClient:
    """연습 세탁기 — 원격 제어 켜짐·대기 상태·남은 시간 예시. 값은 모두 모의(실제 세탁기 값 아님)."""
    client = MockThinqClient()
    client.set_remote_control(True)
    client.set_state(MOCK_WASHER_ID, {
        "runState": {"currentState": "INITIAL"},
        "remoteControlEnable": {"remoteControlEnabled": True},
        "timer": {"remainHour": 0, "remainMinute": 45},
    })
    return client


class PracticeMixClient:
    """실제 클라이언트 + 연습(모의) 기기. 기기 ID로 가른다."""

    def __init__(self, real, practice: MockThinqClient, practice_ids) -> None:
        self._real = real
        self._practice = practice
        self._practice_ids = frozenset(practice_ids)

    # 가르기
    @property
    def execution_mode(self) -> ExecutionMode:
        return getattr(self._real, "execution_mode", ExecutionMode.UNKNOWN)

    def is_practice(self, device_id: str) -> bool:
        return device_id in self._practice_ids

    def client_for(self, device_id: str):
        return self._practice if device_id in self._practice_ids else self._real

    def execution_mode_for(self, device_id: str) -> ExecutionMode:
        return getattr(self.client_for(device_id), "execution_mode", ExecutionMode.UNKNOWN)

    @property
    def practice_client(self) -> MockThinqClient:
        return self._practice

    # 포트
    def list_devices(self) -> tuple[ThinqDeviceInfo, ...]:
        return self._real.list_devices()

    def get_profile(self, device_id: str) -> dict:
        return self.client_for(device_id).get_profile(device_id)

    def get_status(self, device_id: str):
        return self.client_for(device_id).get_status(device_id)

    def post_control(self, device_id: str, payload: dict) -> dict:
        return self.client_for(device_id).post_control(device_id, payload)

    def cached_status(self, device_id: str):
        client = self.client_for(device_id)
        cached = getattr(client, "cached_status", None)
        return cached(device_id) if callable(cached) else client.get_status(device_id)

    def probe_online(self, device_id: str) -> bool:
        client = self.client_for(device_id)
        probe = getattr(client, "probe_online", None)
        if callable(probe):
            return probe(device_id)
        return any(d.device_id == device_id and d.online for d in client.list_devices())

    def forget_status(self, device_id: str) -> None:
        forget = getattr(self.client_for(device_id), "forget_status", None)
        if callable(forget):
            forget(device_id)

    def calls_last_minute(self) -> int:
        calls = getattr(self._real, "calls_last_minute", None)
        return calls() if callable(calls) else 0

    def close(self) -> None:
        close = getattr(self._real, "close", None)
        if callable(close):
            close()
