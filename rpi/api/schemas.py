from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from urllib.parse import urlparse

from pydantic import BaseModel, field_validator

# ── 물리 실행 입력의 제품 계약(상한) ─────────────────────────────────────────
# 무한 입력은 장시간 물리 실행·거대 LLM 프롬프트·로그/DB 팽창으로 이어진다.
# 실사용 최대치의 몇 배 여유를 두고 명시적으로 자른다.
MAX_PURPOSE_LEN = 200        # 음성 발화 한 문장
MAX_BUTTONS_PER_RUN = 20     # 실사용 시퀀스는 2~5개
MAX_BUTTON_LABEL_LEN = 40
MAX_KNOWN_BUTTONS = 50       # 가전 버튼맵 상한(6x6 그리드 여유)
MAX_DND_MINUTES = 24 * 60

# ── 전송 경로 바이트 예산 (단일 기준값) ──────────────────────────────────────
# 개수·글자수 상한만으로는 전송 버퍼를 정할 수 없다. **한글은 UTF-8에서 3바이트**라
# "20개 × 40자"는 800바이트가 아니라 약 2.5KB다. 이 착각으로 버퍼를 800 기준으로
# 잡았다가, 큰 요청이 UART에서 조용히 잘리는 상태였다(교차 리뷰 지적).
#
# 그래서 글자 수가 아니라 **직렬화 바이트 수**를 여기서 한 번 정하고, 아래 경로가
# 전부 이 값에 맞춘다. 어느 한 곳이라도 이보다 작으면 그 지점에서 잘린다:
#   RPi5 --UART--> 게이트웨이 --ESP-NOW--> 노드 --UART--> RPi4
#   (firmware/include/config.h · firmware-node/include/config.h 의 JSON_BUF_SIZE와
#    ESPNOW_MAX_MESSAGE_BYTES가 봉투 여유를 더해 이 값보다 크게 잡혀 있어야 한다.
#    test_payload_budget.py가 그 관계를 고정한다.)
#
# 현재 상한(20개 × 40자, 전부 한글)의 최악값이 약 2,493바이트라 그것을 덮는 값으로
# 잡았다 — 지금 통과하던 요청이 새로 거절되지 않게 하는 것이 우선이다.
MAX_EXECUTE_PAYLOAD_BYTES = 2560


def _normalize_appliance_id(v: str | None) -> str | None:
    """빈 문자열/공백은 '지정 안 함'과 같은 의미로 취급 — None으로 정규화."""
    if v is None:
        return None
    stripped = v.strip()
    return stripped or None


def _validate_purpose_text(v: str) -> str:
    stripped = v.strip()
    if not stripped:
        raise ValueError("text must not be blank")
    if len(stripped) > MAX_PURPOSE_LEN:
        raise ValueError(f"text must be at most {MAX_PURPOSE_LEN} characters")
    return stripped


def execute_payload_bytes(labels: list[str]) -> int:
    """이 버튼 목록이 전송 경로에서 차지할 직렬화 바이트 수.

    글자 수가 아니라 바이트로 재는 이유는 MAX_EXECUTE_PAYLOAD_BYTES 주석 참고.
    """
    return len(json.dumps(labels, ensure_ascii=False).encode("utf-8"))


