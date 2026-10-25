"""공공데이터포털 추가 서비스(2026-10-26) — 에어코리아(바깥 미세먼지)·천문연(공휴일·해 뜨고 짐)·기상청 생활기상지수(자외선).

기상청 단기예보와 **같은 인증키**(``SIMPLELAY_KMA_SERVICE_KEY``)를 쓰되 서비스마다 활용 신청은 따로다. 신청하지 않았거나
인터넷이 없으면 그 기능만 조용히 꺼진다(값 없음 = 안내 없음). 지어낸 값은 쓰지 않는다.

공통 규칙:

- 요청 하나의 상한 5초(``timeout``). **요청을 받는 스레드에서 부르지 않는다** — 읽기(``snapshot``·``is_holiday`` 등)는
  캐시만 보고, 새로 받을 때가 되면 데몬 스레드 하나에 맡긴다(``spawn``, 시험은 바로 부른다).
- 키는 URL에만 실린다 — 예외·로그에 URL·키를 넣지 않는다(kma.py와 같은 규칙). 실패는 종류(network·api·parse)만 남긴다.
- 호출 수(개발 계정 하루 500건 안): 측정소 하루 1번, 실시간 30분마다(하루 48), 예보 3시간마다 2건(하루 16), 공휴일 달마다
  7일에 1번, 자외선 3시간마다, 해 뜨고 짐 하루 1번.
"""

from __future__ import annotations

import json
import logging
import math
import re
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

from . import kma
from .kma import KST, KmaError

log = logging.getLogger(__name__)

AIRKOREA_BASE = "https://apis.data.go.kr/B552584"
NEARBY_URL = f"{AIRKOREA_BASE}/MsrstnInfoInqireSvc/getNearbyMsrstnList"
REALTIME_URL = f"{AIRKOREA_BASE}/ArpltnInforInqireSvc/getMsrstnAcctoRltmMesureDnsty"
FORECAST_URL = f"{AIRKOREA_BASE}/ArpltnInforInqireSvc/getMinuDustFrcstDspth"
HOLIDAY_URL = "https://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/getRestDeInfo"
RISESET_URL = "https://apis.data.go.kr/B090041/openapi/service/RiseSetInfoService/getLCRiseSetInfo"
UV_URL = "https://apis.data.go.kr/1360000/LivingWthrIdxServiceV5/getUVIdxV5"

HttpGet = Callable[[str, float], "tuple[int, bytes]"]
Spawn = Callable[[Callable[[], None]], None]


def _thread_spawn(fn: Callable[[], None]) -> None:
    threading.Thread(target=fn, name="public-data-refresh", daemon=True).start()


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


# ── 요청·응답 공통 ────────────────────────────────────────────────────────────


def build_url(endpoint: str, service_key: str, params: Mapping[str, object]) -> str:
    """serviceKey는 urlencode에 맡기지 않는다(Encoding 키 이중 인코딩 방지 — kma.encode_service_key)."""
    return f"{endpoint}?serviceKey={kma.encode_service_key(service_key)}&{urllib.parse.urlencode(dict(params))}"


def _xml_items(text: str) -> list[dict]:
    root = ET.fromstring(text)
    code_node = root.find(".//resultCode")
    if code_node is None:
        raise kma._xml_error(text)
    code = (code_node.text or "").strip()
    if code == "03":
        return []
    if code != "00":
        msg = root.find(".//resultMsg")
        raise KmaError("api", code, (msg.text or "").strip() if msg is not None and msg.text else "error")
    return [{child.tag: (child.text or "").strip() for child in item} for item in root.iter("item")]


