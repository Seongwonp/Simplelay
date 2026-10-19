"""자동 실행 허용 규칙 (2026-10-13, 시연 v4 — docs/본선-시연-계획-v4.md).

범위는 하나다: **전자레인지 가열 종료 감지(CT) → ThinQ 공기청정기 동작 하나**. 정책(10/14 사용자 확정, 3차 평가 L1):
가열 종료가 감지되면 취소·문 열림이어도 제안·자동 실행이 일어날 수 있다 — 낮은 위험 동작(풍량 변경)이라 허용하고
화면·기록은 '조리 완료가 아닐 수 있음'을 밝힌다. 사용자가 제안 카드에서
'이번에 실행하고 다음부터 자동으로'를 고르고 조건·동작 확인을 본 뒤에만 생긴다. 자주 승인했다고 저절로
켜지지 않는다. 규칙은 카드가 보여 준 내용(조건·대상 기기·속성·값)을 그대로 저장한다 — 빈 루틴 폼이 아니다.

필수 조건과 이 모듈이 강제하는 자리:

1. **낮은 위험 ThinQ 동작만**(`LOW_RISK_ACTIONS`: 공기청정기 풍량·운전 모드·전원 켜기). 물리 버튼 누름이 있는
   카드는 허용 제안이 없고(`offer_for` → None) 서버도 거절한다. 저장된 규칙도 실행 직전에 다시 본다.
2. **모의 사건 → 모의 ThinQ만.** 대상 실행 환경이 real이면 사건 출처도 real(RPi4 L3 실물 판정)이어야 보낸다.
3. **같은 사건 한 번.** 사건 키(가전·이벤트·출처·RPi4 끝 시각)로 멱등 — 재전송·재연결로 다시 와도 한 번.
   사건 나이는 **이 허브 단조 시계로 옮긴 끝 시각**부터 잰다(3차 평가 M1, ``rpi/services/event_clock.py`` — RPi4가
   프레임을 낸 뒤 링크에서 늦어진 시간까지 센다. 다른 장치의 monotonic을 그대로 비교하지 않는다). 옮길 근거가 없거나
   (옛 RPi4·연결 세션 바뀜) 사건이 오래됐거나(``SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S``, 기본 120초, 측정 필요) 허용하기
   전에 끝난 가열이면 보내지 않는다(보류가 기본). 전송 직전에도 나이를 다시 본다(전송 대기 중 만료).
   허용 전후도 같은 허브 단조 시계 축에서 가른다(4차 평가 M-N2) — 재시작 뒤 불러온 허용은 이 프로세스가 시작한 뒤에 끝난
   가열에만 쓴다.
   결과가 미확인이어도 **다시 보내지 않는다**(재시도 코드 없음).
4. **허용은 지문에 묶인다**(조건 가전·이벤트·대상 가전·대상 기기 키·종류·동작·속성·값). 값을 바꾸면 꺼지고 다시
   허용해야 한다. 대상 기기가 없어지거나 다른 기기로 바뀌면 그 자리에서 무효(꺼짐 + 이유)가 된다.
5. **비상정지**: 세대를 올려(`halt`) 판단은 끝났지만 아직 보내지 않은 자동 실행을 실행 게이트 안에서 막고
   (`approval_guard`), 켜진 규칙을 모두 끈다. 이미 클라우드에 보낸 명령은 취소되지 않는다고 그대로 적는다.
6. **가열 종료 근거**(취소·문 열림과 구분 못 함 — 위 정책, 실측 기록표 §6)는 RPi4 ``appliance_done``(전자레인지 CT 채널 전력 끝, 입력에 ``power``)뿐이다. 실행
   끝(버튼 누름 완료)은 이 모듈에 오지 않는다.

**시각 규칙(2026-10-16, 사용자 승인)** — 두 번째 조건 종류(``condition_kind="time"``). 시각 루틴(켜짐·승인 루틴·조건 없음·
**낮은 위험 ThinQ 명령 한 단계**)의 카드에서만 허용이 생기고, 다음 정해진 시각에 루틴 엔진 ``tick``이 :meth:`AutoRuleEngine.on_time_due`
를 부르면 위와 **같은** ``_try_run``·``_submit`` 경로(조용한 시간·비상정지·정지 세대·지문·전송권·사건 나이·허용 전후 경계)로 보낸다.
사건 키는 루틴·날짜·시각(재시작 뒤에도 한 번), 사건 나이는 정해진 시각보다 늦게 확인한 시간(허브 시계). 늦음·허용 전·재시작 전은
보내지 않고 카드(승인)로 돌아간다. 루틴이 바뀌거나 지워지면 규칙이 꺼진다(라우터 철회 + 실행 직전 재검사). 물리 단계는 대상이 아니다.
가열 종료 규칙의 지문 내용은 바뀌지 않았다(저장된 허용 유지).

**검증 수준: 모의 ThinQ·모의 클라우드 끝-끝까지. 실제 CT 판정·실가전 미검증.**
"""

from __future__ import annotations

import hashlib
import logging
import math
import os
import re
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timedelta
from types import MappingProxyType
from uuid import uuid4

from rpi.commands import ApprovedCommand, ControlRoute, canonical_json
from rpi.controller.models import ExecutionMode
from rpi.intent.models import UsageSource
from rpi.josa import josa, josa_stem
from rpi.services.quiet_hours import SKIP_REASON as QUIET_SKIP_REASON
from rpi.services.thinq.wording import direction, dispatch_of

from .model import parse_scenario_key

log = logging.getLogger(__name__)

#: 자동 실행해도 되는 낮은 위험 동작 — 기기 종류 → 동작 → 허용 값(None이면 그 동작의 모든 값).
LOW_RISK_ACTIONS: dict[str, dict[str, tuple[str, ...] | None]] = {
    "DEVICE_AIR_PURIFIER": {
        "set_wind_strength": None,
        "set_job_mode": None,
        "set_power": ("POWER_ON",),  # 사건 규칙은 켜기만. 끄기는 아래 시각 규칙에서만.
    },
}

#: 시각 규칙에만 더 허용하는 동작(2026-10-16 사용자 요청 — '밤에 켜고 아침 07:00에 끄기'). 공기청정기 끄기는 위험이
#: 낮지만 가열 종료 같은 사건에 묶을 이유가 없어 사건 규칙에는 넣지 않는다.
TIME_RULE_EXTRA_ACTIONS: dict[str, dict[str, tuple[str, ...]]] = {
    "DEVICE_AIR_PURIFIER": {"set_power": ("POWER_OFF",)},
}

MAX_EVENT_AGE_ENV = "SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S"
#: 사건 나이 상한(초) — RPi4가 끝을 본 뒤 이 허브가 보내기 직전까지(링크 지연 포함, 3차 평가 M1). **측정 필요**
#: (전자레인지 settle_s 10초 + 여유).
DEFAULT_MAX_EVENT_AGE_S = 120.0
#: 자동 실행 승인 1건의 유효 시간(초).
APPROVAL_SECONDS = 60
#: 실행 기록의 시나리오 ID 접두사(시나리오·루틴 트리거가 다시 깨우지 않게).
AUTO_SCENARIO_PREFIX = "auto:"
#: 자동 실행 기록의 목적 문장 머리. 폰이 이 글자로 출처 '자동'을 가른다(app display_status.dart) — 바꾸지 않는다.
AUTO_PURPOSE_PREFIX = "자동 실행 · "
KIND_AUTO_RULE = "auto_rule"
CONDITION_BASIS = "ct_power_end"
MAX_SEEN_EVENTS = 500

ESTOP_REASON = "비상정지로 자동으로 하기를 껐어요."
# 10/17 쉬운 말: 결과 한 줄 + 되돌리지 않는다는 사실 한 줄(새 자동 실행·보내지 않은 명령은 보내지 않는다는 뜻 유지).
# 10/18 쉬운 말 4차: '자동 실행'·'명령' 대신 '자동으로 하기'·'가전에 전한 것'.
ESTOP_NOTICE = "비상정지로 자동으로 하기를 껐어요. 가전에 이미 전한 것은 되돌리지 않아요."
USER_OFF_REASON = "자동으로 하기를 꺼 두셨어요."
VALUE_CHANGED_REASON = "세기를 바꿔서 다시 허락해야 켜져요."
PHYSICAL_REFUSED = "버튼을 누르는 일은 자동으로 할 수 없어요. 매번 허락해 주세요."
#: 허용 요청을 처리하는 사이 전체 정지가 들어왔다(3차 평가 H2) — 이번 허용은 저장하지 않는다.
STOP_RACE_REASON = "허락하는 사이 멈추기를 눌러서 자동으로 하기를 켜지 않았어요."
#: 다시 허용하는 사이 다른 요청이 그 규칙을 바꿨다(HIGH 재확인 2차) — 옛 내용으로 켜지 않는다.
RULE_CHANGED_REASON = "그사이 다른 곳에서 이 규칙이 바뀌었어요. 목록을 새로 고쳐 주세요."
#: 지난 프로세스가 깨끗이 닫히지 않았다(전원 끊김·강제 종료·규칙 저장 실패, 4차 평가 M-N3) — 정지의 규칙 끄기가 DB에
#: 닿기 전에 끝났을 수 있어 켜진 규칙을 믿지 않는다.
UNCLEAN_RESTART_REASON = "본체가 갑자기 꺼져서 자동으로 하기를 껐어요."
#: 재시작 뒤 불러온 허용인데 사건이 이 프로세스가 시작하기 전에 끝났다(4차 평가 M-N2) — 허용 전후를 단정하지 않는다.
RESTART_BOUNDARY_REASON = "본체가 다시 켜지기 전에 끝난 가열이라 자동으로 하지 않았어요."
#: 철회가 이미 전송을 시작한 자동 실행과 겹쳤다(4차 평가 H-N1) — 그 명령은 되돌리지 않는다.
IN_FLIGHT_NOTICE = "이번 것은 이미 가전에 전하는 중이라 되돌리지 않아요. 다음부터는 자동으로 하지 않아요."
#: 보내기 전 조회에서 이미 목표값이라 보내지 않은 자동 실행(2026-10-14 발견 3) — 같은 사건은 처리 완료다.
ALREADY_REASON = "이미 그 설정이라 보내지 않았어요."
#: 이 프로세스의 표시(세션). 규칙 DB의 세션 표시가 다른 프로세스 것이고 열려 있으면 지난 종료가 깨끗하지 않았다.
PROCESS_SESSION = uuid4().hex
#: 정지의 규칙 끄기를 뒤에서 DB에 쓸 때 다시 해 보는 횟수·간격(초).
PERSIST_ATTEMPTS = 3
PERSIST_RETRY_S = 1.0

# ── 시각 규칙(2026-10-16, 사용자 승인) — 시각 루틴(ThinQ 낮은 위험 동작 하나)의 '다음부터도 자동으로' ──────────
CONDITION_KIND_APPLIANCE_DONE = "appliance_done"
CONDITION_KIND_TIME = "time"
#: 시각 규칙의 판단 근거 — 이 허브의 시계(벽시계로 정한 시각, 늦음은 허브 단조 시계 축으로 잰다).
TIME_CONDITION_BASIS = "hub_clock"
TIME_EVENT = "time"
#: 확인 화면의 단서(``offer.caveat``·규칙 목록 ``caveat``). 폰은 이 문장을 그대로 보인다.
# 판단 근거(전력)는 말하지 않고, 사용자가 알아야 할 결과만(10/17 쉬운 말). 취소·문 열림으로 멈춰도 같게 잡힌다(A5) —
# '조리 완료'라고 하지 않는다는 뜻은 그대로.
COOK_CAVEAT = "다 익지 않았어도 멈추면 실행돼요. 문을 열거나 취소한 경우도 같아요."
# 내부 설명('허브 시계로 판단')은 빼고 짧게(외부 평가 10/16 p06, 10/17 쉬운 말).
TIME_CAVEAT = "그 시각에 본체가 꺼져 있었거나 조용한 시간이면 하지 않아요. 늦게 알면 먼저 물어봐요."
TIME_QUIET_CAVEAT = "이 시각은 조용한 시간이라 자동으로 하지 않아요."
TIME_RESTART_REASON = "본체가 다시 켜지기 전 시각이라 자동으로 하지 않았어요. 먼저 물어볼게요."
TIME_BEFORE_ALLOW_REASON = "허락하기 전 시각이라 자동으로 하지 않았어요. 먼저 물어볼게요."
TIME_NO_CLOCK_REASON = "본체 시계로 시각을 알 수 없어 자동으로 하지 않았어요. 먼저 물어볼게요."
ROUTINE_CHANGED_REASON = "루틴이 바뀌어 자동으로 하기를 껐어요. 다시 허락해 주세요."
ROUTINE_DELETED_REASON = "루틴을 지워서 자동으로 하기를 껐어요."
ROUTINE_OFF_REASON = "루틴이 꺼져 있어 자동으로 하기를 껐어요. 다시 허락해 주세요."
TIME_REENABLE_REFUSED = "루틴이 바뀌었거나 없어서 켤 수 없어요. 다음 루틴 카드에서 다시 허락해 주세요."
TIME_VALUE_REFUSED = "루틴에서 할 일을 바꾼 뒤 카드에서 다시 허락해 주세요."

