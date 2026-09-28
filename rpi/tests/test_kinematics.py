"""CoreXY 변환 — 보고서 C·D절 식만, 모르는 값은 거절.

**이 파일의 수치(R_out·톱니 수·피치·리밋·부호)는 전부 시험용 임의 값이다.**
실물 값이 아니며 설정 기본값으로 옮겨 쓰지 않는다.
"""

import math

import pytest

from rpi.controller.kinematics import (
    ENV_NAMES,
    CoreXYConfig,
    KinematicsNotConfigured,
    SoftLimitExceeded,
    belt_mm_to_counts,
    belt_resolution_mm_per_count,
    belt_to_xy,
    check_soft_limits,
    counts_to_belt_mm,
    motor_counts_to_xy,
    xy_to_belt,
    xy_to_motor_counts,
)

# 시험용 임의 값 — 실물 값 아님
TEST_ONLY = CoreXYConfig(
    counts_per_output_rev=1000.0,
    pulley_teeth=10,
    belt_pitch_mm=3.0,
    x_min_mm=0.0,
    x_max_mm=100.0,
    y_min_mm=-10.0,
    y_max_mm=50.0,
    a_sign=1,
    b_sign=-1,
)


def test_default_config_has_no_hardware_values():
    """기본값에 공칭 700이나 흔한 풀리·벨트 값이 숨어 있지 않다."""
    config = CoreXYConfig()
    assert all(getattr(config, name) is None for name in ENV_NAMES)


def test_corexy_forward_formula():
    assert xy_to_belt(3.0, 1.0) == (4.0, 2.0)
    assert xy_to_belt(0.0, 2.0) == (2.0, -2.0)


@pytest.mark.parametrize("dx, dy", [(0.0, 0.0), (12.5, -3.25), (-7.0, 40.0)])
def test_corexy_inverse_round_trips(dx, dy):
    assert belt_to_xy(*xy_to_belt(dx, dy)) == pytest.approx((dx, dy))


def test_counts_to_belt_follows_report_formula():
    # L = N / R_out * Z_p * p = 500 / 1000 * 10 * 3 = 15
    assert counts_to_belt_mm(500, TEST_ONLY) == pytest.approx(15.0)
    assert belt_mm_to_counts(15.0, TEST_ONLY) == pytest.approx(500.0)
    # res = Z_p * p / R_out = 30 / 1000
    assert belt_resolution_mm_per_count(TEST_ONLY) == pytest.approx(0.03)


def test_xy_to_motor_counts_applies_signs_and_round_trips():
    counts = xy_to_motor_counts(10.0, 5.0, TEST_ONLY)
    # ΔA = 15 mm → 500 counts, ΔB = 5 mm → 166.67 counts, b_sign = -1
    assert counts.a == pytest.approx(500.0)
    assert counts.b == pytest.approx(-5.0 / 30.0 * 1000.0)
    assert motor_counts_to_xy(counts.a, counts.b, TEST_ONLY) == pytest.approx((10.0, 5.0))


@pytest.mark.parametrize(
    "call",
    [
        lambda c: counts_to_belt_mm(1, c),
        lambda c: belt_mm_to_counts(1.0, c),
        lambda c: belt_resolution_mm_per_count(c),
        lambda c: xy_to_motor_counts(1.0, 1.0, c),
        lambda c: motor_counts_to_xy(1, 1, c),
        lambda c: check_soft_limits(0.0, 0.0, c),
    ],
)
def test_unset_config_refuses(call):
    with pytest.raises(KinematicsNotConfigured) as info:
        call(CoreXYConfig())
    assert info.value.missing
    # 메시지가 채워야 할 환경 변수 이름을 알려 준다
    assert any(ENV_NAMES[name] in str(info.value) for name in info.value.missing)


def test_partially_set_config_names_only_the_missing_fields():
    config = CoreXYConfig(counts_per_output_rev=1000.0, pulley_teeth=10)  # 시험용 값
    with pytest.raises(KinematicsNotConfigured) as info:
        belt_mm_to_counts(1.0, config)
    assert info.value.missing == ("belt_pitch_mm",)


