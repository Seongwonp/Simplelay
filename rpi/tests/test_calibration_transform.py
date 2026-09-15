"""자동 보정 좌표 변환 — 맞출 수 있는 것은 정확히, 믿을 수 없는 것은 거절.

프레임을 대충 올려놓아도 버튼을 정확히 누르려면 패널 좌표 → 갠트리 mm
변환이 필요하다. 그런데 변환이 틀리면 **갠트리가 엉뚱한 버튼을 누른다.**
그래서 두 방향을 같이 본다:

- 알려진 변환은 되찾는다 (affine·homography, 잡음 조금은 흡수).
- 점이 모자라거나, 한 줄로 서 있거나, 겹치거나, nan이거나, 한 점이 튀면
  변환을 돌려주지 않고 사유(몇 번 점인지까지)와 함께 거절한다.

잡음은 시드를 고정한다 — 실패가 재현되지 않는 테스트는 고칠 수 없다.
"""

from __future__ import annotations

import dataclasses
import math

import numpy as np
import pytest

from rpi.calibration import (
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

SEED = 20260915


def _affine_matrix(angle_deg: float, scale: float, tx: float, ty: float) -> np.ndarray:
    a = math.radians(angle_deg)
    c, s = math.cos(a) * scale, math.sin(a) * scale
    return np.array([[c, -s, tx], [s, c, ty], [0.0, 0.0, 1.0]])


# 카메라 px → 갠트리 mm: 3.5도 틀어지고, 0.25 mm/px, 몇 mm 밀린 설치.
KNOWN_AFFINE = _affine_matrix(3.5, 0.25, 41.3, -12.7)
# 비스듬히 본 카메라: 원근 성분이 들어간 변환.
KNOWN_HOMOGRAPHY = np.array(
    [
        [0.26, 0.012, 38.0],
        [-0.009, 0.31, -9.5],
        [1.2e-4, 2.5e-4, 1.0],
    ]
)


def _map(h: np.ndarray, point: tuple[float, float]) -> tuple[float, float]:
    u, v, w = h @ np.array([point[0], point[1], 1.0])
    return (u / w, v / w)


def _grid(cols: int = 4, rows: int = 3) -> list[tuple[float, float]]:
    """1280x960 이미지에 고르게 퍼진 기준점."""
    return [
        (80.0 + 1120.0 * i / (cols - 1), 60.0 + 840.0 * j / (rows - 1))
        for j in range(rows)
        for i in range(cols)
    ]


def _pairs(h: np.ndarray, sources, noise=None) -> list[PointPair]:
    pairs = []
    for k, src in enumerate(sources):
        tx, ty = _map(h, src)
        if noise is not None:
            tx, ty = tx + noise[k, 0], ty + noise[k, 1]
        pairs.append(PointPair(source=src, target=(tx, ty)))
    return pairs


def _max_abs_diff(t: Transform2D, expected: np.ndarray) -> float:
    return float(np.max(np.abs(t.as_array() - expected)))


# ── 되찾기 ──────────────────────────────────────────────────────────────────


def test_affine_recovers_known_rotation_scale_translation_exactly():
    result = calibrate(_pairs(KNOWN_AFFINE, _grid()), kind="affine")

    assert result.transform.kind == "affine"
    assert _max_abs_diff(result.transform, KNOWN_AFFINE) <= 1e-9
    assert result.point_count == 12
    assert max(result.residuals_mm) <= 1e-9
    assert result.rms_error_mm <= 1e-9
    assert result.max_error_mm <= 1e-9


def test_affine_with_exactly_three_points_has_no_redundancy():
    """최소 개수로 맞추면 잔차는 항상 0 — 검증력이 없다는 것을 결과가 드러낸다."""
    sources = [(100.0, 100.0), (1100.0, 150.0), (500.0, 900.0)]
    result = calibrate(_pairs(KNOWN_AFFINE, sources))

    assert _max_abs_diff(result.transform, KNOWN_AFFINE) <= 1e-9
    assert result.redundant_points == 0
    assert calibrate(_pairs(KNOWN_AFFINE, _grid())).redundant_points == 12 - MIN_AFFINE_POINTS


def test_homography_recovers_known_perspective_transform():
    result = calibrate(_pairs(KNOWN_HOMOGRAPHY, _grid()), kind="homography")

    assert result.transform.kind == "homography"
    # h22 = 1로 고정되므로 원소 단위로 비교할 수 있다.
    np.testing.assert_allclose(
        result.transform.as_array(), KNOWN_HOMOGRAPHY, rtol=1e-7, atol=1e-12
    )
    assert max(result.residuals_mm) <= 1e-7


def test_homography_recovers_from_exactly_four_points():
    sources = [(80.0, 60.0), (1200.0, 80.0), (1180.0, 900.0), (100.0, 880.0)]
    transform = fit_homography(_pairs(KNOWN_HOMOGRAPHY, sources))

    np.testing.assert_allclose(transform.as_array(), KNOWN_HOMOGRAPHY, rtol=1e-7, atol=1e-12)
    # 맞춘 점 밖(패널 중앙)도 같은 곳으로 간다.
    probe = (640.0, 480.0)
    assert transform.apply(probe) == pytest.approx(_map(KNOWN_HOMOGRAPHY, probe), abs=1e-7)


def test_affine_is_not_enough_for_strong_perspective():
    """원근이 큰 설치를 affine으로 억지로 맞추면 잔차 검증이 거절한다."""
    with pytest.raises(CalibrationRejected):
        calibrate(_pairs(KNOWN_HOMOGRAPHY, _grid()), kind="affine")


# ── 잡음과 튀는 점 ──────────────────────────────────────────────────────────


def test_small_seeded_noise_passes_under_threshold():
    rng = np.random.default_rng(SEED)
    sources = _grid()
    noise = rng.normal(0.0, 0.2, size=(len(sources), 2))

    result = calibrate(_pairs(KNOWN_AFFINE, sources, noise), kind="affine")

    assert 0.0 < result.rms_error_mm < DEFAULT_MAX_RMS_MM
    assert result.max_error_mm < DEFAULT_MAX_POINT_ERROR_MM
    assert len(result.residuals_mm) == len(sources)
    # 잡음이 σ=0.2 mm인데 변환이 크게 벗어나면 안 된다: 패널 중앙에서 0.3 mm 이내.
    center = (640.0, 480.0)
    got = result.transform.apply(center)
    want = _map(KNOWN_AFFINE, center)
    assert math.dist(got, want) < 0.3


def test_small_seeded_noise_passes_for_homography():
    rng = np.random.default_rng(SEED)
    sources = _grid(5, 4)
    noise = rng.normal(0.0, 0.2, size=(len(sources), 2))

    result = calibrate(_pairs(KNOWN_HOMOGRAPHY, sources, noise), kind="homography")

    assert result.rms_error_mm < DEFAULT_MAX_RMS_MM
    assert result.max_error_mm < DEFAULT_MAX_POINT_ERROR_MM


def test_one_large_outlier_is_rejected_and_named():
    rng = np.random.default_rng(SEED)
    sources = _grid()
    noise = rng.normal(0.0, 0.2, size=(len(sources), 2))
    outlier = 7
    noise[outlier] += (6.0, -4.0)  # 검출이 한 점을 7 mm 넘게 잘못 찍었다

    with pytest.raises(CalibrationRejected) as info:
        calibrate(_pairs(KNOWN_AFFINE, sources, noise), kind="affine")

    message = str(info.value)
    assert f"#{outlier}" in message
    assert "mm" in message
    assert info.value.point_index == outlier


def test_rms_rejection_also_names_worst_point():
    rng = np.random.default_rng(SEED)
    sources = _grid()
    noise = rng.normal(0.0, 0.2, size=(len(sources), 2))
    noise[3] += (2.0, 0.0)

    # 한 점 상한은 넉넉하게 두고 RMS 상한만 조여서 RMS 경로를 탄다.
    with pytest.raises(CalibrationRejected) as info:
        calibrate(
            _pairs(KNOWN_AFFINE, sources, noise),
            max_rms_mm=0.3,
            max_point_error_mm=50.0,
        )

    assert "RMS" in str(info.value)
    assert "#3" in str(info.value)
    assert info.value.point_index == 3


# ── 거절 ────────────────────────────────────────────────────────────────────


def test_too_few_points_are_rejected():
    two = _pairs(KNOWN_AFFINE, [(0.0, 0.0), (100.0, 0.0)])
    three = _pairs(KNOWN_HOMOGRAPHY, [(0.0, 0.0), (100.0, 0.0), (0.0, 100.0)])

    with pytest.raises(CalibrationRejected, match=str(MIN_AFFINE_POINTS)):
        calibrate(two, kind="affine")
    with pytest.raises(CalibrationRejected, match=str(MIN_HOMOGRAPHY_POINTS)):
        calibrate(three, kind="homography")
    with pytest.raises(CalibrationRejected):
        fit_affine([])


def test_collinear_points_are_rejected():
    line = [(0.0, 0.0), (100.0, 50.0), (200.0, 100.0), (300.0, 150.0)]
    with pytest.raises(CalibrationRejected, match="직선"):
        calibrate(_pairs(KNOWN_AFFINE, line), kind="affine")
    with pytest.raises(CalibrationRejected, match="직선"):
        calibrate(_pairs(KNOWN_HOMOGRAPHY, line), kind="homography")


def test_nearly_collinear_points_are_rejected():
    almost = [(0.0, 0.0), (1000.0, 1000.0), (500.0, 500.0 + 1e-7)]
    with pytest.raises(CalibrationRejected, match="직선"):
        fit_affine(_pairs(KNOWN_AFFINE, almost))


def test_collinearity_test_is_scale_aware():
    """1 mm 크기 삼각형은 작을 뿐 퇴화가 아니다 — 절대 면적으로 판정하면 틀린다."""
    tiny = [(0.0, 0.0), (1e-3, 0.0), (0.0, 1e-3)]
    transform = fit_affine(_pairs(KNOWN_AFFINE, tiny))
    np.testing.assert_allclose(transform.as_array(), KNOWN_AFFINE, atol=1e-6)


def test_homography_rejects_three_of_four_collinear():
    sources = [(0.0, 0.0), (500.0, 0.0), (1000.0, 0.0), (500.0, 800.0)]
    with pytest.raises(CalibrationRejected):
        fit_homography(_pairs(KNOWN_HOMOGRAPHY, sources))


def test_collinear_targets_are_rejected():
    """source는 멀쩡해도 갠트리 쪽이 한 줄로 기록되면 변환이 평면을 뭉갠다."""
    sources = [(0.0, 0.0), (100.0, 0.0), (0.0, 100.0), (100.0, 100.0)]
    targets = [(10.0, 10.0), (20.0, 20.0), (30.0, 30.0), (40.0, 40.0)]
    pairs = [PointPair(s, t) for s, t in zip(sources, targets)]

    with pytest.raises(CalibrationRejected):
        fit_affine(pairs)
    with pytest.raises(CalibrationRejected):
        fit_homography(pairs)


def test_duplicate_source_points_are_rejected():
    sources = [(100.0, 100.0), (900.0, 120.0), (100.0, 100.0), (500.0, 800.0)]
    pairs = _pairs(KNOWN_AFFINE, sources)

    with pytest.raises(CalibrationRejected, match="#0.*#2") as info:
        calibrate(pairs)
    assert info.value.point_index == 2


@pytest.mark.parametrize(
    "bad",
    [
        PointPair((float("nan"), 10.0), (1.0, 2.0)),
        PointPair((10.0, 20.0), (float("inf"), 2.0)),
        PointPair((10.0, 20.0), (1.0, float("-inf"))),
    ],
)
def test_non_finite_input_is_rejected(bad):
    pairs = _pairs(KNOWN_AFFINE, _grid())
    pairs[5] = bad

    with pytest.raises(CalibrationRejected, match="#5") as info:
        calibrate(pairs)
    assert info.value.point_index == 5


def test_unknown_kind_is_rejected():
    with pytest.raises(CalibrationRejected, match="projective"):
        calibrate(_pairs(KNOWN_AFFINE, _grid()), kind="projective")


def test_invalid_thresholds_are_caller_errors():
    pairs = _pairs(KNOWN_AFFINE, _grid())
    with pytest.raises(ValueError):
        calibrate(pairs, max_rms_mm=0.0)
    with pytest.raises(ValueError):
        calibrate(pairs, max_point_error_mm=float("nan"))


# ── 버전 ────────────────────────────────────────────────────────────────────


def test_version_is_deterministic_and_tracks_the_transform():
    first = calibrate(_pairs(KNOWN_AFFINE, _grid()))
    again = calibrate(_pairs(KNOWN_AFFINE, _grid()))
    shifted = calibrate(_pairs(_affine_matrix(3.5, 0.25, 41.3 + 0.5, -12.7), _grid()))

    assert first.version == again.version
    assert len(first.version) == 12
    assert all(ch in "0123456789abcdef" for ch in first.version)
    assert shifted.version != first.version


def test_version_distinguishes_kind():
    """같은 행렬이라도 어떤 모델로 맞췄는지는 다른 보정이다."""
    pairs = _pairs(KNOWN_AFFINE, _grid())
    assert calibrate(pairs, kind="affine").version != calibrate(pairs, kind="homography").version


# ── 적용 ────────────────────────────────────────────────────────────────────


def test_map_button_centers_maps_named_centers_and_preserves_keys():
    result = calibrate(_pairs(KNOWN_AFFINE, _grid()))
    centers = {
        "power": (210.0, 140.0),
        "start": (640.0, 480.0),
        "cancel": (1010.0, 820.0),
    }

    mapped = map_button_centers(result, centers)

    assert list(mapped) == list(centers)
    for name, center in centers.items():
        assert mapped[name] == pytest.approx(_map(KNOWN_AFFINE, center), abs=1e-9)
        assert all(isinstance(v, float) for v in mapped[name])


def test_map_button_centers_rejects_unmappable_button_by_name():
    result = calibrate(_pairs(KNOWN_AFFINE, _grid()))
    with pytest.raises(CalibrationRejected, match="start"):
        map_button_centers(result, {"power": (1.0, 2.0), "start": (float("nan"), 3.0)})


def test_homography_point_at_infinity_is_not_mapped():
    # 소실선 x = 1000 위의 점은 무한대로 간다.
    transform = Transform2D(
        "homography", ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (-0.001, 0.0, 1.0))
    )
    with pytest.raises(ValueError, match="무한대"):
        transform.apply((1000.0, 20.0))

    result = CalibrationResult(transform, 4, 0.0, 0.0, (0.0,) * 4, "000000000000")
    with pytest.raises(CalibrationRejected, match="horizon_button"):
        map_button_centers(result, {"horizon_button": (1000.0, 20.0)})