def parse_items(status: int, body: bytes) -> list[dict]:
    """공공데이터포털 응답 → 항목 목록. JSON(``items`` 목록 · ``items.item`` 목록/하나 · 빈 문자열)과 XML을 받는다.

    결과 코드 03(자료 없음)은 빈 목록. 그 밖의 실패는 ``KmaError``."""
    text = body.decode("utf-8", errors="replace").strip()
    if not text:
        raise KmaError("api" if status >= 400 else "parse", str(status), "empty body")
    if text.startswith("<"):
        try:
            return _xml_items(text)
        except ET.ParseError:
            raise KmaError("parse", None, "unparseable XML body") from None
    try:
        doc = json.loads(text)
        header = doc["response"]["header"]
        code = str(header.get("resultCode", "")).strip()
    except (ValueError, KeyError, TypeError, AttributeError):
        raise KmaError("api" if status >= 400 else "parse", str(status), "unexpected body") from None
    if code == "03":
        return []
    if code != "00":
        raise KmaError("api", code, str(header.get("resultMsg", "")).strip() or "error")
    body_doc = doc["response"].get("body") or {}
    items = body_doc.get("items") if isinstance(body_doc, Mapping) else None
    if isinstance(items, Mapping):
        items = items.get("item")
    if isinstance(items, Mapping):
        items = [items]
    if not isinstance(items, list):
        return []
    return [i for i in items if isinstance(i, Mapping)]


def fetch_items(endpoint: str, service_key: str, params: Mapping[str, object], *, timeout: float,
                http_get: HttpGet) -> list[dict]:
    url = build_url(endpoint, service_key, params)
    try:
        status, body = http_get(url, timeout)
    except KmaError:
        raise
    except Exception as exc:  # noqa: BLE001 -- 주입된 전송의 어떤 실패도 네트워크 실패로(URL은 남기지 않는다)
        raise KmaError("network", None, type(exc).__name__) from None
    return parse_items(status, body)


class _Refresher:
    """받기 일을 한 번에 하나만 데몬 스레드로 돌린다. 실패는 종류만 기록한다."""

    def __init__(self, spawn: Spawn | None, name: str) -> None:
        self._spawn = spawn or _thread_spawn
        self._name = name
        self._busy = threading.Lock()
        self.last_error: str | None = None

    def kick(self, job: Callable[[], None]) -> None:
        if not self._busy.acquire(blocking=False):
            return

        def run() -> None:
            try:
                job()
                self.last_error = None
            except KmaError as exc:
                self.last_error = exc.kind
                log.warning("%s fetch failed: kind=%s code=%s", self._name, exc.kind, exc.code)
            except Exception:  # noqa: BLE001 -- 받기 실패가 서버를 멈추지 않게
                self.last_error = "parse"
                log.exception("%s fetch failed unexpectedly", self._name)
            finally:
                self._busy.release()

        try:
            self._spawn(run)
        except Exception:  # noqa: BLE001
            self._busy.release()
            log.exception("%s refresh could not start", self._name)


# ── 좌표: 위경도 → 에어코리아 TM(중부원점, GRS80 — EPSG:5181과 같은 정의) ─────────────────────


def latlon_to_tm(lat: float, lon: float) -> tuple[float, float]:
    """횡메르카토르(Snyder 식). 원점 북위 38°·동경 127°, 축척 1, 가산값 X 200000·Y 500000(m). 측정소 고르기용이라
    좌표계 차이(수백 m)는 결과(가장 가까운 측정소)를 거의 바꾸지 않는다."""
    a, f = 6378137.0, 1 / 298.257222101
    lat0, lon0, k0, fe, fn = math.radians(38.0), math.radians(127.0), 1.0, 200000.0, 500000.0
    e2 = f * (2 - f)
    ep2 = e2 / (1 - e2)

    def meridian(phi: float) -> float:
        return a * ((1 - e2 / 4 - 3 * e2 ** 2 / 64 - 5 * e2 ** 3 / 256) * phi
                    - (3 * e2 / 8 + 3 * e2 ** 2 / 32 + 45 * e2 ** 3 / 1024) * math.sin(2 * phi)
                    + (15 * e2 ** 2 / 256 + 45 * e2 ** 3 / 1024) * math.sin(4 * phi)
                    - (35 * e2 ** 3 / 3072) * math.sin(6 * phi))

    phi, lam = math.radians(lat), math.radians(lon)
    n = a / math.sqrt(1 - e2 * math.sin(phi) ** 2)
    t = math.tan(phi) ** 2
    c = ep2 * math.cos(phi) ** 2
    big_a = (lam - lon0) * math.cos(phi)
    m, m0 = meridian(phi), meridian(lat0)
    x = fe + k0 * n * (big_a + (1 - t + c) * big_a ** 3 / 6 + (5 - 18 * t + t ** 2 + 72 * c - 58 * ep2) * big_a ** 5 / 120)
    y = fn + k0 * (m - m0 + n * math.tan(phi) * (big_a ** 2 / 2 + (5 - t + 9 * c + 4 * c ** 2) * big_a ** 4 / 24
                                                 + (61 - 58 * t + t ** 2 + 600 * c - 330 * ep2) * big_a ** 6 / 720))
    return x, y


