from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum

from pydantic import BaseModel, field_validator


class ExecuteRequest(BaseModel):
    text: str
    source: str = "voice"

    @field_validator("text")
    @classmethod
    def text_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("text must not be blank")
        return v.strip()


class ExecuteButtonsRequest(BaseModel):
    """직접 버튼 시퀀스 실행 — 의도 해석 규칙이 없는 사용자 정의 가전용.
    (규칙 기반 의도 해석기를 우회하므로, 알려진 목적 문자열 없이 버튼 라벨을
    그대로 넘긴다.)"""

    buttons: list[str]

    @field_validator("buttons")
    @classmethod
    def buttons_not_empty(cls, v: list[str]) -> list[str]:
        cleaned = [b.strip() for b in v if b.strip()]
        if not cleaned:
            raise ValueError("buttons must not be empty")
        return cleaned


class ExecuteForApplianceRequest(BaseModel):
    """자유발화 → 버튼 시퀀스 해석, 단 서버의 고정 규칙이 아니라 이 요청에 실려온
    버튼 라벨 어휘(사용자 정의 가전의 실제 버튼 배치)를 기준으로 LLM이 해석한다.
    LLM 클라이언트가 서버에 설정돼 있지 않으면 503으로 거부된다."""

    text: str
    known_buttons: list[str]

    @field_validator("text")
    @classmethod
    def text_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("text must not be blank")
        return v.strip()

    @field_validator("known_buttons")
    @classmethod
    def known_buttons_not_empty(cls, v: list[str]) -> list[str]:
        cleaned = [b.strip() for b in v if b.strip()]
        if not cleaned:
            raise ValueError("known_buttons must not be empty")
        return cleaned


class ButtonStep(BaseModel):
    button: str
    success: bool


class ExecuteResponse(BaseModel):
    status: str
    buttons: list[ButtonStep]


class StatusResponse(BaseModel):
    running: bool
    last_status: str | None
    last_buttons: list[ButtonStep] | None
    # 실행 중 실시간 진행 상황 (running=True일 때만 값이 있음). 원시 센서값(mA/dB)이
    # 아니라 검증기가 이미 계산한 신뢰도·상세 설명을 노출한다 — verifier가 그 이상의
    # 원시값을 구조화된 필드로 내보내지 않기 때문에, 없는 값을 지어내지 않는다.
    current_button: str | None = None
    current_attempt: int | None = None
    completed_steps: int | None = None
    verification_confidence: float | None = None
    verification_detail: str | None = None


class SuggestionResponse(BaseModel):
    id: str
    purpose: str
    time_band: str
    occurrences: int
    # 미리보기. 서버가 승인 전에 계산은 해 보지만, 실제 실행 시퀀스는 승인 시점에
    # 다시 해석되므로 이 값과 달라질 수 있다(예: 규칙이 그 사이 바뀐 경우).
    steps: list[str] = []


class ApproveResponse(BaseModel):
    status: str
    buttons: list[ButtonStep]


class OkResponse(BaseModel):
    ok: bool = True


class HealthResponse(BaseModel):
    ok: bool
    # coreXY 홈 위치 확인 + SwitchBot 연결 상태 통합 — 실기기 연결 후 교체
    actuator_ready: bool = True
    dnd_until: datetime | None = None


class DndRequest(BaseModel):
    duration_minutes: int

    @field_validator("duration_minutes")
    @classmethod
    def positive(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("duration_minutes must be positive")
        return v


class SensorResponse(BaseModel):
    temperature: float | None = None
    humidity: float | None = None
