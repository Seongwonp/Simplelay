"""공기청정기 센서 공기질 → '공기가 나빠요' 제안 판정 (2026-10-15, 사용자 요청).

근거는 **공기청정기 자체 센서를 ThinQ로 읽은 값뿐**이다. 우리 임계값을 두지 않고 가전이 매긴 등급을 그대로 쓴다:
``PM2Level``(초미세먼지, PM2.5) · ``PM10Level``(미세먼지) · ``totalPollutionLevel``(종합) 중 하나라도 ``BAD``·``VERY_BAD``면
나쁨이다. 센서 칸(``airQualitySensor``)이 없거나 비었으면(공기청정기 꺼짐 · 켠 직후 센서 준비 중) **값이 없는 것**이다 —
지어내지 않고 제안하지 않는다. 전원이 ``POWER_OFF``로 보이면 센서 칸이 남아 있어도 값이 없는 것으로 친다(옛 값일 수 있다).

카드는 제안일 뿐이다. 승인하면 ThinQ 한 단계(``set_wind_strength HIGH``)가 종전 승인·실행 경로로 나가고, 결과는 기존 확인
수준(``state_confirmed`` 등)으로만 말한다. **'공기가 좋아졌어요' 같은 결과 문장은 만들지 않는다.** 자동 실행(다음부터 자동으로)은
이 카드에 두지 않는다(시나리오 정의 ``auto_allowed=False``).

중복·재알림(:class:`AirQualityMonitor`):

- 떠 있는 공기질 카드는 하나뿐이다(같은 시나리오의 대기 카드가 있으면 제안 서비스가 그것을 돌려준다).
- 카드를 한 번 만들면 **공기가 좋음·보통으로 돌아온 것을 한 번 본 뒤에만**(다시 준비) 다시 제안한다.
- 그와 별도로 카드를 만든 뒤 ``card_quiet_s``(기본 45분 = 카드 유효 15분 + 30분) 동안은 다시 만들지 않는다 — 카드가 언제
  내려갔든(거절·실행·만료) 내려간 뒤 적어도 30분이다.
- 조용한 시간·잠시 쉬기(두 범위 모두)·다시 받지 않기·부재는 제안 서비스가 다른 제안과 똑같이 막는다. 막혀서 카드가 안
  생겼으면 준비 상태를 그대로 두어 다음 판독에서 다시 본다(조용한 시간이 끝난 뒤에도 나쁘면 그때 제안).

판독 실패는 기록만 하고 이번 판독을 건너뛴다 — 다시 읽기를 서두르지 않는다(다음 주기까지 기다린다).
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass

log = logging.getLogger(__name__)

#: 가전 등급 중 '나쁨'으로 칠 값.
BAD_LEVELS = ("BAD", "VERY_BAD")
#: 다시 준비(재알림 허용)로 칠 값.
OK_LEVELS = ("GOOD", "NORMAL")
KNOWN_LEVELS = OK_LEVELS + BAD_LEVELS
LEVEL_WORDS = {"GOOD": "좋음", "NORMAL": "보통", "BAD": "나쁨", "VERY_BAD": "매우 나쁨"}

#: (값 칸, 등급 칸, 사람 말 이름) — 앞이 우선(근거 문장에는 나쁜 것 중 맨 앞 하나만 적는다).
#: ``totalPollution``은 농도가 아니라 지수라 숫자를 적지 않는다.
SENSOR_FIELDS = (
    ("PM2", "PM2Level", "초미세먼지"),
    ("PM10", "PM10Level", "미세먼지"),
    (None, "totalPollutionLevel", "종합 공기질"),
)

#: 이미 강풍 이상이면 제안하지 않는다(POWER는 강풍보다 센 단계 — 낮추자고 하지 않는다).
STRONG_WIND = ("HIGH", "POWER")

POLL_ENV = "SIMPLELAY_AIR_POLL_SECONDS"
DEFAULT_POLL_SECONDS = 120.0
MIN_POLL_SECONDS = 60.0
MAX_POLL_SECONDS = 3600.0
#: 카드를 만든 뒤 다시 만들지 않는 시간 — 카드 유효 15분 + 내려간 뒤 30분.
DEFAULT_CARD_QUIET_SECONDS = (15 + 30) * 60.0
#: 기동 직후 첫 판독까지 기다리는 시간(기동 절차·첫 요청과 겹치지 않게).
DEFAULT_FIRST_DELAY_SECONDS = 30.0


def poll_seconds_from_env(env: Mapping[str, str] | None = None) -> float:
    """판독 주기(초). 기본 120, 최소 60(그보다 작으면 60), 최대 3600. 숫자가 아니면 기본값."""
    env = os.environ if env is None else env
    raw = (env.get(POLL_ENV) or "").strip()
    if not raw:
        return DEFAULT_POLL_SECONDS
    try:
        value = float(raw)
    except ValueError:
        log.warning("%s 값이 숫자가 아니라 기본 %d초로 읽어요", POLL_ENV, int(DEFAULT_POLL_SECONDS))
        return DEFAULT_POLL_SECONDS
    if value != value:  # NaN
        return DEFAULT_POLL_SECONDS
    return min(max(value, MIN_POLL_SECONDS), MAX_POLL_SECONDS)


@dataclass(frozen=True)
class AirReading:
    """센서 한 번 읽은 것. ``bad``는 나쁜 칸들 ``(이름, 값|None, 등급)``(우선순서), ``wind``는 지금 풍량(모르면 None)."""

    bad: tuple[tuple[str, object, str], ...]
    known: int
    wind: str | None

    @property
    def is_bad(self) -> bool:
        return bool(self.bad)

    @property
    def wind_is_strong(self) -> bool:
        return self.wind in STRONG_WIND

    def reason(self) -> str:
        """근거 한 줄 — 나쁜 칸 중 맨 앞 하나. 예: '공기청정기 센서: 초미세먼지 42 · 나쁨'."""
        name, value, level = self.bad[0]
        word = LEVEL_WORDS.get(level, level)
        if value is None:
            return f"공기청정기 센서: {name} · {word}"
        return f"공기청정기 센서: {name} {value} · {word}"


def _section(state, key: str) -> dict | None:
    section = state.get(key) if isinstance(state, Mapping) else None
    return section if isinstance(section, Mapping) else None


def read_air(state) -> AirReading | None:
    """ThinQ 상태 → 판독. **값이 없으면 None**(센서 칸 없음·빔·전원 꺼짐·아는 등급이 하나도 없음)."""
    sensor = _section(state, "airQualitySensor")
    if not sensor:
        return None
    operation = _section(state, "operation") or {}
    if operation.get("airPurifierOperationMode") == "POWER_OFF":
        return None
    bad = []
    known = 0
    for value_key, level_key, name in SENSOR_FIELDS:
        level = sensor.get(level_key)
        if not isinstance(level, str) or level not in KNOWN_LEVELS:
            continue  # 모르는 등급은 판정에 쓰지 않는다(지어내지 않는다)
        known += 1
        if level in BAD_LEVELS:
            value = sensor.get(value_key) if value_key is not None else None
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                value = None
            bad.append((name, value, level))
    if not known:
        return None
    flow = _section(state, "airFlow") or {}
    wind = flow.get("windStrengthDetail") or flow.get("windStrength")
    return AirReading(bad=tuple(bad), known=known, wind=wind if isinstance(wind, str) else None)


class AirReadSkipped(Exception):
    """이번 판독을 하지 않았다(가전 없음·실행 중·호출 상한 여유 없음 등). 실패가 아니다."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class AirQualityMonitor:
    """판독 한 번(:meth:`check_once`)마다 제안 여부를 정한다. 입출력은 넘겨받은 함수가 한다(이 클래스는 상태만).

    - ``read()`` → ThinQ 상태(dict). 판독을 하지 않을 때는 :class:`AirReadSkipped`, 실패는 아무 예외.
    - ``offer(reason)`` → 만든(또는 이미 떠 있던) 카드, 막혔으면 None(조용한 시간·잠시 쉬기·다시 받지 않기·준비 안 됨).
    """

    def __init__(self, read: Callable[[], object], offer: Callable[[str], object | None], *,
                 monotonic: Callable[[], float] | None = None,
                 card_quiet_s: float = DEFAULT_CARD_QUIET_SECONDS) -> None:
        self._read = read
        self._offer = offer
        self._monotonic = monotonic or time.monotonic
        self._card_quiet_s = card_quiet_s
        self._lock = threading.Lock()
        self._armed = True
        self._last_card_at: float | None = None
        self._failures = 0
        self.last_outcome: str | None = None

    @property
    def armed(self) -> bool:
        return self._armed

    def forget_recent(self) -> None:
        """재알림 기억(다시 준비·카드 뒤 쉬는 시간)을 지운다 — 모의 리허설을 되풀이할 때만(주입 API가 real에서 거절)."""
        with self._lock:
            self._armed = True
            self._last_card_at = None

    def check_once(self) -> str:
        """결과 이름 — ``skipped:<이유>`` · ``read_failed`` · ``no_data`` · ``ok`` · ``already_strong`` ·
        ``waiting_rearm`` · ``card_quiet`` · ``not_offered`` · ``offered``."""
        with self._lock:
            outcome = self._check_locked()
            self.last_outcome = outcome
            return outcome

    def _check_locked(self) -> str:
        try:
            state = self._read()
        except AirReadSkipped as skip:
            return f"skipped:{skip.reason}"
        except Exception as exc:  # noqa: BLE001 -- 판독 실패: 기록만 하고 이번 판독을 건너뛴다(다시 서두르지 않는다)
            self._failures += 1
            reason = getattr(exc, "reason", None)
            message = reason if isinstance(reason, str) and reason else type(exc).__name__
            # 연달아 실패하면 첫 번째만 경고로 남긴다(같은 경고가 주기마다 쌓이지 않게).
            (log.warning if self._failures == 1 else log.debug)(
                "air quality read failed (%d in a row): %s", self._failures, message)
            return "read_failed"
        self._failures = 0
        reading = read_air(state)
        if reading is None:
            return "no_data"
        if not reading.is_bad:
            self._armed = True  # 좋음·보통을 한 번 봤다 — 다시 제안할 수 있다
            return "ok"
        if reading.wind_is_strong:
            return "already_strong"
        if not self._armed:
            return "waiting_rearm"
        now = self._monotonic()
        if self._last_card_at is not None and now - self._last_card_at < self._card_quiet_s:
            return "card_quiet"
        card = self._offer(reading.reason())
        if card is None:
            return "not_offered"
        self._armed = False
        self._last_card_at = now
        return "offered"


