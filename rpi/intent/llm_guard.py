"""말 알아듣기 앞뒤 규칙 거르기(2026-10-26) — 모델 학습 없이 잘못 고르기를 줄인다.

10/26 허브 50문장 평가(docs/발표/언어모델-평가-2026-10-26.md)에서 기기 안 언어 모델이
목록에 없는 기기("에어컨 켜 줘")·이미 한 일("방금 켰어")·반대 방향("바람이 너무 세"→강)에도 공기청정기 동작을
골랐다. 여기 규칙은 모두 결정론적이고, 결과는 언제나 닫힌 목록 중 하나 또는 '고르지 않음'이다.

1. 모델 앞(``pre_guard``):
   (a) 문장이 가리키는 기기/대상이 고를 동작 어디에도 없으면 '고르지 않음'(``out_of_list``).
       덮인 대상은 동작 설명의 가전 종류(영문 종류 이름)와 이름(사용자가 지은 이름 — 본체 안에서만 비교)에서 뽑는다.
   (b) 이미 했다·필요 없다("방금 켰어"·"이미 켜 놨어"·"켤 필요 없어")면 '고르지 않음'
       (``already_done``·``no_need`` — 제안 카드의 '이미 했어요'와 같은 뜻).
   (c) 뻔한 값: "너무 세다·시끄럽다·조용히" → 바람 약, "너무 약하다" → 바람 강, "약하게/세게/중간" → 그 값,
       "수면·잘 거야·자려고" → 수면 모드. 그 동작이 목록에 **하나만** 있을 때만 고른다(여럿이면 모델에 맡김).
   (d) 공기 불평(2026-10-26 §10): "텁텁·답답·탁하다·공기가 안 좋다·먼지·냄새·퀴퀴·매캐·연기·꽃가루"이고
       부정("냄새 안 나"·"안 텁텁해"·"답답하지 않아")·끄는 말이 아니면 전원 켜기 — 그것도 목록에 하나만 있을 때만.
       고를 동작 목록에는 공기청정기 지금 상태가 없으므로 '이미 켜져 있으면 바람 강'은 하지 않는다
       (이미 켜져 있으면 ThinQ '이미 목표값'으로 제어 없이 끝난다).
2. 모델 뒤(``post_check``): 고른 동작의 방향이 문장과 어긋나면 버린다(켜기 ↔ 끄는 말, 공기 불평 ↔ 끄기·약풍,
   너무 세다 ↔ 강풍, 다른 모드 이름).

규칙이 고른 것도 실행이 아니다 — 늘 같은 확인 질문('네')을 거친다.
"""
from __future__ import annotations

import re
import unicodedata

#: 대상 낱말 표: (키, 동작 설명에 나오는 영문 가전 종류 또는 None, 한국어 정규식). 공백은 ``\s*``로 느슨하게.
#: 종류가 None인 대상은 사용자가 그 이름으로 등록했을 때(이름에 낱말이 있을 때)만 덮인 것으로 본다.
#: '청소기'만으로는 대상으로 보지 않는다("청소기 돌렸더니 먼지가 날려"는 공기청정기 이야기).
TARGETS: tuple[tuple[str, str | None, str], ...] = (
    ('air_purifier', 'air purifier', r'공기\s*청정기|청정기|공청기|공기\s*정화기'),
    ('air_conditioner', 'air conditioner', r'에어컨|에어콘|냉방'),
    ('washing_machine', 'washing machine', r'세탁기|빨래'),
    ('microwave', 'microwave', r'전자\s*레인지|렌지'),
    ('induction', 'induction', r'인덕션|전기\s*레인지|가스\s*레인지'),
    ('rice_cooker', 'rice cooker', r'밥솥'),
    ('door', 'intercom', r'인터폰|현관|도어\s*락|문\s*(을|좀)?\s*(열|닫|잠)'),
    ('tv', None, r'텔레비전|티브이|티비|tv'),
    ('light', None, r'조명|전등|형광등|무드등|스탠드|불\s*(을|좀)?\s*(켜|꺼|끄|켤|끌|밝|어둡)'),
    ('curtain', None, r'커튼|블라인드'),
    ('boiler', None, r'보일러|난방'),
    ('fridge', None, r'냉장고|냉동고'),
    ('fan', None, r'선풍기|서큘레이터'),
    ('humidifier', None, r'가습기|제습기'),
    ('vacuum', None, r'로봇\s*청소기'),
    ('speaker', None, r'음악|노래|스피커|라디오'),
)
_TARGET_RE = tuple((key, category, re.compile(pattern)) for key, category, pattern in TARGETS)