#: 대상 가전 ID → 화면 이름(대상이 지금 없을 때만 쓴다).
_TARGET_KIND_NAMES = {"air_purifier": "공기청정기", "thinq_washer": "세탁기", "dehumidifier": "제습기"}

#: 10/14 전에 저장된 꺼짐 사유(긴 문장)의 앞머리 → 지금 문장. 저장값은 바꾸지 않고 보여 줄 때만 바꾼다.
_LEGACY_REASON_PREFIXES = (
    ("허브가 정상 종료되지 않아", "UNCLEAN"),
    ("비상정지로 자동 실행을 껐어요 —", "ESTOP"),
    ("사용자가 자동 실행을 껐어요", "USER_OFF"),
    ("설정값을 바꿔 다시 허용이 필요해요", "VALUE"),
    ("허용을 저장하는 사이 전체 정지가", "STOP_RACE"),
)


#: 10/17 쉬운 말 전에 저장된 꺼짐 사유(그대로 일치) → 지금 문장. 저장값은 바꾸지 않고 보여 줄 때만 바꾼다.
_LEGACY_REASON_EXACT = {
    "세기를 바꿔서 다시 허용해야 켜져요.": "VALUE",
    "허용하는 사이 정지가 들어와서 자동 실행을 켜지 않았어요.": "STOP_RACE",
    "허브가 갑자기 꺼져서 자동 실행을 껐어요.": "UNCLEAN",
    "루틴이 바뀌어 자동 실행을 껐어요 — 다시 허용이 필요해요": "ROUTINE_CHANGED",
    "루틴을 지워서 자동 실행을 껐어요": "ROUTINE_DELETED",
    "루틴이 꺼져 있어 자동 실행을 껐어요 — 다시 허용이 필요해요": "ROUTINE_OFF",
    # 10/18 쉬운 말 2차 전에 저장된 사유.
    "직접 자동 실행을 껐어요.": "USER_OFF",
}
#: 그 밖의 옛 꺼짐 사유 끝말 → 지금 끝말(가전이 없어짐·바뀜 등 문장 앞부분은 그대로 둔다).
_LEGACY_REASON_TAIL = (" — 다시 허용이 필요해요", ". 다시 허락해 주세요.")
#: 10/18 쉬운 말 4차 전 사유 속 기능 이름 → 지금 이름. 저장값은 그대로, 보여 줄 때만.
_LEGACY_AUTO_NAME = (("자동 실행을 ", "자동으로 하기를 "), ("자동 실행이 ", "자동으로 하기가 "),
                     ("정지를 눌러서", "멈추기를 눌러서"))


def display_reason(reason: str | None) -> str | None:
    """화면에 낼 꺼짐 사유 — 옛 긴 문장이면 지금 짧은 문장으로."""
    if not reason:
        return reason
    current = {"UNCLEAN": UNCLEAN_RESTART_REASON, "ESTOP": ESTOP_REASON, "USER_OFF": USER_OFF_REASON,
               "VALUE": VALUE_CHANGED_REASON, "STOP_RACE": STOP_RACE_REASON,
               "ROUTINE_CHANGED": ROUTINE_CHANGED_REASON, "ROUTINE_DELETED": ROUTINE_DELETED_REASON,
               "ROUTINE_OFF": ROUTINE_OFF_REASON}
    for prefix, key in _LEGACY_REASON_PREFIXES:
        if reason.startswith(prefix):
            return current[key]
    if reason in _LEGACY_REASON_EXACT:
        return current[_LEGACY_REASON_EXACT[reason]]
    old_tail, new_tail = _LEGACY_REASON_TAIL
    if reason.endswith(old_tail):
        reason = reason[: -len(old_tail)] + new_tail
    # 10/18 쉬운 말 4차 전에 저장된 사유('…자동 실행을 껐어요')는 지금 이름('자동으로 하기')으로.
    for old, new in _LEGACY_AUTO_NAME:
        reason = reason.replace(old, new)
    return reason