class AirQualityPoller:
    """전용 스레드에서 ``check()``를 주기마다 부른다. 이벤트 루프·공유 스레드 풀을 쓰지 않는다.

    ``stop()``은 표시만 하고 기다리지 않는다 — 판독이 멈춰 있어도 정지·종료가 그것을 기다리지 않는다(데몬 스레드).
    """

    def __init__(self, check: Callable[[], object], *, interval_s: float,
                 first_delay_s: float = DEFAULT_FIRST_DELAY_SECONDS) -> None:
        self._check = check
        self.interval_s = interval_s
        self.first_delay_s = first_delay_s
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="air-quality-poll", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    @property
    def alive(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def _run(self) -> None:
        if self._stop.wait(self.first_delay_s):
            return
        while not self._stop.is_set():
            try:
                self._check()
            except Exception:  # noqa: BLE001 -- 판독 한 번의 실패가 스레드를 죽이지 않는다
                log.exception("air quality check failed")
            if self._stop.wait(self.interval_s):
                return


__all__ = [
    "AirQualityMonitor",
    "AirQualityPoller",
    "AirReadSkipped",
    "AirReading",
    "BAD_LEVELS",
    "LEVEL_WORDS",
    "OK_LEVELS",
    "POLL_ENV",
    "poll_seconds_from_env",
    "read_air",
]
