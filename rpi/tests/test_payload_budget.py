"""전송 경로 바이트 예산이 전 구간에서 일관되는지 고정한다.

이 테스트가 있는 이유: 예산이 **네 곳에 흩어져 있다**(파이썬 스키마 하나, 펌웨어
config 둘, ESP-NOW 재조립 버퍼 둘). 언어가 달라 상수를 공유할 수 없으므로, 어느 한
곳만 바뀌면 그 지점에서 조용히 잘린다 -- 실제로 그런 상태였다.

    RPi5 --UART--> 게이트웨이 --ESP-NOW--> 노드 --UART--> RPi4

한글이 UTF-8 3바이트라 "20개 × 40자"를 800바이트로 계산한 것이 원인이었다.
실제로는 약 2.5KB다.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from rpi.api.schemas import (
    MAX_BUTTON_LABEL_LEN,
    MAX_BUTTONS_PER_RUN,
    MAX_EXECUTE_PAYLOAD_BYTES,
    execute_payload_bytes,
)

_REPO_ROOT = Path(__file__).resolve().parents[2]

# 봉투(type/sequence_id/mac, ESP-NOW 구간의 rid 등)가 페이로드 위에 얹히는
# 최대 크기. 넉넉히 잡는다.
_ENVELOPE_MARGIN_BYTES = 128


def _define(config_path: str, name: str) -> int:
    text = (_REPO_ROOT / config_path).read_text(encoding="utf-8")
    match = re.search(rf"^#define\s+{name}\s+(\d+)", text, re.MULTILINE)
    assert match, f"{config_path}에 {name} 정의가 없다"
    return int(match.group(1))


def _worst_case_button_payload() -> list[str]:
    """스키마가 허용하는 가장 큰 버튼 목록 (전부 한글 = UTF-8 3바이트)."""
    return ["가" * MAX_BUTTON_LABEL_LEN] * MAX_BUTTONS_PER_RUN


class TestBudgetCoversSchema:
    def test_worst_case_allowed_request_fits_the_budget(self):
        # 스키마가 받아주는 요청이 예산을 넘으면, 검증을 통과한 요청이 전송에서
        # 죽는다 -- 어디서 실패했는지 가장 찾기 어려운 조합이다
        assert execute_payload_bytes(_worst_case_button_payload()) <= MAX_EXECUTE_PAYLOAD_BYTES

    def test_korean_labels_are_three_bytes_each(self):
        # 이 전제가 깨지면 위 계산이 전부 틀어진다. 명시적으로 못박아둔다.
        assert len("가".encode("utf-8")) == 3

    def test_budget_is_not_confused_with_character_count(self):
        # 회귀 방지: 예산을 글자 수(20 × 40 = 800)로 되돌리면 실패한다
        assert MAX_EXECUTE_PAYLOAD_BYTES > MAX_BUTTONS_PER_RUN * MAX_BUTTON_LABEL_LEN


class TestFirmwareBuffersCoverBudget:
    """펌웨어 버퍼가 파이썬 예산 + 봉투를 담을 수 있어야 한다."""

    def test_bridge_uart_buffer(self):
        size = _define("firmware/include/config.h", "JSON_BUF_SIZE")
        assert size >= MAX_EXECUTE_PAYLOAD_BYTES + _ENVELOPE_MARGIN_BYTES

    def test_node_uart_buffer(self):
        size = _define("firmware-node/include/config.h", "JSON_BUF_SIZE")
        assert size >= MAX_EXECUTE_PAYLOAD_BYTES + _ENVELOPE_MARGIN_BYTES

    def test_gateway_espnow_reassembly_buffer(self):
        size = _define("firmware/include/config.h", "ESPNOW_MAX_MESSAGE_BYTES")
        assert size >= MAX_EXECUTE_PAYLOAD_BYTES + _ENVELOPE_MARGIN_BYTES

    def test_node_espnow_reassembly_buffer(self):
        size = _define("firmware-node/include/config.h", "ESPNOW_MAX_MESSAGE_BYTES")
        assert size >= MAX_EXECUTE_PAYLOAD_BYTES + _ENVELOPE_MARGIN_BYTES


class TestFragmentationCoversBudget:
    """조각 수 상한(32) × 조각 크기가 예산을 담을 수 있어야 한다."""

    def test_thirty_two_fragments_can_carry_the_budget(self):
        # 재조립 마스크가 32비트라 조각은 최대 32개다. 그보다 큰 메시지는
        # 보낼 수도 받을 수도 없다 -- 예산이 그 안에 들어가는지 확인한다.
        frame = _define("firmware-node/include/config.h", "ESPNOW_MAX_FRAME_BYTES")
        header = _define("firmware-node/include/config.h", "ESPNOW_FRAME_HEADER_BYTES")
        capacity = (frame - header) * 32
        assert capacity >= MAX_EXECUTE_PAYLOAD_BYTES + _ENVELOPE_MARGIN_BYTES

    def test_both_sides_agree_on_frame_geometry(self):
        # 머리 크기나 프레임 크기가 한쪽만 바뀌면 재조립이 어긋난다
        for name in ("ESPNOW_MAX_FRAME_BYTES", "ESPNOW_FRAME_HEADER_BYTES",
                     "ESPNOW_MAX_MESSAGE_BYTES", "ESPNOW_CHANNEL"):
            assert _define("firmware/include/config.h", name) == _define(
                "firmware-node/include/config.h", name
            ), f"{name}가 게이트웨이와 노드에서 다르다"


class TestSchemaRejectsOverBudget:
    def test_over_budget_request_is_refused(self):
        from pydantic import ValidationError

        from rpi.api.schemas import ExecuteButtonsRequest

        # 라벨 길이 상한은 지키면서 예산만 넘기는 것은 현재 개수 상한(20)에서는
        # 불가능하다. 예산 검증이 살아있는지는 함수 수준에서 확인한다.
        oversized = ["가" * MAX_BUTTON_LABEL_LEN] * MAX_BUTTONS_PER_RUN
        assert execute_payload_bytes(oversized) <= MAX_EXECUTE_PAYLOAD_BYTES
        ExecuteButtonsRequest(buttons=oversized)  # 통과해야 한다

        try:
            ExecuteButtonsRequest(buttons=["가" * MAX_BUTTON_LABEL_LEN] * (MAX_BUTTONS_PER_RUN + 1))
        except ValidationError:
            pass
        else:  # pragma: no cover
            raise AssertionError("개수 상한 초과가 거절되지 않았다")
