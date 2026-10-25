"""사진 → 갠트리 mm 매핑(가전 추가 5단계의 ②~④, 2026-09-30). **실제 사진으로는 미검증.**

사용자는 조작부 사진에서 **갠트리 프레임 네 모서리**를 왼쪽 위부터 시계 방향으로 짚고,
버튼·정지 버튼·보관 위치를 짚는다. 프레임 안쪽 치수(mm)를 알고 있으므로 네 모서리 ↔
(0,0)·(W,0)·(W,H)·(0,H)로 원근 변환(``rpi.calibration.fit_homography``)을 구해 짚은 점을
mm로 옮긴다. 원근 왜곡은 여기서 흡수되지만 **렌즈 왜곡은 흡수되지 않는다**.

**네 점만으로는 잔차가 늘 0이다**(transform.py 머리말). 그래서 모서리 배치 자체를 먼저 본다 —
순서가 꼬였는지(자기 교차), 반대 방향으로 짚었는지, 첫 점이 왼쪽 위인지, 너무 작거나 찌그러진
사각형인지, 사진 속 비율이 프레임 치수와 크게 다른지. 기준점(``extra_points``, 사진 px ↔ mm)을
더 주면 여분 점으로 실제 잔차 검증을 한다. 임계값은 전부 **설계 초기값**이다(추측/측정 필요).

프레임 치수: 요청값 → ``SIMPLELAY_FRAME_W_MM``·``SIMPLELAY_FRAME_H_MM``. 프레임 안쪽 왼쪽 위
모서리와 갠트리 원점이 다르면 ``SIMPLELAY_FRAME_ORIGIN_X_MM``·``_Y_MM``(기본 0)로 더한다.
사진 파일은 서버에 올리지 않는다 — 크기와 짚은 좌표만 기록한다.
"""

from __future__ import annotations

import math
import os
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from rpi.calibration import CalibrationRejected, PointPair, calibrate, fit_homography
from rpi.calibration.transform import _version_of  # noqa: PLC2701 - 같은 버전 규칙을 쓴다
from rpi.josa import with_josa
from rpi.services.stop_park import PARK_LABEL  # 보관 위치의 화면 이름(폰 가전 추가 화면의 말)

#: 모서리 사각형 넓이의 사진 대비 최소 비율(사진 크기를 알 때). 설계 초기값.
MIN_QUAD_AREA_RATIO = 0.02
#: 모서리 내각 허용 범위(도). 이보다 뾰족하면 거의 한 직선 — 설계 초기값.
MIN_CORNER_ANGLE_DEG = 25.0
MAX_CORNER_ANGLE_DEG = 155.0
#: 사진 속 가로세로 비율과 프레임 치수 비율의 허용 배수. 원근을 감안한 설계 초기값.
MAX_ASPECT_FACTOR = 2.5
#: 짚은 점이 프레임 밖으로 나가도 받는 여유(mm). 설계 초기값.
FRAME_MARGIN_MM = 5.0

CORNER_NAMES = ("왼쪽 위", "오른쪽 위", "오른쪽 아래", "왼쪽 아래")


class MappingRejected(ValueError):
    """사용자에게 그대로 보여 줄 한국어 문장으로 거절한다.

    폰 가전 추가 화면의 말(버튼판 네 귀퉁이·기다리는 자리·누름 장치)로 쓰고, 프레임·갠트리·mm 좌표 같은 속말과
    '이(가)'처럼 둘 다 적은 조사는 쓰지 않는다(첫 사용 점검 2026-10-19). 다음에 할 일을 함께 적는다."""


@dataclass(frozen=True)
class FrameConfig:
    width_mm: float | None
    height_mm: float | None
    origin_x_mm: float = 0.0
    origin_y_mm: float = 0.0
    source: str = "none"  # request | env | none
    #: 갠트리 Y가 위로 커지는가(2026-10-25, HW 담당 원본 펌웨어 — 원점 좌하단, +Y 위, 음수 좌표 거절). 참이면 사진의
    #: 왼쪽 아래 모서리가 원점, 왼쪽 위가 (0, H)다. 거짓(기본)이면 종전처럼 왼쪽 위가 원점, 아래로 Y가 커진다.
    y_up: bool = False

    def as_dict(self) -> dict:
        return {"frame_w_mm": self.width_mm, "frame_h_mm": self.height_mm,
                "origin_x_mm": self.origin_x_mm, "origin_y_mm": self.origin_y_mm, "source": self.source,
                "y_up": self.y_up}