class AutoRuleError(Exception):
    """허용·수정할 수 없다. ``status``는 HTTP 상태, 메시지는 화면에 보여도 되는 문장."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class AutoRuleBlocked(RuntimeError):
    """실행 게이트 안에서 막혔다(비상정지·규칙 꺼짐). 실행을 시작하지 않는다."""


def is_low_risk(device_type: str | None, action: str | None, value, *, time_rule: bool = False) -> bool:
    if time_rule and value in TIME_RULE_EXTRA_ACTIONS.get(device_type or "", {}).get(action or "", ()):
        return True
    allowed = LOW_RISK_ACTIONS.get(device_type or "", {})
    if action not in allowed:
        return False
    values = allowed[action]
    return values is None or value in values


# 조사 고르기는 rpi/josa.py 하나로(2026-10-19) — 옛 이름은 candidates.py 등이 그대로 쓴다.
_josa = josa
_josa_stem = josa_stem


#: 대상 기능을 찾지 못했을 때 동작 이름 대신 보일 말(원시 이름을 화면에 내지 않는다).
ACTION_LABELS = {"set_wind_strength": "바람 세기", "set_job_mode": "모드", "set_power": "전원"}
#: '무엇을' 조각의 동사·부사(10/18 쉬운 말). 없는 값은 '…을 …로 바꿔요'.
_POWER_WORDS = {"POWER_ON": "켜요", "POWER_OFF": "꺼요"}
_WIND_WORDS = {"HIGH": "세게", "MID": "중간으로", "LOW": "약하게", "AUTO": "자동으로"}


def thinq_action_phrase(name: str, action: str, value, cap=None) -> str:
    """ThinQ 동작 하나를 해요체 한 문장으로(10/18 쉬운 말, 예: '공기청정기를 켜요', '공기청정기 바람을 세게 해요').

    자동 실행 규칙의 '무엇을' 조각과 기록 제목(직접 조작·옛 자동 실행 기록)이 같은 말을 쓴다. '풍량'·'전원 켜기' 같은
    설정표 말은 쓰지 않는다. ``cap``(기능 정의)을 모르면 동작 이름 대신 일반 낱말 — 원시 이름을 화면에 내지 않는다."""
    if cap is None:
        # 원시 동작 이름(set_wind_strength HIGH)을 화면에 내지 않는다(2026-10-14 UX).
        label = ACTION_LABELS.get(action, "설정")
        return f"{name} {label}{_josa(label, '을', '를')} 바꿔요"
    value = str(value)
    spoken = _spoken_phrase(name, action, value)
    if spoken is not None:
        return spoken
    obj = f"{name}{_josa(_josa_stem(name), '을', '를')}"
    label = cap.value_label(value)
    if action == "set_job_mode":
        return f"{obj} {label} 모드로 바꿔요"
    return f"{name} {cap.label}{_josa(cap.label, '을', '를')} {label}{_josa(label, '으로', '로')} 바꿔요"


def _spoken_phrase(name: str, action: str, value: str) -> str | None:
    """전원·바람 세기는 동사·부사로('공기청정기를 켜요', '공기청정기 바람을 세게 해요'). 그 밖은 None."""
    if action == "set_power" and value in _POWER_WORDS:
        return f"{name}{_josa(_josa_stem(name), '을', '를')} {_POWER_WORDS[value]}"
    if action == "set_wind_strength" and value in _WIND_WORDS:
        return f"{name} 바람을 {_WIND_WORDS[value]} 해요"
    return None


#: 10/18 쉬운 말 2차 전 자동 실행 기록의 동작 문장('자동 실행 · 공기청정기 전원 끄기' 등, ``job_history.purpose``에 그대로
#: 저장돼 있다) → 지금 조각. 기록을 고치지 않고 보여 줄 때만 바꾼다(:func:`display_purpose`).
_LEGACY_AUTO_POWER = {"켜기": "POWER_ON", "끄기": "POWER_OFF"}
_LEGACY_AUTO_WIND = {"약": "LOW", "중": "MID", "강": "HIGH", "자동": "AUTO"}
_LEGACY_AUTO_MODES = ("청정", "수면", "저소음", "자동")


def _legacy_auto_action(text: str) -> str | None:
    """옛 동작 문장 하나 → 지금 조각. 모양이 맞지 않으면 None(받은 그대로 둔다)."""
    for word, value in _LEGACY_AUTO_POWER.items():
        tail = f" 전원 {word}"
        if text.endswith(tail) and len(text) > len(tail):
            return _spoken_phrase(text[: -len(tail)], "set_power", value)
    for word, value in _LEGACY_AUTO_WIND.items():
        tail = f" 풍량 {word}{_josa(word, '으로', '로')}"
        if text.endswith(tail) and len(text) > len(tail):
            return _spoken_phrase(text[: -len(tail)], "set_wind_strength", value)
    for mode in _LEGACY_AUTO_MODES:
        tail = f" 운전 모드 {mode}{_josa(mode, '으로', '로')}"
        if text.endswith(tail) and len(text) > len(tail):
            name = text[: -len(tail)]
            return f"{name}{_josa(_josa_stem(name), '을', '를')} {mode} 모드로 바꿔요"
    for label in ACTION_LABELS.values():
        tail = f" {label} 바꾸기"
        if text.endswith(tail) and len(text) > len(tail):
            return f"{text[: -len(tail)]} {label}{_josa(label, '을', '를')} 바꿔요"
    return None


#: 옛 바람 세기 말('강풍으로 바꿔줘'·'풍량을 강으로 바꿀까요?'·'바람 세기를 약으로 바꿔요') → 지금 말('바람을 세게 해줘').
#: 끝(줘·까요·요)은 그대로 두고 동사만 '바꾸다' → '하다'로 — 폰이 끝을 떼어 '~하기'로 만든다(display_status.dart).
_LEGACY_WIND = re.compile(
    r"^(?P<head>.*?)\s*(?:(?:풍량|바람\s?세기)\s?(?:을|를)?\s+(?P<a>강|중|약)|(?P<b>강|중|약)풍)\s?(?:으로|로)\s+"
    r"(?P<verb>바꿔|바꿀|바꾸)(?P<tail>\s?(?:줘|주세요|줄래요?|요|까요|기)?[.!?]?)$")
_LEGACY_WIND_ADVERB = {"강": "세게", "중": "중간으로", "약": "약하게"}
_LEGACY_WIND_VERB = {"바꿔": "해", "바꿀": "할", "바꾸": "하"}
#: 루틴 기록의 목적 문장(``'이름' 루틴``) — 이름은 사용자가 지은 것이라 고치지 않는다.
_ROUTINE_PURPOSE = re.compile(r"^'.+' 루틴$")


def _legacy_wind(text: str) -> str | None:
    """옛 바람 세기 문장 하나 → 지금 문장. 모양이 맞지 않으면 None."""
    m = _LEGACY_WIND.match(text)
    if m is None:
        return None
    head = m.group("head").strip()
    words = head.split()
    # '공기청정기를 강풍으로' → '공기청정기 바람을 세게'. 한 글자 낱말의 '을/를'은 조사로 보지 않는다.
    if words and len(words[-1]) > 1 and words[-1][-1] in "을를":
        words[-1] = words[-1][:-1]
    adverb = _LEGACY_WIND_ADVERB[m.group("a") or m.group("b")]
    body = f"바람을 {adverb} {_LEGACY_WIND_VERB[m.group('verb')]}{m.group('tail')}"
    return " ".join([*words, body])


def display_purpose(purpose: str | None) -> str | None:
    """기록에 저장된 목적 문장을 지금 문체로(10/18 쉬운 말 3차·4차). 저장값은 고치지 않는다 — 보여 줄 때만.

    - 옛 시나리오 질문('공기청정기 풍량을 강으로 바꿀까요?') → 지금 질문(시나리오 카탈로그의 ``former_questions``).
    - 옛 자동 실행 동작 문장('자동 실행 · 공기청정기 전원 끄기') → '자동 실행 · 공기청정기를 꺼요'. 앞의 ``자동 실행 · ``는
      그대로 둔다(폰이 이 글자로 출처 '자동'을 가른다).
    - 옛 바람 세기 말(4차): '강풍으로 바꿔줘' → '바람을 세게 해줘', '공기청정기를 약풍으로 바꿀까요?' → '공기청정기 바람을
      약하게 할까요?', 남은 '풍량' → '바람 세기'. 사람 명령문의 끝('~줘')은 그대로(폰이 '~하기'로 바꾼다).
    그 밖(말로 한 명령·루틴 이름·지금 형식)은 받은 그대로."""
    if not purpose:
        return purpose
    from rpi.scenarios.catalog import current_question  # noqa: PLC0415

    current = current_question(purpose)
    if current != purpose:
        return current
    prefix = AUTO_PURPOSE_PREFIX if purpose.startswith(AUTO_PURPOSE_PREFIX) else ""
    body = purpose[len(prefix):].strip() if prefix else purpose
    if _ROUTINE_PURPOSE.match(body):
        return purpose
    fixed = _legacy_auto_action(body) if prefix else None
    if fixed is None:
        fixed = _legacy_wind(body)
    if fixed is None and "풍량" in body:
        fixed = body.replace("풍량", "바람 세기")
    return prefix + fixed if fixed is not None else purpose


#: 시작 시각 → 때 이름. 0시는 '밤 12시', 12시는 '낮 12시'.
_DAY_PARTS = ((0, "새벽"), (6, "아침"), (12, "낮"), (18, "저녁"), (21, "밤"))


def spoken_time(hhmm: str | None) -> str:
    """'22:00' → '밤 10시', '07:30' → '아침 7시 30분'. 읽을 수 없으면 받은 그대로."""
    try:
        hour, minute = (int(x) for x in (hhmm or "").split(":"))
    except ValueError:
        return hhmm or ""
    if not (0 <= hour < 24 and 0 <= minute < 60):
        return hhmm or ""
    part = "밤" if hour == 0 else next(name for start, name in reversed(_DAY_PARTS) if hour >= start)
    return f"{part} {hour % 12 or 12}시" + (f" {minute}분" if minute else "")


def _days_words(days) -> str:
    from .model import WEEKDAY_LABELS  # noqa: PLC0415

    days = tuple(days or ())
    if not days or days == tuple(range(7)):
        return "매일"
    if days == tuple(range(5)):
        return "평일"
    if days == (5, 6):
        return "주말"
    return ", ".join(f"{WEEKDAY_LABELS[d]}요일" for d in days)


def _device_key(device_id: str) -> str:
    from rpi.services.thinq.discovery import device_key  # noqa: PLC0415

    return device_key(device_id)


@dataclass(frozen=True)
class AutoRule:
    rule_id: str
    scenario_id: str
    condition_appliance_id: str
    condition_event: str
    target_appliance_id: str
    target_device_key: str
    target_device_type: str
    action: str
    arg: str
    value: str
    enabled: bool = False
    #: 사용자가 확인 화면에서 허용한 지문. 지금 지문과 다르면 허용이 아니다.
    allowed_fingerprint: str | None = None
    created_at: str | None = None
    allowed_at: str | None = None
    updated_at: str | None = None
    disabled_reason: str | None = None
    #: 조건 종류(2026-10-16) — ``appliance_done``(가열 종료, 종전) · ``time``(시각 루틴의 정해진 시각). 옛 저장값엔 없다.
    condition_kind: str = CONDITION_KIND_APPLIANCE_DONE
    #: 시각 규칙 — 루틴 ID·요일(0=월)·"HH:MM". 가열 종료 규칙은 None.
    condition_routine_id: str | None = None
    condition_days: tuple[int, ...] | None = None
    condition_time: str | None = None

    @property
    def is_time(self) -> bool:
        return self.condition_kind == CONDITION_KIND_TIME

    def fingerprint(self) -> str:
        """허용이 묶이는 내용 — 조건(가전·이벤트·근거 / 시각 규칙은 루틴·요일·시각·근거)·대상(가전·기기 키·종류)·동작·속성·값.

        가열 종료 규칙의 지문 내용은 시각 규칙을 넣기 전과 바이트까지 같다(저장된 허용이 꺼지지 않게)."""
        if self.is_time:
            condition = {"kind": CONDITION_KIND_TIME, "routine_id": self.condition_routine_id,
                         "days": list(self.condition_days or ()), "time": self.condition_time,
                         "basis": TIME_CONDITION_BASIS}
        else:
            condition = {"appliance_id": self.condition_appliance_id, "event": self.condition_event,
                         "basis": CONDITION_BASIS}
        payload = {
            "scenario": self.scenario_id,
            "condition": condition,
            "target": {"appliance_id": self.target_appliance_id, "device_key": self.target_device_key,
                       "device_type": self.target_device_type},
            "action": self.action, "arg": self.arg, "value": self.value,
        }
        return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()

    @property
    def allowed(self) -> bool:
        return self.enabled and self.allowed_fingerprint == self.fingerprint()

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Mapping) -> "AutoRule":
        fields = {name: data.get(name) for name in cls.__dataclass_fields__}
        fields["enabled"] = data.get("enabled") is True
        # 시각 규칙 전에 저장된 규칙(새 칸 없음)은 가열 종료 규칙이다.
        fields["condition_kind"] = data.get("condition_kind") or CONDITION_KIND_APPLIANCE_DONE
        days = data.get("condition_days")
        fields["condition_days"] = tuple(int(d) for d in days) if days is not None else None
        return cls(**fields)


class AutoRuleStore:
    """규칙 목록 — 서버 DB 설정 칸(``auto_rules``)이 있으면 재시작에도 남는다. 없으면 메모리.

    4차 평가 H-N2: **판정용 메모리와 영속 쓰기를 나눈다.** 규칙 목록은 불변 사본(``MappingProxyType``)을 통째로 바꿔
    끼우고(``put``·``remove``, 짧은 메모리 잠금), 읽기(``get``·``list``)는 지금 사본을 잠금 없이 본다. DB 쓰기(``flush``)는
    따로 잠금을 잡고 그때의 **가장 새 사본**을 쓴다(늦게 끝난 쓰기가 새 상태를 옛 상태로 덮지 않는다). 그래서 실행
    게이트(서비스 잠금 안)의 ``get``이 다른 요청의 DB 쓰기 대기에 묶이지 않는다 — 정지 경로가 서비스 잠금을 기다리지 않는다."""

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None, *,
                 session_load: Callable[[], str | None] | None = None,
                 session_save: Callable[[str], None] | None = None,
                 now: Callable[[], str] | None = None) -> None:
        import json  # noqa: PLC0415

        self._json = json
        self._save_fn = save
        self._session_save = session_save
        #: 메모리 사본 교체만(입출력 없음).
        self._mem_lock = threading.Lock()
        #: DB 쓰기 직렬화 — 이 잠금을 잡은 채 메모리 잠금을 기다리지 않는다(사본·판 번호만 짧게 읽는다).
        self._persist_lock = threading.Lock()
        rules: dict[str, AutoRule] = {}
        raw = load() if load is not None else None
        if raw:
            try:
                for item in json.loads(raw):
                    rule = AutoRule.from_dict(item)
                    rules[rule.rule_id] = rule
            except (ValueError, TypeError, KeyError):
                log.exception("auto rules unreadable; starting empty (자동 실행은 꺼진 것과 같다)")
                rules = {}
        self._rules: Mapping[str, AutoRule] = MappingProxyType(rules)
        self._version = 0
        self._persisted_version = 0
        #: 지난 프로세스가 깨끗이 닫히지 않아 이번 기동에서 끈 규칙 수(4차 평가 M-N3 내구성 경계).
        self.held_on_start = 0
        if session_load is not None or session_save is not None:
            self._open_session(session_load, now)

    # ── 내구성 경계(4차 평가 M-N3) ─────────────────────────────────────────────
    def _open_session(self, session_load, now) -> None:
        """정지의 규칙 끄기는 메모리에서 바로 효력을 내고 DB 쓰기는 뒤에서 한다. 그 쓰기가 끝나기 전에 프로세스가 죽으면
        DB에는 '켜짐'이 남는다 — 그래서 **깨끗이 닫히지 않은 지난 프로세스**(세션 표시가 열린 채, 다른 프로세스)의 켜진
        규칙은 이번 기동에서 끈다(다시 허용 필요). 깨끗한 종료(:meth:`close`)는 남은 쓰기를 마친 뒤에만 표시를 닫는다."""
        raw = None
        try:
            raw = session_load() if session_load is not None else None
        except Exception:  # noqa: BLE001
            log.exception("auto rule session marker unreadable — 지난 종료를 모르므로 켜진 규칙을 끈다")
            raw = '{"open": true, "session": null}'
        marker = None
        if raw:
            try:
                marker = self._json.loads(raw)
            except ValueError:
                marker = {"open": True, "session": None}
        unclean = isinstance(marker, dict) and marker.get("open") is not False \
            and marker.get("session") != PROCESS_SESSION
        if unclean:
            stamp = now() if now is not None else None
            held = [r for r in self._rules.values() if r.enabled]
            for rule in held:
                self.put(replace(rule, enabled=False, updated_at=stamp, disabled_reason=UNCLEAN_RESTART_REASON))
            self.held_on_start = len(held)
            if held:
                log.warning("auto rules: previous process did not close cleanly — %d rule(s) held off", len(held))
                try:
                    self.flush()
                except Exception:  # noqa: BLE001 -- 메모리는 꺼짐. 다음 깨끗한 종료 전까지 표시는 열려 있다
                    log.exception("auto rules: could not persist the restart hold")
        self._write_session(open_=True)

    def _write_session(self, *, open_: bool) -> bool:
        if self._session_save is None:
            return True
        try:
            self._session_save(self._json.dumps({"open": open_, "session": PROCESS_SESSION}))
            return True
        except Exception:  # noqa: BLE001
            log.exception("auto rule session marker write failed")
            return False

    def close(self, timeout_s: float = 5.0) -> bool:
        """깨끗한 종료 — 남은 규칙 쓰기를 ``timeout_s`` 안에 마쳤을 때만 세션 표시를 닫는다(다음 기동이 규칙을 믿는다).
        쓰기가 멈췄거나 실패하면 표시를 열어 둔다 → 다음 기동은 켜진 규칙을 끈다. 닫았으면 True."""
        done = threading.Event()
        ok: list[bool] = []

        def flush() -> None:
            try:
                self.flush()
                ok.append(not self.pending())
            except Exception:  # noqa: BLE001
                log.exception("auto rules: final flush failed — 다음 기동에서 켜진 규칙을 끈다")
            finally:
                done.set()

        threading.Thread(target=flush, name="auto-rule-close", daemon=True).start()
        if not done.wait(timeout_s) or not ok or not ok[0]:
            return False
        return self._write_session(open_=False)

    # ── 읽기: 잠금 없음(불변 사본) ─────────────────────────────────────────────
    def list(self) -> tuple[AutoRule, ...]:
        return tuple(self._rules.values())

    def get(self, rule_id: str) -> AutoRule | None:
        return self._rules.get(rule_id)

    # ── 메모리 바꾸기(즉시 효력) ─────────────────────────────────────────────
    def put(self, rule: AutoRule) -> AutoRule:
        with self._mem_lock:
            rules = dict(self._rules)
            rules[rule.rule_id] = rule
            self._rules = MappingProxyType(rules)
            self._version += 1
        return rule

    def remove(self, rule_id: str) -> bool:
        with self._mem_lock:
            if rule_id not in self._rules:
                return False
            rules = dict(self._rules)
            del rules[rule_id]
            self._rules = MappingProxyType(rules)
            self._version += 1
        return True

    # ── 영속 ────────────────────────────────────────────────────────────────
    def flush(self) -> None:
        """지금 메모리 사본을 DB에 쓴다(이미 쓴 판이면 아무것도 안 함). 실패는 예외로 올린다(메모리는 그대로)."""
        with self._persist_lock:
            with self._mem_lock:
                rules, version = self._rules, self._version
            if version <= self._persisted_version:
                return
            if self._save_fn is not None:
                self._save_fn(self._json.dumps([r.to_dict() for r in rules.values()], ensure_ascii=False))
            self._persisted_version = version

    def pending(self) -> bool:
        """메모리에만 있고 아직 DB에 쓰지 못한 변경이 있다."""
        with self._mem_lock:
            return self._version > self._persisted_version

    def save(self, rule: AutoRule) -> AutoRule:
        self.put(rule)
        self.flush()
        return rule

    def delete(self, rule_id: str) -> bool:
        removed = self.remove(rule_id)
        if removed:
            self.flush()
        return removed


class SeenEvents:
    """한 번 처리한 완료 사건 키(최근 ``MAX_SEEN_EVENTS``개). DB가 있으면 재시작 뒤 재전송도 막는다."""

    def __init__(self, load: Callable[[], str | None] | None = None,
                 save: Callable[[str], None] | None = None) -> None:
        import json  # noqa: PLC0415

        self._json = json
        self._save_fn = save
        self._lock = threading.Lock()
        self._keys: deque[str] = deque(maxlen=MAX_SEEN_EVENTS)
        raw = load() if load is not None else None
        if raw:
            try:
                self._keys.extend(str(k) for k in json.loads(raw))
            except (ValueError, TypeError):
                log.exception("seen auto-rule events unreadable")

    def add(self, key: str) -> bool:
        """처음 본 키면 넣고 True, 이미 있으면 False."""
        with self._lock:
            if key in self._keys:
                return False
            self._keys.append(key)
            if self._save_fn is not None:
                self._save_fn(self._json.dumps(list(self._keys)))
            return True


def event_key(record: Mapping) -> str | None:
    """완료 사건 키 — 가전·이벤트·출처·RPi4 끝 시각(at_s)·그 시각의 시계(clock_id). 끝 시각이 없으면 None(같은 사건인지 모름).

    ``at_s``는 RPi4 프로세스의 단조 시각이라 RPi4가 다시 켜지면 처음부터 다시 센다 — 시계가 다르면 같은 ``at_s``라도 다른
    사건이다(검토 10/19 #6). ``clock_id``가 없는 옛 프레임은 예전 키 그대로(저장된 처리 기록과 맞게)."""
    at_s = record.get("at_s")
    if not isinstance(at_s, (int, float)) or isinstance(at_s, bool) or not math.isfinite(at_s):
        return None
    raw = f"{record.get('appliance_id')}|{record.get('event')}|{record.get('source')}|{float(at_s):.3f}"
    clock_id = record.get("clock_id")
    if isinstance(clock_id, str) and clock_id:
        raw += f"|{clock_id}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def time_event_key(routine_id: str, scheduled: datetime) -> str:
    """시각 사건 키 — 루틴·날짜·정해진 시각. 같은 날 같은 시각은 재시작 뒤에도 한 번(``SeenEvents``에 영속)."""
    raw = f"time|{routine_id}|{scheduled.date().isoformat()}|{scheduled.strftime('%H:%M')}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


#: 신선도 근거가 없을 때(3차 평가 M1) — 보류가 기본이다.
# 연결이 바뀌었거나 옛 RPi4라 끝 시각을 이 본체 시계로 옮길 수 없다.
NO_FRESHNESS_REASON = "가열이 언제 끝났는지 알 수 없어 자동으로 하지 않았어요."


def event_age_s(record: Mapping, now_mono_s: float) -> float | None:
    """사건 나이(초) — 받을 때 이 허브 단조 시계로 옮겨 둔 끝 시각(``event_end_mono_s``)부터 ``now_mono_s``까지.

    옮길 근거가 없었으면(``None``) 또는 1초 넘게 미래면(근거가 어긋남) None — 자동 실행은 보류한다(3차 평가 M1)."""
    end = record.get("event_end_mono_s")
    if not isinstance(end, (int, float)) or isinstance(end, bool) or not math.isfinite(end):
        return None
    age = now_mono_s - float(end)
    return max(age, 0.0) if age >= -1.0 else None


def max_event_age_from_env(env: Mapping[str, str] | None = None) -> float:
    src = os.environ if env is None else env
    raw = (src.get(MAX_EVENT_AGE_ENV) or "").strip()
    if not raw:
        return DEFAULT_MAX_EVENT_AGE_S
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{MAX_EVENT_AGE_ENV} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not (math.isfinite(value) and value > 0):
        raise RuntimeError(f"{MAX_EVENT_AGE_ENV}는 0보다 커야 합니다: {raw!r}")
    return value


class AutoRuleEngine:
    """규칙 만들기·실행·관리. 서비스(실행 게이트)와 시나리오 엔진(카드)을 그때그때 받아 쓴다."""

    def __init__(self, store: AutoRuleStore, seen: SeenEvents, service, clock, *,
                 scenarios: Callable[[], object] | None = None, care_events=None,
                 max_event_age_s: float = DEFAULT_MAX_EVENT_AGE_S,
                 monotonic: Callable[[], float] | None = None,
                 started: Callable[[], float] | None = None,
                 is_quiet: Callable[[], bool] | None = None,
                 routines: Callable[[], object] | None = None,
                 quiet_settings: Callable[[], Mapping] | None = None) -> None:
        self.store = store
        #: 시각 규칙의 루틴 저장소(2026-10-16). 없으면 시각 규칙을 만들지도 쓰지도 않는다.
        self._routines = routines or (lambda: None)
        #: 확인 화면 단서용 조용한 시간 설정(enabled·start·end). 없으면 단서에 넣지 않는다.
        self._quiet_settings = quiet_settings
        #: 조용한 시간·잠시 쉬기(2026-10-14, 5번 정책 b) — 메모리 판정만. 그 사이 사건은 건너뛰고 다시 실행하지 않는다.
        self._is_quiet = is_quiet or (lambda: False)
        #: 이 허브의 단조 시계 — 사건 끝 시각을 옮긴 시계와 같아야 한다(기본: rpi/services/event_clock.py).
        self._monotonic = monotonic or _hub_monotonic
        self._seen = seen
        self.service = service
        self._clock = clock
        self._scenarios = scenarios or (lambda: None)
        self._care = care_events
        self._max_age = max_event_age_s
        self._lock = threading.Lock()
        #: 비상정지 세대. 판단 시점과 실행 게이트 안의 값이 다르면 보내지 않는다.
        self._gen_lock = threading.Lock()
        self._generation = 0
        #: 이 프로세스에서 규칙이 허용된 세대(3차 평가 H2, 메모리). 지금 세대와 다르면 저장된 '켜짐'이어도 쓰지 않는다 —
        #: 정지(세대 올림)가 규칙 끄기 저장보다 먼저 끝나거나, 정지 전에 시작한 허용 요청이 정지 뒤에 저장해도 켜지지 않는다.
        #: 재시작 직후 불러온 규칙은 세대 0(아직 정지 없음)으로 본다.
        self._allowed_generation: dict[str, int] = {}
        #: 이 프로세스에서 규칙을 허용한 허브 단조 시각(4차 평가 M-N2, 메모리). 없으면 재시작 뒤 불러온 허용이다.
        self._allowed_mono: dict[str, float] = {}
        #: 이 프로세스가 시작한 허브 단조 시각 — 사건 끝 시각을 옮긴 시계와 같은 축.
        self._started = started or (_hub_started if monotonic is None else (lambda value=self._monotonic(): value))
        self._runs: deque[dict] = deque(maxlen=50)
        #: 기록보다 먼저 끝난 자동 실행의 결과(job_id → 완료 이벤트).
        self._early_results: dict[str, object] = {}
        #: 보내기 직전 재검사에 걸린 자동 실행(규칙:사건 키 → 이유). 결과가 오면 기록을 '막힘'으로 고친다.
        self._dispatch_blocked: dict[str, str] = {}
        #: 전송권(4차 평가 H-N1) — 전송 개시 표시와 철회를 직렬화하는 메모리 잠금. 입출력·다른 잠금 대기 없음.
        self._send_lock = threading.Lock()
        #: 전송을 시작한 규칙(규칙 ID → 규칙:사건 키). job이 끝나면 지운다.
        self._sending: dict[str, str] = {}

    def _quiet(self) -> bool:
        try:
            return bool(self._is_quiet())
        except Exception:  # noqa: BLE001 -- 판정을 못 하면 보내지 않는 쪽(자동 실행은 건너뛰어도 사용자가 직접 할 수 있다)
            log.exception("quiet hours check failed; skipping auto run")
            return True

    # ── 등록부·문장 ─────────────────────────────────────────────────────────
    def _registry(self):
        return getattr(self.service, "_appliance_registry", None)

    def _appliance(self, appliance_id: str):
        registry = self._registry()
        return registry.get(appliance_id) if registry is not None else None

    def _name(self, appliance_id: str) -> str:
        appliance = self._appliance(appliance_id)
        if appliance is not None:
            return appliance.name
        # 대상이 지금 없으면(ThinQ 끔·지움) 원시 ID 대신 종류 이름(10/14 실물: 'air_purifier'가 보였다).
        return _TARGET_KIND_NAMES.get(appliance_id, "대상 가전")

    def _definition(self, scenario_id: str | None):
        engine = self._scenarios()
        catalog = getattr(engine, "catalog", None)
        return catalog.get(scenario_id) if catalog is not None and scenario_id else None

    def condition_text(self, rule: AutoRule) -> str:
        """'언제' 조각 — 뒤에 '무엇을' 조각을 붙여 읽어도 한 문장이 되게(10/18 쉬운 말, 예: '매일 밤 10시에')."""
        if rule.is_time:
            return f"{_days_words(rule.condition_days)} {spoken_time(rule.condition_time)}에"
        # A5(2026-10-14): CT 끝 판정은 취소·문 열림 가열 종료와 구분하지 못한다 — 조리 완료라고 말하지 않는다.
        # '데우기가 끝나면'도 다 데운 것처럼 읽혀 '데우기를 멈추면'으로 쓴다(이유와 상관없이 멈춘 것이 근거).
        # 그 단서('조리 완료가 아닐 수 있어요')는 허용 확인 시트(폰)에만 둔다 — 목록·카드 문장은 짧게(2026-10-14 UX).
        name = self._name(rule.condition_appliance_id)
        subject = f"{name}{_josa(_josa_stem(name), '이', '가')}"
        if rule.condition_event == "heat_complete":
            return f"{subject} 데우기를 멈추면"
        return f"{subject} 멈추면"

    def action_text(self, rule: AutoRule) -> str:
        name = self._name(rule.target_appliance_id)
        appliance = self._appliance(rule.target_appliance_id)
        binding = getattr(appliance, "thinq", None)
        try:
            cap = binding.capability(rule.action) if binding is not None else None
        except Exception:  # noqa: BLE001 -- 대상이 바뀌었으면 동작 이름만
            cap = None
        return thinq_action_phrase(name, rule.action, rule.value, cap)

    # ── 카드의 허용 제안 ─────────────────────────────────────────────────────
    def offer_for(self, suggestion) -> AutoRule | None:
        """카드가 '다음부터도 자동으로'를 고를 수 있으면 그 내용(저장 전 규칙), 아니면 None.

        v4 정의(``auto_allowed``)의 카드이고, 명령이 ThinQ 하나이며, 낮은 위험 동작일 때만. 물리 누름이 하나라도
        있으면 None — 화면에 버튼이 없고 서버도 거절한다."""
        commands = tuple(getattr(suggestion, "commands", ()) or ())
        if any(c.route is not ControlRoute.THINQ for c in commands) or len(commands) != 1:
            return None
        if parse_scenario_key(getattr(suggestion, "scenario_id", None)) is not None:
            return self._time_offer(suggestion.scenario_id, commands[0])
        definition = self._definition(getattr(suggestion, "scenario_id", None))
        if definition is None or not definition.auto_allowed or definition.trigger.kind != "appliance_done":
            return None
        command = commands[0]
        return self._draft(definition.scenario_id, definition.trigger.appliance_id,
                           definition.trigger.event, command.target_id, command.action,
                           command.args_dict())

    def _draft(self, scenario_id, condition_appliance, condition_event, target_id, action, args) -> AutoRule | None:
        appliance = self._appliance(target_id)
        binding = getattr(appliance, "thinq", None)
        if appliance is None or appliance.control_path is not ControlRoute.THINQ or binding is None:
            return None
        try:
            cap = binding.capability(action)
            value = args.get(cap.arg)
            cap.validate({cap.arg: value})
        except Exception:  # noqa: BLE001
            return None
        if not is_low_risk(binding.device_type, action, value, time_rule=condition_event == TIME_EVENT):
            return None
        return AutoRule(
            rule_id="", scenario_id=scenario_id, condition_appliance_id=condition_appliance,
            condition_event=condition_event, target_appliance_id=target_id,
            target_device_key=_device_key(binding.device_id), target_device_type=binding.device_type,
            action=action, arg=cap.arg, value=str(value),
        )

    # ── 시각 루틴(2026-10-16) ─────────────────────────────────────────────────
    def _routine(self, routine_id: str | None):
        store = self._routines()
        if store is None or not routine_id:
            return None
        try:
            return store.get(routine_id)
        except Exception:  # noqa: BLE001 -- 저장소를 읽지 못하면 없는 것으로(자동 실행은 보류)
            log.exception("routine lookup for auto rule failed")
            return None

    @staticmethod
    def _routine_shape_issue(routine) -> str | None:
        """시각 규칙이 될 수 있는 루틴인가 — 켜짐·승인 루틴·시각 트리거·조건 없음·ThinQ 명령 한 단계(안내·기다리기 없음)."""
        if routine is None:
            return ROUTINE_DELETED_REASON
        if not routine.enabled:
            return ROUTINE_OFF_REASON
        if (routine.mode != "approve" or routine.trigger.kind != "time" or routine.conditions
                or len(routine.steps) != 1 or routine.steps[0].kind != "thinq_command"):
            return ROUTINE_CHANGED_REASON
        return None

    def _time_offer(self, scenario_id: str, command) -> AutoRule | None:
        """시각 루틴 카드의 허용 내용. 카드 명령이 지금 루틴의 그 한 단계와 같을 때만."""
        key = parse_scenario_key(scenario_id)
        routine = self._routine(key[0]) if key else None
        if self._routine_shape_issue(routine) is not None or routine.scenario_key() != scenario_id:
            return None
        step = routine.steps[0]
        if (command.target_id, command.action, command.args_dict()) != (step.appliance_id, step.action,
                                                                        dict(step.args)):
            return None
        draft = self._draft(scenario_id, "", TIME_EVENT, step.appliance_id, step.action, dict(step.args))
        if draft is None:
            return None
        return replace(draft, condition_kind=CONDITION_KIND_TIME, condition_routine_id=routine.routine_id,
                       condition_days=tuple(routine.trigger.days), condition_time=routine.trigger.time)

    def caveat(self, rule: AutoRule) -> str:
        """확인 화면·목록의 단서 — 이 조건을 무엇으로 판단하는지와 하지 않는 경우."""
        if not rule.is_time:
            return COOK_CAVEAT
        if self._time_in_quiet(rule.condition_time):
            # 같은 경고는 한 번(10/17 쉬운 말) — 조용한 시간 문장만.
            return TIME_QUIET_CAVEAT
        return TIME_CAVEAT

    def _time_in_quiet(self, hhmm: str | None) -> bool:
        if self._quiet_settings is None or not hhmm:
            return False
        try:
            from rpi.services.quiet_hours import window_contains  # noqa: PLC0415

            from .model import parse_hhmm  # noqa: PLC0415

            settings = self._quiet_settings()
            if not settings.get("enabled"):
                return False
            at = datetime.combine(self._clock.now().date(), parse_hhmm(hhmm))
            return window_contains(settings["start"], settings["end"], at)
        except Exception:  # noqa: BLE001 -- 단서 문장만 — 판정 실패는 덧붙이지 않는다
            log.exception("quiet window check for caveat failed")
            return False

    def offer_payload(self, suggestion) -> dict | None:
        draft = self.offer_for(suggestion)
        if draft is None:
            return None
        return {"condition_text": self.condition_text(draft), "action_text": self.action_text(draft),
                "caveat": self.caveat(draft), "fingerprint": draft.fingerprint()}

    # ── 정지 세대 ───────────────────────────────────────────────────────────
    def generation(self) -> int:
        """지금 정지 세대. 허용 요청은 시작할 때 이 값을 잡아 저장 단계까지 넘긴다(3차 평가 H2)."""
        with self._gen_lock:
            return self._generation

    def _generation_ok(self, rule: AutoRule) -> bool:
        """규칙이 지금 정지 세대에서 허용된 것인가(메모리 판정, 입출력 없음)."""
        with self._gen_lock:
            return self._allowed_generation.get(rule.rule_id, 0) == self._generation

    def _allowed_boundary(self, rule: AutoRule) -> tuple[float, bool]:
        """허용 전후를 가르는 허브 단조 시각과 '재시작 뒤 불러온 허용인가'(4차 평가 M-N2). 이 프로세스에서 허용했으면 그
        순간, 아니면(DB에서 불러옴) 이 프로세스가 시작한 순간 — 재시작 전에 끝난 가열은 허용 전후를 단정하지 않고 보류."""
        with self._gen_lock:
            allowed = self._allowed_mono.get(rule.rule_id)
        if allowed is not None:
            return allowed, False
        return self._started(), True

    def usable(self, rule: AutoRule) -> bool:
        """저장된 허용(켜짐·지문 일치)이고 그 뒤로 정지가 없었다."""
        return rule.allowed and self._generation_ok(rule)

    def _save_allowed(self, rule: AutoRule, start_generation: int | None,
                      expected: AutoRule | None = None) -> AutoRule:
        """허용 저장 — 요청 시작 세대와 지금 세대를 저장 앞뒤로 대조한다. 정지가 끼면 켜지 않고 409.

        세대 판정은 메모리에서만 한다(정지 경로의 ``halt``는 이 저장의 DB 쓰기를 기다리지 않는다). 저장 전에 이 규칙의 허용
        세대를 **요청 시작 세대**로 적어 두므로, 저장 도중 정지가 들어와도 저장된 '켜짐'은 쓰이지 않고, 저장 뒤 다시 대조해
        꺼진 상태로 되돌린다.

        ``expected``(다시 허용): 호출자가 읽은 그 규칙. 철회와 같은 전송권 잠금 안에서 아직 그대로인지 보고 바꾼다(HIGH
        재확인 2차 — 읽은 뒤 끝난 삭제는 404로 남기고 되살리지 않으며, 끝난 값 바꾸기는 409로 남기고 되돌리지 않는다)."""
        generation = self.generation() if start_generation is None else start_generation
        allowed_mono = self._monotonic()
        if expected is not None:
            with self._send_lock:  # 철회(_revoke)와 같은 잠금 — 메모리만
                current = self.store.get(rule.rule_id)
                if current is None:
                    raise AutoRuleError(404, "이 자동으로 하기를 찾을 수 없어요")
                if current is not expected:
                    raise AutoRuleError(409, RULE_CHANGED_REASON)
                self._mark_allowed(rule, generation, allowed_mono)
                self.store.put(rule)
            self.store.flush()
        else:
            self._mark_allowed(rule, generation, allowed_mono)
            self.store.save(rule)
        if self.generation() != generation:
            # 검토 10/19 #10: 우리가 넣은 그대로일 때만 끈다 — 그 사이 끝난 삭제·값 바꾸기·새 허용을 덮지 않는다.
            self._replace_if_unchanged(rule, replace(rule, enabled=False, updated_at=self._clock.now().isoformat(),
                                                     disabled_reason=ESTOP_REASON))
            raise AutoRuleError(409, STOP_RACE_REASON)
        return rule

    def _replace_if_unchanged(self, seen: AutoRule, new: AutoRule) -> bool:
        """비교 후 저장 — 철회와 같은 전송권 잠금 안에서 지금 규칙이 ``seen`` 그대로일 때만 ``new``로 바꾼다. 지워졌으면
        다시 넣지 않는다. DB 쓰기는 잠금 밖에서. 바꿨으면 True."""
        with self._send_lock:  # 메모리만
            if self.store.get(seen.rule_id) is not seen:
                return False
            self.store.put(new)
        self.store.flush()
        return True

    def _mark_allowed(self, rule: AutoRule, generation: int, allowed_mono: float) -> None:
        with self._gen_lock:
            if self._generation != generation:
                raise AutoRuleError(409, STOP_RACE_REASON)
            self._allowed_generation[rule.rule_id] = generation
            self._allowed_mono[rule.rule_id] = allowed_mono

    def allow_from_offer(self, draft: AutoRule, start_generation: int | None = None) -> AutoRule:
        """확인 화면에서 허용한 내용을 규칙으로 저장한다. 같은 조건·대상·동작의 규칙이 있으면 바꾼다.

        ``start_generation``: 허용 요청을 시작할 때의 정지 세대(:meth:`generation`). 그 뒤 전체 정지가 들어왔으면
        저장하지 않고(또는 꺼진 상태로 되돌리고) ``AutoRuleError(409)`` — 이번 실행과는 따로 알린다(3차 평가 H2)."""
        now = self._clock.now().isoformat()
        if draft.is_time:
            # 시각 규칙: 같은 루틴·대상·동작이면 그 규칙을 바꾼다(루틴 단계 지문·시각이 바뀌어도 하나로).
            same = (draft.condition_kind, draft.condition_routine_id, draft.target_appliance_id, draft.action)
            existing = next((r for r in self.store.list()
                             if (r.condition_kind, r.condition_routine_id, r.target_appliance_id, r.action) == same),
                            None)
        else:
            existing = next((r for r in self.store.list()
                             if (r.scenario_id, r.condition_appliance_id, r.condition_event,
                                 r.target_appliance_id, r.action)
                             == (draft.scenario_id, draft.condition_appliance_id, draft.condition_event,
                                 draft.target_appliance_id, draft.action)), None)
        rule = replace(draft, rule_id=existing.rule_id if existing else f"ar-{uuid4().hex[:10]}",
                       enabled=True, allowed_fingerprint=draft.fingerprint(),
                       created_at=existing.created_at if existing else now,
                       allowed_at=now, updated_at=now, disabled_reason=None)
        # 검토 10/19 (2): 읽은 규칙을 바꿀 때는 철회와 같은 잠금 안에서 그대로인지 보고 바꾼다 — 읽은 뒤 끝난 삭제·끄기를
        # 덮어 지운 규칙을 되살리거나 끈 규칙을 다시 켜지 않는다(404·409로 남기고 자동 허용만 실패).
        self._save_allowed(rule, start_generation, expected=existing)
        log.info("auto rule allowed by user: %s (%s → %s %s)", rule.rule_id, rule.condition_event,
                 rule.target_appliance_id, rule.action)
        return rule

    # ── 사건 ─────────────────────────────────────────────────────────────────
    def on_appliance_done(self, record: Mapping) -> list[dict]:
        """검증한 ``appliance_done`` 기록. 켜진 규칙이 맡은 조건이면 자동 실행을 시도하고, 아니면 카드를 띄운다."""
        key = event_key(record)
        if key is not None and not self._seen.add(key):
            matching = [r for r in self.store.list() if self._matches(r, record)]
            if matching:
                return [self._record(rule, record, key, "duplicate",
                                     "같은 알림이 다시 와서 한 번만 했어요.") for rule in matching]
            return []
        received_at = self._clock.now()
        entries: list[dict] = []
        handled: set[str] = set()
        for rule in self.store.list():
            # 정지 뒤(세대가 바뀐 뒤)로 다시 허용받지 않은 규칙은 저장된 '켜짐'이어도 맡지 않는다(3차 평가 H2).
            if not (rule.enabled and self._generation_ok(rule) and self._matches(rule, record)):
                continue
            entry = self._try_run(rule, record, key, received_at)
            entries.append(entry)
            if not entry.get("reoffer"):
                handled.add(rule.scenario_id)
        engine = self._scenarios()
        if engine is not None and hasattr(engine, "on_appliance_done"):
            try:
                engine.on_appliance_done(dict(record), skip=frozenset(handled))
            except Exception:  # noqa: BLE001
                log.exception("scenario card for appliance_done failed")
        return entries

    def on_time_due(self, routine, scheduled: datetime, now: datetime) -> list[dict]:
        """시각 루틴의 정해진 시각(루틴 엔진 ``tick``). 켜진 시각 규칙이 맡으면 카드 없이 자동 실행을 시도한다.

        돌려준 기록 중 ``reoffer``가 아닌 것이 있으면 맡은 것이다(호출자는 카드를 만들지 않는다). 빈 목록이거나 모두
        ``reoffer``(늦음·허용 전·재시작 전·규칙 무효)면 호출자가 종전처럼 카드를 만든다(승인 필요). 같은 날 같은 시각은
        ``SeenEvents``로 한 번만(재시작 뒤에도) — 두 번째는 'duplicate'(맡은 것, 카드 없음)."""
        rules = [r for r in self.store.list()
                 if r.is_time and r.condition_routine_id == routine.routine_id
                 and r.enabled and self._generation_ok(r)]
        if not rules:
            return []
        key = time_event_key(routine.routine_id, scheduled)
        lateness = (now - scheduled).total_seconds()
        # 가열 종료 사건과 같은 모양 — 끝 시각을 이 허브 단조 시계 축으로 옮긴다(정해진 시각 = 지금 - 늦음).
        record = {"appliance_id": None, "event": TIME_EVENT, "source": "schedule", "state": None,
                  "event_end_mono_s": self._monotonic() - lateness,
                  "routine_id": routine.routine_id, "scheduled_at": scheduled.isoformat()}
        if not self._seen.add(key):
            return [self._record(rule, record, key, "duplicate", "같은 시각이 다시 와서 한 번만 했어요.")
                    for rule in rules]
        return [self._try_run(rule, record, key, now) for rule in rules]

    def on_time_skipped(self, routine, scheduled: datetime, reason: str) -> list[dict]:
        """사용자가 '다음 루틴 건너뛰기'로 고른 회차(2026-10-18) — 보내지 않고 켜진 시각 규칙마다 ``skipped`` 기록만 남긴다.
        같은 회차를 처리한 것으로 표시해(``SeenEvents``) 그 뒤 같은 시각이 다시 와도 보내지 않는다."""
        rules = [r for r in self.store.list()
                 if r.is_time and r.condition_routine_id == routine.routine_id and r.enabled]
        if not rules:
            return []
        key = time_event_key(routine.routine_id, scheduled)
        self._seen.add(key)
        record = {"appliance_id": None, "event": TIME_EVENT, "source": "schedule", "state": None,
                  "routine_id": routine.routine_id, "scheduled_at": scheduled.isoformat()}
        return [self._record(rule, record, key, "skipped", reason) for rule in rules]

    @staticmethod
    def _matches(rule: AutoRule, record: Mapping) -> bool:
        if rule.is_time:
            return False
        return (rule.condition_appliance_id == record.get("appliance_id")
                and rule.condition_event == record.get("event"))

    def _try_run(self, rule: AutoRule, record: Mapping, key: str | None, received_at: datetime) -> dict:
        with self._gen_lock:
            generation = self._generation
        source = record.get("source")
        # 조용한 시간(정책 b): 그 시간에 온 사건은 건너뛴다. 사건은 이미 처리한 것으로 남아(SeenEvents) 끝난 뒤 다시 와도
        # 'duplicate' — 재실행하지 않는다. 카드도 다시 띄우지 않는다(조용한 동안은 제안도 쉰다).
        timed = rule.is_time
        if self._quiet():
            return self._record(rule, record, key, "blocked", QUIET_SKIP_REASON)
        # ⑥ 가열 종료 근거 = CT 전력 끝(취소·문 열림 종료도 같게 온다 — 정책상 허용, 문구로 밝힘). 시각 규칙은 허브 시계가 근거.
        if not timed and "power" not in (record.get("inputs") or []):
            return self._record(rule, record, key, "blocked",
                                "전기 플러그로 가열이 끝난 것을 보지 못해 자동으로 하지 않았어요.")
        # ③ 같은 사건·오래된 사건 — 나이는 이 허브 시계로 옮긴 끝 시각부터 지금까지(링크 지연 포함, 3차 평가 M1).
        # 시각 규칙: 나이 = 정해진 시각보다 늦게 확인한 시간. 늦음·허용 전·재시작 전은 보내지 않고 카드로 묻는다(reoffer).
        age = event_age_s(record, self._monotonic())
        if key is None or age is None:
            return self._record(rule, record, key, "blocked",
                                TIME_NO_CLOCK_REASON if timed else NO_FRESHNESS_REASON, reoffer=timed)
        if age > self._max_age:
            return self._record(rule, record, key, "blocked",
                                "정해진 시각보다 늦게 알아서 자동으로 하지 않았어요. 먼저 물어볼게요."
                                if timed else "가열이 끝난 지 오래돼서 자동으로 하지 않았어요.",
                                reoffer=timed)
        # 4차 평가 M-N2: 허용 전후는 같은 허브 단조 시계 축에서만 가른다(벽시계 보정·NTP에 흔들리지 않게). 이 프로세스에서
        # 허용했으면 그 순간, 재시작 뒤 불러온 허용이면 이 프로세스가 시작한 순간이 경계 — 그 전에 끝난 가열은 보류한다.
        boundary, restarted = self._allowed_boundary(rule)
        if float(record["event_end_mono_s"]) < boundary:
            if timed:
                reason = TIME_RESTART_REASON if restarted else TIME_BEFORE_ALLOW_REASON
            else:
                reason = RESTART_BOUNDARY_REASON if restarted else "허락하기 전에 끝난 가열이라 자동으로 하지 않았어요."
            return self._record(rule, record, key, "blocked", reason, reoffer=timed)
        # ④ 허용 지문·대상 기기.
        invalid = self._invalid_reason(rule)
        if invalid is not None:
            # 판단 사이 끝난 삭제·값 바꾸기·다시 허용을 옛 사본으로 덮지 않는다(검토 10/19 #10).
            self._replace_if_unchanged(rule, replace(rule, enabled=False, allowed_fingerprint=None,
                                                     updated_at=received_at.isoformat(), disabled_reason=invalid))
            return self._record(rule, record, key, "blocked", invalid, reoffer=True)
        # ⑤ 비상정지 걸림(RPi4 콘센트 모듈).
        latched = getattr(self.service, "estop_latched", None)
        if callable(latched) and latched():
            return self._record(rule, record, key, "blocked",
                                "비상정지가 걸려 있어 자동으로 하지 않았어요.")
        # ② 모의 사건 → 모의 ThinQ만.
        thinq = getattr(self.service, "thinq_controller", None)
        if thinq is None:
            return self._record(rule, record, key, "blocked", "LG 가전 연결이 꺼져 있어 자동으로 하지 않았어요.")
        mode = getattr(thinq, "execution_mode", ExecutionMode.UNKNOWN)
        # 시각 규칙은 사건 출처가 없다(허브 시계) — 사용자가 허용한 명령을 그 시각에 보낸다.
        if mode is ExecutionMode.REAL and not timed and source != "real":
            return self._record(rule, record, key, "blocked",
                                "연습 신호라서 실제 공기청정기는 움직이지 않았어요.")
        if mode not in (ExecutionMode.REAL, ExecutionMode.MOCK):
            return self._record(rule, record, key, "blocked",
                                "LG 가전 연결 상태를 알 수 없어 자동으로 하지 않았어요.")
        return self._submit(rule, record, key, generation)

    def _time_rule_issue(self, rule: AutoRule) -> str | None:
        """시각 규칙이 지금 루틴과 맞는가 — 루틴이 없거나 꺼졌거나, 시각·요일·단계(대상·동작·값)가 바뀌었으면 그 이유."""
        routine = self._routine(rule.condition_routine_id)
        issue = self._routine_shape_issue(routine)
        if issue is not None:
            return issue
        step = routine.steps[0]
        if (tuple(routine.trigger.days) != tuple(rule.condition_days or ())
                or routine.trigger.time != rule.condition_time
                or routine.scenario_key() != rule.scenario_id
                or (step.appliance_id, step.action, dict(step.args))
                != (rule.target_appliance_id, rule.action, {rule.arg: rule.value})):
            return ROUTINE_CHANGED_REASON
        return None

    def _invalid_reason(self, rule: AutoRule) -> str | None:
        if rule.is_time:
            issue = self._time_rule_issue(rule)
            if issue is not None:
                return issue
        elif self._appliance(rule.condition_appliance_id) is None:
            return "살펴보던 가전이 없어져 자동으로 하기를 껐어요. 다시 허락해 주세요."
        appliance = self._appliance(rule.target_appliance_id)
        binding = getattr(appliance, "thinq", None)
        if appliance is None or appliance.control_path is not ControlRoute.THINQ or binding is None:
            return "공기청정기를 찾을 수 없어 자동으로 하기를 껐어요. 다시 허락해 주세요."
        if (binding.device_type != rule.target_device_type
                or _device_key(binding.device_id) != rule.target_device_key):
            return "공기청정기가 다른 기기로 바뀌어 자동으로 하기를 껐어요. 다시 허락해 주세요."
        if not is_low_risk(rule.target_device_type, rule.action, rule.value, time_rule=rule.is_time):
            return "자동으로 할 수 없는 일이라 자동으로 하기를 껐어요."
        try:
            binding.validate_command(binding.command(rule.target_appliance_id, rule.action,
                                                     {rule.arg: rule.value}))
        except Exception:  # noqa: BLE001
            return "이 가전에서 쓸 수 없는 설정이라 자동으로 하기를 껐어요. 다시 허락해 주세요."
        if rule.allowed_fingerprint != rule.fingerprint():
            return "허락한 뒤 내용이 바뀌어 자동으로 하기를 껐어요. 다시 허락해 주세요."
        return None

    def _submit(self, rule: AutoRule, record: Mapping, key: str, generation: int) -> dict:
        appliance = self._appliance(rule.target_appliance_id)
        command = appliance.thinq.command(rule.target_appliance_id, rule.action, {rule.arg: rule.value})
        # 3차 평가 M2: 이 job이 보낼 대상·동작·설정값의 불변 사본 — 결과 기록·알림·키오스크 문구는 이것만 쓴다.
        # 보낸 뒤 규칙을 바꾸거나 지우거나 대상 이름이 바뀌어도 결과를 현재 규칙으로 다시 읽어 덮지 않는다.
        snapshot = {**self._target_words(rule), "action": rule.action, "value": rule.value,
                    "action_text": self.action_text(rule)}
        now = self._clock.now()
        approved = ApprovedCommand(
            command=command, approval_id=f"auto-rule:{rule.rule_id}:{key}", approved_at=now,
            shown_summary=self.service.summary_of(command),
            expires_at=now + timedelta(seconds=APPROVAL_SECONDS),
        )

        decided = rule.fingerprint()
        block_key = f"{rule.rule_id}:{key}"

        def guard() -> None:
            # 실행 게이트(서비스 락) 안에서 — 비상정지 세대가 바뀌었거나 규칙이 꺼졌거나, 판단 때와 내용
            # (설정값·대상)이 달라졌으면 시작하지 않는다. 값을 바꾸고 다시 허용해도 판단 때의 옛 명령은 보내지 않는다.
            # 4차 평가 H-N2: 메모리 사본만 읽는다(``store.get``은 잠금 없음) — 다른 요청의 규칙 DB 쓰기를 기다리지 않으므로
            # 이 게이트를 품은 서비스 잠금도, 그 잠금을 잡아야 하는 정지(``request_stop``)도 DB에 묶이지 않는다.
            with self._gen_lock:
                if self._generation != generation:
                    raise AutoRuleBlocked("비상정지가 들어와서 하지 않았어요.")
            # 판단 뒤 보내기 전에 조용한 시간이 시작됐으면 — 아직 시작하지 않은 자동 실행이라 보내지 않는다(메모리 판정).
            if self._quiet():
                raise AutoRuleBlocked(QUIET_SKIP_REASON)
            current = self.store.get(rule.rule_id)
            if current is None or not self.usable(current):
                raise AutoRuleBlocked("자동으로 하기가 꺼져서 하지 않았어요.")
            if current.fingerprint() != decided:
                raise AutoRuleBlocked("설정이 바뀌어서 이전 내용으로는 하지 않았어요.")
            # 전송 대기 중 만료(3차 평가 M1) — 판단 뒤 조회·대기로 상한을 넘겼으면 보내지 않는다.
            age = event_age_s(record, self._monotonic())
            if age is None or age > self._max_age:
                if rule.is_time:
                    raise AutoRuleBlocked("정해진 시각이 너무 지나서 하지 않았어요."
                                          if age is not None else TIME_NO_CLOCK_REASON)
                raise AutoRuleBlocked(
                    "가열이 끝난 지 너무 오래돼서 하지 않았어요." if age is not None else NO_FRESHNESS_REASON)

        def blocked(exc: AutoRuleBlocked) -> None:
            with self._lock:
                self._dispatch_blocked[block_key] = str(exc)

        def commit(will_send: bool = True) -> None:
            # 4차 평가 H-N1: 전송권 — 실행기가 정지 확인과 같은 잠금 안에서 POST 바로 앞에 부른다. 철회(끄기·값 바꾸기·
            # 삭제·비상정지의 규칙 끄기)와 같은 잠금(``_send_lock``, 메모리만)으로 직렬화한다: 철회가 먼저 끝났으면 여기서
            # 걸려 보내지 않고, 여기를 지났으면 '전송 개시'로 표시해 그 뒤의 철회는 '이미 보내는 중'임을 안다.
            # 네트워크 응답까지 잠그지 않는다(표시만 남기고 곧바로 놓는다).
            with self._send_lock:
                try:
                    guard()
                except AutoRuleBlocked as exc:
                    blocked(exc)
                    raise
                if will_send:  # 이미 목표값이라 보내지 않는 결과(10/14)는 검사만 — '전송 개시'로 표시하지 않는다
                    self._sending[rule.rule_id] = block_key

        def dispatch_guard(binding=None):
            # 보내기 직전(실행 스레드) 재검사 — 시작 게이트 뒤에 꺼지거나 바뀌었으면 보내지 않는다. 실행기는 프로필·상태
            # 조회를 마친 뒤 이번에 보낼 대상 바인딩을 넘겨 한 번 더 부른다(3차 평가 H1): 그 대상이 판단 때 결속한 기기
            # (기기 키·종류)와 다르면 보내지 않는다. 메모리 판정만(입출력 없음). 바인딩과 함께 불렸으면 전송권 확인
            # (``commit``)을 돌려준다 — 실행기가 POST 바로 앞에서 부른다(4차 평가 H-N1).
            try:
                guard()
                if binding is not None and (
                        getattr(binding, "device_type", None) != rule.target_device_type
                        or _device_key(getattr(binding, "device_id", "")) != rule.target_device_key):
                    raise AutoRuleBlocked("공기청정기가 바뀌어서 하지 않았어요.")
            except AutoRuleBlocked as exc:
                blocked(exc)
                raise
            return commit if binding is not None else None

        try:
            job_id = self.service.submit_approved(
                (approved,), purpose=self._run_purpose(rule),
                usage_source=UsageSource.SUGGESTION, approval_guard=guard,
                scenario_id=f"{AUTO_SCENARIO_PREFIX}{rule.rule_id}", dispatch_guard=dispatch_guard,
            )
        except AutoRuleBlocked as exc:
            return self._record(rule, record, key, "blocked", str(exc), snapshot=snapshot)
        except Exception as exc:  # noqa: BLE001 -- 시작 못 함. 나중에 다시 보내지 않는다.
            text = str(exc)
            # 예외 원문·클래스 이름은 화면에 내지 않는다(10/17 쉬운 말) — 기록에만.
            log.warning("auto rule %s submit failed: %s", rule.rule_id, text or type(exc).__name__)
            reason = ("다른 일을 하는 중이라 이번에는 하지 않았어요. 나중에 다시 하지도 않아요."
                      if "already in progress" in text
                      else "자동으로 하지 못했어요.")
            return self._record(rule, record, key, "blocked", reason, snapshot=snapshot)
        return self._record(rule, record, key, "sent", "허락해 둔 일이라 묻지 않고 가전에 전했어요.", job_id=job_id,
                            notices=[self._time_notice(rule) if rule.is_time else self._cook_notice(rule, record)],
                            snapshot=snapshot)

    def _run_purpose(self, rule: AutoRule) -> str:
        """자동 실행 기록의 목적 문장. 시각 규칙은 루틴 이름으로 — 루틴 탭과 같은 이름이라야 기록과 이어진다
        (UI 평가 5차 10/17: '공기청정기 전원 끄기'만으로는 '아침 공기청정기 끄기' 규칙인 줄 몰랐다). 폰은
        ``자동 실행 · '이름' 루틴``을 제목 '이름'과 출처 '자동 실행'으로 나눠 보인다. 루틴을 모르면 동작 문장."""
        if rule.is_time:
            routine = self._routine(rule.condition_routine_id)
            if routine is not None:
                return f"{AUTO_PURPOSE_PREFIX}'{routine.name}' 루틴"
        return f"{AUTO_PURPOSE_PREFIX}{self.action_text(rule)}"

    def _time_notice(self, rule: AutoRule) -> str:
        routine = self._routine(rule.condition_routine_id)
        when = spoken_time(rule.condition_time)
        when = f"{when}{_josa(when, '이', '가')}"
        if routine is None:
            return f"{when} 되어 묻지 않고 가전에 전했어요."
        return f"{when} 되어 '{routine.name}' 루틴을 묻지 않고 시작했어요."

    def _cook_notice(self, rule: AutoRule, record: Mapping) -> str:
        # A5(2026-10-14): 취소·문 열림으로 끝난 가열도 같은 사건으로 온다 — '데우기가 끝났어요'라고 하지 않는다.
        # 10/17 쉬운 말: '멈춘 것 같아요' + 할 일 한 줄. 가열 종료를 '조리 완료'로 단정하지 않는다.
        name = self._name(rule.condition_appliance_id)
        notice = f"{name}{_josa(_josa_stem(name), '이', '가')} 멈춘 것 같아요. 다 익었는지는 봐 주세요."
        source = record.get("source")
        if source == "injected":
            notice += " 연습으로 넣은 신호예요."
        elif source != "real":
            notice += " 연습 신호예요."
        return notice

    # ── 실행 결과 ────────────────────────────────────────────────────────────
    def on_job_finished(self, event) -> None:
        scenario_id = getattr(event, "scenario_id", None) or ""
        if not scenario_id.startswith(AUTO_SCENARIO_PREFIX):
            return
        with self._send_lock:
            self._sending.pop(scenario_id[len(AUTO_SCENARIO_PREFIX):], None)
        with self._lock:
            entry = next((e for e in reversed(self._runs) if e.get("job_id") == event.job_id), None)
            if entry is None:
                # 실행이 기록보다 먼저 끝났다(제출 직후 끝난 모의 실행) — 기록할 때 붙인다.
                self._early_results[event.job_id] = event
                return
            self._apply_result_locked(entry, event)
        self._notify(entry)

    def _apply_result_locked(self, entry: dict, event) -> None:
        # 3차 평가 M2: 대상·설정 낱말은 job을 만들 때 entry에 넣은 사본 그대로 — 지금 규칙을 다시 읽지 않는다.
        blocked = self._dispatch_blocked.pop(f"{entry['rule_id']}:{entry.get('event_key')}", None)
        if blocked is not None and event.receipt.value == "not_dispatched":
            notice = blocked
            entry.update({"outcome": "blocked", "reason": blocked})
        else:
            notice = self._result_notice(entry, event)
            if event.confirmation.value == "already_at_target":
                # 보낸 것이 아니다 — 제출 때 적은 '승인 없이 보냈어요'를 남기지 않는다(2026-10-14 발견 3).
                entry["reason"] = ALREADY_REASON
        entry.update({"status": event.status, "receipt": event.receipt.value,
                      "confirmation": event.confirmation.value,
                      # 명령을 보낸 실행인가, 상태만 확인한 결과인가(sent · state_only · not_sent · unknown).
                      "dispatch": dispatch_of(event.receipt.value, event.confirmation.value),
                      "execution_mode": event.execution_mode.value,
                      "notices": [*entry.get("notices", []), notice]})

    def _target_words(self, rule: AutoRule | None) -> dict:
        """키오스크 알림용 낱말(대상 이름·설정 이름·값 이름). 모르면 None — 지어내지 않는다."""
        if rule is None:
            return {"target_name": None, "setting_label": None, "value_label": None, "value_phrase": None}
        words = {"target_name": self._name(rule.target_appliance_id), "setting_label": None, "value_label": None,
                 "value_phrase": None}
        try:
            cap = self._appliance(rule.target_appliance_id).thinq.capability(rule.action)
            words["setting_label"] = cap.label
            words["value_label"] = cap.value_label(str(rule.value))
            words["value_phrase"] = cap.setting_phrase(str(rule.value))
        except Exception:  # noqa: BLE001 -- 대상이 바뀌었으면 이름만
            pass
        return words

    def last_result_payload(self) -> dict | None:
        """결과가 나온 마지막 자동 실행(키오스크 짧은 알림, 2026-10-14). 없으면 None.

        보낸 실행만(막힌 판단은 job이 없다). 키오스크는 ``job_id``가 바뀔 때 한 번 알린다."""
        with self._lock:
            entry = next((e for e in reversed(self._runs) if e.get("job_id") and e.get("status")), None)
            if entry is None:
                return None
            return {key: entry.get(key) for key in (
                "job_id", "at", "outcome", "status", "receipt", "confirmation", "dispatch", "execution_mode",
                "target_name", "setting_label", "value_label", "value_phrase")}

    def _notify(self, entry: dict) -> None:
        if self._care is None:
            return
        try:
            for text in entry["notices"]:
                self._care.append(KIND_AUTO_RULE, text, purpose=entry.get("action_text"))
        except Exception:  # noqa: BLE001
            log.exception("auto rule care notice failed")

    def _result_notice(self, entry: dict, event) -> str:
        # job을 만들 때의 사본(3차 평가 M2). 사본에 없으면 일반 낱말 — 지금 규칙으로 지어내지 않는다.
        name = entry.get("target_name") or "공기청정기"
        label = entry.get("setting_label") or "설정"
        mock = " 연습이라 실제 가전은 그대로예요." if event.execution_mode is ExecutionMode.MOCK else ""
        status, receipt = event.status, event.receipt.value
        confirmation = event.confirmation.value
        # 2026-10-14 발견 3: 확인한 사실만큼 — 이미 목표값(보내지 않음) · 바꿈 · 보낸 뒤 목표값(전 값 모름) · 미확인.
        phrase = entry.get("value_phrase") or (
            f"{label} {entry['value_label']}" if entry.get("value_label") else "목표 설정")
        stem = _josa_stem(name)
        to = direction(phrase)
        if status == "succeeded" and confirmation == "already_at_target":
            return f"{name}{_josa(stem, '은', '는')} 이미 {phrase}{to} 설정돼 있어요. 그래서 보내지 않았어요.{mock}"
        if status == "succeeded" and confirmation == "state_confirmed":
            return f"{name}{_josa(stem, '을', '를')} {phrase}{to} 바꿨어요.{mock}"
        if status == "succeeded" and confirmation == "state_confirmed_unknown_before":
            # 보내기 전 값을 몰라 '바꿨어요'라고 하지 않는다.
            return f"{name}{_josa(stem, '이', '가')} {phrase}{to} 설정된 것을 확인했어요.{mock}"
        if status == "unconfirmed":
            # 확인 못 한 것은 됐다고 하지 않는다. 자동으로 다시 보내지 않는다는 사실은 남긴다.
            return f"{name} 설정이 바뀌었는지 몰라요. 저절로 다시 하지 않으니 가전을 봐 주세요.{mock}"
        if status == "stopped":
            if receipt == "not_dispatched":
                return f"멈추기를 눌러서 {name}{_josa(stem, '을', '를')} 바꾸지 않았어요.{mock}"
            return f"{name}에 이미 전했어요. 멈춰도 되돌리지 않아요.{mock}"
        if receipt == "not_dispatched":
            return f"{name}에 전하지 못했어요. 바뀌지 않았어요.{mock}"
        return f"{name} {label}{_josa(label, '을', '를')} 바꾸지 못했어요.{mock}"

    # ── 비상정지 ─────────────────────────────────────────────────────────────
    def halt(self) -> None:
        """세대만 올린다(입출력 없음) — 정지 경로 맨 앞에서 부른다."""
        with self._gen_lock:
            self._generation += 1

    def emergency_stop(self, reason: str = "비상정지") -> int:
        """세대를 올리고 켜진 규칙을 모두 끈다. 끈 개수.

        4차 평가 M-N3: 끄기는 **메모리에서 바로** 효력을 내고(판정·목록이 곧바로 '꺼짐'), DB 쓰기와 알림함 기록은 뒤에서
        한다 — ``/stop`` 응답이 DB 쓰기를 기다리지 않는다. 쓰기가 끝나기 전에 프로세스가 죽으면 다음 기동이 세션 표시로
        알아채고 켜진 규칙을 끈다(:class:`AutoRuleStore` 내구성 경계)."""
        self.halt()
        now = self._clock.now().isoformat()
        with self._send_lock:  # 전송권과 직렬화(4차 평가 H-N1) — 메모리만
            disabled = [r for r in self.store.list() if r.enabled]
            for rule in disabled:
                self.store.put(replace(rule, enabled=False, updated_at=now, disabled_reason=ESTOP_REASON))
        if disabled:
            entry = {"at": now, "rule_id": disabled[0].rule_id, "outcome": "estop", "reason": ESTOP_NOTICE,
                     "event_key": None, "event_source": None, "job_id": None, "notices": [ESTOP_NOTICE],
                     "trigger": reason}
            with self._lock:
                self._runs.append(entry)
        self._persist_later(ESTOP_NOTICE if disabled else None)
        return len(disabled)

    def _persist_later(self, notice: str | None = None) -> threading.Thread:
        """메모리 변경을 뒤에서 DB에 쓴다(몇 번 다시 해 본다). 끝까지 못 쓰면 메모리는 그대로 두고 기록만 남긴다 —
        세션 표시가 열려 있어 다음 기동이 켜진 규칙을 끈다."""

        def run() -> None:
            for attempt in range(PERSIST_ATTEMPTS):
                try:
                    self.store.flush()
                    break
                except Exception:  # noqa: BLE001
                    log.exception("auto rules: background persist failed (attempt %d)", attempt + 1)
                    time.sleep(PERSIST_RETRY_S)
            if notice is not None and self._care is not None:
                try:
                    self._care.append(KIND_AUTO_RULE, notice, purpose="자동 실행")
                except Exception:  # noqa: BLE001
                    log.exception("auto rule estop notice failed")

        thread = threading.Thread(target=run, name="auto-rule-persist", daemon=True)
        thread.start()
        return thread

    def close(self, timeout_s: float = 5.0) -> bool:
        """서버 종료 — 남은 규칙 쓰기를 마치고 세션 표시를 닫는다(:meth:`AutoRuleStore.close`)."""
        return self.store.close(timeout_s)

    # ── 목록에서 끄기·켜기·수정·삭제 ─────────────────────────────────────────
    def _require(self, rule_id: str) -> AutoRule:
        rule = self.store.get(rule_id)
        if rule is None:
            raise AutoRuleError(404, "이 자동으로 하기를 찾을 수 없어요")
        return rule

    def _rebound(self, rule: AutoRule) -> AutoRule | None:
        """지금 등록된 대상 기기로 다시 묶은 규칙(다시 허용할 때 사용자가 보는 내용). 대상이 없으면 None."""
        draft = self._draft(rule.scenario_id, rule.condition_appliance_id, rule.condition_event,
                            rule.target_appliance_id, rule.action, {rule.arg: rule.value})
        if draft is None:
            return None
        return replace(rule, target_device_key=draft.target_device_key,
                       target_device_type=draft.target_device_type)

    def _revoke(self, rule_id: str, change: Callable[[AutoRule], AutoRule | None],
                report: dict | None) -> AutoRule | None:
        """철회(끄기·값 바꾸기·삭제) — 전송권 잠금 안에서 메모리를 바꿔(4차 평가 H-N1) 그 뒤의 전송 개시를 막고, 이미 전송을
        시작했으면 ``report["in_flight"]``로 알린다. DB 쓰기는 잠금 밖에서."""
        with self._send_lock:
            current = self.store.get(rule_id)
            if current is None:
                raise AutoRuleError(404, "이 자동으로 하기를 찾을 수 없어요")
            in_flight = rule_id in self._sending
            changed = change(current)
            if changed is None:
                self.store.remove(rule_id)
            elif changed is not current:
                self.store.put(changed)
        if report is not None:
            report["in_flight"] = in_flight
            report["in_flight_notice"] = IN_FLIGHT_NOTICE if in_flight else None
        self.store.flush()
        return changed

    def set_enabled(self, rule_id: str, enabled: bool, fingerprint: str | None = None,
                    start_generation: int | None = None, report: dict | None = None) -> AutoRule:
        """끄기·다시 허용. 다시 허용은 요청 시작 세대(``start_generation``)를 저장 단계까지 대조한다(3차 평가 H2).
        ``report``(선택): 끄기가 이미 전송을 시작한 자동 실행과 겹쳤는지(4차 평가 H-N1)."""
        rule = self._require(rule_id)
        now = self._clock.now().isoformat()
        if not enabled:
            return self._revoke(rule_id, lambda r: replace(r, enabled=False, updated_at=now,
                                                           disabled_reason=USER_OFF_REASON), report)
        if rule.is_time:
            issue = self._time_rule_issue(rule)
            if issue is not None:
                # 루틴이 바뀌었거나 없다 — 목록에서 옛 내용으로 켜지 않는다(다음 시각 카드에서 새로 허용).
                raise AutoRuleError(409, TIME_REENABLE_REFUSED)
        rebound = self._rebound(rule)
        if rebound is None or (not rule.is_time and self._appliance(rule.condition_appliance_id) is None):
            raise AutoRuleError(409, "가전을 찾지 못해 켤 수 없어요. 가전 연결을 봐 주세요.")
        if fingerprint != rebound.fingerprint():
            raise AutoRuleError(409, "허락할 내용이 바뀌었어요. 내용을 다시 봐 주세요.")
        return self._save_allowed(replace(rebound, enabled=True, allowed_fingerprint=fingerprint,
                                          allowed_at=now, updated_at=now, disabled_reason=None), start_generation,
                                  expected=rule)

    def update(self, rule_id: str, body: Mapping, report: dict | None = None) -> AutoRule:
        """설정값만 바꿀 수 있다. 바꾸면 꺼지고 다시 허용해야 한다."""
        rule = self._require(rule_id)
        if not isinstance(body, Mapping):
            raise AutoRuleError(422, "형식이 맞지 않아요")
        if body.get("kind") == "press_sequence" or "buttons" in body:
            raise AutoRuleError(422, PHYSICAL_REFUSED)
        if rule.is_time:
            # 값은 루틴 단계에 묶여 있다 — 규칙만 바꾸면 루틴과 어긋난다.
            raise AutoRuleError(422, TIME_VALUE_REFUSED)
        extra = set(body) - {"value"}
        if extra:
            raise AutoRuleError(422, "여기서는 설정값만 바꿀 수 있어요. 다른 내용은 카드에서 새로 허락해 주세요.")
        value = body.get("value")
        if not isinstance(value, str) or not value:
            raise AutoRuleError(422, "바꿀 설정값을 골라 주세요")
        if self._draft(rule.scenario_id, rule.condition_appliance_id, rule.condition_event,
                       rule.target_appliance_id, rule.action, {rule.arg: value}) is None:
            raise AutoRuleError(422, "이 가전에서 자동으로 할 수 없는 설정이에요")
        if value == rule.value:
            if report is not None:
                report.update(in_flight=False, in_flight_notice=None)
            return rule
        now = self._clock.now().isoformat()
        return self._revoke(rule_id, lambda r: replace(r, value=value, enabled=False, allowed_fingerprint=None,
                                                       updated_at=now, disabled_reason=VALUE_CHANGED_REASON),
                            report)

    def delete(self, rule_id: str, report: dict | None = None) -> None:
        self._revoke(rule_id, lambda _r: None, report)

    def revoke_for_routine(self, routine_id: str, reason: str = ROUTINE_CHANGED_REASON) -> int:
        """루틴을 바꾸거나 지웠다 — 그 루틴의 켜진 시각 규칙을 끈다(전송권 잠금 안, 다시 허용 필요). 끈 개수."""
        now = self._clock.now().isoformat()
        count = 0
        for rule in self.store.list():
            if not (rule.is_time and rule.condition_routine_id == routine_id and rule.enabled):
                continue
            try:
                self._revoke(rule.rule_id, lambda r: replace(r, enabled=False, allowed_fingerprint=None,
                                                             updated_at=now, disabled_reason=reason), None)
                count += 1
            except AutoRuleError:
                continue  # 그 사이 지워졌다
        return count

    def time_rule_on(self, routine_id: str) -> bool:
        """이 시각 루틴의 다음 회차를 카드 없이 자동 실행할 규칙이 켜져 있고 지금 루틴과 맞는가('다음 실행' 표시용)."""
        return any(r.is_time and r.condition_routine_id == routine_id and r.enabled
                   and self._generation_ok(r) and self._time_rule_issue(r) is None
                   for r in self.store.list())

    # ── 조회 ─────────────────────────────────────────────────────────────────
    def payload(self, rule: AutoRule) -> dict:
        if rule.is_time:
            routine = self._routine(rule.condition_routine_id)
            name = routine.name if routine is not None else "자동 실행"
        else:
            # 이름은 저장하지 않고 시나리오 ID로 정한다 — 지금 카탈로그에 없으면(다른 구성으로 켠 허브) 서버가 아는 이름표에서
            # 찾는다. 옛 이름('가열 종료 → 공기청정기')은 어디에도 남지 않는다(10/18 쉬운 말 3차).
            from rpi.scenarios.catalog import scenario_name  # noqa: PLC0415

            definition = self._definition(rule.scenario_id)
            name = definition.name if definition is not None else scenario_name(rule.scenario_id)
        rebound = self._rebound(rule)
        values = []
        appliance = self._appliance(rule.target_appliance_id)
        try:
            cap = appliance.thinq.capability(rule.action)
            # 시각 규칙의 값은 루틴 단계에 묶여 목록에서 바꾸지 않는다(빈 목록).
            values = [] if rule.is_time else [{"value": v, "label": cap.value_label(v)} for v in cap.allowed
                                              if is_low_risk(rule.target_device_type, rule.action, v)]
        except Exception:  # noqa: BLE001
            pass
        last = next((dict(e) for e in reversed(self.runs_snapshot()) if e.get("rule_id") == rule.rule_id), None)
        return {
            "id": rule.rule_id, "scenario_id": rule.scenario_id,
            "name": name, "condition_kind": rule.condition_kind,
            # 시각 규칙의 'HH:MM'(그 밖은 null) — 폰이 조용한 시간과 겹치는 자동 실행을 미리 말한다(UI 평가 6차 10/17).
            "condition_time": rule.condition_time if rule.is_time else None,
            "condition_text": self.condition_text(rule), "action_text": self.action_text(rule),
            "caveat": self.caveat(rule),
            "target_appliance_id": rule.target_appliance_id, "action": rule.action, "value": rule.value,
            "allowed_values": values,
            "enabled": self.usable(rule),
            "status_label": "자동 실행 켜짐" if self.usable(rule) else "자동 실행 꺼짐",
            "disabled_reason": display_reason(rule.disabled_reason),
            #: 다시 허용할 때 보낼 지문(지금 등록된 대상 기기로 묶은 내용). 대상이 없으면 null.
            "fingerprint": rebound.fingerprint() if rebound is not None else None,
            "created_at": rule.created_at, "allowed_at": rule.allowed_at,
            "last_run": last,
        }

    def list_payloads(self) -> list[dict]:
        return [self.payload(r) for r in self.store.list()]

    def runs_snapshot(self) -> list[dict]:
        with self._lock:
            return [dict(e) for e in self._runs]

    def recent_runs(self) -> list[dict]:
        return list(reversed(self.runs_snapshot()))

    def _record(self, rule: AutoRule, record: Mapping, key: str | None, outcome: str, reason: str, *,
                job_id: str | None = None, notices: list[str] | None = None, reoffer: bool = False,
                snapshot: Mapping | None = None) -> dict:
        entry = {
            "at": self._clock.now().isoformat(), "rule_id": rule.rule_id, "outcome": outcome,
            "reason": reason, "event_key": key, "event_source": record.get("source"),
            "event_state": record.get("state"), "job_id": job_id, "notices": list(notices or []),
            "action_text": self.action_text(rule),
        }
        if snapshot is not None:
            # job을 만들 때 잡은 사본(대상 이름·설정 이름·값 이름·동작·값·동작 문장) — 결과가 와도 덮지 않는다.
            entry.update(snapshot)
        early = None
        with self._lock:
            self._runs.append(entry)
            if job_id is not None:
                early = self._early_results.pop(job_id, None)
                if early is not None:
                    self._apply_result_locked(entry, early)
        if early is not None:
            self._notify(entry)
        if outcome == "blocked":
            log.warning("auto rule %s blocked: %s", rule.rule_id, reason)
        result = dict(entry)
        if reoffer:
            result["reoffer"] = True
        return result


def _hub_monotonic() -> float:
    from rpi.services.event_clock import get_event_clock  # noqa: PLC0415

    return get_event_clock().monotonic()


def _hub_started() -> float:
    from rpi.services.event_clock import get_event_clock  # noqa: PLC0415

    return get_event_clock().started_s


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


__all__ = [
    "AUTO_SCENARIO_PREFIX",
    "AutoRule",
    "AutoRuleEngine",
    "AutoRuleError",
    "AutoRuleStore",
    "LOW_RISK_ACTIONS",
    "SeenEvents",
    "event_age_s",
    "event_key",
    "is_low_risk",
    "max_event_age_from_env",
    "time_event_key",
]