def _validate_button_list(
    v: list[str], max_items: int, name: str, *, byte_budget: int | None = None
) -> list[str]:
    cleaned = [b.strip() for b in v if b.strip()]
    if not cleaned:
        raise ValueError(f"{name} must not be empty")
    if len(cleaned) > max_items:
        raise ValueError(f"{name} must have at most {max_items} items")
    for label in cleaned:
        if len(label) > MAX_BUTTON_LABEL_LEN:
            raise ValueError(
                f"button label must be at most {MAX_BUTTON_LABEL_LEN} characters"
            )
    # 실제로 전송되는 목록만 바이트 예산을 적용한다. known_buttons는 LLM 프롬프트로만
    # 쓰이고 노드로 나가지 않으므로 이 예산의 대상이 아니다.
    if byte_budget is not None:
        size = execute_payload_bytes(cleaned)
        if size > byte_budget:
            raise ValueError(
                f"{name} is {size} bytes, over the {byte_budget}-byte transport "
                f"budget (labels are UTF-8; Korean characters are 3 bytes each)"
            )
    return cleaned


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
        return _validate_purpose_text(v)

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
        return _validate_button_list(
            v, MAX_BUTTONS_PER_RUN, "buttons",
            byte_budget=MAX_EXECUTE_PAYLOAD_BYTES,
        )

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
        return _validate_purpose_text(v)

    @field_validator("known_buttons")
    @classmethod
    def known_buttons_not_empty(cls, v: list[str]) -> list[str]:
        return _validate_button_list(v, MAX_KNOWN_BUTTONS, "known_buttons")

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
    def base_url_valid(cls, v: str) -> str:
        """실행 트래픽이 전달될 주소 — file:// 등 이상 스킴, userinfo 포함
        URL, 호스트 없는 값이 등록되면 물리 실행 요청이 엉뚱한 곳으로 간다."""
        stripped = v.strip()
        if not stripped:
            raise ValueError("base_url must not be blank")
        parsed = urlparse(stripped)
        if parsed.scheme not in ("http", "https"):
            raise ValueError("base_url must use http or https")
        if not parsed.hostname:
            raise ValueError("base_url must include a host")
        if parsed.username or parsed.password:
            raise ValueError("base_url must not contain credentials")
        try:
            port = parsed.port  # 잘못된 포트는 여기서 ValueError
        except ValueError as exc:
            raise ValueError("base_url has an invalid port") from exc
        if port is not None and not 1 <= port <= 65535:
            raise ValueError("base_url has an invalid port")
        return stripped


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
    reason: str = ""


class ApproveResponse(BaseModel):
    status: str
    buttons: list[ButtonStep]


class HistoryButton(BaseModel):
    button: str
    success: bool
    attempts: int


class HistoryEntryResponse(BaseModel):
    """GET /history — 실행 1건의 이력. retry_count > 0이면 폐루프가 실제로
    회복 재시도를 했다는 뜻(앱 타임라인에서 배지로 강조)."""

    job_id: str
    finished_at: datetime
    purpose: str | None = None  # 버튼 직접 실행(수동 조작)은 없다
    status: str
    retry_count: int
    buttons: list[HistoryButton]


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
    # 현재 Act 경로 — "local"(mock 폐루프) | "uart"(RPi4 실연결).
    # 화면엔 성공인데 실물이 안 움직이는 오설정(모드 미전환)을 즉시 탐지용.
    act_mode: str = "local"


class DemoSuggestRequest(BaseModel):
    """POST /demo/suggest — 시연용 제안 강제 생성. 패턴 감지(이력 3회 +
    시간대 일치)를 우회해 지금 즉시 제안 카드를 띄운다. 결선 데모에서
    '선제 제안 → 승인 → 실행' 장면을 원하는 시점에 연출하기 위한 것."""

    purpose: str = "즉석밥 데워줘"

    @field_validator("purpose")
    @classmethod
    def purpose_not_blank(cls, v: str) -> str:
        return _validate_purpose_text(v)


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


class PresenceRequest(BaseModel):
    """POST /presence — 공간 존재 감지기(RPi4 카메라 등)가 판정을 보고한다."""

    present: bool
    source: str = "camera"


class PresenceResponse(BaseModel):
    # present=None: 감지기 없음 또는 정보 만료(TTL) — '알 수 없음'
    present: bool | None = None
    source: str | None = None
    updated_at: datetime | None = None


class DndRequest(BaseModel):
    duration_minutes: int

    @field_validator("duration_minutes")
    @classmethod
    def positive(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("duration_minutes must be positive")
        if v > MAX_DND_MINUTES:
            raise ValueError(
                f"duration_minutes must be at most {MAX_DND_MINUTES} (24h)"
            )
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


class RejectSuggestionRequest(BaseModel):
    """POST /suggestions/{id}/reject 본문(선택). mute=True면 "다시 추천 안 함"."""

    mute: bool = False


class SuppressionListResponse(BaseModel):
    """다시 추천 안 하는 루틴 목록(설정 화면용)."""

    purposes: list[str]


class UnmuteRequest(BaseModel):
    """POST /suppressions/unmute 본문 -- 억제 해제할 루틴."""

    purpose: str


class DemoEnvironmentRequest(BaseModel):
    """POST /demo/environment -- 시연용 온습도 강제값(센서 미연결 대비)."""

    temperature: float
    humidity: float

