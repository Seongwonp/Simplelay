"""기상청 단기예보 조회서비스(공공데이터포털, VilageFcstInfoService_2.0) 클라이언트.

쓰는 것은 ``getVilageFcst``(단기예보) 하나다. 3시간 간격 예보 발표
(02·05·08·11·14·17·20·23시, 발표 뒤 약 10분부터 조회 가능)에서
TMP(기온 ℃)·POP(강수확률 %)·PTY(강수형태)·SKY(하늘상태)만 시간별로 모은다.
키오스크의 안내 한 줄과 예보 4칸에는 이것으로 충분하다. 초단기예보
(``getUltraSrtFcst``, 매시 30분 발표·6시간 앞)는 '지금 비' 정확도를 높일 때
붙일 자리로 남겨 둔다.

서비스키: 공공데이터포털은 같은 키를 Encoding·Decoding 두 형태로 보여 준다.
**Decoding 키를 넣는 것을 권장**한다(여기서 한 번 URL 인코딩한다). 실수로
Encoding 키(``%2B``·``%2F``·``%3D``가 섞인 것)를 넣어도 ``%``가 있으면 이미
인코딩된 것으로 보고 다시 인코딩하지 않는다 -- 이중 인코딩은 포털이
``SERVICE_KEY_IS_NOT_REGISTERED_ERROR``로 거절하는 가장 흔한 원인이다.

키는 URL에만 실리므로 예외·로그에 URL을 절대 넣지 않는다.
"""

from __future__ import annotations

import json
import socket
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Callable

KST = timezone(timedelta(hours=9), "KST")

ENDPOINT = "https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getVilageFcst"

#: 단기예보 발표 시각(시). 발표 뒤 약 10분부터 조회된다.
ISSUE_HOURS = (2, 5, 8, 11, 14, 17, 20, 23)
AVAILABILITY_DELAY = timedelta(minutes=10)

#: 한 번 발표에 12개 항목 × 시간별(최대 약 3일) -- 1000줄이면 앞 80여 시간을 덮는다.
NUM_OF_ROWS = 1000

#: 응답 본문 상한(바이트). 정상 응답은 수백 KB 이하다.
MAX_BODY_BYTES = 2_000_000

#: 공공데이터포털·기상청 결과 코드(활용가이드). 사용자 문구가 아니다.
RESULT_CODES = {
    "00": "NORMAL_SERVICE",
    "01": "APPLICATION_ERROR",
    "02": "DB_ERROR",
    "03": "NODATA_ERROR",
    "04": "HTTP_ERROR",
    "05": "SERVICETIME_OUT",
    "10": "INVALID_REQUEST_PARAMETER_ERROR",
    "11": "NO_MANDATORY_REQUEST_PARAMETERS_ERROR",
    "12": "NO_OPENAPI_SERVICE_ERROR",
    "20": "SERVICE_ACCESS_DENIED_ERROR",
    "21": "TEMPORARILY_DISABLE_THE_SERVICEKEY_ERROR",
    "22": "LIMITED_NUMBER_OF_SERVICE_REQUESTS_EXCEEDS_ERROR",
    "30": "SERVICE_KEY_IS_NOT_REGISTERED_ERROR",
    "31": "DEADLINE_HAS_EXPIRED_ERROR",
    "32": "UNREGISTERED_IP_ERROR",
    "33": "UNSIGNED_CALL_ERROR",
    "99": "UNKNOWN_ERROR",
}

# PTY(강수형태) -- 단기예보: 0 없음, 1 비, 2 비/눈, 3 눈, 4 소나기.
# 초단기 코드(5 빗방울, 6 빗방울눈날림, 7 눈날림)도 같은 표로 받는다.
PTY_RAIN = frozenset({1, 2, 4, 5, 6})
PTY_SNOW = frozenset({3, 7})


class KmaError(Exception):
    """예보를 받지 못했다. ``kind``: network | api | parse."""

    def __init__(self, kind: str, code: str | None, message: str) -> None:
        super().__init__(f"{kind}:{code or '-'}:{message}")
        self.kind = kind
        self.code = code
        self.message = message


@dataclass(frozen=True)
class HourlyForecast:
    at: datetime  # KST, 정시
    tmp: float | None = None
    pop: int | None = None
    pty: int | None = None
    sky: int | None = None

    @property
    def precipitation(self) -> str | None:
        """'rain' | 'snow' | None -- 강수형태만 본다(강수확률 판단은 호출자가)."""
        if self.pty in PTY_SNOW:
            return "snow"
        if self.pty in PTY_RAIN:
            return "rain"
        return None

    def icon(self, rain_pop: int = 60) -> str:
        """키오스크 아이콘 키: clear | partly | cloudy | rain | snow."""
        precip = self.precipitation
        if precip:
            return precip
        if self.pop is not None and self.pop >= rain_pop:
            return "rain"
        if self.sky == 1:
            return "clear"
        if self.sky == 3:
            return "partly"
        if self.sky == 4:
            return "cloudy"
        return "partly"


