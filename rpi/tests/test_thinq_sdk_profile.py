"""ThinQ 프로필 판정·오류 코드 표 (2026-10-13, 단계 1).

- 프로필 판정(``rpi.services.thinq.profile``)은 SDK 없이도 돈다 -- 기본 설치·기본 시험용.
- 공식 SDK(``thinqconnect==1.0.14``, extra ``thinq``)가 설치돼 있으면 같은 샘플을 SDK의
  프로필 클래스에 넣어 **판정이 같은지** 대조하고, 오류 코드 표가 SDK 열거형과 같은지 본다.
  SDK가 없으면 그 대조만 건너뛴다(실패가 아니다).

샘플 프로필은 SDK 저장소의 공개 형식(``property.<resource>.<prop>.{type, mode, value.{r,w}}``)을
따른 **예시**다. 구매 예정 공기청정기(AS186HWWA)의 실제 프로필은 아직 확인하지 않았다.
"""

from __future__ import annotations

import pytest

from rpi.services.thinq.errors import (
    API_ERROR_CODES,
    API_ERROR_REASONS,
    error_from_api,
)
from rpi.services.thinq.client import (
    ThinqCommandRejected,
    ThinqOfflineError,
    ThinqTransportError,
)
from rpi.services.thinq.profile import DeviceProfile
from rpi.services.thinq.profiles_sample import (
    air_purifier_profile,
    dehumidifier_profile,
    washer_profile,
)


# ── 프로필 판정 (SDK 없이) ────────────────────────────────────────────────


def test_enum_property_writable_only_for_listed_values():
    profile = DeviceProfile(air_purifier_profile())
    spec = profile.spec("airFlow", "windStrength")
    assert spec is not None and spec.readable and spec.writable
    assert spec.accepts("HIGH")
    assert not spec.accepts("TURBO")


def test_property_missing_from_profile_is_none_and_never_writable():
    profile = DeviceProfile(air_purifier_profile(job_modes_w=("CLEAN", "SLEEP")))
    assert profile.spec("airFlow", "windStrengthLevel") is None
    assert profile.spec("timer", "absoluteHourToStart") is None
    job = profile.spec("airPurifierJobMode", "currentJobMode")
    assert job.accepts("SLEEP") and not job.accepts("SILENT")


def test_read_only_property_is_not_writable():
    profile = DeviceProfile(air_purifier_profile())
    pm = profile.spec("airQualitySensor", "PM2")
    assert pm is not None and pm.readable and not pm.writable
    assert not pm.accepts(10)


def test_preferred_key_follows_sdk_order():
    """SDK는 airFlow에 windStrengthDetail이 있으면 그것을 먼저 쓴다(_get_preferred_property_key)."""
    plain = DeviceProfile(air_purifier_profile())
    detail = DeviceProfile(air_purifier_profile(wind_key="windStrengthDetail"))
    keys = ("windStrengthDetail", "windStrength")
    assert plain.resolve_key("airFlow", keys) == "windStrength"
    assert detail.resolve_key("airFlow", keys) == "windStrengthDetail"
    assert plain.resolve_key("airFlow", ("nothing",)) is None


def test_washer_profile_is_per_location_and_operation_is_write_only():
    profile = DeviceProfile(washer_profile())
    assert profile.locations == ("MAIN",)
    op = profile.spec("operation", "washerOperationMode", location="MAIN")
    assert op.writable and not op.readable
    assert op.accepts("START") and op.accepts("STOP") and not op.accepts("SPIN_ONLY")
    remote = profile.spec("remoteControlEnable", "remoteControlEnabled", location="MAIN")
    assert remote.readable and not remote.writable
    # 다른 위치는 없다.
    assert profile.spec("operation", "washerOperationMode", location="MINI") is None


def test_range_property_checks_min_max_step():
    profile = DeviceProfile(dehumidifier_profile())
    target = profile.spec("humidity", "targetHumidity")
    assert target.accepts(40) and target.accepts(50)
    assert not target.accepts(42)  # step 5
    assert not target.accepts(75)
    assert not target.accepts("40")


def test_garbage_profile_is_empty_not_crash():
    for raw in (None, {}, {"property": None}, {"property": "x"}, [1, 2]):
        profile = DeviceProfile(raw)
        assert profile.spec("operation", "airPurifierOperationMode") is None


# ── 오류 코드 → 사람 말 ────────────────────────────────────────────────────