#: 이미 함: 때 낱말 + 끝이 지난 일. "방금 켰어"·"이미 켜 놨어"·"아까 내가 껐어"·"벌써 됐어".
_ALREADY = re.compile(r'(방금|아까|이미|벌써|진작|금방|조금\s*전)'
                      r'.*(었|았|였|했|켰|껐|놨|놓았|뒀|됐|왔)(어|어요|다|음|지|는데|거든)?$')
_ALREADY_STATE = re.compile(r'(켜져|꺼져|켜|꺼)\s*(있어|있다|있음|있는데)')
#: 필요 없음: "켤 필요 없어"·"안 해도 돼"·"괜찮아"·"그냥 둬".
_NO_NEED = re.compile(r'필요\s*(가|는)?\s*없|안\s*\S+\s*도\s*(돼|되|괜찮)|않아도|괜찮아|'
                      r'그냥\s*둬|놔\s*둬|내버려|그대로\s*둬')

_TOO_STRONG = re.compile(r'너무\s*세(다|네|요|서|$)|세다$|시끄러|시끄럽|소음|조용')
_TOO_WEAK = re.compile(r'너무\s*약|약한\s*것\s*같|약하다|약해서')
_SLEEP = re.compile(r'수면|잘\s*거|잘거|자려고|자야|재우|재울|잠\s*잘')
_SAY_LOW = re.compile(r'약하게|약풍|약으로')
_SAY_HIGH = re.compile(r'세게|강하게|강풍|강으로')
_SAY_MID = re.compile(r'중간|중으로|중풍')
_ON = re.compile(r'켜|켤|틀어|틀자|작동|가동')
_OFF = re.compile(r'꺼|끄|끌|껐|멈춰|그만')
#: 공기 불평 — 끄기·약풍과 어긋난다(더 깨끗하게 해 달라는 말).
_COMPLAINT = re.compile(r'먼지|냄새|연기|답답|텁텁|탁(하|해|한|했)|매캐|꽃가루|기침|담배')
#: 모델 앞 공기 불평(d) — 켜기를 고른다. 위 ``_COMPLAINT``(뒤 확인용)보다 '공기가 안 좋다'·'퀴퀴'를 더 본다.
_AIR_COMPLAINT = re.compile(r'텁텁|답답|(?<!부)탁(하|해|한|했)|퀴퀴|매캐|먼지|냄새|연기|꽃가루|'
                            r'공기\S*\s*(안\s*좋|좋지\s*않|나쁘|나빠|별로)')
#: 불평 부정 — "냄새 안 나"·"먼지가 없네"·"안 텁텁해"·"답답하지 않아". "냄새가 안 빠져"는 불평이라 거르지 않는다.
_AIR_NEGATED = re.compile(r'(냄새|먼지|연기)\S*\s*(안\s*(나(?![가갔])|날|보)|없|사라)|'
                          r'안\s*(텁텁|답답|탁|퀴퀴|매캐)|(텁텁|답답|탁|퀴퀴|매캐)\S*\s*않')
#: 모드 이름 → 값. 문장이 다른 모드를 말하면 모델 답을 버린다.
_MODE_WORDS = (('SLEEP', re.compile(r'수면')), ('CLEAN', re.compile(r'청정\s*모드')),
               ('AUTO', re.compile(r'자동\s*모드')))


def _clean(text: str) -> str:
    s = unicodedata.normalize('NFC', text or '').strip().lower()
    return re.sub(r'[.,!?~…"\'“”‘’]+', ' ', s).strip()


def mentioned_targets(text: str) -> set[str]:
    s = _clean(text)
    return {key for key, _, pattern in _TARGET_RE if pattern.search(s)}