# ── 에어코리아: 바깥 미세먼지 ──────────────────────────────────────────────────

GRADE_WORDS = {1: "좋음", 2: "보통", 3: "나쁨", 4: "매우 나쁨"}
#: 등급 칸이 비었을 때(측정소가 계산 중 '-') 환경부 공개 기준으로 값에서 등급을 매긴다(µg/m³, 상한 포함).
PM10_BREAKS = (30, 80, 150)
PM25_BREAKS = (15, 35, 75)
#: 예보 등급 말 → 숫자(같은 표).
FORECAST_GRADES = {"좋음": 1, "보통": 2, "나쁨": 3, "매우나쁨": 4, "매우 나쁨": 4}

#: 예보 권역 이름 — 측정소 주소 첫 낱말(또는 시도 이름)로 고른다. 경기·강원은 남북·동서로 나뉜다(아래 함수).
_REGION_PREFIXES = (
    ("서울", "서울"), ("부산", "부산"), ("대구", "대구"), ("인천", "인천"), ("광주", "광주"), ("대전", "대전"),
    ("울산", "울산"), ("세종", "세종"), ("충청북", "충북"), ("충북", "충북"), ("충청남", "충남"), ("충남", "충남"),
    ("전라북", "전북"), ("전북", "전북"), ("전라남", "전남"), ("전남", "전남"), ("경상북", "경북"), ("경북", "경북"),
    ("경상남", "경남"), ("경남", "경남"), ("제주", "제주"),
)
#: 경기북부·강원영동을 가르는 대략의 선(**추측** — 의정부·고양·구리는 북부, 하남·광명은 남부 / 강릉·속초는 영동).
GYEONGGI_NORTH_LAT = 37.58
GANGWON_EAST_LON = 128.6


def forecast_region(addr: str | None, lat: float | None, lon: float | None) -> str | None:
    text = (addr or "").strip()
    if text.startswith("경기"):
        return None if lat is None else ("경기북부" if lat >= GYEONGGI_NORTH_LAT else "경기남부")
    if text.startswith("강원"):
        return None if lon is None else ("영동" if lon >= GANGWON_EAST_LON else "영서")
    for prefix, region in _REGION_PREFIXES:
        if text.startswith(prefix):
            return region
    return None


def _int_value(raw) -> int | None:
    try:
        return int(round(float(str(raw).strip())))
    except (TypeError, ValueError):
        return None


def _grade_from(value: int | None, breaks: tuple[int, int, int]) -> int | None:
    if value is None:
        return None
    for grade, top in enumerate(breaks, start=1):
        if value <= top:
            return grade
    return 4


def _grade(item: Mapping, key: str, value: int | None, breaks) -> int | None:
    for field in (f"{key}Grade1h", f"{key}Grade"):
        g = _int_value(item.get(field))
        if g in GRADE_WORDS:
            return g
    return _grade_from(value, breaks)


def worse(*grades: int | None) -> int | None:
    known = [g for g in grades if g is not None]
    return max(known) if known else None


