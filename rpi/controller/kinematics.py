"""CoreXY 좌표 ↔ 벨트 이동량 ↔ 엔코더 카운트 변환 (순수 함수, 하드웨어 없음).

근거 식은 하드웨어 기술 조사 보고서 C·D절의 것만 쓴다. 다른 식을 더하지 않는다.

    ΔA = ΔX + ΔY,  ΔB = ΔX − ΔY          (벨트 이동량, mm)
    ΔX = (ΔA + ΔB)/2,  ΔY = (ΔA − ΔB)/2
    n_out = N / R_out                      (카운트 → 출력축 회전수)
    L = n_out · Z_p · p                    (출력축 회전 → 벨트 mm)
    res_belt = Z_p · p / R_out             (mm/카운트)

**모르는 값은 모른다고 둔다.** R_out(디코딩 배율 포함 출력축 1회전당 카운트),
풀리 톱니 수 Z_p, 벨트 피치 p, XY 소프트 리밋, 모터 방향 부호는 전부 실측·제작자
제공 전이다. 그래서 `CoreXYConfig`의 모든 필드는 기본값이 None이고, 그 값이
필요한 변환은 `KinematicsNotConfigured`로 거절한다. 공식 공칭값 700(x1 기준)이나
"GT2 2 mm·20T" 같은 흔한 값을 기본값으로 넣지 않는다 — 보고서 D절이 금지한 일이다.

Z축은 회전→직선 변환 기구가 미정이라 여기서 mm 변환을 하지 않는다(보고서 D절).
Z는 모션 어댑터가 엔코더 카운트 그대로 다룬다.

부호 규약(어느 모터가 A인지, 정회전이 +인지)은 배선·엔코더 방향 실측으로 정한다
(보고서 C절). `a_sign`·`b_sign`이 그 결과를 담는다.
"""

from __future__ import annotations

import math
import os
from collections.abc import Mapping
from dataclasses import dataclass, fields


class KinematicsNotConfigured(RuntimeError):
    """변환에 필요한 하드웨어 값이 아직 설정되지 않았다.

    ``missing``은 비어 있는 설정 필드 이름들이다. 메시지에 환경 변수 이름을 함께
    적어 하드웨어 담당자가 무엇을 채워야 하는지 바로 알 수 있게 한다.
    """

    def __init__(self, operation: str, missing: tuple[str, ...]) -> None:
        self.operation = operation
        self.missing = missing
        env = ", ".join(ENV_NAMES[name] for name in missing)
        super().__init__(
            f"{operation}: 하드웨어 값이 설정되지 않아 거절합니다 — "
            f"미설정 {', '.join(missing)} (환경 변수 {env}). "
            "실측·제작자 제공 전에는 추정값을 넣지 않습니다"
        )


class SoftLimitExceeded(ValueError):
    """목표 좌표가 설정된 XY 소프트 리밋 밖이다. 이동 전에 거절한다."""


#: 설정 필드 → 환경 변수 이름. `CoreXYConfig.from_env()`와 오류 메시지가 같이 쓴다.
ENV_NAMES: dict[str, str] = {
    "counts_per_output_rev": "SIMPLELAY_MOTION_R_OUT",
    "pulley_teeth": "SIMPLELAY_MOTION_PULLEY_TEETH",
    "belt_pitch_mm": "SIMPLELAY_MOTION_BELT_PITCH_MM",
    "x_min_mm": "SIMPLELAY_MOTION_X_MIN_MM",
    "x_max_mm": "SIMPLELAY_MOTION_X_MAX_MM",
    "y_min_mm": "SIMPLELAY_MOTION_Y_MIN_MM",
    "y_max_mm": "SIMPLELAY_MOTION_Y_MAX_MM",
    "a_sign": "SIMPLELAY_MOTION_A_SIGN",
    "b_sign": "SIMPLELAY_MOTION_B_SIGN",
}

_BELT_FIELDS = ("counts_per_output_rev", "pulley_teeth", "belt_pitch_mm")
_SIGN_FIELDS = ("a_sign", "b_sign")
_LIMIT_FIELDS = ("x_min_mm", "x_max_mm", "y_min_mm", "y_max_mm")


