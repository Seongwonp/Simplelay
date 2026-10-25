"""밤마다 만드는 생활 습관 정리 두 문장(2026-10-26 — '알게 된 것' 화면 맨 위).

- 근거(FACTS)는 '알게 된 것'과 같은 학습 결과(``learning_status``)에서만 만든다. 가전 이름처럼 사용자가 적은 글은
  넣지 않는다(지시문 끼워 넣기 차단). 숨긴 습관은 근거에서 뺀다.
- 본체 안 언어 모델(``SIMPLELAY_LLM_URL``)이 없으면 스레드를 띄우지 않고 화면 요청 때 정해진 문장만 만든다(입출력 없음).
- 본체 안 언어 모델이 있으면 영어 지시문으로 존댓말 두 문장을 부탁한다. 한 번에 25~35초가
  걸리므로(보드 실측) **요청 경로에서 부르지 않는다** — 전용 데몬 스레드가 매일 03:00(현지)과 기동 때(없거나 24시간 지남)
  만든다. 공유 스레드 풀을 쓰지 않는다.
- 모델 답은 검사를 통과해야만 쓴다: 영문자 없음, 근거에 있는 숫자만, 120자 이하, 두 문장 이하, 느낌표·물음표 없음,
  허용 글자만, 근거의 습관 이름을 하나 이상 포함. 아니면 근거로 만든 정해진 문장(template)을 쓴다.
- 결과(문장·만든 시각·출처 ``llm``|``template``·근거 습관 이름)는 설정 저장소에 남아 재시작 뒤에도 보인다.
- 화면은 읽기만 한다. 자동으로 소리 내 읽지 않는다.
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
import threading
import time as time_mod
from dataclasses import dataclass
from datetime import datetime, timedelta

from .habit_words import has_final_consonant

log = logging.getLogger(__name__)

SETTING_KEY = 'lifestyle_summary'
MAX_CHARS = 120
MAX_SENTENCES = 2
#: 매일 다시 만드는 시각(현지).
NIGHTLY_HOUR = 3
STALE_AFTER = timedelta(hours=24)
#: 저장된 정리를 화면에 보이는 최대 나이 — 밤 생성이 빠졌거나 모델을 끈 뒤 옛 문장을 계속 보이지 않게.
SHOW_AT_MOST = timedelta(hours=36)
#: 모델이 켜져 있는데 정해진 문장이 나왔을 때 다시 해 보는 간격·횟수.
RETRY_SECONDS = 1800
MAX_RETRIES = 3
#: 사실 줄에 넣는 습관 수 상한(지시문을 짧게).
MAX_FACT_HABITS = 4

SYSTEM_PROMPT = (
    'You write a short lifestyle summary for a Korean smart-home hub screen. '
    'Use ONLY the facts below. Write exactly 2 short sentences in polite Korean (존댓말, 해요체). '
    'Do not use exclamation marks, questions, English letters, emoji, or numbers that are not in the facts. '
    'Do not give advice and do not invent habits. Keep it under 100 Korean characters.'
)

_ALLOWED = re.compile(r"^[가-힣0-9\s.,·~'\"()%:\-]+$")
_LATIN = re.compile(r'[A-Za-z]')
_NUMBER = re.compile(r'\d+')


@dataclass(frozen=True)
class Facts:
    window_days: int
    habits: tuple[dict, ...]  # purpose · when_text · distinct_days · occurrences (숨기지 않은 습관만, 근거가 강한 순)

    @property
    def text(self) -> str:
        lines = [f'기간: 최근 {self.window_days}일']
        if not self.habits:
            lines.append('습관: 없음')
        for h in self.habits:
            lines.append(f"습관: {h['purpose']} | 때: {h['when_text']} | "
                         f"최근 {self.window_days}일 중 {h['distinct_days']}일, 모두 {h['occurrences']}번")
        return '\n'.join(lines)

    @property
    def purposes(self) -> tuple[str, ...]:
        return tuple(h['purpose'] for h in self.habits)


def build_facts(status: dict) -> Facts:
    """학습 결과 → 근거. 습관으로 기억한(established) 것 중 숨기지 않은 것만, 근거가 강한 순."""
    habits = [r for r in status.get('routines', ())
              if r.get('established') and not r.get('muted') and str(r.get('purpose', '')).strip()]
    habits.sort(key=lambda r: (-int(r.get('distinct_days') or 0), -int(r.get('occurrences') or 0), r['purpose']))
    picked = []
    seen = set()
    for r in habits:
        purpose = r['purpose'].strip()
        if purpose in seen:
            continue
        seen.add(purpose)
        picked.append({'purpose': purpose,
                       'when_text': r.get('when_text') or f"{r.get('time_band', '')} 이맘때".strip(),
                       'distinct_days': int(r.get('distinct_days') or 0),
                       'occurrences': int(r.get('occurrences') or 0)})
        if len(picked) >= MAX_FACT_HABITS:
            break
    return Facts(int(status.get('window_days') or 0), tuple(picked))


def template_text(facts: Facts) -> str:
    """정해진 문장 — 모델이 없거나 답이 검사를 못 넘을 때."""
    if not facts.habits:
        return '아직 습관으로 기억한 사용 기록이 없어요. 평소처럼 사용해 주시면 정리해 드릴게요.'
    top = facts.habits[0]
    # 습관 이름은 '즉석밥 데워줘'처럼 시키는 말이라 따옴표로 묶고 조사만 받침에 맞춘다.
    particle = '을' if has_final_consonant(top['purpose']) else '를'
    first = f"{top['when_text']} '{top['purpose']}'{particle} 가장 꾸준히 하셨어요."
    if len(facts.habits) > 1:
        second = f'그 밖에 {len(facts.habits) - 1}가지 습관을 더 기억하고 있어요.'
    else:
        second = f"최근 {facts.window_days}일 중 {top['distinct_days']}일 하셨어요."
    return f'{first} {second}'


def validate(text, facts: Facts) -> str | None:
    """모델 답을 쓸 수 있으면 다듬은 문장, 아니면 None."""
    if not isinstance(text, str):
        return None
    cleaned = ' '.join(text.split())
    if not cleaned or len(cleaned) > MAX_CHARS:
        return None
    if _LATIN.search(cleaned) or not _ALLOWED.match(cleaned):
        return None  # 느낌표·물음표·기호·이모지·영문자는 여기서 걸린다
    sentences = [s for s in re.split(r'[.]', cleaned) if s.strip()]
    if not sentences or len(sentences) > MAX_SENTENCES:
        return None
    allowed_numbers = set(_NUMBER.findall(facts.text))
    if any(n not in allowed_numbers for n in _NUMBER.findall(cleaned)):
        return None
    if facts.habits and not any(p in cleaned for p in facts.purposes):
        return None  # 근거의 습관을 하나도 말하지 않으면 지어낸 것으로 본다
    return cleaned


@dataclass(frozen=True)
class SummaryConfig:
    url: str = ''
    timeout: float = 90

    @classmethod
    def from_env(cls) -> 'SummaryConfig':
        try:
            timeout = float(os.environ.get('SIMPLELAY_LLM_SUMMARY_TIMEOUT_SECONDS', '90'))
        except ValueError:
            timeout = 90
        if not math.isfinite(timeout) or timeout <= 0:
            timeout = 90
        return cls(os.environ.get('SIMPLELAY_LLM_URL', '').strip().rstrip('/'), timeout)


def _http_transport(url, body, timeout):
    from .llm_intent import http_transport  # noqa: PLC0415 -- 같은 HTTP 모양

    return http_transport(url, body, timeout)


def generate(status: dict, config: SummaryConfig, now: datetime, transport=None) -> dict:
    """근거 → 문장 하나(블로킹 — 모델이 있으면 수십 초). 요청 경로에서 부르지 않는다."""
    facts = build_facts(status)
    text = None
    if config.url and facts.habits:
        start = time_mod.monotonic()
        try:
            reply = (transport or _http_transport)(config.url + '/invoke', {
                'messages': [{'role': 'system', 'content': SYSTEM_PROMPT + '\nFACTS:\n' + facts.text},
                             {'role': 'user', 'content': '위 사실만으로 두 문장 정리를 써 주세요.'}],
                'stream': False}, config.timeout)
            text = validate(reply['choices'][0]['message']['content'], facts)
        except Exception:  # noqa: BLE001 -- 실패는 정해진 문장(응답·오류 본문은 남기지 않는다)
            text = None
        finally:
            log.info('lifestyle summary llm latency_ms=%d accepted=%s',
                     (time_mod.monotonic() - start) * 1000, text is not None)
    source = 'llm' if text is not None else 'template'
    return {'text': text if text is not None else template_text(facts), 'generated_at': now.isoformat(),
            'source': source, 'purposes': list(facts.purposes)}


class LifestyleSummaryStore:
    """설정 저장소 한 칸(JSON). 저장소가 없으면 메모리만."""

    def __init__(self, load=None, save=None) -> None:
        self._load = load
        self._save = save
        self._lock = threading.Lock()
        self._cached: dict | None = None
        self._loaded = False

    def get(self) -> dict | None:
        with self._lock:
            if not self._loaded:
                self._loaded = True
                try:
                    raw = self._load() if self._load else None
                    value = json.loads(raw) if raw else None
                    self._cached = value if _well_formed(value) else None
                except Exception:  # noqa: BLE001 -- 못 읽으면 없는 것으로(다음 생성이 채운다)
                    log.exception('lifestyle summary load failed')
                    self._cached = None
            return dict(self._cached) if self._cached else None

    def put(self, value: dict) -> None:
        with self._lock:
            self._cached = dict(value)
            self._loaded = True
        if self._save:
            try:
                self._save(json.dumps(value, ensure_ascii=False))
            except Exception:  # noqa: BLE001
                log.exception('lifestyle summary save failed')


def _well_formed(value) -> bool:
    return (isinstance(value, dict) and isinstance(value.get('text'), str) and value['text']
            and isinstance(value.get('generated_at'), str) and value.get('source') in ('llm', 'template'))


def is_stale(stored: dict | None, now: datetime, limit: timedelta = STALE_AFTER) -> bool:
    if not stored:
        return True
    try:
        at = datetime.fromisoformat(stored['generated_at'])
    except (KeyError, TypeError, ValueError):
        return True
    if at.tzinfo is None or now.tzinfo is None:
        return True
    return not (timedelta(0) <= now - at <= limit)


def current_summary(stored: dict | None, status: dict, now: datetime) -> dict:
    """화면에 보일 정리 — 요청 경로용(모델을 부르지 않는다).

    저장된 정리가 없거나 36시간보다 오래됐거나, 그 정리가 말한 습관을 그 뒤 숨겼으면 지금 근거로 만든 정해진
    문장을 준다(숨긴 습관·옛 문장을 계속 말하지 않게)."""
    muted = {str(r.get('purpose', '')).strip() for r in status.get('routines', ()) if r.get('muted')}
    if (stored and not is_stale(stored, now, SHOW_AT_MOST)
            and not (set(stored.get('purposes') or ()) & muted)):
        return {'text': stored['text'], 'generated_at': stored['generated_at'], 'source': stored['source']}
    facts = build_facts(status)
    return {'text': template_text(facts), 'generated_at': now.isoformat(), 'source': 'template'}


def next_run(now: datetime) -> datetime:
    target = now.replace(hour=NIGHTLY_HOUR, minute=0, second=0, microsecond=0)
    return target if target > now else target + timedelta(days=1)


class SummaryScheduler:
    """전용 데몬 스레드 — 기동 때(없거나 오래됨) 한 번, 그 뒤 매일 03:00. 요청 경로·공유 스레드 풀과 무관."""

    def __init__(self, *, status, store: LifestyleSummaryStore, clock, config: SummaryConfig,
                 transport=None, sleep=None) -> None:
        self._status = status
        self._store = store
        self._clock = clock
        self._config = config
        self._transport = transport
        self._stop = threading.Event()
        self._sleep = sleep or self._stop.wait
        self._thread: threading.Thread | None = None

    def run_once(self) -> dict:
        value = generate(self._status(), self._config, self._clock.now(), self._transport)
        self._store.put(value)
        return value

    def run_if_stale(self) -> dict | None:
        if is_stale(self._store.get(), self._clock.now()):
            return self.run_once()
        return None

    def _wants_retry(self, value: dict | None) -> bool:
        """모델이 켜져 있는데 습관이 있는 정리를 정해진 문장으로 만들었다(기동 직후 모델이 아직 안 떴을 수 있다)."""
        return bool(self._config.url and value and value.get('source') == 'template' and value.get('purposes'))

    def _loop(self) -> None:
        value = None
        try:
            value = self.run_if_stale()
        except Exception:  # noqa: BLE001
            log.exception('lifestyle summary startup run failed')
        retries = MAX_RETRIES if self._wants_retry(value) else 0
        while not self._stop.is_set():
            wait = RETRY_SECONDS if retries else (next_run(self._clock.now()) - self._clock.now()).total_seconds()
            if self._sleep(max(1.0, wait)) or self._stop.is_set():
                return
            try:
                value = self.run_once()
            except Exception:  # noqa: BLE001
                log.exception('lifestyle summary run failed')
                value = None
            if retries:
                retries = retries - 1 if self._wants_retry(value) else 0
            else:
                retries = MAX_RETRIES if self._wants_retry(value) else 0

    def start(self) -> None:
        if self._thread is None:
            self._thread = threading.Thread(target=self._loop, name='lifestyle-summary', daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
