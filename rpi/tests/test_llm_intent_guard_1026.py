"""말 알아듣기 앞뒤 규칙 거르기(2026-10-26, rpi/intent/llm_guard.py) — 언어 모델 없이 규칙만 본다.

문장은 10/26 허브 50문장 평가에서 모델이 잘못 고른 것들이다(docs/발표/언어모델-평가-2026-10-26.md).
"""
import pytest

from rpi.intent.llm_intent import IntentChoice, LlmIntentConfig, understand

CONFIG = LlmIntentConfig('http://localhost')


def _thinq(label, description, action, arg, value, appliance_id='air'):
    return IntentChoice(label, description, {'kind': 'thinq', 'appliance_id': appliance_id,
                                             'action': action, 'args': {arg: value}})


# 10/26 허브에 있던 11개와 같은 모양(공기청정기 동작 9 + 루틴 2).
CHOICES = (
    _thinq('공기청정기 전원 켜기', 'turn ON air purifier', 'set_power', 'power', 'POWER_ON'),
    _thinq('공기청정기 전원 끄기', 'turn OFF air purifier', 'set_power', 'power', 'POWER_OFF'),
    _thinq('공기청정기 바람 세기 약', 'air purifier fan LOW', 'set_wind_strength', 'wind_strength', 'LOW'),
    _thinq('공기청정기 바람 세기 중', 'air purifier fan MID', 'set_wind_strength', 'wind_strength', 'MID'),
    _thinq('공기청정기 바람 세기 강', 'air purifier fan HIGH', 'set_wind_strength', 'wind_strength', 'HIGH'),
    _thinq('공기청정기 바람 세기 자동', 'air purifier fan AUTO', 'set_wind_strength', 'wind_strength', 'AUTO'),
    _thinq('공기청정기 운전 모드 청정', 'air purifier clean mode', 'set_job_mode', 'job_mode', 'CLEAN'),
    _thinq('공기청정기 운전 모드 수면', 'air purifier sleep mode', 'set_job_mode', 'job_mode', 'SLEEP'),
    _thinq('공기청정기 운전 모드 자동', 'air purifier auto mode', 'set_job_mode', 'job_mode', 'AUTO'),
    IntentChoice('저녁 공기청정기 켜기', 'saved routine', {'kind': 'routine', 'routine_id': 'r1'}, ('저녁 공기청정기 켜기',)),
    IntentChoice('아침 공기청정기 끄기', 'saved routine', {'kind': 'routine', 'routine_id': 'r2'}, ('아침 공기청정기 끄기',)),
)
LABELS = {c.label: i for i, c in enumerate(CHOICES, 1)}


def forbidden(*args):
    pytest.fail('rule-decided sentence was sent to the model')


def model_says(label):
    return lambda *a: {'choices': [{'message': {'content': str(LABELS[label])}}]}


@pytest.mark.parametrize('text', ['불 꺼 줘', '에어컨 켜 줘', '텔레비전 틀어 줘', '세탁기 돌려 줘', '현관문 잠가 줘'])
def test_out_of_list_targets_are_refused_before_model(text):
    result = understand(text, CHOICES, CONFIG, forbidden)
    assert not result['understood'] and result['reason'] == 'out_of_list'


def test_covered_set_comes_from_choices():
    # 에어컨이 목록에 있으면 같은 문장을 막지 않는다(모델로 간다).
    aircon = CHOICES + (_thinq('거실 에어컨 전원 켜기', 'turn ON air conditioner', 'set_power', 'power',
                               'POWER_ON', 'ac'),)
    calls = []
    understand('에어컨 켜 줘', aircon, CONFIG, lambda *a: calls.append(1) or {'choices': [{'message': {'content': '12'}}]})
    assert calls
    # 사용자가 '거실 조명'으로 등록한 저장 동작이 있으면 '불 꺼 줘'도 덮인 것으로 본다.
    light = CHOICES + (IntentChoice('거실 조명 끄기', 'saved action (other)',
                                    {'kind': 'buttons', 'appliance_id': 'l', 'buttons': ['끄기']}),)
    assert understand('불 꺼 줘', light, CONFIG, model_says('공기청정기 전원 끄기')).get('reason') != 'out_of_list'


def test_context_word_vacuum_is_not_a_target():
    result = understand('청소기 돌렸더니 먼지가 날려', CHOICES, CONFIG, model_says('공기청정기 전원 켜기'))
    assert result['understood'] and result['label'] == '공기청정기 전원 켜기'