@dataclass(frozen=True)
class Forecast:
    source: str  # "kma" | "mock"
    fetched_at: datetime  # UTC aware
    base: str  # 발표 시각 YYYYMMDDHHMM
    slots: tuple[HourlyForecast, ...] = field(default_factory=tuple)

    def to_json(self) -> str:
        return json.dumps(
            {
                "source": self.source,
                "fetched_at": self.fetched_at.isoformat(),
                "base": self.base,
                "slots": [
                    [s.at.isoformat(), s.tmp, s.pop, s.pty, s.sky] for s in self.slots
                ],
            },
            ensure_ascii=False,
        )

    @classmethod
    def from_json(cls, raw: str) -> "Forecast":
        doc = json.loads(raw)
        return cls(
            source=str(doc["source"]),
            fetched_at=datetime.fromisoformat(doc["fetched_at"]),
            base=str(doc["base"]),
            slots=tuple(
                HourlyForecast(datetime.fromisoformat(at), tmp, pop, pty, sky)
                for at, tmp, pop, pty, sky in doc["slots"]
            ),
        )


# ── 발표 시각 ────────────────────────────────────────────────────────────────


def base_datetime(now: datetime) -> datetime:
    """지금 조회할 수 있는 가장 최근 발표 시각(KST).

    발표 뒤 약 10분이 지나야 조회되므로 10분을 빼고 고른다. 02:10 이전이면
    전날 23시 발표다.
    """
    t = now.astimezone(KST) - AVAILABILITY_DELAY
    for hour in reversed(ISSUE_HOURS):
        if t.hour >= hour:
            return t.replace(hour=hour, minute=0, second=0, microsecond=0)
    prev = t - timedelta(days=1)
    return prev.replace(hour=ISSUE_HOURS[-1], minute=0, second=0, microsecond=0)


def base_params(now: datetime) -> tuple[str, str]:
    """(base_date YYYYMMDD, base_time HHMM)."""
    b = base_datetime(now)
    return b.strftime("%Y%m%d"), b.strftime("%H%M")


# ── 요청 ────────────────────────────────────────────────────────────────────


def encode_service_key(key: str) -> str:
    """Decoding 키는 인코딩하고, 이미 인코딩된 Encoding 키(``%`` 포함)는 그대로 둔다."""
    key = key.strip()
    if "%" in key:
        return key
    return urllib.parse.quote(key, safe="")


def build_url(service_key: str, nx: int, ny: int, now: datetime) -> str:
    base_date, base_time = base_params(now)
    rest = urllib.parse.urlencode(
        {
            "pageNo": 1,
            "numOfRows": NUM_OF_ROWS,
            "dataType": "JSON",
            "base_date": base_date,
            "base_time": base_time,
            "nx": nx,
            "ny": ny,
        }
    )
    # serviceKey는 urlencode에 맡기지 않는다 -- Encoding 키를 두 번 인코딩하게 된다.
    return f"{ENDPOINT}?serviceKey={encode_service_key(service_key)}&{rest}"


HttpGet = Callable[[str, float], tuple[int, bytes]]


