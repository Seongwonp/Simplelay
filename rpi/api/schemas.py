from __future__ import annotations

from dataclasses import dataclass
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