@dataclass(frozen=True)
class CoreXYConfig:
    """CoreXY 기구 값. **전부 기본 None** — 채워지기 전에는 변환을 거절한다."""

    #: R_out — 출력축 1회전당 카운트, **디코딩 배율(x1/x2/x4) 포함 실측값**.
    #: 공식 공칭 700은 x1 기준이며 실측 전이라 기본값으로 쓰지 않는다.
    counts_per_output_rev: float | None = None
    #: Z_p — 구동 풀리 톱니 수 (제작자 제공).
    pulley_teeth: int | None = None
    #: p — 벨트 피치 mm (제작자 제공).
    belt_pitch_mm: float | None = None
    #: 원점 기준 XY 소프트 리밋(mm). 기구 이동 한계에서 여유를 뺀 값을 넣는다.
    x_min_mm: float | None = None
    x_max_mm: float | None = None
    y_min_mm: float | None = None
    y_max_mm: float | None = None
    #: 모터 A·B의 방향 부호(+1/−1). 벨트 +방향 이동일 때 엔코더 카운트가
    #: 증가하면 +1. 배선·엔코더 방향 실측으로 정한다.
    a_sign: int | None = None
    b_sign: int | None = None

    def __post_init__(self) -> None:
        for name in ("counts_per_output_rev", "belt_pitch_mm"):
            value = getattr(self, name)
            if value is not None and not (_finite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")
        if self.pulley_teeth is not None:
            if isinstance(self.pulley_teeth, bool) or not isinstance(self.pulley_teeth, int):
                raise ValueError(f"pulley_teeth는 정수여야 합니다: {self.pulley_teeth!r}")
            if self.pulley_teeth <= 0:
                raise ValueError(f"pulley_teeth는 1 이상이어야 합니다: {self.pulley_teeth!r}")
        for name in _LIMIT_FIELDS:
            value = getattr(self, name)
            if value is not None and not _finite(value):
                raise ValueError(f"{name}는 유한한 수여야 합니다: {value!r}")
        for low, high in (("x_min_mm", "x_max_mm"), ("y_min_mm", "y_max_mm")):
            lo, hi = getattr(self, low), getattr(self, high)
            if lo is not None and hi is not None and not lo < hi:
                raise ValueError(f"{low}({lo})는 {high}({hi})보다 작아야 합니다")
        for name in _SIGN_FIELDS:
            value = getattr(self, name)
            if value is not None and (isinstance(value, bool) or value not in (1, -1)):
                raise ValueError(f"{name}는 +1 또는 -1이어야 합니다: {value!r}")

    # ── 설정 상태 ────────────────────────────────────────────────────────────

    def missing(self, names: tuple[str, ...]) -> tuple[str, ...]:
        return tuple(name for name in names if getattr(self, name) is None)

    def missing_for_motion(self) -> tuple[str, ...]:
        """XY 이동 명령 하나를 만들기 위해 필요한데 비어 있는 필드."""
        return self.missing(_BELT_FIELDS + _SIGN_FIELDS + _LIMIT_FIELDS)

    def require(self, operation: str, names: tuple[str, ...]) -> None:
        missing = self.missing(names)
        if missing:
            raise KinematicsNotConfigured(operation, missing)

    # ── 생성 ─────────────────────────────────────────────────────────────────

    @classmethod
    def from_mapping(cls, values: Mapping[str, object]) -> "CoreXYConfig":
        known = {f.name for f in fields(cls)}
        unknown = sorted(set(values) - known)
        if unknown:
            raise ValueError(f"알 수 없는 CoreXY 설정 필드: {unknown}")
        return cls(**values)  # type: ignore[arg-type]

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "CoreXYConfig":
        """환경 변수에서 읽는다. 없거나 빈 값은 None으로 남긴다(추정값으로 채우지 않는다)."""
        source = os.environ if env is None else env
        values: dict[str, object] = {}
        for name, env_name in ENV_NAMES.items():
            raw = source.get(env_name, "").strip()
            if not raw:
                continue
            try:
                if name in ("pulley_teeth", "a_sign", "b_sign"):
                    values[name] = int(raw)
                else:
                    values[name] = float(raw)
            except ValueError as exc:
                raise ValueError(f"{env_name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
        return cls(**values)  # type: ignore[arg-type]


@dataclass(frozen=True)
class MotorCounts:
    """모터 A·B의 엔코더 카운트(부호 적용 뒤, 실수). 정수 반올림은 호출하는 쪽이 한다."""

    a: float
    b: float


# ── 식 (보고서 C·D절) ───────────────────────────────────────────────────────


def xy_to_belt(dx_mm: float, dy_mm: float) -> tuple[float, float]:
    """ΔA = ΔX + ΔY, ΔB = ΔX − ΔY. 기구 값이 필요 없는 순수 CoreXY 관계."""
    _require_finite(dx_mm, "dx_mm")
    _require_finite(dy_mm, "dy_mm")
    return dx_mm + dy_mm, dx_mm - dy_mm


def belt_to_xy(da_mm: float, db_mm: float) -> tuple[float, float]:
    """ΔX = (ΔA + ΔB)/2, ΔY = (ΔA − ΔB)/2."""
    _require_finite(da_mm, "da_mm")
    _require_finite(db_mm, "db_mm")
    return (da_mm + db_mm) / 2.0, (da_mm - db_mm) / 2.0


def belt_mm_per_rev(config: CoreXYConfig) -> float:
    """출력축 1회전당 벨트 이동(mm) = Z_p · p."""
    config.require("벨트 mm/회전 계산", ("pulley_teeth", "belt_pitch_mm"))
    return float(config.pulley_teeth) * float(config.belt_pitch_mm)  # type: ignore[arg-type]


def belt_resolution_mm_per_count(config: CoreXYConfig) -> float:
    """res_belt = Z_p · p / R_out."""
    config.require("벨트 분해능 계산", _BELT_FIELDS)
    return belt_mm_per_rev(config) / float(config.counts_per_output_rev)  # type: ignore[arg-type]


def counts_to_belt_mm(counts: float, config: CoreXYConfig) -> float:
    """L = (N / R_out) · Z_p · p."""
    _require_finite(counts, "counts")
    config.require("카운트 → 벨트 mm 변환", _BELT_FIELDS)
    n_out = counts / float(config.counts_per_output_rev)  # type: ignore[arg-type]
    return n_out * belt_mm_per_rev(config)


def belt_mm_to_counts(belt_mm: float, config: CoreXYConfig) -> float:
    """N = L / (Z_p · p) · R_out — 위 식의 역."""
    _require_finite(belt_mm, "belt_mm")
    config.require("벨트 mm → 카운트 변환", _BELT_FIELDS)
    return belt_mm / belt_mm_per_rev(config) * float(config.counts_per_output_rev)  # type: ignore[arg-type]


def xy_to_motor_counts(x_mm: float, y_mm: float, config: CoreXYConfig) -> MotorCounts:
    """XY 변위(mm) → 모터 A·B 엔코더 카운트(방향 부호 적용).

    원점 복귀 뒤 (0, 0) mm = (0, 0) 카운트로 두면 절대 좌표에도 그대로 쓴다.
    """
    config.require("XY → 모터 카운트 변환", _BELT_FIELDS + _SIGN_FIELDS)
    da, db = xy_to_belt(x_mm, y_mm)
    return MotorCounts(
        a=config.a_sign * belt_mm_to_counts(da, config),  # type: ignore[operator]
        b=config.b_sign * belt_mm_to_counts(db, config),  # type: ignore[operator]
    )


def motor_counts_to_xy(a_counts: float, b_counts: float, config: CoreXYConfig) -> tuple[float, float]:
    """모터 A·B 카운트(MCU 보고값) → XY(mm). `xy_to_motor_counts`의 역."""
    config.require("모터 카운트 → XY 변환", _BELT_FIELDS + _SIGN_FIELDS)
    da = counts_to_belt_mm(a_counts * config.a_sign, config)  # type: ignore[operator]
    db = counts_to_belt_mm(b_counts * config.b_sign, config)  # type: ignore[operator]
    return belt_to_xy(da, db)


def check_soft_limits(x_mm: float, y_mm: float, config: CoreXYConfig) -> None:
    """목표가 설정된 XY 소프트 리밋 안인지 본다. 리밋이 없으면 **거절**한다.

    리밋을 모르면 기구 끝에 부딪히는지 판단할 수 없다 — 그때는 움직이지 않는다.
    """
    config.require("XY 소프트 리밋 검사", _LIMIT_FIELDS)
    _require_finite(x_mm, "x_mm")
    _require_finite(y_mm, "y_mm")
    if not config.x_min_mm <= x_mm <= config.x_max_mm:  # type: ignore[operator]
        raise SoftLimitExceeded(
            f"x={x_mm:g} mm가 소프트 리밋 [{config.x_min_mm:g}, {config.x_max_mm:g}] 밖입니다"
        )
    if not config.y_min_mm <= y_mm <= config.y_max_mm:  # type: ignore[operator]
        raise SoftLimitExceeded(
            f"y={y_mm:g} mm가 소프트 리밋 [{config.y_min_mm:g}, {config.y_max_mm:g}] 밖입니다"
        )


def _finite(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _require_finite(value: float, label: str) -> None:
    if not _finite(value):
        raise ValueError(f"{label}는 유한한 수여야 합니다: {value!r}")