# ── 불변성 ──────────────────────────────────────────────────────────────────


def test_transform_is_immutable_and_apply_many_matches_apply():
    result = calibrate(_pairs(KNOWN_HOMOGRAPHY, _grid()), kind="homography")
    transform = result.transform

    with pytest.raises(dataclasses.FrozenInstanceError):
        transform.kind = "affine"  # type: ignore[misc]
    with pytest.raises(dataclasses.FrozenInstanceError):
        transform.matrix = ((1.0, 0.0, 0.0),) * 3  # type: ignore[misc]
    with pytest.raises(dataclasses.FrozenInstanceError):
        result.version = "tampered"  # type: ignore[misc]
    assert isinstance(transform.matrix, tuple)
    assert all(isinstance(row, tuple) for row in transform.matrix)

    # 계산용 사본을 고쳐도 변환은 그대로다.
    copy = transform.as_array()
    copy[0, 2] += 100.0
    assert transform.matrix[0][2] != copy[0, 2]

    points = [(0.0, 0.0), (640.0, 480.0), (1279.0, 959.0), (33.3, 777.7)]
    assert transform.apply_many(points) == [transform.apply(p) for p in points]
    assert transform.apply_many([]) == []


def test_transform_constructor_normalizes_and_validates():
    t = Transform2D("affine", [[1, 0, 5], [0, 1, 7], [0, 0, 1]])
    assert t.matrix == ((1.0, 0.0, 5.0), (0.0, 1.0, 7.0), (0.0, 0.0, 1.0))
    assert t.apply((1.0, 1.0)) == (6.0, 8.0)

    with pytest.raises(ValueError):
        Transform2D("affine", ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.1, 0.0, 1.0)))
    with pytest.raises(ValueError):
        Transform2D("similarity", ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)))
    with pytest.raises(ValueError):
        Transform2D("affine", ((1.0, 0.0), (0.0, 1.0)))


def test_point_pair_is_frozen_and_coerced_to_float_tuples():
    pair = PointPair([1, 2], np.array([3.5, 4.5]))
    assert pair.source == (1.0, 2.0)
    assert pair.target == (3.5, 4.5)
    assert all(type(v) is float for v in pair.source + pair.target)
    with pytest.raises(dataclasses.FrozenInstanceError):
        pair.source = (0.0, 0.0)  # type: ignore[misc]
    with pytest.raises(ValueError):
        PointPair((1.0, 2.0, 3.0), (0.0, 0.0))
