"""보정 좌표 변환 — 대충 올려놓은 프레임의 장착 오차를 소프트웨어가 흡수한다.

사용자는 CoreXY 갠트리 프레임을 가전 조작부 위에 **대충** 올려놓는다. 몇 mm
밀리고 몇 도 돌아가 있는 것이 정상이다. 그래서 버튼 좌표를 mm로 박아 두지
않고, 설치할 때마다 다음 순서로 다시 맞춘다:

    원점 복귀 → 패널 촬영 → 기준점 검출 → **변환 맞춤 → 잔차 검증** → 버튼 좌표(mm) 기록

이 모듈은 굵게 쓴 두 단계와 마지막 적용만 맡는다. 카메라·검출은 여기 없다.

**왜 거절이 기본인가.** 변환이 틀리면 갠트리가 *엉뚱한 버튼을 누른다.*
폐루프 검증(전류·소리)이 잡아내더라도 그건 이미 누른 뒤다 — 세탁기의
'취소' 대신 '시작'을 눌렀다면 되돌릴 수 없다. 그래서 의심스러운 입력·결과는
변환을 돌려주지 않고 `CalibrationRejected`로 사유 문장과 함께 거절한다.
"대략 맞는 변환"을 조용히 쓰는 경로는 없다.

**affine vs homography.**

- affine(6 자유도): 회전·배율·전단·이동. 카메라가 패널을 거의 정면으로
  보거나, 기준점이 이미 패널 mm 좌표일 때 충분하다. 최소 3점.
- homography(8 자유도): 원근까지 흡수한다. 카메라가 비스듬히 볼 때.
  최소 4점. 자유도가 많은 만큼 잡음에도 더 끌려가므로 필요할 때만 쓴다.

**잔차 0은 검증이 아니다.** 최소 개수(affine 3점, homography 4점)로 맞추면
변환이 점을 정확히 지나가도록 풀리므로 잔차는 항상 0이다. 검출이 한 점을
잘못 찍어도 모른다. 잔차 검증이 의미를 가지려면 최소보다 많은 점이 필요하다
(`CalibrationResult.redundant_points`).

**여기 없는 것 (발표·인계 때 경계를 흐리지 않는다):**

- 카메라 촬영, 기준 마커 검출 — 입력 `PointPair`를 누가 만드는지는 모른다.
- 렌즈 왜곡 보정 — 광각 렌즈의 방사 왜곡은 homography로도 흡수되지 않는다.
  검출 단계에서 왜곡을 편 좌표를 넘겨야 한다.
- 갠트리 행정 한계 — 옮긴 버튼 좌표가 기계가 갈 수 있는 범위인지는 모션 층이 판정한다.
- 저장 — `version`은 `ApplianceReadiness.calibration_profile_version`에 넣을
  문자열을 만들 뿐, 프로파일을 어디에 남기는지는 이 모듈이 정하지 않는다.

임계값은 전부 **설계 초기값**이다. 실제 버튼 크기·검출 정밀도를 실측한 뒤
조정한다 (추측/측정 필요).
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from typing import Iterable, Mapping, Sequence

import numpy as np

#: 전체 잔차 RMS 상한(mm). 설계 초기값 — 실측 후 조정.
#: 가전 버튼은 대개 한 변 8 mm 이상이라, 평균 1 mm 어긋남이면 중심 근처는 누른다는 가정이다.
DEFAULT_MAX_RMS_MM = 1.0
#: 한 점 잔차 상한(mm). 설계 초기값 — 실측 후 조정.
#: RMS만 보면 점이 많을 때 한 점의 큰 오검출이 평균에 묻힌다. 그래서 따로 본다.
DEFAULT_MAX_POINT_ERROR_MM = 2.0
#: affine은 자유도 6 → 비공선 3점이 최소.
MIN_AFFINE_POINTS = 3
#: homography는 자유도 8 → 어느 셋도 한 직선에 있지 않은 4점이 최소.
MIN_HOMOGRAPHY_POINTS = 4

_KINDS = ("affine", "homography")
_MIN_POINTS = {"affine": MIN_AFFINE_POINTS, "homography": MIN_HOMOGRAPHY_POINTS}

#: 퇴화 판정 문턱(특이값 비). 좌표 단위(px, mm)와 무관하게 쓰려고 **비율**로 본다 --
#: 절대 면적으로 보면 px 입력에서는 멀쩡한 삼각형이, mm 입력에서는 퇴화로 읽힌다.
_DEGENERACY_TOL = 1e-6
#: 중복 판정 문턱 — 점 분포 크기에 대한 비율.
_DUPLICATE_TOL = 1e-9
#: |w| / ‖(u, v, w)‖ 가 이보다 작으면 무한대로 날아간 것으로 본다. 대략 옮긴 좌표가
#: 1e6 단위(mm면 1 km)를 넘는다는 뜻이라, 행정이 1 m도 안 되는 갠트리에서는 무한대와 같다.
_W_TOL = 1e-6
#: 버전 해시에 넣을 소수 자릿수. 부동소수 끝자리 잡음(1e-12 수준)이 버전을
#: 흔들지 않게 하려고 반올림한다. -0.0은 0.0으로 맞춘다.
_VERSION_DECIMALS = 9


class CalibrationRejected(ValueError):
    """이 기준점들로는 믿을 수 있는 변환을 만들 수 없다.

    메시지는 설치하는 사람에게 그대로 보여줄 수 있는 문장으로 쓴다 — '실패'만
    말하고 끝내면 무엇을 다시 찍어야 하는지 알 수 없다. 특정 점이 원인이면
    `point_index`(입력 순서, 0부터)를 함께 싣는다.
    """

    def __init__(self, message: str, *, point_index: int | None = None) -> None:
        super().__init__(message)
        self.point_index = point_index


@dataclass(frozen=True)
class PointPair:
    """기준점 하나의 대응 — 같은 물리 지점을 두 좌표계에서 본 값."""

    #: 패널/이미지 좌표 (px 또는 패널 mm)
    source: tuple[float, float]
    #: 갠트리 좌표 (mm)
    target: tuple[float, float]

    def __post_init__(self) -> None:
        # 모양만 여기서 맞춘다. nan/inf는 일부러 통과시킨다 -- 맞춤 단계에서
        # '몇 번째 점'인지 붙여 거절해야 설치하는 사람이 그 점을 다시 찍을 수 있다.
        object.__setattr__(self, "source", _as_xy(self.source, "source"))
        object.__setattr__(self, "target", _as_xy(self.target, "target"))


@dataclass(frozen=True)
class Transform2D:
    """3x3 동차 행렬로 표현한 평면 변환. 불변이다.

    불변인 이유: 이 행렬로 버전 문자열을 만들고, 그 버전이 실험 기록에 남는다.
    만든 뒤에 행렬이 바뀌면 기록된 버전과 실제로 누른 좌표가 어긋난다.
    """

    #: "affine" | "homography"
    kind: str
    #: 3x3, 행 우선. affine이면 마지막 행은 정확히 (0, 0, 1).
    matrix: tuple[tuple[float, float, float], ...]

    def __post_init__(self) -> None:
        if self.kind not in _KINDS:
            raise ValueError(f"알 수 없는 변환 종류입니다: {self.kind!r} (affine | homography)")
        m = np.asarray(self.matrix, dtype=float)
        if m.shape != (3, 3):
            raise ValueError(f"변환 행렬은 3x3이어야 합니다 (받은 모양: {m.shape})")
        if not np.all(np.isfinite(m)):
            raise ValueError("변환 행렬에 유한하지 않은 값이 있습니다")
        if self.kind == "affine":
            if not np.allclose(m[2], (0.0, 0.0, 1.0), rtol=0.0, atol=1e-12):
                raise ValueError("affine 행렬의 마지막 행은 (0, 0, 1)이어야 합니다")
            m[2] = (0.0, 0.0, 1.0)
        object.__setattr__(
            self,
            "matrix",
            tuple(tuple(float(v) for v in row) for row in m),
        )

    def as_array(self) -> np.ndarray:
        """계산용 사본. 사본이라 고쳐도 이 변환은 바뀌지 않는다."""
        return np.array(self.matrix, dtype=float)

    def apply(self, point: tuple[float, float]) -> tuple[float, float]:
        # 단일 점도 apply_many와 같은 경로를 탄다 -- 두 경로가 따로 있으면
        # 끝자리 반올림이 달라져 '같은 점인데 다른 좌표'가 생길 수 있다.
        return self.apply_many((point,))[0]

    def apply_many(self, points: Iterable[tuple[float, float]]) -> list[tuple[float, float]]:
        """여러 점을 한 번에 옮긴다.

        무한대로 날아가는 점(|w| ≈ 0)이나 유한하지 않은 입력은 `ValueError`.
        좌표 하나라도 믿을 수 없으면 목록 전체를 돌려주지 않는다.
        """
        pts = np.asarray(list(points), dtype=float)
        if pts.size == 0:
            return []
        pts = pts.reshape(-1, 2)
        if not np.all(np.isfinite(pts)):
            raise ValueError("유한하지 않은 좌표는 옮길 수 없습니다")
        homogeneous = np.column_stack([pts, np.ones(len(pts))]) @ self.as_array().T
        w = homogeneous[:, 2]
        norms = np.linalg.norm(homogeneous, axis=1)
        bad = np.flatnonzero(np.abs(w) <= _W_TOL * norms)
        if bad.size:
            i = int(bad[0])
            raise ValueError(
                f"{i}번째 점 ({pts[i, 0]:g}, {pts[i, 1]:g})이 무한대로 옮겨집니다 "
                "— 이 변환의 유효 범위 밖입니다"
            )
        mapped = homogeneous[:, :2] / w[:, None]
        return [(float(x), float(y)) for x, y in mapped]


@dataclass(frozen=True)
class CalibrationResult:
    """검증을 통과한 보정 결과. 이 객체가 있다는 것 자체가 '임계값 안'이라는 뜻이다."""

    transform: Transform2D
    point_count: int
    rms_error_mm: float
    max_error_mm: float
    #: 입력 순서대로 각 기준점의 잔차(mm) — 옮긴 source와 target 사이 거리.
    residuals_mm: tuple[float, ...]
    #: 결정적 버전 문자열: 종류 + 행렬 반올림 값의 sha256 앞 12자.
    #: 같은 입력 → 같은 버전. 어떤 보정에서 나온 성공률인지 기록에 남기는 용도다.
    version: str

    @property
    def redundant_points(self) -> int:
        """최소 개수보다 몇 점 더 썼나. 0이면 잔차가 항상 0이라 검증력이 없다."""
        return self.point_count - _MIN_POINTS[self.transform.kind]


def fit_affine(pairs: Sequence[PointPair]) -> Transform2D:
    """최소제곱 affine. 최소 3쌍, source가 한 직선 위에 있으면 거절.

    source 좌표를 먼저 정규화(중심 0, 평균 거리 √2)한 뒤 푼다 -- px 좌표가
    수백~수천이면 [x, y, 1] 열의 크기 차이로 조건수가 나빠지기 때문이다.
    """
    src, dst = _validated_arrays(pairs, "affine")
    _reject_collinear(src)

    t_src = _normalizing_matrix(src)
    src_n = _apply_h(t_src, src)
    design = np.column_stack([src_n, np.ones(len(src_n))])
    solution, *_ = np.linalg.lstsq(design, dst, rcond=None)  # (3, 2)

    normalized = np.array(
        [
            [solution[0, 0], solution[1, 0], solution[2, 0]],
            [solution[0, 1], solution[1, 1], solution[2, 1]],
            [0.0, 0.0, 1.0],
        ]
    )
    m = normalized @ t_src
    m[2] = (0.0, 0.0, 1.0)

    linear_sv = np.linalg.svd(m[:2, :2], compute_uv=False)
    if linear_sv[0] == 0.0 or linear_sv[1] / linear_sv[0] < _DEGENERACY_TOL:
        # source는 멀쩡한데 target이 한 직선으로 모였다 -- 갠트리 쪽 좌표가
        # 잘못 기록된 것이다. 이 변환은 평면을 선으로 뭉개므로 버튼을 구분하지 못한다.
        raise CalibrationRejected(
            "갠트리 좌표(target)가 한 직선 위로 모여 변환이 평면을 뭉갭니다 "
            "— 갠트리 쪽 기준점 기록을 확인해 주세요"
        )
    return Transform2D("affine", _to_tuple(m))


def fit_homography(pairs: Sequence[PointPair]) -> Transform2D:
    """정규화 DLT(Hartley)로 푼 homography. 최소 4쌍.

    정규화 없이 DLT를 풀면 px 좌표의 제곱항(x·u ~ 1e6)과 상수항(1)이 한 행렬에
    섞여 SVD 결과가 잡음에 크게 흔들린다. 그래서 source·target을 각각 중심 0,
    평균 거리 √2로 옮겨 풀고 되돌린다.

    거절: 점 배치가 해를 하나로 정하지 못할 때(4점 중 셋이 한 직선 등),
    풀린 행렬이 특이할 때, 입력 점 중 하나라도 무한대로 옮겨지거나 점들이
    소실선을 사이에 두고 갈릴 때(실제 카메라로 본 평면에서는 생기지 않는 배치).
    """
    src, dst = _validated_arrays(pairs, "homography")
    _reject_collinear(src)

    t_src = _normalizing_matrix(src)
    t_dst = _normalizing_matrix(dst)
    s = _apply_h(t_src, src)
    d = _apply_h(t_dst, dst)

    rows = []
    for (x, y), (u, v) in zip(s, d):
        rows.append([-x, -y, -1.0, 0.0, 0.0, 0.0, u * x, u * y, u])
        rows.append([0.0, 0.0, 0.0, -x, -y, -1.0, v * x, v * y, v])
    a = np.asarray(rows)
    _, sv, vt = np.linalg.svd(a)

    # 해 공간이 1차원이어야 해가 하나다. 두 번째로 작은 특이값(sv[7])까지 0이면
    # 해가 여럿 -- 4점 중 셋이 한 직선에 있는 경우가 대표적이다.
    if sv[0] == 0.0 or sv[7] / sv[0] < _DEGENERACY_TOL:
        raise CalibrationRejected(
            "기준점 배치로는 원근 변환을 하나로 정할 수 없습니다 "
            "(세 점 이상이 거의 한 직선 위에 있습니다) — 네 모서리에 고르게 퍼진 점을 써 주세요"
        )

    h_normalized = vt[-1].reshape(3, 3)
    h_sv = np.linalg.svd(h_normalized, compute_uv=False)
    if h_sv[0] == 0.0 or h_sv[2] / h_sv[0] < _DEGENERACY_TOL:
        raise CalibrationRejected(
            "풀린 원근 변환 행렬이 특이합니다 — 갠트리 좌표(target)가 한 직선 위로 "
            "모이지 않았는지 확인해 주세요"
        )

    h = np.linalg.inv(t_dst) @ h_normalized @ t_src
    h = _canonical_scale(h)

    homogeneous = np.column_stack([src, np.ones(len(src))]) @ h.T
    w = homogeneous[:, 2]
    ratios = np.abs(w) / np.linalg.norm(homogeneous, axis=1)
    worst = int(np.argmin(ratios))
    if ratios[worst] <= _W_TOL:
        raise CalibrationRejected(
            f"기준점 #{worst}이 무한대로 옮겨집니다 — 원근 변환이 성립하지 않는 배치입니다",
            point_index=worst,
        )
    if not (np.all(w > 0) or np.all(w < 0)):
        raise CalibrationRejected(
            "기준점들이 원근 변환의 소실선 양쪽으로 갈립니다 "
            "— 실제 패널 사진에서 나올 수 없는 배치라 검출 결과를 믿을 수 없습니다"
        )
    return Transform2D("homography", _to_tuple(h))


def calibrate(
    pairs: Sequence[PointPair],
    *,
    kind: str = "affine",
    max_rms_mm: float = DEFAULT_MAX_RMS_MM,
    max_point_error_mm: float = DEFAULT_MAX_POINT_ERROR_MM,
) -> CalibrationResult:
    """맞추고, 검증하고, 통과했을 때만 결과를 돌려준다.

    한 점 잔차 상한을 RMS보다 먼저 본다 -- 한 점이 튀는 경우가 가장 흔한
    실패(오검출)이고, 그때 필요한 정보는 '몇 번 점을 다시 찍어라'이기 때문이다.
    RMS로 거절할 때도 가장 나쁜 점을 함께 알려준다.
    """
    if kind not in _KINDS:
        raise CalibrationRejected(
            f"알 수 없는 변환 종류입니다: {kind!r} (affine | homography 중 하나)"
        )
    for name, value in (("max_rms_mm", max_rms_mm), ("max_point_error_mm", max_point_error_mm)):
        if not (isinstance(value, (int, float)) and math.isfinite(value) and value > 0):
            # 임계값이 잘못되면 모든 보정이 통과(또는 거절)된다. 호출부 실수라 보정 거절과 구분한다.
            raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")

    pairs = list(pairs)
    transform = fit_affine(pairs) if kind == "affine" else fit_homography(pairs)

    targets = np.asarray([p.target for p in pairs], dtype=float)
    mapped = np.asarray(transform.apply_many(p.source for p in pairs), dtype=float)
    residuals = np.linalg.norm(mapped - targets, axis=1)
    rms = float(math.sqrt(float(np.mean(residuals**2))))
    worst = int(np.argmax(residuals))
    worst_error = float(residuals[worst])

    if worst_error > max_point_error_mm:
        raise CalibrationRejected(
            f"기준점 #{worst}의 오차가 {worst_error:.2f} mm로 한 점 허용치 "
            f"{max_point_error_mm:.2f} mm를 넘습니다 — 이 점의 검출을 확인하고 다시 찍어 주세요",
            point_index=worst,
        )
    if rms > max_rms_mm:
        raise CalibrationRejected(
            f"전체 오차(RMS) {rms:.2f} mm가 허용치 {max_rms_mm:.2f} mm를 넘습니다 "
            f"— 가장 나쁜 점은 기준점 #{worst} ({worst_error:.2f} mm)입니다",
            point_index=worst,
        )

    return CalibrationResult(
        transform=transform,
        point_count=len(pairs),
        rms_error_mm=rms,
        max_error_mm=worst_error,
        residuals_mm=tuple(float(r) for r in residuals),
        version=_version_of(transform),
    )


def map_button_centers(
    result: CalibrationResult,
    centers: Mapping[str, tuple[float, float]],
) -> dict[str, tuple[float, float]]:
    """이름 붙은 버튼 중심(패널/이미지 좌표)을 갠트리 mm로 옮긴다. 키와 순서를 보존한다.

    하나라도 옮길 수 없으면 전부 거절한다 -- 일부만 기록하면 빠진 버튼을
    누르라는 명령이 옛 좌표로 나갈 수 있다.

    주의: 기준점이 감싼 영역 밖의 버튼은 외삽이라 잔차 검증의 보장을 받지 못한다.
    행정 한계 판정도 여기서 하지 않는다(모듈 머리말).
    """
    mapped: dict[str, tuple[float, float]] = {}
    for name, center in centers.items():
        try:
            xy = _as_xy(center, f"버튼 '{name}'")
        except ValueError as exc:
            raise CalibrationRejected(str(exc)) from exc
        if not all(math.isfinite(v) for v in xy):
            raise CalibrationRejected(f"버튼 '{name}'의 중심 좌표가 유한한 수가 아닙니다: {xy}")
        try:
            out = result.transform.apply(xy)
        except ValueError as exc:
            raise CalibrationRejected(f"버튼 '{name}'을 옮길 수 없습니다: {exc}") from exc
        mapped[name] = out
    return mapped


# ── 내부 도우미 ─────────────────────────────────────────────────────────────


def _as_xy(value: object, label: str) -> tuple[float, float]:
    try:
        items = tuple(value)  # type: ignore[arg-type]
    except TypeError:
        raise ValueError(f"{label} 좌표는 (x, y) 두 값이어야 합니다: {value!r}") from None
    if len(items) != 2:
        raise ValueError(f"{label} 좌표는 (x, y) 두 값이어야 합니다: {value!r}")
    return (float(items[0]), float(items[1]))


def _validated_arrays(
    pairs: Sequence[PointPair], kind: str
) -> tuple[np.ndarray, np.ndarray]:
    """개수 → 유한성 → 중복 순으로 본다. 앞의 거절 사유가 더 근본적이다."""
    pairs = list(pairs)
    for i, pair in enumerate(pairs):
        if not isinstance(pair, PointPair):
            raise TypeError(f"{i}번째 항목이 PointPair가 아닙니다: {type(pair).__name__}")

    minimum = _MIN_POINTS[kind]
    if len(pairs) < minimum:
        raise CalibrationRejected(
            f"{kind} 변환에는 기준점이 최소 {minimum}개 필요한데 {len(pairs)}개뿐입니다"
        )

    src = np.asarray([p.source for p in pairs], dtype=float)
    dst = np.asarray([p.target for p in pairs], dtype=float)
    finite = np.all(np.isfinite(src), axis=1) & np.all(np.isfinite(dst), axis=1)
    if not np.all(finite):
        i = int(np.flatnonzero(~finite)[0])
        raise CalibrationRejected(
            f"기준점 #{i}의 좌표가 유한한 수가 아닙니다 "
            f"(source={pairs[i].source}, target={pairs[i].target}) — 검출에 실패한 점입니다",
            point_index=i,
        )

    # 중복: 같은 source가 두 번이면 방정식 하나가 사라진다. 게다가 target이
    # 서로 다르면 '같은 지점이 두 곳에 있다'는 모순이라 검출 결과 자체를 믿을 수 없다.
    spread = float(np.max(np.linalg.norm(src - src.mean(axis=0), axis=1)))
    tolerance = _DUPLICATE_TOL * spread
    for i in range(len(src)):
        distances = np.linalg.norm(src[i + 1 :] - src[i], axis=1)
        close = np.flatnonzero(distances <= tolerance)
        if close.size:
            j = i + 1 + int(close[0])
            raise CalibrationRejected(
                f"기준점 #{i}와 #{j}의 패널 좌표(source)가 같습니다 — 같은 점을 두 번 검출했습니다",
                point_index=j,
            )
    return src, dst


def _reject_collinear(src: np.ndarray) -> None:
    """source가 (거의) 한 직선 위면 평면 변환이 정해지지 않는다.

    중심을 뺀 점들의 특이값 비(작은 것/큰 것)로 본다. 비율이라 좌표 단위와
    배율에 무관하다 -- 1 mm 크기 삼각형도, 2000 px 크기 삼각형도 같은 기준이다.
    """
    centered = src - src.mean(axis=0)
    sv = np.linalg.svd(centered, compute_uv=False)
    ratio = 0.0 if sv[0] == 0.0 else float(sv[1] / sv[0])
    if ratio < _DEGENERACY_TOL:
        raise CalibrationRejected(
            "기준점이 (거의) 한 직선 위에 있어 평면 변환을 정할 수 없습니다 "
            f"(특이값 비 {ratio:.1e} < {_DEGENERACY_TOL:.0e}) — 패널 전체에 퍼진 점을 써 주세요"
        )


def _normalizing_matrix(points: np.ndarray) -> np.ndarray:
    """Hartley 정규화: 중심을 원점으로, 원점까지 평균 거리를 √2로."""
    center = points.mean(axis=0)
    mean_distance = float(np.mean(np.linalg.norm(points - center, axis=1)))
    # 중복·공선 검사를 통과한 뒤에만 부르므로 0일 수 없다.
    scale = math.sqrt(2.0) / mean_distance
    return np.array(
        [
            [scale, 0.0, -scale * center[0]],
            [0.0, scale, -scale * center[1]],
            [0.0, 0.0, 1.0],
        ]
    )


def _apply_h(h: np.ndarray, points: np.ndarray) -> np.ndarray:
    homogeneous = np.column_stack([points, np.ones(len(points))]) @ h.T
    return homogeneous[:, :2] / homogeneous[:, 2:3]


def _canonical_scale(h: np.ndarray) -> np.ndarray:
    """동차 행렬은 배율이 자유라 같은 변환이 여러 행렬로 쓰인다. 버전이 결정적이려면
    하나로 고정해야 한다: h22 = 1. h22가 사실상 0이면(원점이 무한대로 가는 변환)
    Frobenius 노름 1 + 절댓값 최대 원소 양수로 고정한다."""
    frobenius = float(np.linalg.norm(h))
    if abs(h[2, 2]) > 1e-12 * frobenius:
        return h / h[2, 2]
    h = h / frobenius
    flat = h.ravel()
    if flat[int(np.argmax(np.abs(flat)))] < 0:
        h = -h
    return h


def _to_tuple(m: np.ndarray) -> tuple[tuple[float, float, float], ...]:
    return tuple(tuple(float(v) for v in row) for row in m)


def _version_of(transform: Transform2D) -> str:
    values = ",".join(
        f"{round(v, _VERSION_DECIMALS) + 0.0:.{_VERSION_DECIMALS}f}"
        for row in transform.matrix
        for v in row
    )
    payload = f"{transform.kind}:{values}".encode("ascii")
    return hashlib.sha256(payload).hexdigest()[:12]
