"""가전 **종류(category)** 가 폰 → 서버 → 키오스크로 왕복하지 않는 문제.

지금 서버는 `icon` 문자열 하나만 받는다. 폰은 내장 가전이면 그 자리에
`appliance_id`를 넣고, 커스텀 가전이면 `"custom"`을 넣는다. 그래서:

- **식별자와 종류가 같은 개념으로 뭉개진다.** 내장 가전은 id가 곧 종류다.
- 커스텀 가전은 종류가 통째로 사라진다 -- 사용자가 에어컨으로 등록했든
  세탁기로 등록했든 서버에는 `custom` 하나로 남는다.
- 그러니 같은 종류를 여러 대(거실 에어컨 / 안방 에어컨) 등록해도 화면이
  둘을 같은 것으로 그린다.

아래는 그 동작을 **재현**해서 못 박는 테스트다.
"""

import pytest

from rpi.services.appliance_registry import (
    BUILTIN_APPLIANCES,
    ApplianceDef,
    ApplianceRegistry,
)


@pytest.fixture()
def registry():
    return ApplianceRegistry()


# ── 내장 목록의 불일치 ────────────────────────────────────────────────────


def test_backend_builtins_do_not_include_the_aircon_the_phone_shows():
    """폰은 전자레인지·인덕션·**에어컨** 셋을 목록에 넣는데
    (app/lib/models/appliance.dart의 kAppliances), 서버는 둘뿐이다.

    사용자가 폰에서 에어컨을 고르면 서버는 그 가전을 모른다."""
    ids = {a.appliance_id for a in BUILTIN_APPLIANCES}

    assert ids == {"microwave", "induction"}
    assert "aircon" not in ids


# ── 종류가 식별자와 뭉개진다 ──────────────────────────────────────────────


def test_builtin_icon_is_just_the_id():
    """내장 가전은 `icon`이 곧 `appliance_id`다 -- 종류를 따로 말하는
    자리가 없다는 뜻이다."""
    for a in BUILTIN_APPLIANCES:
        assert a.icon == a.appliance_id


def test_custom_appliances_lose_their_kind(registry):
    """폰 편집기는 커스텀 가전에 `icon="custom"`을 보낸다
    (rpi_api_service.dart의 registerAppliance).

    사용자가 무엇으로 등록했든 서버에는 같은 값만 남는다."""
    living = ApplianceDef(
        appliance_id="custom_1",
        name="거실 에어컨",
        icon="custom",
        rows=2,
        cols=2,
        buttons=(),
        is_custom=True,
    )
    bed = ApplianceDef(
        appliance_id="custom_2",
        name="안방 에어컨",
        icon="custom",
        rows=2,
        cols=2,
        buttons=(),
        is_custom=True,
    )
    registry.register(living)
    registry.register(bed)

    stored = {a.appliance_id: a for a in registry.list() if a.is_custom}

    # id는 다르다 -- 여기까지는 맞다.
    assert set(stored) == {"custom_1", "custom_2"}
    # 그런데 **종류를 담은 자리가 없어서** 둘이 구분되지 않는다.
    assert stored["custom_1"].icon == stored["custom_2"].icon == "custom"
    assert not hasattr(living, "category")


def test_definition_has_no_category_field():
    """계약 자체에 종류가 없다. `icon`은 그림 힌트지 안정적인 종류가 아니다."""
    assert "category" not in ApplianceDef.__dataclass_fields__
    assert "icon" in ApplianceDef.__dataclass_fields__
