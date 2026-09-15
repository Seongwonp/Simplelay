"""자동 보정 — 패널/이미지 좌표를 갠트리 mm 좌표로 옮기는 변환의 소프트웨어 핵심.

카메라 촬영·기준점 검출·하드웨어 구동은 이 패키지 밖이다. 여기는 **이미 얻은
기준점 쌍**으로 변환을 맞추고, 믿을 수 없는 변환은 거절하고, 버튼 좌표를
옮기는 데까지만 한다. 자세한 제약은 `transform` 모듈 머리말에 있다.
"""

from __future__ import annotations

from .transform import (
    DEFAULT_MAX_POINT_ERROR_MM,
    DEFAULT_MAX_RMS_MM,
    MIN_AFFINE_POINTS,
    MIN_HOMOGRAPHY_POINTS,
    CalibrationRejected,
    CalibrationResult,
    PointPair,
    Transform2D,
    calibrate,
    fit_affine,
    fit_homography,
    map_button_centers,
)

__all__ = [
    "DEFAULT_MAX_POINT_ERROR_MM",
    "DEFAULT_MAX_RMS_MM",
    "MIN_AFFINE_POINTS",
    "MIN_HOMOGRAPHY_POINTS",
    "CalibrationRejected",
    "CalibrationResult",
    "PointPair",
    "Transform2D",
    "calibrate",
    "fit_affine",
    "fit_homography",
    "map_button_centers",
]