def test_motor_counts_need_direction_signs():
    config = CoreXYConfig(counts_per_output_rev=1000.0, pulley_teeth=10, belt_pitch_mm=3.0)
    with pytest.raises(KinematicsNotConfigured) as info:
        xy_to_motor_counts(1.0, 1.0, config)
    assert set(info.value.missing) == {"a_sign", "b_sign"}


def test_soft_limits_accept_inside_and_refuse_outside():
    check_soft_limits(0.0, -10.0, TEST_ONLY)
    check_soft_limits(100.0, 50.0, TEST_ONLY)
    with pytest.raises(SoftLimitExceeded):
        check_soft_limits(100.01, 0.0, TEST_ONLY)
    with pytest.raises(SoftLimitExceeded):
        check_soft_limits(0.0, -10.5, TEST_ONLY)


@pytest.mark.parametrize(
    "kwargs",
    [
        {"counts_per_output_rev": 0.0},
        {"counts_per_output_rev": math.nan},
        {"pulley_teeth": 0},
        {"pulley_teeth": 2.5},
        {"belt_pitch_mm": -1.0},
        {"a_sign": 0},
        {"b_sign": True},
        {"x_min_mm": 10.0, "x_max_mm": 5.0},
        {"y_max_mm": math.inf},
    ],
)
def test_invalid_values_are_rejected(kwargs):
    with pytest.raises(ValueError):
        CoreXYConfig(**kwargs)


def test_from_env_leaves_unset_values_none_and_reads_given_ones():
    env = {"SIMPLELAY_MOTION_PULLEY_TEETH": "10", "SIMPLELAY_MOTION_B_SIGN": "-1", "SIMPLELAY_MOTION_R_OUT": " "}
    config = CoreXYConfig.from_env(env)
    assert config.pulley_teeth == 10
    assert config.b_sign == -1
    assert config.counts_per_output_rev is None
    assert config.belt_pitch_mm is None


def test_from_env_rejects_garbage():
    with pytest.raises(ValueError, match="SIMPLELAY_MOTION_BELT_PITCH_MM"):
        CoreXYConfig.from_env({"SIMPLELAY_MOTION_BELT_PITCH_MM": "2mm"})


def test_from_mapping_rejects_unknown_fields():
    with pytest.raises(ValueError):
        CoreXYConfig.from_mapping({"pulley_teeth": 10, "belt_pitch": 2.0})


def test_hardware_metadata_fields_are_optional_and_validated():
    """디코딩 배율·최대 rpm·정지 방식은 기본 None이고 변환 의미를 바꾸지 않는다."""
    from rpi.controller.kinematics import STOP_MODES
    config = CoreXYConfig()
    assert config.decoding_multiplier is None and config.max_rpm is None and config.stop_mode is None
    assert STOP_MODES == ("brake", "coast")
    assert "decoding_multiplier" not in config.missing_for_motion()
    for kwargs in ({"decoding_multiplier": 3}, {"decoding_multiplier": True}, {"max_rpm": 0},
                   {"max_rpm": float("nan")}, {"stop_mode": "hold"}):
        with pytest.raises(ValueError):
            CoreXYConfig(**kwargs)
    env = CoreXYConfig.from_env({"SIMPLELAY_MOTION_DECODING_MULTIPLIER": "2", "SIMPLELAY_MOTION_MAX_RPM": "150",
                                 "SIMPLELAY_MOTION_STOP_MODE": "COAST"})
    assert (env.decoding_multiplier, env.max_rpm, env.stop_mode) == (2, 150.0, "coast")
    # 배율은 기록용 — 변환은 여전히 배율 포함 실측 R_out만 쓴다.
    with_meta = CoreXYConfig(counts_per_output_rev=1000.0, pulley_teeth=10, belt_pitch_mm=3.0, decoding_multiplier=4)
    assert counts_to_belt_mm(500, with_meta) == pytest.approx(15.0)