def parse_realtime(items: list[dict]) -> dict | None:
    """실시간 측정(최근 시각 먼저) → {pm10, pm25, grade(숫자)} — 값이 있는 첫 시각."""
    for item in items:
        pm10, pm25 = _int_value(item.get("pm10Value")), _int_value(item.get("pm25Value"))
        g10, g25 = _grade(item, "pm10", pm10, PM10_BREAKS), _grade(item, "pm25", pm25, PM25_BREAKS)
        grade = worse(g10, g25)
        if grade is not None:
            return {"pm10": pm10, "pm25": pm25, "grade": grade, "data_time": str(item.get("dataTime") or "")}
    return None


def _issued_key(item: Mapping) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(r"\d+", str(item.get("dataTime") or "")))


def parse_forecast(items: list[dict], region: str) -> dict[str, int]:
    """예보 항목 → {예보 날짜 'YYYY-MM-DD': 그 권역 등급(숫자)}. 날짜마다 가장 늦게 발표한 것."""
    latest: dict[str, tuple[tuple[int, ...], int]] = {}
    for item in items:
        day = str(item.get("informData") or "").strip()
        grades = str(item.get("informGrade") or "")
        if not day:
            continue
        grade = None
        for part in grades.split(","):
            name, _, word = part.partition(":")
            if name.strip() == region:
                grade = FORECAST_GRADES.get(word.strip())
                break
        if grade is None:
            continue
        key = _issued_key(item)
        if day not in latest or key > latest[day][0]:
            latest[day] = (key, grade)
    return {day: grade for day, (_, grade) in latest.items()}


@dataclass(frozen=True)
class PublicDataConfig:
    service_key: str | None = None
    lat: float | None = None
    lon: float | None = None
    #: 측정소 이름을 직접 정할 때(위치 대신) — ``SIMPLELAY_AIRKOREA_STATION``.
    station: str | None = None
    #: 자외선 지역 코드를 직접 정할 때 — ``SIMPLELAY_UV_AREA_NO``.
    uv_area_no: str | None = None
    timeout_seconds: float = 5.0
    #: 실시간 미세먼지를 다시 받는 간격(분, 30~60).
    air_refresh_minutes: float = 30.0

    def __repr__(self) -> str:  # 키가 로그·예외에 새지 않게
        return f"PublicDataConfig(key={'set' if self.service_key else 'unset'}, station={self.station!r})"

    @classmethod
    def from_weather(cls, weather_config, env: Mapping[str, str]) -> "PublicDataConfig":
        """날씨가 실제 모드이고 키가 있을 때만 켠다(아니면 키 없음 = 전부 꺼짐)."""
        key = weather_config.service_key if getattr(weather_config, "mode", "off") == "real" else None
        try:
            refresh = float((env.get("SIMPLELAY_AIRKOREA_REFRESH_MINUTES") or "30").strip())
        except ValueError:
            refresh = 30.0
        return cls(
            service_key=key,
            lat=weather_config.lat,
            lon=weather_config.lon,
            station=(env.get("SIMPLELAY_AIRKOREA_STATION") or "").strip() or None,
            uv_area_no=(env.get("SIMPLELAY_UV_AREA_NO") or "").strip() or None,
            timeout_seconds=weather_config.timeout_seconds,
            air_refresh_minutes=min(60.0, max(30.0, refresh)),
        )


