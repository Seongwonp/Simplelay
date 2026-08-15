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


class SuggestionResponse(BaseModel):
    id: str
    purpose: str
    time_band: str
    occurrences: int


class ApproveResponse(BaseModel):
    status: str
    buttons: list[ButtonStep]


class OkResponse(BaseModel):
    ok: bool = True
