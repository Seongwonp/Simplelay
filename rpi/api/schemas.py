from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import date, datetime
from enum import Enum
from urllib.parse import urlparse

import math

from typing import Annotated, Literal

from pydantic import BaseModel, Field, field_validator, model_validator
from .job_receipts import CLIENT_REQUEST_ID_PATTERN

# 물리 실행 입력의 제품 계약(상한)
# 무한 입력은 장시간 물리 실행·거대 LLM 프롬프트·로그/DB 팽창으로 이어진다.
# 실사용 최대치의 몇 배 여유를 두고 명시적으로 자른다.
MAX_PURPOSE_LEN = 200        # 음성 발화 한 문장
MAX_BUTTONS_PER_RUN = 20     # 실사용 시퀀스는 2~5개
MAX_BUTTON_LABEL_LEN = 40
MAX_KNOWN_BUTTONS = 50       # 가전 버튼맵 상한(6x6 그리드 여유)
MAX_DND_MINUTES = 24 * 60

# 전송 경로 바이트 예산 (단일 기준값)
# 개수·글자수 상한만으로는 전송 버퍼를 정할 수 없다. **한글은 UTF-8에서 3바이트**라
# "20개 × 40자"는 800바이트가 아니라 약 2.5KB다. 이 착각으로 버퍼를 800 기준으로
# 잡았다가 큰 요청이 UART에서 조용히 잘릴 수 있다.
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
    #: 선택(검토 10/19) — 클라이언트 요청 번호(영문·숫자·_·- 1~64자). 같은 번호로 다시 보내면 같은 job_id(다시 실행 안 함).
    client_request_id: str | None = Field(default=None, pattern=CLIENT_REQUEST_ID_PATTERN)
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
    #: 선택(검토 10/19) — 클라이언트 요청 번호(영문·숫자·_·- 1~64자). 같은 번호로 다시 보내면 같은 job_id(다시 실행 안 함).
    client_request_id: str | None = Field(default=None, pattern=CLIENT_REQUEST_ID_PATTERN)

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
    #: 선택(검토 10/19) — 클라이언트 요청 번호(영문·숫자·_·- 1~64자). 같은 번호로 다시 보내면 같은 job_id(다시 실행 안 함).
    client_request_id: str | None = Field(default=None, pattern=CLIENT_REQUEST_ID_PATTERN)

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


