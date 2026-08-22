from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum

from pydantic import BaseModel, field_validator


def _normalize_appliance_id(v: str | None) -> str | None:
    """빈 문자열/공백은 '지정 안 함'과 같은 의미로 취급 — None으로 정규화."""
    if v is None:
        return None
    stripped = v.strip()
    return stripped or None


class ExecuteRequest(BaseModel):
    text: str
    source: str = "voice"
    # 지정하면 NodeRegistry에 등록된 해당 가전 노드로 라우팅, 없으면(또는
    # 등록 안 돼있으면) 로컬 기본 컨트롤러로 실행된다 — rpi/api/service.py의
    # SimpleLayService._controller_for() 참고.
    appliance_id: str | None = None

    @field_validator("text")
    @classmethod
    def text_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("text must not be blank")
        return v.strip()

    @field_validator("appliance_id")
    @classmethod
    def normalize_appliance_id(cls, v: str | None) -> str | None:
        return _normalize_appliance_id(v)


class ExecuteButtonsRequest(BaseModel):
    """직접 버튼 시퀀스 실행 — 의도 해석 규칙이 없는 사용자 정의 가전용.
    (규칙 기반 의도 해석기를 우회하므로, 알려진 목적 문자열 없이 버튼 라벨을
    그대로 넘긴다.)"""

    buttons: list[str]
    appliance_id: str | None = None

    @field_validator("buttons")
    @classmethod
    def buttons_not_empty(cls, v: list[str]) -> list[str]:
        cleaned = [b.strip() for b in v if b.strip()]
        if not cleaned:
            raise ValueError("buttons must not be empty")
        return cleaned

    @field_validator("appliance_id")
    @classmethod
    def normalize_appliance_id(cls, v: str | None) -> str | None:
        return _normalize_appliance_id(v)


class ExecuteForApplianceRequest(BaseModel):
    """자유발화 → 버튼 시퀀스 해석, 단 서버의 고정 규칙이 아니라 이 요청에 실려온
    버튼 라벨 어휘(사용자 정의 가전의 실제 버튼 배치)를 기준으로 LLM이 해석한다.
    LLM 클라이언트가 서버에 설정돼 있지 않으면 503으로 거부된다."""

    text: str
    known_buttons: list[str]
    appliance_id: str | None = None

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

    @field_validator("appliance_id")
    @classmethod
    def normalize_appliance_id(cls, v: str | None) -> str | None:
        return _normalize_appliance_id(v)


class NodeRegisterRequest(BaseModel):
    """가전 하나를 담당하는 원격 노드(현재: ESP32 dev-mode HTTP 서버)의 주소를
    등록한다. 같은 appliance_id로 다시 등록하면 주소가 교체된다."""

    base_url: str

    @field_validator("base_url")
    @classmethod
    def base_url_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("base_url must not be blank")
        return v.strip()


class NodeResponse(BaseModel):
    appliance_id: str
    base_url: str


class ButtonStep(BaseModel):
    button: str
    success: bool


class ExecuteResponse(BaseModel):
    status: str
    buttons: list[ButtonStep]


class JobAcceptedResponse(BaseModel):
    """실행 접수 응답(비동기 job 모델). 실기기에서 버튼 시퀀스는 수 초~수십 초
    걸리므로 실행 완료를 기다리지 않고 즉시 job_id를 돌려준다. 클라이언트는
    GET /status를 폴링하다가 running=false && last_job_id == 이 job_id가 되면
    last_status/last_buttons를 자기 실행의 결과로 읽는다."""

    job_id: str
    status: str = "accepted"


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
    # 비동기 job 모델: 실행 중이면 job_id에, 끝나면 last_job_id에 값이 있다.
    # 클라이언트는 자기가 제출한 job_id와 대조해 완료를 판정한다.
    job_id: str | None = None
    last_job_id: str | None = None
    # 진행바용 전체 단계 수 (실행 중일 때만). completed_steps와 조합해
    # 가짜 애니메이션 대신 실제 진행률을 그릴 수 있다.
    total_steps: int | None = None


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


class StopResponse(BaseModel):
    """POST /stop 응답. was_running으로 클라이언트가 "정지됨"과
    "실행 중인 작업 없음"을 구분해 표시할 수 있다. (기존 OkResponse와
    필드 호환 — ok만 보던 클라이언트는 그대로 동작한다.)"""

    ok: bool = True
    was_running: bool = False


class HealthResponse(BaseModel):
    ok: bool
    # coreXY 홈 위치 확인 + SwitchBot 연결 상태 통합 — 실기기 연결 후 교체
    actuator_ready: bool = True
    dnd_until: datetime | None = None


class DemoSuggestRequest(BaseModel):
    """POST /demo/suggest — 시연용 제안 강제 생성. 패턴 감지(이력 3회 +
    시간대 일치)를 우회해 지금 즉시 제안 카드를 띄운다. 결선 데모에서
    '선제 제안 → 승인 → 실행' 장면을 원하는 시점에 연출하기 위한 것."""

    purpose: str = "우유 데워줘"

    @field_validator("purpose")
    @classmethod
    def purpose_not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("purpose must not be blank")
        return v.strip()


class DemoInjectFailureRequest(BaseModel):
    """POST /demo/inject-failure — 다음 실행의 지정 버튼 검증을 강제 실패.

    결선 핵심 장면("일부러 실패시켜도 스스로 재시도")을 원할 때 연출하기
    위한 리허설 장치. attempts 1~2면 재시도 후 성공, 3 이상이면 재시도
    소진 → 안전 정지. 1회용(다음 실행에서 소진되면 자동 해제).
    """

    button_index: int = 0
    attempts: int = 1

    @field_validator("button_index")
    @classmethod
    def index_non_negative(cls, v: int) -> int:
        if v < 0:
            raise ValueError("button_index must be >= 0")
        return v

    @field_validator("attempts")
    @classmethod
    def attempts_in_range(cls, v: int) -> int:
        if not 1 <= v <= 10:
            raise ValueError("attempts must be between 1 and 10")
        return v


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
    # True면 실측이 아니라 mock 폴백값 — 이전엔 DHT22 실패 시 26.5°C를
    # 실측인 척 반환해 클라이언트가 구분할 수 없었다.
    mocked: bool = False


class AlertResponse(BaseModel):
    """RPi4가 자체발신하는 alert/alert_cleared 상태의 최신 스냅샷(이력 아님) --
    docs/protocol.md 참고. active=False면 kind 이하는 마지막으로 있었던 알림의
    잔여값일 수 있으니 무시해야 한다(한 번도 안 울렸으면 전부 None)."""

    active: bool
    kind: str | None = None
    band_energy_ratio: float | None = None
    mean_period_seconds: float | None = None
    updated_at: datetime | None = None
