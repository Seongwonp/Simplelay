"""가전 **종류(category)** 계약.

앞 커밋(`ea92f02`)에서 나는 지금의 잘못된 동작을 그대로 assert 해두었다.
"재현 테스트"라고 이름 붙였지만, 남겨두면 결함을 명세로 못 박는 회귀
검사가 된다. 여기서는 **목표 계약**을 적는다.

계약:
- `appliance_id`는 설치된 **개별 기기**의 식별자다.
- `category`는 **종류**를 나타내는 안정적인 값이다. 둘은 다른 개념이다.
- 아이콘은 category에서 파생되는 표현 정보라 서버가 정하지 않는다.
- 같은 category를 여러 대 등록할 수 있다.
- 모르는 category는 오류가 아니라 `other`다.
- category가 없던 기존 정의는 데이터를 잃지 않고 `other`로 살아남는다.
"""

import pytest

from rpi.services.appliance_registry import (
    BUILTIN_APPLIANCES,
    ApplianceCategory,
    ApplianceDef,
    ApplianceRegistry,
)


@pytest.fixture()
def registry():
    return ApplianceRegistry()


def _custom(appliance_id: str, name: str, category: ApplianceCategory):
    return ApplianceDef(
        appliance_id=appliance_id,
        name=name,
        category=category,
        rows=2,
        cols=2,
        buttons=(),
        is_custom=True,
    )


# ── 식별자와 종류는 다른 개념이다 ─────────────────────────────────────────


def test_definition_carries_a_category():
    assert "category" in ApplianceDef.__dataclass_fields__


def test_same_category_can_be_installed_twice(registry):
    """거실 에어컨과 안방 에어컨은 **같은 종류의 다른 기기**다."""
    registry.register(_custom("a1", "거실 에어컨", ApplianceCategory.AIR_CONDITIONER))
    registry.register(_custom("a2", "안방 에어컨", ApplianceCategory.AIR_CONDITIONER))

    stored = {a.appliance_id: a for a in registry.list() if a.is_custom}

    assert set(stored) == {"a1", "a2"}
    assert stored["a1"].category is ApplianceCategory.AIR_CONDITIONER
    assert stored["a2"].category is ApplianceCategory.AIR_CONDITIONER
    assert stored["a1"].name != stored["a2"].name


def test_custom_appliances_keep_their_kind(registry):
    """예전에는 커스텀 가전이 전부 `icon="custom"`으로 저장돼 종류가
    사라졌다. 이제는 무엇으로 등록했는지가 남는다."""
    registry.register(_custom("w1", "우리집 세탁기", ApplianceCategory.WASHING_MACHINE))

    (stored,) = [a for a in registry.list() if a.appliance_id == "w1"]

    assert stored.category is ApplianceCategory.WASHING_MACHINE


# ── 모르는 값은 오류가 아니다 ─────────────────────────────────────────────


def test_unknown_category_falls_back_to_other():
    """앞선 버전의 폰이 새 종류를 보낼 수 있다. 거절하면 그 기기는 가전을
    등록할 수 없게 된다 -- 모르면 `other`로 받는다."""
    assert ApplianceCategory.parse("아직_없는_종류") is ApplianceCategory.OTHER
    assert ApplianceCategory.parse(None) is ApplianceCategory.OTHER
    assert ApplianceCategory.parse("") is ApplianceCategory.OTHER


def test_known_categories_round_trip():
    for category in ApplianceCategory:
        assert ApplianceCategory.parse(category.value) is category


# ── 마이그레이션 ──────────────────────────────────────────────────────────


def test_definition_without_category_survives_as_other():
    """category가 없던 시절의 정의도 데이터를 잃지 않는다."""
    legacy = ApplianceDef(
        appliance_id="custom_1",
        name="예전에 등록한 가전",
        rows=2,
        cols=2,
        buttons=(),
        is_custom=True,
    )

    assert legacy.name == "예전에 등록한 가전"
    assert legacy.category is ApplianceCategory.OTHER


# ── 내장 가전 ─────────────────────────────────────────────────────────────


def test_builtin_ids_are_not_categories():
    """내장 가전도 식별자와 종류를 따로 갖는다. 예전에는 `icon`이 곧
    `appliance_id`라 둘이 같은 개념으로 뭉개져 있었다."""
    for a in BUILTIN_APPLIANCES:
        assert isinstance(a.category, ApplianceCategory)
        assert a.category is not ApplianceCategory.OTHER