def covered_targets(choices) -> set[str]:
    """고를 동작이 덮는 대상 — 설명의 영문 가전 종류 + 이름(본체 안 비교만, 모델에 보내지 않음)."""
    covered = set()
    for c in choices:
        description = (c.description or '').lower()
        names = ' '.join(_clean(s) for s in (c.label, *c.aliases))
        for key, category, pattern in _TARGET_RE:
            if (category and category in description) or pattern.search(names):
                covered.add(key)
    return covered


def _thinq_value(choice, action):
    a = choice.action
    if a.get('kind') != 'thinq' or a.get('action') != action:
        return None
    return next(iter(a.get('args', {}).values()), None)


def _only(choices, action, value):
    found = [c for c in choices if _thinq_value(c, action) == value]
    return found[0] if len(found) == 1 else None


def _direction(choice):
    """'on'·'off'·None — LG 전원/시작, 또는 이름 끝이 켜기·끄기인 루틴·저장 동작."""
    power = _thinq_value(choice, 'set_power')
    if power in ('POWER_ON', 'POWER_OFF'):
        return 'on' if power == 'POWER_ON' else 'off'
    operation = _thinq_value(choice, 'set_operation')
    if operation in ('START', 'STOP'):
        return 'on' if operation == 'START' else 'off'
    if choice.action.get('kind') in ('routine', 'buttons'):
        label = (choice.label or '').strip()
        if label.endswith(('켜기', '켜줘', '켜')):
            return 'on'
        if label.endswith(('끄기', '꺼줘', '꺼')):
            return 'off'
    return None


def pre_guard(text, choices):
    """모델 앞. ``('none', 이유)`` · ``('pick', 동작)`` · ``None``(모델에 맡김)."""
    s = _clean(text)
    named = mentioned_targets(s)
    if named and not (named & covered_targets(choices)):
        return 'none', 'out_of_list'
    if _ALREADY.search(s) or _ALREADY_STATE.search(s):
        return 'none', 'already_done'
    if _NO_NEED.search(s):
        return 'none', 'no_need'
    if _TOO_STRONG.search(s):
        pick = _only(choices, 'set_wind_strength', 'LOW')
    elif _TOO_WEAK.search(s):
        pick = _only(choices, 'set_wind_strength', 'HIGH')
    elif _SAY_LOW.search(s):
        pick = _only(choices, 'set_wind_strength', 'LOW')
    elif _SAY_HIGH.search(s):
        pick = _only(choices, 'set_wind_strength', 'HIGH')
    elif _SAY_MID.search(s):
        pick = _only(choices, 'set_wind_strength', 'MID')
    elif _SLEEP.search(s) and not _OFF.search(s):
        pick = _only(choices, 'set_job_mode', 'SLEEP')
    elif (_AIR_COMPLAINT.search(s) and not _AIR_NEGATED.search(s)
          and not (_OFF.search(s) and not _ON.search(s))):
        pick = _only(choices, 'set_power', 'POWER_ON')
    else:
        pick = None
    # 다른 기기를 말한 문장("인덕션 불 약하게")이면 그 기기의 동작일 때만.
    if pick is not None and named and not (named & covered_targets([pick])):
        pick = None
    return ('pick', pick) if pick is not None else None


def post_check(text, choice) -> str | None:
    """모델 뒤. 고른 동작이 문장과 어긋나면 이유(``contradiction``), 괜찮으면 None."""
    s = _clean(text)
    direction = _direction(choice)
    on, off = bool(_ON.search(s)), bool(_OFF.search(s))
    if direction == 'on' and off and not on:
        return 'contradiction'
    if direction == 'off' and (on and not off or _COMPLAINT.search(s)):
        return 'contradiction'
    wind = _thinq_value(choice, 'set_wind_strength')
    if wind == 'HIGH' and _TOO_STRONG.search(s):
        return 'contradiction'
    if wind == 'LOW' and (_TOO_WEAK.search(s) or _COMPLAINT.search(s) and not _TOO_STRONG.search(s)):
        return 'contradiction'
    mode = _thinq_value(choice, 'set_job_mode')
    if mode is not None:
        said = {value for value, pattern in _MODE_WORDS if pattern.search(s)}
        if said and mode not in said:
            return 'contradiction'
    return None
