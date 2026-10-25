"""기상특보 구역 표 만들기(2026-10-25) — 허브 위치 → 특보구역코드.

기상청 공개 자료 두 개(공공데이터포털 활용가이드, 공공누리 제1유형 — 출처: 기상청)를 읽어
``rpi/services/weather/data/warn_zones.json``을 만든다:
  - 단기예보 조회서비스 활용가이드의 '격자_위경도' 엑셀: 행정동마다 시도·시군구·위경도
  - 기상특보 조회서비스 활용가이드의 '특보구역코드안내' 엑셀: 특보구역 계층(REG_ID·REG_UP·REG_NAME)

규칙(넉넉하게 알리는 쪽):
  - 시군구 이름으로 특보구역을 찾는다('수원시장안구' → '수원시'). 찾은 구역과 그 아래 세부 구역을 함께 본다(파주시동북부 등).
  - 광역시처럼 구 이름으로 구역이 없으면 그 시도 구역 전체를 본다(서울 4권역, 부산 3권역 등 — 구↔권역 공식 표가 없어 묶는다).
    시도 아래 군 단위 구역(달성군·강화군 등)은 따로 이름이 맞을 때만.
  - 산지·도서 같은 따로 떨어진 세부 구역은 넣지 않는다(집은 평지·본토라고 본다).

사용: python -m rpi.tools.build_warn_zones <격자_위경도.xlsx> <특보구역코드안내.xlsx>
"""
from __future__ import annotations

import json
import re
import sys
import zipfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "services" / "weather" / "data" / "warn_zones.json"

SIDO_ALIASES = {"강원특별자치도": "강원도", "전북특별자치도": "전북자치도", "제주특별자치도": "제주도"}
SEPARATE = ("산지", "산간", "도서", "낙월면", "위도면", "옥도면", "어청도", "여서도")


def _sheet_rows(path: str, sheet: str) -> list[dict[str, str]]:
    z = zipfile.ZipFile(path)
    ss = z.read("xl/sharedStrings.xml").decode()
    strs = [re.sub(r"<[^>]+>", "", m) for m in re.findall(r"<si>(.*?)</si>", ss, flags=re.S)]
    x = z.read(f"xl/worksheets/{sheet}.xml").decode()
    rows = []
    for row in re.findall(r"<row[^>]*>(.*?)</row>", x, flags=re.S):
        vals = {}
        for ref, attrs, inner in re.findall(r'<c r="([A-Z]+)\d+"([^>]*?)(?:/>|>(.*?)</c>)', row, flags=re.S):
            v = re.search(r"<v>(.*?)</v>", inner or "")
            vals[ref] = "" if not v else (strs[int(v.group(1))] if 't="s"' in attrs else v.group(1))
        rows.append(vals)
    return rows


def _separate(name: str) -> bool:
    return "제외" not in name and any(k in name for k in SEPARATE)


def build(grid_xlsx: str, zone_xlsx: str) -> dict:
    zones = {}
    for r in _sheet_rows(zone_xlsx, "sheet2")[1:]:
        code, end, up, name = r.get("A", ""), r.get("C", ""), r.get("E", ""), r.get("G", "")
        if code.startswith("L") and end.startswith("2100"):
            zones[code] = (up, name)
    children: dict[str, list[str]] = {}
    for code, (up, _name) in zones.items():
        children.setdefault(up, []).append(code)

    def subtree(code: str, skip_gun: bool = False) -> list[str]:
        out = [code]
        for c in children.get(code, []):
            name = zones[c][1]
            if _separate(name) or (skip_gun and name.endswith("군")):
                continue
            out += subtree(c, skip_gun)
        return out

    sido_code = {name: code for code, (up, name) in zones.items() if up == "L1000000"}

    def zones_for(sido: str, sigungu: str) -> list[str]:
        top = sido_code.get(SIDO_ALIASES.get(sido, sido))
        if top is None:
            return []
        m = re.match(r"^(.+?[시군])", sigungu) if sigungu else None
        base = m.group(1) if m else sigungu
        if base:
            for code in subtree(top):
                if zones[code][1].startswith(base) and code != top:
                    return sorted(set(subtree(code)))
        return sorted(set(subtree(top, skip_gun=True)))

    groups: dict[tuple[str, ...], int] = {}
    points = []
    for r in _sheet_rows(grid_xlsx, "sheet1")[1:]:
        if r.get("A") != "kor" or not r.get("E"):
            continue
        try:
            lon, lat = float(r["N"]), float(r["O"])
        except (KeyError, ValueError):
            continue
        codes = tuple(zones_for(r.get("C", ""), r.get("D", "")))
        if not codes:
            continue
        idx = groups.setdefault(codes, len(groups))
        points.append([round(lat, 4), round(lon, 4), idx])
    return {
        "source": "기상청 단기예보 격자·위경도, 기상특보 특보구역코드(공공데이터포털 활용가이드, 공공누리 제1유형)",
        "groups": [list(g) for g in sorted(groups, key=groups.get)],
        "points": points,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    data = build(argv[0], argv[1])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(data['points'])} points, {len(data['groups'])} zone groups -> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