class OutdoorAirService:
    """가까운 측정소의 실시간 미세먼지 등급과 시도 권역 예보(오늘·내일). 읽기는 캐시만."""

    STATION_TTL = timedelta(days=1)
    FORECAST_TTL = timedelta(hours=3)
    #: 실시간 값이 이보다 오래되면 쓰지 않는다.
    STALE = timedelta(hours=3)
    RETRY = timedelta(minutes=10)

    def __init__(self, config: PublicDataConfig, *, http_get: HttpGet = kma.urllib_get,
                 clock: Callable[[], datetime] = _utc_now, spawn: Spawn | None = None) -> None:
        self._config = config
        self._http_get = http_get
        self._clock = clock
        self._refresher = _Refresher(spawn, "airkorea")
        self._lock = threading.Lock()
        self._station: tuple[str, str | None, datetime] | None = None  # (이름, 주소, 받은 시각)
        self._realtime: tuple[dict, datetime] | None = None
        self._forecast: tuple[dict[str, int], datetime] | None = None
        self._attempt: datetime | None = None

    @property
    def enabled(self) -> bool:
        c = self._config
        return bool(c.service_key) and (c.station is not None or (c.lat is not None and c.lon is not None))

    def snapshot(self, now: datetime | None = None) -> dict | None:
        """``{station, pm10, pm25, grade, forecast_today, forecast_tomorrow}``(등급은 말 — '보통'). 모르면 None."""
        if not self.enabled:
            return None
        now = now or self._clock()
        self._maybe_refresh(now)
        with self._lock:
            station, realtime, forecast = self._station, self._realtime, self._forecast
        if station is None:
            return None
        rt = realtime[0] if realtime is not None and now - realtime[1] <= self.STALE else None
        fc = forecast[0] if forecast is not None and now - forecast[1] <= timedelta(hours=12) else {}
        today = now.astimezone(KST).date()
        f_today, f_tomorrow = fc.get(today.isoformat()), fc.get((today + timedelta(days=1)).isoformat())
        if rt is None and f_today is None and f_tomorrow is None:
            return None
        return {
            "station": station[0],
            "pm10": rt["pm10"] if rt else None,
            "pm25": rt["pm25"] if rt else None,
            "grade": GRADE_WORDS.get(rt["grade"]) if rt else None,
            "forecast_today": GRADE_WORDS.get(f_today) if f_today else None,
            "forecast_tomorrow": GRADE_WORDS.get(f_tomorrow) if f_tomorrow else None,
        }

    def _due(self, now: datetime) -> bool:
        with self._lock:
            station, realtime, forecast, attempt = self._station, self._realtime, self._forecast, self._attempt
        if attempt is not None and now - attempt < self.RETRY:
            return False
        if station is None or now - station[2] >= self.STATION_TTL:
            return True
        if realtime is None or now - realtime[1] >= timedelta(minutes=self._config.air_refresh_minutes):
            return True
        return forecast is None or now - forecast[1] >= self.FORECAST_TTL

    def _maybe_refresh(self, now: datetime) -> None:
        if self._due(now):
            with self._lock:
                self._attempt = now
            self._refresher.kick(lambda: self.refresh(now))

    def refresh(self, now: datetime) -> None:
        """받기 한 바퀴(스레드 안). 측정소 → 실시간 → 예보, 필요한 것만."""
        c = self._config
        get = lambda url, params: fetch_items(url, c.service_key, params, timeout=c.timeout_seconds,  # noqa: E731
                                              http_get=self._http_get)
        with self._lock:
            station, realtime, forecast = self._station, self._realtime, self._forecast
        if station is None or now - station[2] >= self.STATION_TTL:
            if c.station is not None:
                station = (c.station, None, now)
            else:
                tm_x, tm_y = latlon_to_tm(c.lat, c.lon)
                items = get(NEARBY_URL, {"tmX": f"{tm_x:.3f}", "tmY": f"{tm_y:.3f}", "returnType": "json",
                                         "ver": "1.1"})
                first = next((i for i in items if str(i.get("stationName") or "").strip()), None)
                if first is None:
                    raise KmaError("parse", None, "no nearby station")
                station = (str(first["stationName"]).strip(), str(first.get("addr") or "").strip() or None, now)
            with self._lock:
                self._station = station
        if realtime is None or now - realtime[1] >= timedelta(minutes=c.air_refresh_minutes):
            items = get(REALTIME_URL, {"stationName": station[0], "dataTerm": "DAILY", "ver": "1.3",
                                       "returnType": "json", "numOfRows": 5, "pageNo": 1})
            parsed = parse_realtime(items)
            with self._lock:
                self._realtime = (parsed, now) if parsed is not None else self._realtime
        region = forecast_region(station[1], c.lat, c.lon)
        if region is not None and (forecast is None or now - forecast[1] >= self.FORECAST_TTL):
            merged: dict[str, int] = {}
            local = now.astimezone(KST).date()
            for code in ("PM10", "PM25"):
                grades: dict[str, int] = {}
                for day in (local, local - timedelta(days=1)):
                    items = get(FORECAST_URL, {"searchDate": day.isoformat(), "InformCode": code,
                                               "returnType": "json", "ver": "1.1", "numOfRows": 100, "pageNo": 1})
                    grades = parse_forecast(items, region)
                    if grades:
                        break
                for day_key, grade in grades.items():
                    merged[day_key] = max(merged.get(day_key, 0), grade)
            with self._lock:
                self._forecast = (merged, now)