@pytest.mark.parametrize("name, kind", [
    ("INVALID_TOKEN", ThinqCommandRejected),
    ("NOT_ACCEPTABLE_TERMS", ThinqCommandRejected),
    ("NOT_ALLOWED_API_AGAIN", ThinqCommandRejected),
    ("NOT_SUPPORTED_COUNTRY", ThinqCommandRejected),
    ("EXCEEDED_API_CALLS", ThinqCommandRejected),
    ("COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF", ThinqCommandRejected),
    ("NOT_CONNECTED_DEVICE", ThinqOfflineError),
    ("DEVICE_RESPONSE_DELAY", ThinqTransportError),
    ("INTERNAL_SERVER_ERROR", ThinqTransportError),
])
def test_api_error_maps_to_kind_and_human_reason(name, kind):
    err = error_from_api(API_ERROR_CODES[name], name)
    assert isinstance(err, kind)
    assert err.name == name and err.code == API_ERROR_CODES[name]
    assert err.reason == API_ERROR_REASONS[name]
    # 사람 말이다 -- 코드 이름 그대로가 아니다.
    assert name not in err.reason and any("가" <= ch <= "힣" for ch in err.reason)


def test_specific_reasons_say_what_to_do():
    assert "PAT" in API_ERROR_REASONS["INVALID_TOKEN"]
    assert "약관" in API_ERROR_REASONS["NOT_ACCEPTABLE_TERMS"]
    assert "국가" in API_ERROR_REASONS["NOT_SUPPORTED_COUNTRY"]
    assert "한도" in API_ERROR_REASONS["EXCEEDED_API_CALLS"]
    assert "원격" in API_ERROR_REASONS["COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF"]


def test_unknown_code_is_not_called_a_rejection():
    """모르는 코드는 '실행 안 됨'이라고 단정하지 않는다 -- 제어였다면 접수 불명이다."""
    for name in (None, "UNKNOWN_ERROR"):  # SDK는 모르는 코드에 UNKNOWN_ERROR를 붙인다
        err = error_from_api("9999", name)
        assert isinstance(err, ThinqTransportError)
        assert "9999" in err.reason and "몰라요" in err.reason


# ── 공식 SDK와 대조 (설치돼 있을 때만) ─────────────────────────────────────


def test_error_table_matches_sdk_enum():
    sdk = pytest.importorskip("thinqconnect")
    codes = {m.name: m.value for m in sdk.ThinQAPIErrorCodes}
    for name, code in API_ERROR_CODES.items():
        assert codes.get(name) == code, name
    for name in API_ERROR_REASONS:
        assert name in codes, name


def test_profile_judgement_matches_sdk_profile_classes():
    pytest.importorskip("thinqconnect")
    from thinqconnect.devices.air_purifier import AirPurifierProfile
    from thinqconnect.devices.const import Property
    from thinqconnect.devices.washer import WasherProfile

    raw = air_purifier_profile(job_modes_w=("CLEAN", "SLEEP"))
    ours = DeviceProfile(raw)
    sdk = AirPurifierProfile(raw)
    for value in ("CLEAN", "SLEEP", "SILENT", "AUTO", "TURBO"):
        assert sdk.check_enum_attribute_writable(Property.CURRENT_JOB_MODE, value) == ours.spec(
            "airPurifierJobMode", "currentJobMode").accepts(value), value
    for value in ("LOW", "MID", "HIGH", "AUTO", "TURBO"):
        assert sdk.check_enum_attribute_writable(Property.WIND_STRENGTH, value) == ours.spec(
            "airFlow", "windStrength").accepts(value), value
    assert sdk.get_enum_attribute_payload(Property.WIND_STRENGTH, "HIGH") == {
        "airFlow": {"windStrength": "HIGH"}}

    # windStrengthDetail이 있으면 SDK도 그 키로 payload를 만든다.
    detail = AirPurifierProfile(air_purifier_profile(wind_key="windStrengthDetail"))
    assert detail.get_enum_attribute_payload(Property.WIND_STRENGTH, "HIGH") == {
        "airFlow": {"windStrengthDetail": "HIGH"}}

    washer = WasherProfile(washer_profile())
    main = washer.get_sub_profile("main")
    assert main is not None
    ours_w = DeviceProfile(washer_profile())
    for value in ("START", "STOP", "SPIN_ONLY"):
        assert main.check_enum_attribute_writable(Property.WASHER_OPERATION_MODE, value) == ours_w.spec(
            "operation", "washerOperationMode", location="MAIN").accepts(value), value
    assert main.check_attribute_writable(Property.REMOTE_CONTROL_ENABLED) is False