# ── 왕복 (폰 → 서버 → 키오스크) ───────────────────────────────────────────


def _client():
    from fastapi.testclient import TestClient

    import rpi.api.deps as deps
    from rpi.main import app

    for dep in (deps.get_appliance_registry, deps.get_service):
        dep.cache_clear()
    return TestClient(app)


def test_category_round_trips_through_the_api():
    """폰이 보낸 종류가 `GET /appliances`로 그대로 돌아온다 -- 키오스크도
    같은 목록을 읽으므로 두 화면이 같은 종류를 그린다."""
    client = _client()

    res = client.put(
        "/appliances/a1",
        json={
            "name": "거실 에어컨",
            "category": "air_conditioner",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )
    assert res.status_code == 200, res.text

    (stored,) = [a for a in client.get("/appliances").json() if a["id"] == "a1"]
    assert stored["category"] == "air_conditioner"
    # icon은 종류에서 파생한 호환 출력이라 따로 어긋날 수 없다.
    assert stored["icon"] == stored["category"]


def test_unknown_category_from_a_newer_phone_is_accepted_as_other():
    """앞선 버전의 폰이 새 종류를 보내도 등록을 거절하지 않는다."""
    client = _client()

    res = client.put(
        "/appliances/a2",
        json={
            "name": "미래의 가전",
            "category": "아직_없는_종류",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )

    assert res.status_code == 200, res.text
    (stored,) = [a for a in client.get("/appliances").json() if a["id"] == "a2"]
    assert stored["category"] == "other"
    assert stored["name"] == "미래의 가전"


def test_legacy_client_without_category_is_migrated_by_icon():
    """category를 모르는 구버전 폰은 icon만 보낸다. **명시적인 표로만**
    되살리고, 표에 없으면 other다 -- 이름으로 추측하지 않는다."""
    client = _client()

    client.put(
        "/appliances/old1",
        json={
            "name": "예전 에어컨",
            "icon": "aircon",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )
    client.put(
        "/appliances/old2",
        json={
            "name": "에어컨이라고 이름만 붙인 것",
            "icon": "custom",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )

    got = {a["id"]: a["category"] for a in client.get("/appliances").json()}
    assert got["old1"] == "air_conditioner"
    # "custom"은 종류를 담은 적이 없다. 이름에 에어컨이 있어도 추측하지 않는다.
    assert got["old2"] == "other"


def test_category_wins_when_it_contradicts_a_legacy_icon():
    """진실원천은 하나여야 한다. 둘이 어긋날 때 무엇을 믿을지 정해두지
    않으면 화면마다 다른 그림이 나온다."""
    client = _client()

    client.put(
        "/appliances/a3",
        json={
            "name": "세탁기",
            "category": "washing_machine",
            "icon": "microwave",  # 어긋난 값
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )

    (stored,) = [a for a in client.get("/appliances").json() if a["id"] == "a3"]
    assert stored["category"] == "washing_machine"
    # 파생 출력도 category를 따른다 -- 둘이 따로 놀 수 없다.
    assert stored["icon"] == "washing_machine"


def test_legacy_phone_without_category_still_registers():
    """구버전 폰은 category를 모른다. 거절하면 그 폰은 가전을 등록할 수
    없게 되므로, 받아 두고 other로 둔다."""
    client = _client()

    res = client.put(
        "/appliances/old3",
        json={
            "name": "이름만 있는 가전",
            "icon": "custom",
            "rows": 1,
            "cols": 1,
            "buttons": [{"id": "b1", "label": "전원", "x": 0, "y": 0}],
        },
    )

    assert res.status_code == 200, res.text
    (stored,) = [
        a for a in client.get("/appliances").json() if a["id"] == "old3"
    ]
    assert stored["category"] == "other"


def test_response_keeps_the_fields_an_old_phone_reads():
    """신버전 서버가 category를 더해도 구버전 폰의 파싱이 깨지지 않아야
    한다. 그 폰이 읽던 필드가 그대로 있고 뜻도 그대로인지 본다."""
    client = _client()

    (builtin,) = [
        a for a in client.get("/appliances").json() if a["id"] == "microwave"
    ]

    # 구버전 폰이 쓰던 필드들.
    for field in ("id", "name", "icon", "rows", "cols", "buttons"):
        assert field in builtin, field
    # icon은 여전히 문자열이고, 그 폰이 알던 값 그대로다.
    assert builtin["icon"] == "microwave"
