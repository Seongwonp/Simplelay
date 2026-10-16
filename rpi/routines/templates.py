"""추천 루틴 템플릿 — 시연 v3 "한 사람의 하루"(docs/archive/본선-시연-시나리오-v3.md §3-3)의 네 루틴.

**사용자 데이터가 아니다.** 저장돼 있지 않고 실행되지도 않는다. 앱의 '추천' 목록이
보여 주고, 사용자가 자기 가전·버튼으로 고친 뒤 ``POST /routines``로 저장해야 루틴이
된다. 가전 ID(``microwave``·``washer``·``intercom``)와 버튼 이름은 **예시**라서 등록된 가전과
다르면 저장할 때 422가 난다. ``washer``는 사용자가 등록하는 버튼식 세탁기다 — ThinQ 모의 세탁기는
``thinq_washer``로 비켜 있다(2026-10-06). v2의 '귀가 냉방'(에어컨)·'세탁 끝나면 제습'(제습기)은 v3에
없는 가전이라 뺐다.
"""

from __future__ import annotations

from datetime import datetime, timezone

from .model import build_routine

_EPOCH = datetime(2026, 9, 30, tzinfo=timezone.utc)

TEMPLATES: tuple[dict, ...] = (
    {
        "template_id": "morning",
        "scene": "아침",
        "name": "아침 데우기",
        "icon": "sunrise",
        "description": "평일 아침 전자레인지로 데우고, 끝나면 약 드실 시간을 알려 드려요",
        "caution": "복약 안내는 시간 알림까지예요. 약이나 건강 상태를 판단하지 않아요",
        "trigger": {"kind": "time", "days": [0, 1, 2, 3, 4], "time": "07:30"},
        "conditions": [],
        "mode": "approve",
        "steps": [
            {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["즉석밥", "시작"],
             "note": "사진 속 버튼으로 바꿔 주세요"},
            {"kind": "wait_until_done", "appliance_id": "microwave"},
            {"kind": "announce", "text": "약 드실 시간이에요. 아직 안 드셨으면 지금 챙겨 드세요"},
        ],
    },
    {
        "template_id": "outing",
        "scene": "외출 전",
        "name": "외출 전 세탁",
        "icon": "laundry",
        "description": "외출하기 전에 세탁기를 시작할지 물어봐요",
        "caution": "세탁기 버튼 이름은 예시예요",
        "trigger": {"kind": "time", "days": [0, 1, 2, 3, 4], "time": "08:40"},
        "conditions": [],
        "mode": "approve",
        "steps": [
            {"kind": "press_sequence", "appliance_id": "washer", "buttons": ["전원", "표준", "시작"],
             "note": "사진 속 버튼으로 바꿔 주세요"},
        ],
    },
    {
        "template_id": "visitor",
        "scene": "낮",
        "name": "방문자 문 열기",
        "icon": "door",
        "description": "인터폰으로 방문자를 확인하고, 승인하면 문 열림 버튼을 눌러요",
        "caution": "인터폰 호출 감지는 아직 없어요. 지금은 직접 실행해서 승인 카드를 띄워요",
        "trigger": {"kind": "manual"},
        "conditions": [],
        "mode": "approve",
        "steps": [
            {"kind": "press_sequence", "appliance_id": "intercom", "buttons": ["문열림"],
             "note": "사진 속 버튼으로 바꿔 주세요"},
        ],
    },
    {
        "template_id": "wash_done",
        "scene": "귀가",
        "name": "세탁 끝 알림",
        "icon": "laundry",
        "description": "세탁기가 끝났다고 알리면 빨래를 꺼내 널라고 알려 드려요",
        "caution": ("버튼식 세탁기는 콘센트 전력 하강과 종료음이 같이 확인될 때만 '끝났어요', 하나만이면 "
                    "'끝난 것 같아요, 확인해 주세요'로 알려요. 기준값은 아직 실측 전이에요"),
        "trigger": {"kind": "event", "event": "wash_complete"},
        "conditions": [],
        "mode": "notify",
        "steps": [
            {"kind": "announce", "text": "세탁이 끝났어요. 빨래를 꺼내 널어 주세요"},
        ],
    },
)


def template_payloads() -> list[dict]:
    """``GET /routines/templates`` 응답. 구조 검증을 통과한 것만 내보낸다."""
    out = []
    for template in TEMPLATES:
        build_routine(template, routine_id=f"template-{template['template_id']}", now=_EPOCH)
        out.append({**template, "is_template": True})
    return out