@pytest.mark.parametrize('text,reason', [('방금 켰어', 'already_done'), ('공기청정기는 이미 켜 놨어', 'already_done'),
                                         ('아까 내가 껐어', 'already_done'), ('지금은 켤 필요 없어', 'no_need'),
                                         ('괜찮아, 그냥 둬', 'no_need')])
def test_already_done_and_no_need_are_refused_before_model(text, reason):
    result = understand(text, CHOICES, CONFIG, forbidden)
    assert not result['understood'] and result['reason'] == reason


@pytest.mark.parametrize('text,label', [
    ('바람이 너무 세', '공기청정기 바람 세기 약'),
    ('공기청정기 소리가 너무 시끄러워', '공기청정기 바람 세기 약'),
    ('조용히 해 줘', '공기청정기 바람 세기 약'),
    ('바람이 너무 약한 것 같아', '공기청정기 바람 세기 강'),
    ('공기청정기 바람 약하게 해 줘', '공기청정기 바람 세기 약'),
    ('공기청정기 바람 세게 해 줘', '공기청정기 바람 세기 강'),
    ('공기청정기 수면 모드로 바꿔 줘', '공기청정기 운전 모드 수면'),
    ('이제 잘 거야', '공기청정기 운전 모드 수면'),
    ('아기 재우려고 해', '공기청정기 운전 모드 수면'),
])
def test_obvious_slots_are_picked_by_rules(text, label):
    result = understand(text, CHOICES, CONFIG, forbidden)
    assert result['understood'] and result['source'] == 'rules' and result['label'] == label


def test_slot_rule_needs_a_single_matching_choice():
    # 공기청정기가 두 대면 어느 쪽 약풍인지 규칙이 정하지 않는다(모델에 맡김).
    two = CHOICES + (_thinq('안방 공기청정기 바람 세기 약', 'air purifier #2 fan LOW', 'set_wind_strength',
                            'wind_strength', 'LOW', 'air2'),)
    calls = []
    understand('바람이 너무 세', two, CONFIG, lambda *a: calls.append(1) or {'choices': [{'message': {'content': '0'}}]})
    assert calls
    # 수면을 고를 동작이 없으면 규칙은 고르지 않는다.
    no_sleep = tuple(c for c in CHOICES if c.label != '공기청정기 운전 모드 수면')
    calls.clear()
    understand('이제 잘 거야', no_sleep, CONFIG, lambda *a: calls.append(1) or {'choices': [{'message': {'content': '0'}}]})
    assert calls


@pytest.mark.parametrize('text,picked', [
    ('공기가 너무 탁해서 꺼야겠어', '공기청정기 전원 켜기'),   # 켜기 ↔ 끄는 말
    ('공기청정기 다시 켜 줄래', '공기청정기 전원 끄기'),       # 끄기 ↔ 켜는 말
    ('집에서 먼지 냄새가 나', '공기청정기 전원 끄기'),         # 공기 불평 ↔ 끄기
    ('나가는데 냄새가 좀 나', '아침 공기청정기 끄기'),  # 루틴 이름 끝이 끄기
    ('고기 구웠더니 연기가 자욱해', '공기청정기 바람 세기 약'),  # 공기 불평 ↔ 약풍
    ('방 공기가 좀 탁한 것 같아', '공기청정기 바람 세기 약'),  # '탁한'(관형형)도 불평 — 10/26 새 문장에서 찾음
    ('공기청정기 청정 모드로 해 줘', '공기청정기 운전 모드 자동'),  # 다른 모드 이름
])
def test_post_check_rejects_contradicting_model_pick(text, picked):
    result = understand(text, CHOICES, CONFIG, model_says(picked))
    assert not result['understood'] and result['source'] in ('llm', 'rules')


def test_demo_sentence_still_maps_to_power_on():
    result = understand('공기가 텁텁하네', CHOICES, CONFIG, model_says('공기청정기 전원 켜기'))
    assert result['understood'] and result['source'] == 'llm'
    assert result['label'] == '공기청정기 전원 켜기' and result['question']


def test_consistent_model_picks_pass_post_check():
    assert understand('외출할 거야, 공기청정기는 이제 됐어', CHOICES, CONFIG,
                      model_says('공기청정기 전원 끄기'))['understood']
    assert understand('먼지가 많은 것 같아', CHOICES, CONFIG, model_says('공기청정기 바람 세기 강'))['understood']
    assert understand('공기청정기 자동 모드로 해 줘', CHOICES, CONFIG,
                      model_says('공기청정기 운전 모드 자동'))['understood']