def _env_number(env: Mapping[str, str], name: str) -> float | None:
    raw = (env.get(name) or "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def frame_config(width_mm: float | None = None, height_mm: float | None = None,
                 env: Mapping[str, str] | None = None) -> FrameConfig:
    src = os.environ if env is None else env
    ox = _env_number(src, "SIMPLELAY_FRAME_ORIGIN_X_MM") or 0.0
    oy = _env_number(src, "SIMPLELAY_FRAME_ORIGIN_Y_MM") or 0.0
    y_up = src.get("SIMPLELAY_FRAME_Y_UP", "").strip().lower() in ("1", "true", "yes")
    if width_mm is not None and height_mm is not None:
        return FrameConfig(float(width_mm), float(height_mm), ox, oy, "request", y_up)
    w, h = _env_number(src, "SIMPLELAY_FRAME_W_MM"), _env_number(src, "SIMPLELAY_FRAME_H_MM")
    if w is not None and h is not None:
        return FrameConfig(w, h, ox, oy, "env", y_up)
    return FrameConfig(None, None, ox, oy, "none", y_up)


@dataclass(frozen=True)
class MappingInput:
    photo_w: int
    photo_h: int
    corners_px: tuple[tuple[float, float], ...]
    frame: FrameConfig
    buttons_px: Mapping[str, tuple[float, float]] = field(default_factory=dict)
    stop_px: tuple[float, float] | None = None
    park_px: tuple[float, float] | None = None
    #: 선택 — (사진 px, mm) 기준점. 있으면 잔차 검증을 한다.
    extra_points: tuple[tuple[tuple[float, float], tuple[float, float]], ...] = ()
    #: 선택 — 버튼 id → 화면 이름. 거절 문장에 id 대신 이름을 쓴다.
    button_labels: Mapping[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class MappingResult:
    version: str
    buttons_mm: dict[str, tuple[float, float]]
    stop_mm: tuple[float, float] | None
    park_mm: tuple[float, float] | None
    quality: dict
    record: dict


def _cross(o, a, b) -> float:
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def _segments_intersect(p1, p2, p3, p4) -> bool:
    d1, d2 = _cross(p3, p4, p1), _cross(p3, p4, p2)
    d3, d4 = _cross(p1, p2, p3), _cross(p1, p2, p4)
    return (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0)


def check_corners(corners: Sequence[tuple[float, float]], photo_w: int, photo_h: int,
                  frame: FrameConfig) -> dict:
    """네 모서리 배치를 본다. 통과하면 품질 요약, 아니면 ``MappingRejected``."""
    if len(corners) != 4:
        raise MappingRejected("버튼판 네 귀퉁이를 모두 골라 주세요")
    pts = [(float(u), float(v)) for u, v in corners]
    for i, (u, v) in enumerate(pts):
        if not (math.isfinite(u) and math.isfinite(v)) or not (0 <= u <= photo_w and 0 <= v <= photo_h):
            raise MappingRejected(f"{CORNER_NAMES[i]} 귀퉁이가 사진 밖에 있어요 — 사진 안에서 다시 골라 주세요")
    for i in range(4):
        for j in range(i + 1, 4):
            if math.dist(pts[i], pts[j]) < 1e-6 * max(photo_w, photo_h):
                raise MappingRejected(f"{with_josa(CORNER_NAMES[i], '과', '와')} {CORNER_NAMES[j]} 귀퉁이가 같은 곳이에요 "
                                      "— 네 귀퉁이를 따로따로 골라 주세요")
    if _segments_intersect(pts[0], pts[1], pts[2], pts[3]) or _segments_intersect(pts[1], pts[2], pts[3], pts[0]):
        raise MappingRejected("귀퉁이 순서가 꼬였어요 — 왼쪽 위부터 시계 방향(오른쪽 위 → 오른쪽 아래 → "
                              "왼쪽 아래)으로 다시 골라 주세요")
    crosses = [_cross(pts[i], pts[(i + 1) % 4], pts[(i + 2) % 4]) for i in range(4)]
    if not (all(c > 0 for c in crosses) or all(c < 0 for c in crosses)):
        raise MappingRejected("고른 네 귀퉁이가 네모 모양이 되지 않아요 — 버튼판 귀퉁이를 다시 골라 주세요")
    if crosses[0] < 0:
        # 사진 좌표는 y가 아래로 커진다 — 시계 방향이면 외적이 양수다.
        raise MappingRejected("귀퉁이를 반대 방향으로 골랐어요 — 왼쪽 위부터 시계 방향으로 다시 골라 주세요")
    sums = [u + v for u, v in pts]
    if sums.index(min(sums)) != 0:
        raise MappingRejected("첫 귀퉁이가 사진의 왼쪽 위가 아니에요 — 사진이 돌아가 있지 않은지 보고, "
                              "왼쪽 위부터 다시 골라 주세요")
    angles = []
    for i in range(4):
        a, o, b = pts[i - 1], pts[i], pts[(i + 1) % 4]
        v1, v2 = (a[0] - o[0], a[1] - o[1]), (b[0] - o[0], b[1] - o[1])
        cosang = (v1[0] * v2[0] + v1[1] * v2[1]) / (math.hypot(*v1) * math.hypot(*v2))
        angles.append(math.degrees(math.acos(max(-1.0, min(1.0, cosang)))))
    worst = min(range(4), key=lambda i: min(angles[i] - MIN_CORNER_ANGLE_DEG, MAX_CORNER_ANGLE_DEG - angles[i]))
    if not MIN_CORNER_ANGLE_DEG <= angles[worst] <= MAX_CORNER_ANGLE_DEG:
        raise MappingRejected(f"사진 속 버튼판이 {CORNER_NAMES[worst]} 귀퉁이 쪽으로 너무 찌그러졌어요 — "
                              "버튼판을 정면에서 다시 찍어 주세요")
    area = 0.5 * abs(sum(pts[i][0] * pts[(i + 1) % 4][1] - pts[(i + 1) % 4][0] * pts[i][1] for i in range(4)))
    area_ratio = area / float(photo_w * photo_h)
    if area_ratio < MIN_QUAD_AREA_RATIO:
        raise MappingRejected("사진 속 버튼판이 너무 작아요 — 버튼판이 사진을 채우도록 가까이서 다시 찍어 주세요")
    top, bottom = math.dist(pts[0], pts[1]), math.dist(pts[3], pts[2])
    left, right = math.dist(pts[0], pts[3]), math.dist(pts[1], pts[2])
    photo_aspect = ((top + bottom) / 2) / ((left + right) / 2)
    frame_aspect = frame.width_mm / frame.height_mm  # type: ignore[operator]
    factor = max(photo_aspect / frame_aspect, frame_aspect / photo_aspect)
    if factor > MAX_ASPECT_FACTOR:
        raise MappingRejected(
            "사진 속 버튼판의 가로·세로 비율이 적어 준 크기와 많이 달라요 — "
            "버튼판 가로·세로 크기와 귀퉁이를 고른 순서(왼쪽 위부터 시계 방향)를 확인해 주세요")
    return {"corner_angles_deg": [round(a, 1) for a in angles], "area_ratio": round(area_ratio, 4),
            "photo_aspect": round(photo_aspect, 3), "frame_aspect": round(frame_aspect, 3),
            "aspect_factor": round(factor, 3)}


def compute_mapping(data: MappingInput) -> MappingResult:
    frame = data.frame
    if frame.width_mm is None or frame.height_mm is None:
        # 화면에는 할 일만 — 설치하는 분용 설정 이름(SIMPLELAY_FRAME_W_MM·_H_MM)은 이 주석과 문서에 둔다.
        raise MappingRejected("버튼판 가로·세로 크기가 없어요 — 자로 재서 가로·세로 크기(mm)를 적어 주세요")
    if not (frame.width_mm > 0 and frame.height_mm > 0):
        raise MappingRejected("버튼판 가로·세로 크기는 0보다 커야 해요 — 크기를 다시 적어 주세요")
    if data.photo_w <= 0 or data.photo_h <= 0:
        raise MappingRejected("사진 크기를 읽지 못했어요 — 사진을 다시 찍어 주세요")
    quality = check_corners(data.corners_px, data.photo_w, data.photo_h, frame)
    w, h, ox, oy = frame.width_mm, frame.height_mm, frame.origin_x_mm, frame.origin_y_mm
    # 짚는 순서는 늘 사진의 왼쪽 위부터 시계 방향. Y가 위로 커지는 갠트리면 왼쪽 위 모서리가 (0, H)다.
    targets = ([(ox, oy + h), (ox + w, oy + h), (ox + w, oy), (ox, oy)] if frame.y_up
               else [(ox, oy), (ox + w, oy), (ox + w, oy + h), (ox, oy + h)])
    pairs = [PointPair(src, dst) for src, dst in zip(data.corners_px, targets)]
    extra = [PointPair(src, dst) for src, dst in data.extra_points]
    try:
        if extra:
            result = calibrate(pairs + extra, kind="homography")
            transform, version = result.transform, result.version
            quality.update(residual_check="extra_points", redundant_points=result.redundant_points,
                           rms_error_mm=round(result.rms_error_mm, 3), max_error_mm=round(result.max_error_mm, 3))
        else:
            transform = fit_homography(pairs)
            version = _version_of(transform)
            quality.update(residual_check="none", redundant_points=0,
                           note="모서리 네 점뿐이라 잔차 검증이 없어요 — 확인 주행으로 확인해 주세요")
    except CalibrationRejected as exc:
        raise MappingRejected(str(exc)) from exc

    def to_mm(label: str, point: tuple[float, float]) -> tuple[float, float]:
        u, v = float(point[0]), float(point[1])
        if not (math.isfinite(u) and math.isfinite(v)) or not (0 <= u <= data.photo_w and 0 <= v <= data.photo_h):
            raise MappingRejected(f"{with_josa(label, '이', '가')} 사진 밖에 있어요 — 사진 안에서 다시 골라 주세요")
        try:
            x, y = transform.apply((u, v))
        except ValueError as exc:
            raise MappingRejected(f"{label} 자리를 계산하지 못했어요 — 버튼판 네 귀퉁이를 다시 골라 주세요") from exc
        m = FRAME_MARGIN_MM
        if not (ox - m <= x <= ox + w + m and oy - m <= y <= oy + h + m):
            raise MappingRejected(f"{with_josa(label, '이', '가')} 버튼판 네 귀퉁이 밖에 있어요 "
                                  "— 네 귀퉁이 안쪽에서 다시 골라 주세요")
        return (round(float(np.clip(x, ox, ox + w)), 2), round(float(np.clip(y, oy, oy + h)), 2))

    buttons_mm = {bid: to_mm(f"버튼 '{data.button_labels.get(bid, bid)}'", p) for bid, p in data.buttons_px.items()}
    stop_mm = to_mm("정지 버튼", data.stop_px) if data.stop_px is not None else None
    park_mm = to_mm(PARK_LABEL, data.park_px) if data.park_px is not None else None
    record = {
        "photo": {"width": data.photo_w, "height": data.photo_h},
        "corners_px": [[float(u), float(v)] for u, v in data.corners_px],
        "frame": frame.as_dict(),
        "buttons_px": {k: [float(p[0]), float(p[1])] for k, p in data.buttons_px.items()},
        "stop_px": None if data.stop_px is None else [float(data.stop_px[0]), float(data.stop_px[1])],
        "park_px": None if data.park_px is None else [float(data.park_px[0]), float(data.park_px[1])],
        "version": version,
    }
    return MappingResult(version, buttons_mm, stop_mm, park_mm, quality, record)


def verify_targets(appliance: Any, button_ids: Sequence[str] | None = None) -> list[dict]:
    """확인 주행 목록 — 보정된 버튼(지정 순서 또는 등록 순서) → 보관 위치."""
    by_id = {b.id: b for b in appliance.buttons}
    ids = list(button_ids) if button_ids else [b.id for b in appliance.buttons if b.calibrated]
    targets: list[dict] = []
    for bid in ids:
        b = by_id.get(bid)
        if b is None:
            raise MappingRejected(f"이 가전에 없는 버튼이에요: {bid}")
        if not b.calibrated:
            raise MappingRejected(f"버튼 '{b.label}'의 자리를 아직 정하지 않았어요 — 사진에서 버튼을 먼저 골라 주세요")
        targets.append({"button": b.label, "button_id": b.id, "kind": "button",
                        "x_mm": float(b.x_mm), "y_mm": float(b.y_mm)})
    if appliance.park_xy is not None:
        targets.append({"button": PARK_LABEL, "button_id": None, "kind": "park",
                        "x_mm": float(appliance.park_xy[0]), "y_mm": float(appliance.park_xy[1])})
    if not targets:
        raise MappingRejected("확인할 자리가 없어요 — 사진에서 버튼을 골라 먼저 저장해 주세요")
    return targets