# ── 천문연: 공휴일 ───────────────────────────────────────────────────────────


class HolidayCalendar:
    """공휴일(쉬는 날) 표 — 달마다 받아 7일 동안 쓴다. 모르면 None(호출자는 평일 규칙만 쓴다)."""

    TTL = timedelta(days=7)
    RETRY = timedelta(minutes=30)

    def __init__(self, config: PublicDataConfig, *, http_get: HttpGet = kma.urllib_get,
                 clock: Callable[[], datetime] = _utc_now, spawn: Spawn | None = None) -> None:
        self._config = config
        self._http_get = http_get
        self._clock = clock
        self._refresher = _Refresher(spawn, "holidays")
        self._lock = threading.Lock()
        self._months: dict[tuple[int, int], tuple[frozenset[date], datetime]] = {}
        self._attempts: dict[tuple[int, int], datetime] = {}

    @property
    def enabled(self) -> bool:
        return bool(self._config.service_key)

    def is_holiday(self, day: date) -> bool | None:
        if not self.enabled:
            return None
        now = self._clock()
        month = (day.year, day.month)
        with self._lock:
            cached = self._months.get(month)
            attempt = self._attempts.get(month)
        if (cached is None or now - cached[1] >= self.TTL) and (attempt is None or now - attempt >= self.RETRY):
            with self._lock:
                self._attempts[month] = now
            self._refresher.kick(lambda: self.refresh(month, now))
            with self._lock:
                cached = self._months.get(month)  # 바로 끝난 받기(시험의 동기 실행)도 반영
        return None if cached is None else day in cached[0]

    def refresh(self, month: tuple[int, int], now: datetime) -> None:
        c = self._config
        items = fetch_items(HOLIDAY_URL, c.service_key,
                            {"solYear": month[0], "solMonth": f"{month[1]:02d}", "_type": "json", "numOfRows": 50},
                            timeout=c.timeout_seconds, http_get=self._http_get)
        days = set()
        for item in items:
            if str(item.get("isHoliday") or "").strip().upper() != "Y":
                continue
            try:
                days.add(datetime.strptime(str(item.get("locdate")).strip(), "%Y%m%d").date())
            except ValueError:
                continue
        with self._lock:
            self._months[month] = (frozenset(days), now)


# ── 생활기상지수(자외선)·해 뜨고 짐 ──────────────────────────────────────────────

