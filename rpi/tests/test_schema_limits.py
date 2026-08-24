"""요청 스키마 상한·URL 검증 (교차 리뷰 #9·#10).

물리 실행 API에 무한 입력이 들어오면 장시간 실행·거대 LLM 프롬프트·DB 팽창으로
이어지고, 검증 없는 base_url은 실행 트래픽을 엉뚱한 곳으로 보낸다.
"""

import pytest
from pydantic import ValidationError

from rpi.api.schemas import (
    MAX_BUTTON_LABEL_LEN,
    MAX_BUTTONS_PER_RUN,
    MAX_DND_MINUTES,
    MAX_KNOWN_BUTTONS,
    MAX_PURPOSE_LEN,
    DndRequest,
    ExecuteButtonsRequest,
    ExecuteForApplianceRequest,
    ExecuteRequest,
    NodeRegisterRequest,
)


# ── 텍스트(발화) 상한 ────────────────────────────────────────────────────


def test_execute_text_at_limit_passes():
    req = ExecuteRequest(text="가" * MAX_PURPOSE_LEN)
    assert len(req.text) == MAX_PURPOSE_LEN


def test_execute_text_over_limit_rejected():
    with pytest.raises(ValidationError):
        ExecuteRequest(text="가" * (MAX_PURPOSE_LEN + 1))


def test_appliance_request_text_over_limit_rejected():
    with pytest.raises(ValidationError):
        ExecuteForApplianceRequest(
            text="가" * (MAX_PURPOSE_LEN + 1), known_buttons=["전원"]
        )


# ── 버튼 목록 상한 ───────────────────────────────────────────────────────


def test_buttons_at_limit_pass():
    req = ExecuteButtonsRequest(
        buttons=[f"버튼{i}" for i in range(MAX_BUTTONS_PER_RUN)]
    )
    assert len(req.buttons) == MAX_BUTTONS_PER_RUN


def test_buttons_over_limit_rejected():
    with pytest.raises(ValidationError):
        ExecuteButtonsRequest(
            buttons=[f"버튼{i}" for i in range(MAX_BUTTONS_PER_RUN + 1)]
        )


def test_blank_buttons_do_not_count_toward_limit():
    # 공백 항목은 정리 후 세므로, 공백 100개 + 실제 1개는 통과해야 한다
    req = ExecuteButtonsRequest(buttons=["  "] * 100 + ["전원"])
    assert req.buttons == ["전원"]


def test_button_label_over_limit_rejected():
    with pytest.raises(ValidationError):
        ExecuteButtonsRequest(buttons=["가" * (MAX_BUTTON_LABEL_LEN + 1)])


def test_known_buttons_over_limit_rejected():
    with pytest.raises(ValidationError):
        ExecuteForApplianceRequest(
            text="우유 데워줘",
            known_buttons=[f"버튼{i}" for i in range(MAX_KNOWN_BUTTONS + 1)],
        )


# ── DND 상한 ─────────────────────────────────────────────────────────────


def test_dnd_at_limit_passes():
    assert DndRequest(duration_minutes=MAX_DND_MINUTES).duration_minutes == (
        MAX_DND_MINUTES
    )


def test_dnd_over_limit_rejected():
    # 오타(예: 분 대신 초 단위 입력)로 영구 DND가 되는 사고 방지
    with pytest.raises(ValidationError):
        DndRequest(duration_minutes=MAX_DND_MINUTES + 1)


# ── 노드 base_url 검증 ───────────────────────────────────────────────────


@pytest.mark.parametrize(
    "url",
    [
        "http://192.168.0.42",
        "http://esp-node.local:8080",
        "https://node.example.com",
    ],
)
def test_valid_base_urls_pass(url):
    assert NodeRegisterRequest(base_url=f"  {url}  ").base_url == url


@pytest.mark.parametrize(
    "url",
    [
        "ftp://192.168.0.42",       # 이상 스킴
        "file:///etc/passwd",       # 로컬 파일
        "192.168.0.42:8080",        # 스킴 없음
        "http://",                  # 호스트 없음
        "http://user:pw@host",      # 자격증명 포함
        "http://host:99999",        # 포트 범위 초과
        "http://host:abc",          # 포트가 숫자 아님
        "",
        "   ",
    ],
)
def test_invalid_base_urls_rejected(url):
    with pytest.raises(ValidationError):
        NodeRegisterRequest(base_url=url)
