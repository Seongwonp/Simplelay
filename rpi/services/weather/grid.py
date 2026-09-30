"""위경도 → 기상청 동네예보 격자(nx, ny).

기상청이 공개한 람베르트 정각원추도법(LCC) 변환식을 그대로 옮겼다
(단기예보 조회서비스 활용가이드 부록의 변환 코드와 같은 상수).
격자 간격 5 km, 표준위도 30°·60°, 기준점 위도 38°·경도 126°, 기준점 격자 (43, 136).
"""

from __future__ import annotations

import math

_RE = 6371.00877  # 지구 반경(km)
_GRID = 5.0  # 격자 간격(km)
_SLAT1 = 30.0  # 투영 위도1(°)
_SLAT2 = 60.0  # 투영 위도2(°)
_OLON = 126.0  # 기준점 경도(°)
_OLAT = 38.0  # 기준점 위도(°)
_XO = 43  # 기준점 X 격자
_YO = 136  # 기준점 Y 격자


def latlon_to_grid(lat: float, lon: float) -> tuple[int, int]:
    """위도·경도(°) → (nx, ny). 서울시청(37.5665, 126.9780) → (60, 127)."""
    if not (-90.0 <= lat <= 90.0) or not (-180.0 <= lon <= 180.0):
        raise ValueError(f"위경도 범위 밖: {lat}, {lon}")
    degrad = math.pi / 180.0
    re = _RE / _GRID
    slat1 = _SLAT1 * degrad
    slat2 = _SLAT2 * degrad
    olon = _OLON * degrad
    olat = _OLAT * degrad

    sn = math.tan(math.pi * 0.25 + slat2 * 0.5) / math.tan(math.pi * 0.25 + slat1 * 0.5)
    sn = math.log(math.cos(slat1) / math.cos(slat2)) / math.log(sn)
    sf = math.tan(math.pi * 0.25 + slat1 * 0.5)
    sf = math.pow(sf, sn) * math.cos(slat1) / sn
    ro = math.tan(math.pi * 0.25 + olat * 0.5)
    ro = re * sf / math.pow(ro, sn)

    ra = math.tan(math.pi * 0.25 + lat * degrad * 0.5)
    ra = re * sf / math.pow(ra, sn)
    theta = lon * degrad - olon
    if theta > math.pi:
        theta -= 2.0 * math.pi
    if theta < -math.pi:
        theta += 2.0 * math.pi
    theta *= sn
    nx = math.floor(ra * math.sin(theta) + _XO + 0.5)
    ny = math.floor(ro - ra * math.cos(theta) + _YO + 0.5)
    return int(nx), int(ny)