#: 자외선 지역 — 시도 대표 위치와 지역 코드(행정구역 코드 앞 두 자리 + 0). 허브 위치에서 가장 가까운 곳(**추측** — 시도 경계와
#: 다를 수 있다. ``SIMPLELAY_UV_AREA_NO``로 바꿀 수 있다).
UV_AREAS = (
    ("서울", 37.5665, 126.9780, "1100000000"), ("부산", 35.1796, 129.0756, "2600000000"),
    ("대구", 35.8714, 128.6014, "2700000000"), ("인천", 37.4563, 126.7052, "2800000000"),
    ("광주", 35.1595, 126.8526, "2900000000"), ("대전", 36.3504, 127.3845, "3000000000"),
    ("울산", 35.5384, 129.3114, "3100000000"), ("세종", 36.4800, 127.2890, "3611000000"),
    ("경기", 37.2752, 127.0095, "4100000000"), ("강원", 37.8813, 127.7298, "5100000000"),
    ("충북", 36.6357, 127.4917, "4300000000"), ("충남", 36.6588, 126.6728, "4400000000"),
    ("전북", 35.8242, 127.1480, "5200000000"), ("전남", 34.8161, 126.4629, "4600000000"),
    ("경북", 36.5760, 128.5056, "4700000000"), ("경남", 35.2383, 128.6925, "4800000000"),
    ("제주", 33.4996, 126.5312, "5000000000"),
)
#: 자외선 '매우 높음'부터 안내(지수 8 이상), 낮 시간(지역 시각 9~16시).
UV_STRONG = 8
UV_HOURS = (9, 16)
UV_ADVICE = "자외선이 강해요. 외출하실 때 선크림 바르세요."
#: 자외선 지수 발표 시각(06·18시) 뒤 조회 지연(**추측**).
UV_ISSUE_HOURS = (6, 18)
UV_DELAY = timedelta(minutes=30)


def uv_area_for(lat: float | None, lon: float | None) -> str | None:
    if lat is None or lon is None:
        return None
    return min(UV_AREAS, key=lambda a: (a[1] - lat) ** 2 + ((a[2] - lon) * math.cos(math.radians(lat))) ** 2)[3]


def uv_base(now: datetime) -> datetime:
    t = now.astimezone(KST) - UV_DELAY
    for hour in reversed(UV_ISSUE_HOURS):
        if t.hour >= hour:
            return t.replace(hour=hour, minute=0, second=0, microsecond=0)
    prev = t - timedelta(days=1)
    return prev.replace(hour=UV_ISSUE_HOURS[-1], minute=0, second=0, microsecond=0)


def parse_uv(items: list[dict], base: datetime) -> dict[datetime, int]:
    """``h0``·``h3``… → {시각(KST): 지수}. 빈 칸은 뺀다."""
    out: dict[datetime, int] = {}
    for item in items:
        for key, raw in item.items():
            match = re.fullmatch(r"h(\d+)", str(key))
            value = _int_value(raw)
            if match and value is not None:
                out[base + timedelta(hours=int(match.group(1)))] = value
    return out


def _hhmm(raw) -> str | None:
    text = re.sub(r"\D", "", str(raw or ""))
    if len(text) < 4:
        return None
    hour, minute = int(text[:2]), int(text[2:4])
    return f"{hour:02d}:{minute:02d}" if hour < 24 and minute < 60 else None