def urllib_get(url: str, timeout: float) -> tuple[int, bytes]:
    """(HTTP 상태, 본문). 오류 상태도 본문을 돌려준다(포털은 오류를 XML로 싣는다)."""
    req = urllib.request.Request(
        url, headers={"User-Agent": "SimpleLay/1.0", "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - 고정 https 주소
            return resp.status, resp.read(MAX_BODY_BYTES)
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read(MAX_BODY_BYTES)
        except Exception:  # noqa: BLE001
            body = b""
        return exc.code, body
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError) as exc:
        # str(exc)에 URL은 없지만, 원문 대신 종류만 남긴다.
        raise KmaError("network", None, type(exc).__name__) from None


# ── 응답 해석 ────────────────────────────────────────────────────────────────


def _xml_error(text: str) -> KmaError:
    """포털 게이트웨이 오류(dataType=JSON이어도 XML로 온다) 또는 XML 응답."""
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return KmaError("parse", None, "unparseable XML body")

    def find(tag: str) -> str | None:
        node = root.find(f".//{tag}")
        return node.text.strip() if node is not None and node.text else None

    code = find("returnReasonCode") or find("resultCode")
    msg = find("returnAuthMsg") or find("resultMsg") or find("errMsg") or "XML error"
    if code == "00":
        return KmaError("parse", code, "XML body while JSON was requested")
    return KmaError("api", code, msg)


def _num(raw) -> float | None:
    try:
        return float(str(raw).strip())
    except (TypeError, ValueError):
        return None


def parse_response(status: int, body: bytes, *, source: str, fetched_at: datetime) -> Forecast:
    text = body.decode("utf-8", errors="replace").strip()
    if not text:
        raise KmaError("api" if status >= 400 else "parse", str(status), "empty body")
    if text.startswith("<"):
        raise _xml_error(text)
    try:
        doc = json.loads(text)
    except ValueError:
        # 'Unauthorized' 같은 평문 -- 게이트웨이가 키를 거절한 경우가 많다.
        raise KmaError("api" if status >= 400 else "parse", str(status), text[:80]) from None
    try:
        header = doc["response"]["header"]
        code = str(header.get("resultCode", "")).strip()
        msg = str(header.get("resultMsg", "")).strip()
    except (KeyError, TypeError, AttributeError):
        raise KmaError("parse", None, "unexpected JSON shape") from None
    if code != "00":
        raise KmaError("api", code, msg or RESULT_CODES.get(code, "error"))
    try:
        body_doc = doc["response"]["body"]
        items = body_doc["items"]["item"]
    except (KeyError, TypeError):
        raise KmaError("parse", code, "missing items") from None
    if isinstance(items, dict):
        items = [items]

    base = ""
    grouped: dict[datetime, dict[str, float | None]] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        cat = item.get("category")
        if cat not in ("TMP", "POP", "PTY", "SKY"):
            continue
        try:
            at = datetime.strptime(
                f"{item['fcstDate']}{str(item['fcstTime']).zfill(4)}", "%Y%m%d%H%M"
            ).replace(tzinfo=KST)
        except (KeyError, ValueError):
            continue
        if not base and item.get("baseDate") and item.get("baseTime"):
            base = f"{item['baseDate']}{str(item['baseTime']).zfill(4)}"
        grouped.setdefault(at, {})[cat] = _num(item.get("fcstValue"))

    if not grouped:
        raise KmaError("parse", code, "no TMP/POP/PTY/SKY items")

    def _int(v):
        return None if v is None else int(round(v))

    slots = tuple(
        HourlyForecast(
            at=at,
            tmp=values.get("TMP"),
            pop=_int(values.get("POP")),
            pty=_int(values.get("PTY")),
            sky=_int(values.get("SKY")),
        )
        for at, values in sorted(grouped.items())
    )
    return Forecast(source=source, fetched_at=fetched_at, base=base, slots=slots)


def fetch_forecast(
    service_key: str,
    nx: int,
    ny: int,
    now: datetime,
    *,
    timeout: float = 5.0,
    http_get: HttpGet = urllib_get,
) -> Forecast:
    """받아 해석한다. 실패는 전부 ``KmaError``로 바꿔 올린다.

    최신 발표가 아직 올라오지 않았으면(결과 코드 03 NO_DATA) 바로 앞 발표로 **한 번만** 다시 묻는다 —
    10/14 실물: 00:03에 23:00 발표가 없었고 20:00 발표는 있었다(발표 뒤 10분 가정이 늘 맞지는 않다).
    """
    def _once(at: datetime) -> Forecast:
        url = build_url(service_key, nx, ny, at)
        try:
            status, body = http_get(url, timeout)
        except KmaError:
            raise
        except Exception as exc:  # noqa: BLE001 - 주입된 전송의 어떤 실패도 네트워크 실패로
            raise KmaError("network", None, type(exc).__name__) from None
        return parse_response(
            status, body, source="kma", fetched_at=now.astimezone(timezone.utc)
        )

    try:
        return _once(now)
    except KmaError as exc:
        if exc.kind != "api" or exc.code != "03":
            raise
    # 앞 발표 시각을 고르게 하는 '지금': 최신 발표 시각 바로 전(조회 지연을 더해 base_datetime이 앞 발표를 고른다).
    previous = base_datetime(now) - timedelta(minutes=1) + AVAILABILITY_DELAY
    return _once(previous)


# ── 리허설용 고정 예보 ────────────────────────────────────────────────────────

# (시, 기온, 강수확률, 강수형태, 하늘) -- 맑은 아침 → 흐려지다 오후 3시부터 비.
_MOCK_DAY = (
    (0, 17, 10, 0, 1), (1, 17, 10, 0, 1), (2, 16, 10, 0, 1), (3, 16, 10, 0, 1),
    (4, 16, 10, 0, 1), (5, 16, 10, 0, 1), (6, 17, 10, 0, 1), (7, 18, 10, 0, 1),
    (8, 19, 10, 0, 1), (9, 21, 20, 0, 1), (10, 22, 20, 0, 3), (11, 23, 20, 0, 3),
    (12, 24, 30, 0, 3), (13, 24, 30, 0, 4), (14, 23, 50, 0, 4), (15, 21, 70, 1, 4),
    (16, 20, 80, 1, 4), (17, 19, 80, 1, 4), (18, 19, 70, 1, 4), (19, 18, 60, 1, 4),
    (20, 18, 60, 1, 4), (21, 18, 30, 0, 4), (22, 17, 20, 0, 3), (23, 17, 20, 0, 3),
)


def mock_forecast(now: datetime) -> Forecast:
    """리허설용 고정 예보: 오늘·내일 모두 오후 3~8시 비. 네트워크를 쓰지 않는다."""
    local = now.astimezone(KST)
    today: date = local.date()
    slots = []
    for day in (today, today + timedelta(days=1)):
        for hour, tmp, pop, pty, sky in _MOCK_DAY:
            at = datetime(day.year, day.month, day.day, hour, tzinfo=KST)
            slots.append(HourlyForecast(at, float(tmp), pop, pty, sky))
    return Forecast(
        source="mock",
        fetched_at=now.astimezone(timezone.utc),
        base=base_datetime(now).strftime("%Y%m%d%H%M"),
        slots=tuple(slots),
    )