class ApplianceButtonModel(BaseModel):
    id: str
    label: str
    x: int
    y: int
    # 버튼맵 확장 — 모두 선택. 구버전 폰·키오스크는 보내지도 읽지도 않는다
    #: button | dial. 모르는 값은 거절한다(누르기·돌리기는 다른 물리 동작).
    behavior: str = "unknown"

    @field_validator("behavior", mode="before")
    @classmethod
    def normalize_behavior(cls, value):
        from rpi.controller.models import button_behavior
        return button_behavior(value)

    kind: str = "button"
    #: 다이얼 전용 딸깍 수.
    detents: int | None = None
    #: 누름 유지 시간(ms). 없으면 하드웨어 프로필 기본값.
    press_ms: int | None = None
    #: 갠트리 좌표(mm) — 캘리브레이션·수동 티칭이 채운다. 둘은 함께 온다.
    x_mm: float | None = None
    y_mm: float | None = None

    @field_validator("id", "label")
    @classmethod
    def not_blank(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("must not be blank")
        if len(stripped) > MAX_BUTTON_LABEL_LEN:
            raise ValueError(f"must be at most {MAX_BUTTON_LABEL_LEN} characters")
        return stripped

    @field_validator("kind")
    @classmethod
    def kind_known(cls, v: str) -> str:
        from rpi.services.appliance_registry import ButtonKind  # noqa: PLC0415

        return ButtonKind.parse(v).value

    @field_validator("press_ms")
    @classmethod
    def press_ms_in_range(cls, v: int | None) -> int | None:
        from rpi.services.appliance_registry import PRESS_MS_RANGE  # noqa: PLC0415

        if v is not None and not PRESS_MS_RANGE[0] <= v <= PRESS_MS_RANGE[1]:
            raise ValueError(
                f"press_ms must be between {PRESS_MS_RANGE[0]} and {PRESS_MS_RANGE[1]}"
            )
        return v

    @field_validator("x_mm", "y_mm")
    @classmethod
    def mm_in_frame(cls, v: float | None) -> float | None:
        from rpi.services.appliance_registry import MM_RANGE  # noqa: PLC0415

        if v is None:
            return v
        if not math.isfinite(v) or not MM_RANGE[0] <= v <= MM_RANGE[1]:
            raise ValueError(f"mm coordinate must be within {MM_RANGE[0]}..{MM_RANGE[1]}")
        return v

    @model_validator(mode="after")
    def kind_consistent(self) -> "ApplianceButtonModel":
        from rpi.services.appliance_registry import DETENTS_RANGE  # noqa: PLC0415

        if self.kind == "dial":
            if self.detents is None or not DETENTS_RANGE[0] <= self.detents <= DETENTS_RANGE[1]:
                raise ValueError(
                    f"dial '{self.label}' needs detents between "
                    f"{DETENTS_RANGE[0]} and {DETENTS_RANGE[1]}"
                )
        elif self.detents is not None:
            raise ValueError(f"button '{self.label}' must not have detents")
        if (self.x_mm is None) != (self.y_mm is None):
            raise ValueError("x_mm and y_mm must be given together")
        return self


class ApplianceResponse(BaseModel):
    """GET /appliances 한 항목 — 폰·키오스크가 같은 정의를 받는 지점.
    icon은 클라이언트용 힌트 문자열(모르면 기본 아이콘을 쓴다)."""

    id: str
    name: str
    #: 이 기기의 **종류**. 아이콘·이름은 여기서 파생한다.
    category: str
    #: 구버전 클라이언트 호환 — category에서 파생한 값이다.
    icon: str
    rows: int
    cols: int
    is_custom: bool
    # 이 가전을 무엇으로 조작하는가 -- physical(갠트리가 버튼을 누름) 또는
    # thinq(클라우드 가전). 추가 필드라 옛 클라이언트는 그냥 무시한다.
    # 없으면 종전대로 물리 경로로 읽는다.
    control_path: str = "physical"
    buttons: list[ApplianceButtonModel]
    # 저장할 때마다 오르는 판 번호. 클라이언트가 "내가 본 판"을 밝히고
    # 저장하면 그 사이 다른 기기가 먼저 바꿨는지 서버가 가려준다.
    revision: int = 0
    # 준비 상태 (F1)
    # disconnected | needs_setup | operable. **등록됐다는 것과 조작할 수
    # 있다는 것은 다르다** -- heartbeat만으로 operable을 선언하지 않는다.
    readiness: str = "disconnected"
    # 맡길 수 없는 이유들. '안 됩니다'만 말하면 사용자가 할 수 있는
    # 일이 없다.
    readiness_reasons: list[str] = []
    # 노드로 라우팅되지 않는 가전(내장)은 종전대로 로컬에서 실행된다.
    # 그래서 readiness가 disconnected여도 실행은 가능하다 -- 화면이
    # 버튼을 막을지 정할 때는 이 값을 본다.
    can_execute: bool = True
    # 목적 → 단계("라벨" 누름, "라벨:+N" 다이얼). 없으면 빈 사전.
    functions: dict[str, list[str]] = {}
    # 버튼 mm 좌표를 만든 보정 결과의 버전. 보정 전이거나 무효화되면 None.
    calibration_version: str | None = None
    # 정지 대기·보관(2026-09-30). 옛 클라이언트는 무시한다
    #: 정지(취소) 버튼 id와 정지까지 누를 횟수(1~3).
    stop_button: str | None = None
    stop_presses: int = 1
    #: 보관 위치(갠트리 mm) [x, y].
    park_xy: list[float] | None = None
    #: {status: ok|unverified|incomplete|none, notes: [...]} — unverified는 "범위 미확인".
    stop_park_check: dict | None = None
    #: 사진 매핑 기록(사진 크기·모서리·버튼 px). 가전 상세가 사진 위에 버튼을 그릴 때 쓴다.
    panel_mapping: dict | None = None
    #: 놓인 곳(방 이름, 선택 — 2026-10-19). 없으면 키를 싣지 않던 옛 응답과 같게 null.
    location: str | None = None


class WellnessPauseRequest(BaseModel):
    """POST /wellness-pause — 안부 확인을 그 날짜까지 쉰다.

    무기한은 받지 않는다. 꺼둔 것을 잊으면 안부 기능이 있는 채로 없는
    것과 같아지므로, 종료 날짜를 반드시 받는다.
    """

    until: date


class WellnessPauseResponse(BaseModel):
    paused: bool
    until: date | None = None


class ReadinessReportRequest(BaseModel):
    """POST /readiness/{appliance_id} — 노드(또는 설치 도구)가 자기
    준비 상태를 보고한다.

    실제 판정은 하드웨어가 붙은 뒤 노드 쪽에서 한다. 서버는 그 보고를
    받아 두고 유효기간이 지나면 '다시 확인해야 함'으로 되돌린다 --
    한참 전에 한 번 확인했다는 것은 지금 조작해도 된다는 뜻이 아니다.
    """

    transport: bool = False
    motion: bool = False
    sensor: bool = False
    calibration: bool = False
    #: 축별 사유(선택). 키는 위 네 이름.
    reasons: dict[str, str] = {}
    calibration_profile_version: str | None = None


class ApplianceRegisterRequest(BaseModel):
    """PUT /appliances/{id} — 폰 가전 편집기가 저장할 때 서버에도 등록한다.
    이 정의는 그대로 키오스크 조작판이 되고 액추에이터가 누를 물리 버튼의
    거울이므로, 그리드 밖 좌표·중복 위치처럼 물리적으로 성립 안 하는 값은
    등록 시점에 거른다."""

    #: "내가 본 판은 이거였다". 그 사이 다른 기기가 먼저 바꿨으면 409로
    #: 거절하고 서버 내용을 유지한다. 밝히지 않으면(None) 종전대로 저장 --
    #: 최초 등록과 구버전 클라이언트의 경로다.
    expected_revision: int | None = None

    name: str
    #: 이 기기의 **종류**. 모르는 값이면 거절하지 않고 other로 받는다 --
    #: 앞선 버전의 폰이 새 종류를 보낼 수 있고, 거절하면 그 기기는
    #: 가전을 등록할 수 없게 된다.
    category: str | None = None
    #: 구버전 클라이언트 호환. category가 없을 때만 여기서 되살린다.
    icon: str | None = None
    rows: int
    cols: int
    buttons: list[ApplianceButtonModel]
    #: 목적별 시퀀스(선택). 등록 시점에 이 조작부로 실행 가능한지 검증한다.
    functions: dict[str, list[str]] | None = None
    #: 정지 대기·보관(선택, 2026-09-30). 셋 다 없으면 저장된 값을 이어받는다.
    stop_button: str | None = None
    stop_presses: int | None = None
    park_xy: list[float] | None = None
    #: 놓인 곳(방 이름, 선택 — 2026-10-19). 보내지 않으면 저장된 값을 이어받고, 빈 문자열이면 지운다.
    location: str | None = None

    @field_validator("location")
    @classmethod
    def location_short(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        if len(stripped) > MAX_BUTTON_LABEL_LEN:
            raise ValueError(f"location must be at most {MAX_BUTTON_LABEL_LEN} characters")
        return stripped

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        if len(stripped) > MAX_BUTTON_LABEL_LEN:
            raise ValueError(
                f"name must be at most {MAX_BUTTON_LABEL_LEN} characters"
            )
        return stripped

    @field_validator("rows", "cols")
    @classmethod
    def grid_in_range(cls, v: int) -> int:
        if not 1 <= v <= 8:
            raise ValueError("grid must be between 1x1 and 8x8")
        return v

    @field_validator("icon")
    @classmethod
    def icon_short(cls, v: str) -> str:
        # 클라이언트용 힌트 문자열일 뿐 — 긴 값이 DB·키오스크 응답에
        # 실릴 이유가 없다
        stripped = v.strip() or "custom"
        if len(stripped) > 32:
            raise ValueError("icon hint must be at most 32 characters")
        return stripped

    @field_validator("buttons")
    @classmethod
    def buttons_valid(
        cls, v: list[ApplianceButtonModel]
    ) -> list[ApplianceButtonModel]:
        if not v:
            raise ValueError("buttons must not be empty")
        if len(v) > MAX_KNOWN_BUTTONS:
            raise ValueError(f"at most {MAX_KNOWN_BUTTONS} buttons")
        # id·라벨 중복 금지 — 실행은 라벨로 전송되므로 같은 라벨의 물리
        # 버튼 두 개는 어느 좌표를 누를지 구분할 수 없다.
        ids = [b.id for b in v]
        if len(set(ids)) != len(ids):
            raise ValueError("duplicate button id")
        labels = [b.label for b in v]
        if len(set(labels)) != len(labels):
            raise ValueError(
                "duplicate button label — 실행이 라벨 기준이라 구분 불가"
            )
        return v

    def validate_layout(self) -> None:
        """그리드 좌표 검증 — rows/cols가 파싱된 뒤에만 가능해서 별도 메서드
        (라우터가 호출한다)."""
        seen: set[tuple[int, int]] = set()
        for b in self.buttons:
            if not (0 <= b.x < self.cols and 0 <= b.y < self.rows):
                raise ValueError(
                    f"button '{b.label}' at ({b.x},{b.y}) is outside the "
                    f"{self.rows}x{self.cols} grid"
                )
            if (b.x, b.y) in seen:
                raise ValueError(f"duplicate button position ({b.x},{b.y})")
            seen.add((b.x, b.y))
        if self.functions:
            from rpi.services.appliance_registry import (  # noqa: PLC0415
                validate_functions,
            )

            validate_functions(self.button_defs(), self.functions)

    def button_defs(self) -> tuple:
        """요청 버튼을 레지스트리 정의로 — 라우터와 검증이 같은 변환을 쓴다."""
        from rpi.services.appliance_registry import (  # noqa: PLC0415
            ApplianceButtonDef,
            ButtonKind,
        )

        return tuple(
            ApplianceButtonDef(
                id=b.id,
                label=b.label,
                x=b.x,
                y=b.y,
                kind=ButtonKind.parse(b.kind),
                behavior=b.behavior,
                detents=b.detents,
                press_ms=b.press_ms,
                x_mm=b.x_mm,
                y_mm=b.y_mm,
            )
            for b in self.buttons
        )


class CalibrationPointModel(BaseModel):
    #: 패널·이미지 좌표계의 기준점
    source: tuple[float, float]
    #: 같은 기준점의 갠트리 좌표(mm)
    target: tuple[float, float]


class ApplianceCalibrationRequest(BaseModel):
    """PUT /appliances/{id}/calibration — 기준점으로 변환을 구해 버튼 mm를 확정한다.

    ``button_centers``는 기준점과 **같은 좌표계**의 버튼 중심이다(촬영 이미지
    또는 패널 도면). 촬영·검출은 이 요청을 만드는 쪽의 몫이다.
    """

    expected_revision: int | None = None
    kind: str = "affine"
    points: list[CalibrationPointModel]
    button_centers: dict[str, tuple[float, float]]
    max_rms_mm: float | None = None
    max_point_error_mm: float | None = None

    @field_validator("points")
    @classmethod
    def points_bounded(cls, v: list[CalibrationPointModel]) -> list[CalibrationPointModel]:
        if not 3 <= len(v) <= 50:
            raise ValueError("points must contain 3 to 50 reference points")
        return v

    @field_validator("button_centers")
    @classmethod
    def centers_bounded(cls, v: dict[str, tuple[float, float]]) -> dict[str, tuple[float, float]]:
        if not 1 <= len(v) <= MAX_KNOWN_BUTTONS:
            raise ValueError(f"button_centers must contain 1 to {MAX_KNOWN_BUTTONS} buttons")
        return v


class ApplianceCalibrationResponse(BaseModel):
    appliance: ApplianceResponse
    version: str
    kind: str
    point_count: int
    redundant_points: int
    rms_error_mm: float
    max_error_mm: float
    #: 이번 보정에 포함되지 않아 mm 좌표가 없는 버튼 — 누를 수 없다
    unmapped_buttons: list[str]


#: 조작부 사진 한 장 상한(디코딩 후). 휴대폰 사진을 줄여 보내면 1~2MB면 충분하다.
PANEL_SCAN_MAX_IMAGE_BYTES = 8 * 1024 * 1024


def _decode_panel_image(value: str) -> tuple[bytes, str]:
    """base64(또는 data URI) → (바이트, 형식). 형식은 머리 바이트로만 정한다."""
    import binascii  # noqa: PLC0415

    from rpi.vision import sniff_image_mime  # noqa: PLC0415

    text = value.strip()
    if text.startswith("data:"):
        _, _, text = text.partition(",")
    text = "".join(text.split())
    limit_mb = PANEL_SCAN_MAX_IMAGE_BYTES / (1024 * 1024)
    if len(text) > (PANEL_SCAN_MAX_IMAGE_BYTES + 2) // 3 * 4:
        raise ValueError(f"사진이 너무 커요 (최대 {limit_mb:g}MB)")
    try:
        data = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("사진 데이터가 올바른 base64가 아니에요") from exc
    if not data:
        raise ValueError("사진 데이터가 비어 있어요")
    if len(data) > PANEL_SCAN_MAX_IMAGE_BYTES:
        raise ValueError(f"사진이 너무 커요 (최대 {limit_mb:g}MB)")
    mime = sniff_image_mime(data)
    if mime is None:
        raise ValueError("JPEG·PNG·WebP 사진만 받을 수 있어요")
    return data, mime


class PanelScanRequest(BaseModel):
    """POST /panel-scan — 조작부 사진으로 버튼맵 **초안**을 만든다(저장하지 않음).

    ``reference_points``를 주면 사진 좌표(0~1000 정규화)를 갠트리 mm로 옮겨
    초안에 싣는다. 사진은 서버가 저장하거나 기록하지 않는다.
    """

    image_base64: str
    kind: str = "affine"
    #: source = 사진 좌표(0~1000), target = 같은 지점의 갠트리 mm
    reference_points: list[CalibrationPointModel] | None = None

    @field_validator("image_base64")
    @classmethod
    def image_valid(cls, v: str) -> str:
        _decode_panel_image(v)
        return v

    @field_validator("reference_points")
    @classmethod
    def reference_points_bounded(
        cls, v: list[CalibrationPointModel] | None
    ) -> list[CalibrationPointModel] | None:
        if v is not None and not 3 <= len(v) <= 50:
            raise ValueError("reference_points must contain 3 to 50 points")
        return v

    def image(self) -> tuple[bytes, str]:
        return _decode_panel_image(self.image_base64)


class PanelScanButtonModel(BaseModel):
    id: str
    label: str
    #: 편집기 격자 칸
    x: int
    y: int
    kind: str
    #: 사진 좌표(0~1000) [x_min, y_min, x_max, y_max]와 중심
    box: list[float]
    center: list[float]
    #: False면 모델이 이름을 읽지 못해 임시 이름을 붙였다
    label_from_model: bool
    #: 기준점을 줬을 때만 채워진다
    x_mm: float | None = None
    y_mm: float | None = None


class PanelScanCalibrationModel(BaseModel):
    version: str
    kind: str
    point_count: int
    redundant_points: int
    rms_error_mm: float
    max_error_mm: float


class PanelScanResponse(BaseModel):
    rows: int
    cols: int
    buttons: list[PanelScanButtonModel]
    #: 인식 결과에서 뺀 항목과 이유
    dropped: list[str]
    #: 저장 전에 사람이 확인할 것
    notes: list[str]
    #: 인식에 쓴 모델 id(실험 기록용)
    model: str
    calibration: PanelScanCalibrationModel | None = None


class PresenceDistanceRequest(BaseModel):
    """POST /presence/distance — 거리 센서(레이더) 한 주기의 관측값.

    ``distance_m``가 None이면 이번 주기에는 사람이 감지되지 않았다는 뜻이다.
    """

    distance_m: float | None = None

    @field_validator("distance_m")
    @classmethod
    def distance_valid(cls, v: float | None) -> float | None:
        if v is not None and (not math.isfinite(v) or v < 0):
            raise ValueError("distance_m must be a non-negative finite number")
        return v


class PresenceTransitionModel(BaseModel):
    at_s: float
    previous: str
    current: str
    reason: str
    actions: list[str]


class PresenceStateResponse(BaseModel):
    state: str
    executing: bool
    arrival_hint: bool
    radar: bool
    node_awake: bool
    screen_on: bool
    actuator_powered: bool
    #: 설계 추정치(최소, 최대 W) — 실측 전
    estimated_watts: list[float]
    #: 이번 요청으로 일어난 전이
    transitions: list[PresenceTransitionModel]


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
    #: 이 버튼을 실제로 누른 횟수(재시도 포함). 옛 클라이언트는 무시한다(2026-09-29).
    attempts: int | None = None


class ExecuteResponse(BaseModel):
    status: str
    buttons: list[ButtonStep]


class ApproveSuggestionRequest(BaseModel):
    """``POST /suggestions/{id}/approve``의 선택 본문(검토 10/19). 본문 없이 보내도 종전 그대로."""

    client_request_id: str | None = Field(default=None, pattern=CLIENT_REQUEST_ID_PATTERN)


class JobByRequestResponse(BaseModel):
    """``GET /jobs/by-request/{client_request_id}`` — 그 요청 번호로 접수한 실행 번호."""

    client_request_id: str
    job_id: str


class JobAcceptedResponse(BaseModel):
    """실행 접수 응답(비동기 job 모델). 실기기에서 버튼 시퀀스는 수 초~수십 초
    걸리므로 실행 완료를 기다리지 않고 즉시 job_id를 돌려준다. 클라이언트는
    GET /status를 폴링하다가 running=false && last_job_id == 이 job_id가 되면
    last_status/last_buttons를 자기 실행의 결과로 읽는다.

    정지어(2026-10-16 안전 보고 G7): ``POST /execute``·``/execute-for-appliance``의 발화 전체가 정지어("멈춰"·"그만" 등,
    ``rpi/intent/stop_words.py``)면 버튼을 누르지 않고 ``POST /stop``과 같은 일을 한 뒤 ``status: "stopped"``와
    ``stop``(``POST /stop`` 응답과 같은 모양)을 돌려준다. 이때 ``job_id``는 **멈춘 실행의 job**(실행 중이었을 때)이고, 멈출
    실행이 없었으면 빈 문자열이다 — 새 job은 만들지 않는다."""

    job_id: str
    status: str = "accepted"
    stop: "StopResponse | None" = None


class StatusResponse(BaseModel):
    running: bool
    #: 서버 개발자 모드(SIMPLELAY_DEV_MODE) 여부. 앱은 이 값이 true일 때만
    #: "개발자" 탭을 띄운다(2026-09-30). 옛 클라이언트는 무시한다.
    developer_mode: bool = False
    # 정지 대기·보관(2026-09-30) — RPi4 보고를 옮긴다. 옛 클라이언트는 무시한다
    #: hovering_stop | stopping | parking | parked | fault | released | None(대기 없음)
    hold_state: str | None = None
    #: stopped(정지됨·전력 하강 확인) | requested_unconfirmed(정지 요청함·미확인) |
    #: drive_fault(구동부 이상으로 버튼 정지 못 함) | None
    hold_stop_outcome: str | None = None
    hold_detail: str | None = None
    hold_appliance_id: str | None = None
    hold_stop_button: str | None = None
    #: 대기 보고의 실행 환경(mock | real | unknown)
    hold_execution_mode: str | None = None
    #: 시뮬레이터만(2026-10-06, 시연 v3 갭 M3). 대기 위치 출처: mock(모의 위치 — 실물 좌표 아님) |
    #: calibrated(사진 매핑 mm) | None
    hold_position_source: str | None = None
    #: 가전 켜짐 근거: mock(모의 가전) | real | none(전력 리더 없음) | None
    hold_probe_source: str | None = None
    #: 대기를 하지 않은 이유(no_stop_button | no_appliance | no_park_position). 이때 hold_state는 null이다.
    hold_unavailable_reason: str | None = None
    # 콘센트 모듈 비상정지 걸림(2026-10-05) — RPi4 보고. 옛 클라이언트는 무시한다
    #: true면 POST /stop/ack로 해제 확인 전까지 실행을 거절한다. 보고 수단이 없는 실행기면 None.
    estop_latched: bool | None = None
    estop_detail: str | None = None
    #: RPi4(누름 장치) 링크(2026-10-06 인계 §6). false면 끊김·첫 연결 전 — 실행은 거절된다.
    #: 링크를 보고하지 않는 실행 대상(로컬 모의 등)이면 null. 옛 클라이언트는 무시한다.
    actuator_link_up: bool | None = None
    last_status: str | None
    #: success | failed | stopped | safety_stop — 화면이 "정지됨"(stopped)과
    #: "실패"(failed·safety_stop)를 가르는 값. last_status의 safety_stopped는
    #: 정지 요청과 검증 실패 안전 정지를 뭉갠다(2026-09-29 추가, 옛 클라이언트는 무시).
    last_outcome: str | None = None
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
    # 이 실행이 **대상으로 삼은** 가전. 실행 중이면 appliance_id, 끝나면
    # last_appliance_id에 값이 있다(job_id와 같은 규칙).
    #
    # 화면이 이 값을 안 받으면 버튼 이름을 "지금 고른 가전"의 버튼맵으로
    # 읽게 되는데, 실행 중에 다른 가전을 고르면 그 순간 화면이 틀린 버튼
    # 이름을 말한다. 대상은 실행이 정하지, 화면이 정하지 않는다.
    appliance_id: str | None = None
    last_appliance_id: str | None = None
    execution_mode: str = "unknown"
    last_execution_mode: str = "unknown"
    # 명령 계약(U1-a) — 실행 환경(real/mock)과 독립인 축. 옛 클라이언트는 무시한다.
    #: 제어 경로 physical | thinq (실행 중 / 마지막).
    route: str | None = None
    last_route: str | None = None
    #: 상대가 받았나: accepted | unknown | not_dispatched.
    last_receipt: str | None = None
    #: 확인 근거: none | reported | press_confirmed | state_confirmed | operation_confirmed | already_at_target.
    #: ThinQ의 "접수됨"은 receipt=accepted·confirmation=none, "상태 확인됨"은 state_confirmed.
    #: already_at_target(2026-10-14)은 보내기 전 조회에서 이미 목표값이라 보내지 않은 성공(receipt=not_dispatched).
    last_confirmation: str | None = None
    #: 사람이 읽을 한 줄(ThinQ 결과). ThinQ면 last_status가 unconfirmed일 수 있다(실패 아님).
    last_detail: str | None = None
    # 2026-09-29 (G1·G2) — 옛 클라이언트는 무시한다.
    #: 마지막 물리 실행의 재시도 합(버튼별 시도 수 - 1의 합). ThinQ·버튼 결과 없음이면 None.
    last_retry_count: int | None = None
    #: L3(가전 동작) 판정 true/false. 판정기가 없거나 판정하지 못했으면 None.
    last_operation_confirmed: bool | None = None
    #: 판정 입력 real | mock(합성 전력). mock의 true는 실제 동작 근거가 아니다.
    last_operation_source: str | None = None
    last_operation_detail: str | None = None
    #: 마지막 물리 실행이 모션 걸림·재시작·기한 초과·준비 안 됨으로 재시도 없이 멈췄다면 그 원인(2026-10-14).
    last_abort_reason: str | None = None
    #: 결과가 나온 마지막 자동 실행(허용 규칙, 2026-10-14) — 키오스크 짧은 알림용. {job_id, at, outcome, status,
    #: receipt, confirmation, execution_mode, target_name, setting_label, value_label, run_id, undo_until,
    #: undo_remaining_s(되돌리기 남은 초 — 없으면 null, 2026-10-26), undone}. 없으면 None.
    last_auto_run: dict | None = None
    # 정지 확인 단계(2026-10-13) — 마지막 긴급 정지의 모션 확인. 새 실행이 시작되면 null. 옛 클라이언트는 무시
    #: sent | mcu_ack | verified | None
    last_stop_level: str | None = None
    last_stop_ack_ms: int | None = None
    #: 그 정지가 멈춘 실행의 job_id(실행 중이 아닐 때의 정지면 None). 클라이언트는 자기 job과 같을 때만 단계를 쓴다(H1).
    last_stop_job_id: str | None = None
    # 루틴 실행(검토 10/19) — 옛 클라이언트는 무시
    # /status: 루틴이 도는 동안(구간 실행 중·구간 사이 기다림·안내 포함)만 싣는다 — 쉬다가 /status로 루틴을 알아챈
    # 클라이언트가 구간 번호 대신 루틴 첫 번호(``GET /jobs/{routine_run_id}``)를 따라가게. 루틴이 없으면 모두 null.
    # ``GET /jobs/{id}``: 첫 번호면 루틴 전체 수명, 구간 번호면 그 구간이 속한 루틴(``routine_run_id``로 갈아탄다).
    #: 루틴 실행 번호(``/routines/runs/{id}``, 첫 구간 번호와 같다).
    routine_run_id: str | None = None
    #: running | succeeded | failed | stopped | unconfirmed — 루틴 전체 상태(모든 구간이 성공일 때만 succeeded).
    routine_status: str | None = None
    #: 구간 순번(1부터)과 그 구간의 실행 번호. /status·첫 번호는 지금(끝났으면 마지막) 구간, 구간 번호로 물으면 그 구간.
    routine_segment: int | None = None
    routine_segment_job_id: str | None = None


class SuggestionResponse(BaseModel):
    is_demo: bool = False
    id: str
    purpose: str
    time_band: str
    occurrences: int
    # 미리보기. 서버가 승인 전에 계산은 해 보지만, 실제 실행 시퀀스는 승인 시점에
    # 다시 해석되므로 이 값과 달라질 수 있다(예: 규칙이 그 사이 바뀐 경우).
    steps: list[str] = []
    reason: str = ""
    # 이 제안이 조작할 가전. **없으면 클라이언트는 대상을 모르는 것으로
    # 취급하고 실행을 막는다** -- 지금 고른 가전으로 메우면 화면과 실제
    # 실행 대상이 어긋난다.
    appliance_id: str | None = None
    #: 시나리오 제안이면 그 ID. 승인은 아래 commands에 그대로 묶인다(재해석 없음).
    scenario_id: str | None = None
    #: [{target_id, route, action, args, buttons, summary}] — 비었으면 종전 물리 제안.
    commands: list[dict] = []
    #: 사용자 루틴(2026-09-30). 있으면 화면은 purpose 대신 이 이름을 제목으로 쓴다.
    routine_id: str | None = None
    routine_name: str | None = None
    #: '다음부터도 자동으로'를 고를 수 있는 카드(2026-10-13, v4 가열 종료 감지 → 공기청정기)면
    #: {condition_text, action_text, fingerprint}. 물리 누름이 있거나 대상이 아니면 null — 화면에 버튼이 없다.
    auto_rule_offer: dict | None = None
    #: 습관 카드에서 바로 루틴으로(2026-10-25): {candidate_key, ask_time, auto, days, days_label, routine_name, evidence}.
    #: days·days_label(매일·평일·주말)은 저장할 루틴 요일 그대로(2026-10-26). auto=true면
    #: '매일 이 시간에 알아서 하기'(낮은 위험 LG 가전 동작), false면 '매일 이 시간에 물어보기'(물리 누름)로 저장한다.
    adopt_offer: dict | None = None
    #: '왜 지금' 신호(2026-10-26) — [{label, ok}], 최대 4개. 카드를 만들 때 서버가 실제로 본 신호만. 없으면 빈 목록.
    signals: list[dict] = []
    #: '이미 했어요'를 둘 습관 카드인가(2026-10-26). 참이면 거절 본문에 ``reason: "already_done"``을 보낼 수 있다.
    can_mark_done: bool = False
    #: ``action``(승인하면 실행) · ``advice``(조언 — 실행 없음, '알겠어요'는 거절 본문 ``reason: "acknowledged"``,
    #: '괜찮아요'는 본문 없는 거절. 승인은 409). 옛 클라이언트는 이 칸을 모른다(2026-10-26).
    kind: str = "action"
    #: 묻는 말("제습기를 켤까요?") — 서버가 알 때만. 없으면 화면이 목적 문장에서 만든다.
    question: str | None = None
    #: 소리로 읽을 말 — "<근거 문장> <묻는 말>"(조언은 조언 문장). 서버가 묻는 말을 모르면 null.
    speech: str | None = None


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
    # 실험 계측 (F4)
    # 이 열이 생기기 전 기록은 값이 없거나 'unknown'이다 — 지어내지 않는다.
    appliance_id: str | None = None
    # real | mock | unknown. mock 실행이 실제 성공률에 섞이지 않게 가른다.
    execution_mode: str = "unknown"
    # completed | stopped_by_user | retries_exhausted | motion_aborted | unknown.
    # status만으로는 '사용자가 멈춤'과 '재시도 소진'이 뭉개진다.
    termination: str = "unknown"
    #: success | failed | stopped | safety_stop. 옛 기록은 status·termination에서
    #: 보수적으로 유도한다(근거 없이 stopped로 적지 않는다).
    outcome: str = "failed"
    duration_seconds: float | None = None
    # 명령 계약(U1-a). 이 열이 생기기 전 기록은 unknown.
    route: str = "unknown"
    receipt: str = "unknown"
    confirmation: str = "unknown"
    #: 명령을 보낸 실행인가, 상태만 확인한 결과인가(2026-10-14): sent | state_only(이미 목표값, 보내지 않음) |
    #: not_sent | unknown. receipt·confirmation에서 유도한다.
    dispatch: str = "unknown"
    detail: str = ""
    #: L3 판정(2026-09-29). 판정기 없음·미판정·옛 기록은 None.
    operation_confirmed: bool | None = None
    operation_detail: str = ""
    #: 모션 장치 쪽 이유로 재시도 없이 멈춘 원인(2026-10-14, 예: ``motion_alarm: stall``). 그 밖은 None.
    abort_reason: str | None = None
    #: 실행할 때의 가전 이름(2026-10-16) — 옛 기록은 None(클라이언트가 지금 목록에서 찾는다).
    appliance_name: str | None = None


class OkResponse(BaseModel):
    ok: bool = True


class SettingSavedResponse(OkResponse):
    """설정을 바꾸는 응답(``POST``·``DELETE /dnd``) — 메모리 적용과 저장 결과를 나눈다(2026-10-14 HIGH 재확인 M-R1).

    200이면 이번 세션에는 적용됐다. ``persisted``: true 저장됨(재시작 뒤 유지) · false 저장 실패 · null 저장소 없는 구성
    (개발용 메모리 전용). ``session_only``: 재시작하면 유지되지 않음(``persisted``가 true가 아니면 true) — 재시작한 서버는
    마지막으로 저장에 성공한 값으로 시작한다. 폰·키오스크는 ``persisted``가 false일 때 사람 말로 알린다.
    """

    persisted: bool | None = None
    session_only: bool = False

    @classmethod
    def of(cls, persisted: bool | None) -> "SettingSavedResponse":
        return cls(persisted=persisted, session_only=persisted is not True)


class StopResponse(BaseModel):
    """POST /stop 응답 — **정지 요청을 접수하고 전달한 결과**다.

    어떤 필드도 모터가 물리적으로 멈췄다는 확인이 아니다. ok는 서버가 요청을
    받았다는 뜻이고, was_running으로 클라이언트가 "정지 요청함"과 "실행 중인
    작업 없음"을 구분한다. 노드 필드는 정지 요청이 **노드에 닿았는지**만
    나눈다: 받았다고 응답한 노드(acknowledged)와, 실패·기한 내 무응답·수신
    확인 수단이 없는 노드(unconfirmed). (기존 OkResponse와 필드 호환 — ok만
    보던 클라이언트는 그대로 동작한다.)"""

    ok: bool = True
    was_running: bool = False
    nodes_requested: int = 0
    nodes_acknowledged: list[str] = []
    nodes_unconfirmed: list[str] = []
    #: ThinQ 명령을 보내기 전이라 취소한 가전.
    cloud_cancelled: list[str] = []
    #: 이미 보낸 ThinQ 명령 — 취소할 수 없다. 가전 운전 정지는 자동으로 보내지 않는다.
    cloud_uncancellable: list[str] = []
    #: 요청 순간 정지 버튼 위에서 대기 중이었나 — 그렇다면 이 정지는 **정지 버튼 누름**으로
    #: 전달됐다(2026-09-30). 결과(정지됨/미확인)는 /status의 hold_stop_outcome으로 온다.
    appliance_stop_requested: bool = False
    hold_state_at_request: str | None = None
    # 정지 확인 단계(2026-10-13) — RPi4 정지 보고. 옛 클라이언트는 무시한다
    #: sent(정지 명령을 보냄) | mcu_ack(모션 보드가 받음) | verified(엔코더로 멈춤 확인) | None(보고 수단 없음·멈출 것 없음)
    stop_level: str | None = None
    #: 정지를 보낸 뒤 모션 보드 응답까지(ms). mcu_ack 이상일 때만.
    stop_ack_ms: int | None = None
    #: RPi4가 멈춘 대상: run | dev | hold | idle | None
    stop_target: str | None = None
    #: mcu_ack 이상일 때만 true — sent는 '보냄'이지 확인이 아니다.
    stop_confirmed: bool = False
    stop_detail: str | None = None
    #: 이 정지가 멈춘 실행의 job_id(요청 시점에 실행 중이었을 때만). 폰은 추적 중인 job과 같을 때만 단계를 반영한다(H1).
    stop_job_id: str | None = None


class DemoOutletEstopRequest(BaseModel):
    """POST /demo/outlet-estop — 리허설용 콘센트 모듈 비상 버튼(2026-10-06, 시연 v3 갭 S3).

    **실물 콘센트 모듈이 아니다.** 시뮬레이터의 모의 RPi4 실행기에 모듈 ``estop`` 이벤트를 넣을 뿐이다."""

    model_config = {"extra": "forbid"}
    #: True면 버튼이 눌린 채로 둔다 — ``POST /stop/ack``가 ``ok=false``(estop_button_pressed)로 거절된다.
    #: ``DELETE /demo/outlet-estop``으로 버튼을 푼다.
    hold_button: bool = False


class DemoOutletEstopResponse(BaseModel):
    ok: bool
    button_held: bool
    detail: str


class DemoApplianceDoneRequest(BaseModel):
    """POST /demo/appliance-done — 리허설용 '버튼식 가전 끝' 주입(2026-10-06, 시연 v3 갭 S8).

    **측정이 아니다.** 실물 세탁기·CT·마이크 없이, RPi4가 융합해 보내는 ``appliance_done``과 같은 규칙
    (`rpi/verifier/done_fusion.py`)에 주입 입력을 넣는다. 결과와 루틴 안내에는 "연습으로 넣은 신호예요."가 붙는다."""

    model_config = {"extra": "forbid"}
    appliance_id: str = Field(default="washer", pattern=r"^[A-Za-z0-9_-]{1,64}$")
    #: 끝을 알린 입력 — power(콘센트 CT 전력 하강)·beep(종료음). 둘 다면 done_confirmed.
    inputs: list[Literal["power", "beep"]] = Field(min_length=1, max_length=2)
    #: 비우면 가전의 끝 이벤트(세탁기 wash_complete · 전자레인지 heat_complete, `done_event_for`).
    event: str | None = Field(default=None, pattern=r"^[a-z][a-z0-9_]{0,63}$")


class DemoApplianceDoneResponse(BaseModel):
    ok: bool
    appliance_id: str
    state: str
    confidence: str
    inputs: list[str]
    source: str
    #: injected_in: rpi4_simulator(모의 RPi4 실행기가 프레임을 보냄) | rpi4_uart(UART 리허설 — 가짜 콘센트·모의 모션 RPi4가
    #: 보냄, 2026-10-06) | rpi5_mock(RPi5 안에서 같은 규칙으로)
    injected_in: str
    detail: str


class EstopAckResponse(BaseModel):
    """POST /stop/ack 응답 — 비상정지 걸림 해제 확인의 결과(2026-10-05).

    ok=true(latched=false)면 풀렸다. 버튼이 아직 눌려 있거나 콘센트 모듈이 답하지 않으면 ok=false·latched=true와
    사유(reason: estop_button_pressed | outlet_unreachable | estop_retriggered)를 돌려준다. 풀려도 가전 전원
    릴레이는 꺼진 채다 — 켜기는 별도다."""

    ok: bool
    latched: bool
    reason: str | None = None
    detail: str | None = None


class CareEventResponse(BaseModel):
    """GET /care-events 한 항목 — 보호자 폰의 알림함이 이걸 그대로 그린다.
    message는 서버가 이미 사용자 언어로 만들어 보낸다(클라이언트마다 문구가
    갈라지지 않게)."""

    id: int
    kind: str  # execution_failed | emergency_stop | danger_sound | quiet_routine
    message: str
    purpose: str | None = None
    occurred_at: datetime


class AcksResponse(BaseModel):
    """GET/POST /acks — 사람이 확인한 것(2026-10-19, ``rpi/services/person_acks.py``).

    - care_seen_id: 보호자 알림을 이 번호까지 봤다(모든 기기 공통).
    - failures_seen_id: 이 알림 번호까지의 '못 한 일' 알림(execution_failed·appliance_done_undelivered)은 봤다(2026-10-19
      검토 — 번호 비교라 본체 시계가 뒤로 가도 새 실패를 덮지 않는다).
    - failures_seen_until: 옛 앱 호환 파생값(시각) — 안 본 못 한 일 알림을 덮지 않는 시각. 새 앱은 failures_seen_id를 쓴다.
    - job_answers: 실행 하나에 남긴 답(seen·moved·not_moved), 최근 200건.
    - persisted(``POST``만, 검토 10/19 D): true 저장됨(재시작 뒤 유지) · false 저장 실패(이번 세션에만 적용 — 재시작하면
      마지막으로 저장된 값으로 돌아간다) · null 저장소 없는 구성. ``GET`` 응답에는 싣지 않는다. 저장 실패여도 200이다(옛 클라이언트 호환)."""

    care_seen_id: int
    failures_seen_id: int = 0
    failures_seen_until: datetime | None = None
    job_answers: dict[str, str] = {}
    persisted: bool | None = None


class AckRequest(BaseModel):
    """POST /acks — 하나 이상. 화면에 **실제로 보인 것만** 적는다(계약은 ``rpi/services/person_acks.py`` 머리말).

    - care_seen_id: 알림함을 연 기기가 본 가장 새 알림 번호(본체에 있는 가장 새 번호를 넘지 않게 줄인다).
    - failures_seen_id: 화면에 보인 가장 새 못 한 일 알림 번호 — 이 번호까지만 '봤다'(같은 방식으로 줄인다).
    - seen_job_ids: 화면에 보인 실행 기록 번호들 — 그 번호만 '봤다'.
    - seen_until_job_id: 화면에 보인 가장 새 실행 기록 번호 — 그것과 그보다 오래된 최근 기록만 '봤다'.
    - failures_seen: 옛 폰 '기록 보기'(호환) — 커서가 없으면 본체에 있는 가장 새 못 한 일·최근 실행 기록 전체까지.
    - job_id + answer: 키오스크 지난 일 '확인'(seen)·'움직였어요'(moved)·'안 움직였어요'(not_moved) — 그 실행 하나만."""

    care_seen_id: int | None = Field(default=None, ge=0)
    failures_seen: bool = False
    failures_seen_id: int | None = Field(default=None, ge=0)
    seen_job_ids: list[Annotated[str, Field(min_length=1, max_length=64)]] | None = Field(default=None, max_length=200)
    seen_until_job_id: str | None = Field(default=None, min_length=1, max_length=64)
    job_id: str | None = Field(default=None, min_length=1, max_length=64)
    answer: Literal["seen", "moved", "not_moved"] | None = None


class DemoCareEventRequest(BaseModel):
    """POST /demo/care-event — 보호자 알림을 강제 생성(리허설).

    안부 신호는 '시간대 종료 + 3일 루틴 + 오늘 미사용'이 조건이라 시연장에서
    자연 발생시키기 어렵다 — 다른 /demo/*와 같은 연출 장치. message를 비우면
    kind별 기본 문구를 서버가 채운다(클라이언트와 문구 일치 보장)."""

    kind: str = "quiet_routine"
    message: str = ""
    purpose: str | None = None

    @field_validator("kind")
    @classmethod
    def known_kind(cls, v: str) -> str:
        allowed = {
            "execution_failed",
            "emergency_stop",
            "danger_sound",
            "quiet_routine",
        }
        if v not in allowed:
            raise ValueError(f"kind must be one of {sorted(allowed)}")
        return v


class PublicHealthResponse(BaseModel):
    """키 없이 열린 ``GET /health`` — 생존·버전만(2026-10-14 보안 점검). 생활 정보(조용한 시간·잠시 쉬기)와
    준비 상태는 인증 경로 ``GET /health/detail``(`HealthResponse`)로만 준다."""

    ok: bool
    version: str


class HealthResponse(BaseModel):
    """인증된 ``GET /health/detail`` — 폰·키오스크가 준비 상태·잠시 쉬기·조용한 시간을 본다."""

    ok: bool
    # coreXY 홈 위치 확인 + SwitchBot 연결 상태 통합 — 실기기 연결 후 교체. 기본값 없음(모르면 준비됨으로 보지 않는다).
    actuator_ready: bool
    dnd_until: datetime | None = None
    # 잠시 쉬기 범위(2026-10-14 마감 2번) — "suggestions_and_auto"(새 제안+자동 실행)·"suggestions_only"(업데이트 전 설정을
    # 이어받음, 새 제안만)·None(꺼짐). 폰·키오스크가 문구를 범위대로 고른다.
    dnd_scope: str | None = None
    # 조용한 시간(2026-10-14) — /quiet-hours와 같은 모양. 키오스크가 폰과 같은 상태를 보인다.
    quiet: dict | None = None
    # 현재 Act 경로 — "local"(mock 폐루프) | "uart"(RPi4 실연결).
    # 화면엔 성공인데 실물이 안 움직이는 오설정(모드 미전환)을 즉시 탐지용.
    act_mode: str = "local"


class DemoSuggestRequest(BaseModel):
    """POST /demo/suggest — 시연용 제안 강제 생성. 패턴 감지(이력 3회 +
    시간대 일치)를 우회해 지금 즉시 제안 카드를 띄운다. 결선 데모에서
    '선제 제안 → 승인 → 실행' 장면을 원하는 시점에 연출하기 위한 것."""

    purpose: str = "즉석밥 데워줘"
    # 어느 가전으로 연출할지 -- **필수**다(B10). 대상 없는 제안은 승인이
    # 거절되므로, 리허설에서 실행까지 이어지려면 대상을 명시해야 한다.
    # 기본값이 내장 전자레인지인 이유: 기본 purpose(데우기)와 짝이 맞고,
    # body 없는 리허설 호출(데모시나리오.md)이 그대로 동작해야 하기 때문.
    appliance_id: str = "microwave"

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


class RoomLightView(BaseModel):
    """방 밝기 판단(2026-10-26) — 키오스크 '자동' 화면 밝기. 감지 파일이 없거나 20초 넘게 안 바뀌면 unknown."""

    state: str = "unknown"  # dark | light | unknown
    level: int | None = None  # 30초 평균 밝기(0~255), 모르면 None


class PlatformAgentView(BaseModel):
    """플랫폼 AI 에이전트가 가진 제안·날씨(읽기만, 2026-10-26). 꺼져 있거나 못 읽으면 available=false."""

    available: bool = False
    suggestion: str | None = None  # 오류 문장처럼 보이면 None
    weather_summary: str | None = None


class RoomPresenceResponse(BaseModel):
    """GET /presence/room — 방 안 사람 감지(카메라) 판단(2026-10-25). 감지기가 꺼져 있으면 enabled=false."""

    enabled: bool
    state: str  # unknown | present | idle(자리 비움) | away(외출로 봄)
    persons: int = 0
    sleep_screen: bool = False  # 키오스크 화면을 어둡게 해도 되는가(자리 비움·외출)
    last_seen_at: datetime | None = None
    arrived_at: datetime | None = None  # 마지막으로 '돌아온' 시각 — 키오스크 인사·깨우기
    greeting: str | None = None  # 그 돌아옴에 건넬 인사 한 줄(외출 뒤 저녁이면 하루 위로)
    #: 인사 뒤에 이어 말할 날씨 한 줄(10/26 사용자 — '좋은 아침이에요. 오늘 비 예보가 있어요…'). 특보 안내가 먼저, 없으면 비·눈·더위·추위 안내.
    #: 키오스크는 인사 알약에는 [greeting]만 띄우고 소리로는 둘을 이어 읽는다. 인사가 없으면 늘 None.
    greeting_weather: str | None = None
    changed_at: datetime | None = None
    dim_after_s: float | None = None
    away_after_s: float | None = None
    camera_enabled: bool = False  # 사용자가 끈 동안은 본체가 카메라를 열지 않는다
    light: RoomLightView = RoomLightView()  # 방 밝기(사람 감지와 따로 켠다) — 옛 클라이언트는 무시
    platform_agent: PlatformAgentView = PlatformAgentView()  # 덤 — 키오스크가 나중에 띄울 수 있게, 옛 클라이언트는 무시


class ProfileRequest(BaseModel):
    """PUT /profile — 인사에 부를 이름(10자까지, 비우면 이름 없이). 허브에만 남는다(2026-10-25)."""

    name: str | None = None


class ProfileResponse(BaseModel):
    name: str | None = None


class RoomCameraRequest(BaseModel):
    """POST /presence/room/camera — 사람 감지 카메라 켜기·끄기(2026-10-25)."""

    enabled: bool


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


class ReviseSuggestionRequest(BaseModel):
    model_config = {"extra": "forbid"}
    purpose: str

    @field_validator("purpose")
    @classmethod
    def validate_purpose(cls, value: str) -> str:
        return _validate_purpose_text(value)


class RejectSuggestionRequest(BaseModel):
    """POST /suggestions/{id}/reject 본문(선택). mute=True면 "다시 추천 안 함"."""

    mute: bool = False
    #: ``already_done``(2026-10-26, 선택) — '이미 했어요': 오늘은 이 습관을 다시 묻지 않고, 거절로 세지 않는다. 습관 카드만.
    #: ``acknowledged``(2026-10-26) — 조언 카드의 '알겠어요'(닫고 기록만). 조언 카드에만.
    reason: Literal["already_done", "acknowledged"] | None = None


class SuppressionListResponse(BaseModel):
    """다시 추천 안 하는 루틴 목록(설정 화면용)."""

    purposes: list[str]


class UnmuteRequest(BaseModel):
    """POST /suppressions/unmute·/suppressions/mute 본문 -- 억제 해제(또는 억제)할 루틴."""

    purpose: str


class DemoAlertRequest(BaseModel):
    """POST /demo/alert -- 위험 소리 경보 주입(G13, 모의·시뮬레이터 전용).

    필드는 RPi4가 스스로 보내는 ``alert``/``alert_cleared`` 프레임과 같다
    (docs/protocol.md). 주입은 **리허설 장치**이지 감지가 아니다 -- 실제
    UART 모드에서는 열리지 않는다.
    """

    model_config = {"extra": "forbid"}
    #: 지금은 ``danger_sound`` 하나뿐이다(RPi4가 보내는 종류와 같은 문자열).
    kind: str = "danger_sound"
    #: True면 경보 발생(``alert``), False면 해제(``alert_cleared``).
    raised: bool = True
    band_energy_ratio: float | None = None
    mean_period_seconds: float | None = None

    @field_validator("kind")
    @classmethod
    def non_empty(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("kind must not be empty")
        return value


class DemoEnvironmentRequest(BaseModel):
    """POST /demo/environment -- 시연용 온습도 강제값(센서 미연결 대비)."""

    temperature: float
    humidity: float



class LearningRoutineResponse(BaseModel):
    purpose: str
    appliance_id: str | None
    time_band: str
    occurrences: int
    distinct_days: int
    established: bool
    muted: bool
    recent_days: list[str] = []  # 실제로 쓴 날(ISO 날짜, 최근 5일) — 화면이 '왜 습관인지' 근거로 보인다
    # '알게 된 것'(2026-10-26) — 모두 선택 필드(옛 화면은 무시한다)
    usual_time: str | None = None  # 평소 시각 "HH:MM"
    confident: bool = True  # 시각이 모여 있나(아니면 화면은 정확한 시각 대신 '저녁 이맘때')
    paused_until: str | None = None  # 연달아 거절해 묻기를 쉬는 끝 시각(ISO), 아니면 null
    day_kind: str | None = None  # weekday · weekend · null(섞임·근거 적음)
    when_text: str | None = None  # 사람에게 보일 때 — '평일 오후 10시쯤' / '저녁 이맘때'
    state: str | None = None  # auto · hidden · paused · asking · learning
    routine_name: str | None = None  # state=auto일 때 그 루틴 이름


class LifestyleSummaryResponse(BaseModel):
    """밤마다 만드는 생활 습관 정리(2026-10-26). source=llm은 본체 안 언어 모델, template은 정해진 문장."""

    text: str
    generated_at: str
    source: str


class LearningStatusResponse(BaseModel):
    window_days: int
    minimum_days: int
    minimum_occurrences: int
    paused: bool
    routines: list[LearningRoutineResponse]
    summary: LifestyleSummaryResponse | None = None


class SuggestionEventResponse(BaseModel):
    event_id: str
    occurred_at: str
    suggestion_id: str
    origin: str
    purpose: str
    time_band: str
    evidence: str
    occurrences: int
    appliance_id: str | None
    action: str
    reason: str
    job_id: str | None
    execution_status: str | None


class SuggestionEventsResponse(BaseModel):
    persistent: bool
    persistence_ok: bool
    capacity: int
    events: list[SuggestionEventResponse]


class JobStatusResponse(StatusResponse):
    """``GET /jobs/{job_id}`` — 실행 번호 하나의 상태·결과(검토 10/19). 필드는 ``StatusResponse``와 같고 그 실행 것만 싣는다.

    기기 전체 값(``estop_*``·``hold_*``·``actuator_link_up``·``last_auto_run``·``developer_mode``)은 비운다(/status에서 읽는다)."""

    #: 끝났나(true면 ``last_job_id``가 이 번호, last_*가 그 결과). 실행 중이면 false.
    finished: bool
    #: 여러 단계 실행의 단계 번호(``<기본>-<n>``)로 물었을 때 n. 아니면 null.
    step: int | None = None
    # 루틴 필드(``routine_run_id``·``routine_status``·``routine_segment``·``routine_segment_job_id``)는 ``StatusResponse``에 있다.
    #: 루틴 결과 한 줄(끝났을 때). 루틴이 성공하지 못했으면 ``last_detail``도 이 문장이다.
    routine_detail: str | None = None
