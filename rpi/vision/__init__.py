"""조작부 사진 인식 — 설치 때 한 번 쓰는 선택 기능(기본 꺼짐).

사진을 외부 인식 서비스에 보내 버튼 라벨·위치를 받고, 그 응답을 **믿지 않는 입력**으로
검증해 버튼맵 **초안**을 만든다. 저장은 사람이 확인한 뒤 기존 등록 API가 한다.

실행 경로(목적 → 누름 → 판정)는 이 패키지를 부르지 않는다 — 인터넷이 끊겨도 폐루프는
그대로 동작해야 한다(docs/inference-boundary.md §4).
"""

from __future__ import annotations

from .client import (
    ALLOWED_IMAGE_MIME,
    PANEL_PROMPT,
    HttpVisionClient,
    HttpVisionClientConfig,
    VisionClient,
    VisionUnavailable,
    sniff_image_mime,
)
from .panel_scan import (
    BOX_SCALE,
    MAX_CONTROLS,
    MAX_GRID,
    DetectedControl,
    DraftButton,
    PanelDraft,
    PanelScanError,
    build_draft,
    map_draft_to_mm,
    parse_controls,
)

__all__ = [
    "ALLOWED_IMAGE_MIME",
    "BOX_SCALE",
    "MAX_CONTROLS",
    "MAX_GRID",
    "PANEL_PROMPT",
    "DetectedControl",
    "DraftButton",
    "HttpVisionClient",
    "HttpVisionClientConfig",
    "PanelDraft",
    "PanelScanError",
    "VisionClient",
    "VisionUnavailable",
    "build_draft",
    "map_draft_to_mm",
    "parse_controls",
    "sniff_image_mime",
]