class LivingWeather:
    """자외선 지수(3시간마다)와 오늘 해 뜨고 지는 시각(하루 1번). 읽기는 캐시만."""

    UV_TTL = timedelta(hours=3)
    RETRY = timedelta(minutes=30)

    def __init__(self, config: PublicDataConfig, *, http_get: HttpGet = kma.urllib_get,
                 clock: Callable[[], datetime] = _utc_now, spawn: Spawn | None = None) -> None:
        self._config = config
        self._http_get = http_get
        self._clock = clock
        self._uv_refresher = _Refresher(spawn, "uv")
        self._sun_refresher = _Refresher(spawn, "riseset")
        self._lock = threading.Lock()
        self._uv: tuple[dict[datetime, int], datetime] | None = None
        self._uv_attempt: datetime | None = None
        self._sun: tuple[date, str | None, str | None] | None = None
        self._sun_attempt: datetime | None = None

    @property
    def area_no(self) -> str | None:
        return self._config.uv_area_no or uv_area_for(self._config.lat, self._config.lon)

    def uv_index(self, now: datetime | None = None) -> int | None:
        """지금 시각이 든 3시간 칸의 자외선 지수. 모르면 None."""
        if not self._config.service_key or self.area_no is None:
            return None
        now = now or self._clock()
        with self._lock:
            cached, attempt = self._uv, self._uv_attempt
        if ((cached is None or now - cached[1] >= self.UV_TTL)
                and (attempt is None or now - attempt >= self.RETRY)):
            with self._lock:
                self._uv_attempt = now
            self._uv_refresher.kick(lambda: self.refresh_uv(now))
            with self._lock:
                cached = self._uv
        if cached is None or now - cached[1] > timedelta(hours=12):
            return None
        local = now.astimezone(KST)
        slots = [(at, v) for at, v in cached[0].items() if at <= local < at + timedelta(hours=3)]
        return slots[0][1] if slots else None

    def uv_advice(self, now: datetime | None = None) -> str | None:
        now = now or self._clock()
        hour = now.astimezone(KST).hour
        if not UV_HOURS[0] <= hour < UV_HOURS[1]:
            return None
        value = self.uv_index(now)
        return UV_ADVICE if value is not None and value >= UV_STRONG else None

    def refresh_uv(self, now: datetime) -> None:
        c = self._config
        base = uv_base(now)
        items = fetch_items(UV_URL, c.service_key, {"areaNo": self.area_no, "time": base.strftime("%Y%m%d%H"),
                                                    "dataType": "JSON", "numOfRows": 10, "pageNo": 1},
                            timeout=c.timeout_seconds, http_get=self._http_get)
        values = parse_uv(items, base)
        if values:
            with self._lock:
                self._uv = (values, now)

    def sun_times(self, now: datetime | None = None) -> tuple[str | None, str | None]:
        """오늘(지역 날짜) ``("HH:MM" 해 뜸, "HH:MM" 해 짐)``. 모르면 (None, None)."""
        c = self._config
        if not c.service_key or c.lat is None or c.lon is None:
            return None, None
        now = now or self._clock()
        today = now.astimezone(KST).date()
        with self._lock:
            sun, attempt = self._sun, self._sun_attempt
        if (sun is None or sun[0] != today) and (attempt is None or now - attempt >= self.RETRY):
            with self._lock:
                self._sun_attempt = now
            self._sun_refresher.kick(lambda: self.refresh_sun(today))
            with self._lock:
                sun = self._sun
        if sun is None or sun[0] != today:
            return None, None
        return sun[1], sun[2]

    def refresh_sun(self, day: date) -> None:
        c = self._config
        items = fetch_items(RISESET_URL, c.service_key,
                            {"locdate": day.strftime("%Y%m%d"), "longitude": f"{c.lon:.2f}",
                             "latitude": f"{c.lat:.2f}", "dnYn": "Y", "_type": "json"},
                            timeout=c.timeout_seconds, http_get=self._http_get)
        item = items[0] if items else {}
        rise, sset = _hhmm(item.get("sunrise")), _hhmm(item.get("sunset"))
        if rise is None and sset is None:
            raise KmaError("parse", None, "no sunrise/sunset")
        with self._lock:
            self._sun = (day, rise, sset)


def sunset_at(sun: tuple[str | None, str | None], local_now: datetime) -> datetime | None:
    """오늘 해 지는 시각(``local_now``와 같은 시간대). 모르면 None."""
    text = sun[1] if sun else None
    if not text:
        return None
    hour, minute = (int(p) for p in text.split(":"))
    kst = local_now.astimezone(KST)
    return kst.replace(hour=hour, minute=minute, second=0, microsecond=0).astimezone(local_now.tzinfo)


__all__ = [
    "GRADE_WORDS",
    "HolidayCalendar",
    "LivingWeather",
    "OutdoorAirService",
    "PublicDataConfig",
    "UV_ADVICE",
    "forecast_region",
    "latlon_to_tm",
    "parse_forecast",
    "parse_items",
    "parse_realtime",
    "parse_uv",
    "sunset_at",
    "uv_area_for",
]
