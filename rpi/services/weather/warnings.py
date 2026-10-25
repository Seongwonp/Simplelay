"""기상특보(2026-10-25) — 기상청 기상특보 조회서비스의 특보코드조회(getPwnCd)로 우리 지역에 지금 걸린 주의보·경보를 고른다.

공공데이터포털 같은 일반 인증키를 쓰되 서비스는 따로 활용 신청한다(안 하면 403 — 그때는 특보 없이 예보 안내만).
지역은 특보구역코드 앞부분(``SIMPLELAY_WEATHER_WARN_AREAS``, 예: 서울 ``L1100``)으로 거른다. 키는 URL에만 실리므로
예외·로그에 URL을 넣지 않는다(kma.py와 같은 규칙).

지역은 허브 위치(폰 앱이 저장한 위경도)에서 가장 가까운 행정동의 시군구 특보구역으로 정한다 — 표는
``data/warn_zones.json``(기상청 공개 자료로 ``rpi.tools.build_warn_zones``가 만든다). env로 구역을 직접 줄 수도 있다.
"""
from __future__ import annotations

import json
import math
import socket
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Iterable, Sequence

from .kma import KST, KmaError

ENDPOINT = "https://apis.data.go.kr/1360000/WthrWrnInfoService/getPwnCd"
#: 특보는 며칠씩 이어질 수 있다 — 지난 7일 발표를 보고 구역·종류마다 마지막 발표로 지금 상태를 정한다.
LOOKBACK_DAYS = 7
NUM_OF_ROWS = 1000
MAX_BODY_BYTES = 2_000_000

#: 특보종류(warnVar, 활용가이드). 바다 특보(폭풍해일·풍랑)는 땅 구역에 오지 않아 안내를 두지 않는다.
KINDS = {
    1: ("강풍", "wind", "바람이 강해요. 외출할 때 조심하세요."),
    2: ("호우", "rain", "비가 많이 와요. 우산을 챙기고 외출을 줄이세요."),
    3: ("한파", "cold", "많이 추워요. 따뜻하게 입으세요."),
    4: ("건조", "dry", "공기가 건조해요. 불조심하세요."),
    7: ("태풍", "storm", "태풍이 와요. 창문을 닫고 외출을 줄이세요."),
    8: ("대설", "snow", "눈이 많이 와요. 길이 미끄러우니 조심하세요."),
    9: ("황사", "dust", "황사가 있어요. 창문을 닫고 나갈 때 마스크를 쓰세요."),
    12: ("폭염", "hot", "많이 더워요. 물을 자주 드세요."),
    13: ("열대야", "hot", "밤에도 더워요. 시원하게 주무세요."),
}
LEVELS = {0: "주의보", 1: "경보", 2: "중대경보"}
#: 특보발표코드 — 발표·연장·정정·변경발표는 걸려 있음, 해제·변경해제는 풀림.
ACTIVE_COMMANDS = {1, 3, 6, 7}


ZONES_FILE = Path(__file__).with_name("data") / "warn_zones.json"


@lru_cache(maxsize=1)
def _zone_table() -> dict:
    try:
        return json.loads(ZONES_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"groups": [], "points": []}


def zones_for_location(lat: float | None, lon: float | None) -> tuple[str, ...]:
    """위경도 → 그곳 시군구의 특보구역코드(세부 구역 포함). 표에 없거나 위치가 없으면 빈 값(특보 안 봄)."""
    if lat is None or lon is None:
        return ()
    table = _zone_table()
    if not table["points"]:
        return ()
    k = math.cos(math.radians(lat))
    best = min(table["points"], key=lambda p: (p[0] - lat) ** 2 + ((p[1] - lon) * k) ** 2)
    # 가장 가까운 동이 30 km 넘게 떨어져 있으면(바다 위·국외 좌표) 고르지 않는다.
    if math.hypot(best[0] - lat, (best[1] - lon) * k) * 111 > 30:
        return ()
    return tuple(table["groups"][best[2]])


def _int(v) -> int | None:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def active_warnings(items: Iterable[dict], area_prefixes: Sequence[str]) -> list[dict]:
    """발표 목록 → 지금 걸린 특보(종류마다 가장 센 단계 하나). 센 단계·종류 순."""
    latest: dict[tuple[str, int, int], tuple[tuple[int, int], dict]] = {}
    for it in items:
        area = str(it.get("areaCode") or "")
        if not any(area.startswith(p) for p in area_prefixes):
            continue
        var, stress = _int(it.get("warnVar")), _int(it.get("warnStress"))
        if var is None or stress is None:
            continue
        order = (_int(it.get("tmFc")) or 0, _int(it.get("tmSeq")) or 0)
        key = (area, var, stress)
        if key not in latest or order >= latest[key][0]:
            latest[key] = (order, it)
    strongest: dict[int, int] = {}
    for (_area, var, stress), (_order, it) in latest.items():
        if _int(it.get("cancel")) == 1 or _int(it.get("command")) not in ACTIVE_COMMANDS:
            continue
        if var in KINDS and stress > strongest.get(var, -1):
            strongest[var] = stress
    out = []
    for var, stress in sorted(strongest.items(), key=lambda kv: (-kv[1], kv[0])):
        name, icon, advice = KINDS[var]
        out.append({
            "kind": name,
            "level": LEVELS.get(stress, "주의보"),
            "title": f"{name}{LEVELS.get(stress, '주의보')}",
            "icon": icon,
            "advice": advice,
        })
    return out


def fetch_items(service_key: str, now: datetime, timeout: float) -> list[dict]:
    """지난 [LOOKBACK_DAYS]일 특보 발표 목록. 실패는 [KmaError](URL·키는 넣지 않는다)."""
    today = now.astimezone(KST).date()
    params = {
        "serviceKey": urllib.parse.unquote(service_key),
        "pageNo": 1,
        "numOfRows": NUM_OF_ROWS,
        "dataType": "JSON",
        "fromTmFc": (today - timedelta(days=LOOKBACK_DAYS)).strftime("%Y%m%d"),
        "toTmFc": today.strftime("%Y%m%d"),
    }
    url = ENDPOINT + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as res:
            body = res.read(MAX_BODY_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise KmaError("http", str(exc.code), "warning request rejected") from None
    except (urllib.error.URLError, socket.timeout, OSError):
        raise KmaError("network", None, "warning request failed") from None
    if len(body) > MAX_BODY_BYTES:
        raise KmaError("parse", None, "warning response too large")
    try:
        data = json.loads(body.decode("utf-8"))
        header = data["response"]["header"]
    except (ValueError, KeyError, TypeError):
        raise KmaError("parse", None, "warning response unreadable") from None
    code = str(header.get("resultCode", ""))
    if code in ("03", "3"):
        return []
    if code not in ("00", "0"):
        raise KmaError("api", code, "warning api error")
    items = (data["response"].get("body") or {}).get("items") or {}
    rows = items.get("item") if isinstance(items, dict) else None
    if isinstance(rows, dict):
        rows = [rows]
    return list(rows or [])
