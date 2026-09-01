"""가전 정의의 단일 진실원천 — 내장 가전 + 폰에서 등록한 커스텀 가전.

그동안 가전 정의가 다섯 곳(백엔드 button-maps JSON, 폰 하드코딩, 폰
SharedPreferences 커스텀, 키오스크 하드코딩, 자연어 규칙)에 흩어져 있었다.
그 결과 폰에서 가전을 추가해도 키오스크는 모르고, 버튼 하나 바꾸려면 다섯
파일을 맞춰야 했다(8/31 코스 교체 때 실제로 그랬다).

이 레지스트리가 서버 쪽 진실원천이 된다:
- 내장 가전(전자레인지·인덕션)은 여기 상수로 정의 — docs/button-maps와의
  일치는 테스트가 고정한다.
- 커스텀 가전은 폰 편집기가 ``PUT /appliances/{id}``로 등록하고, SQLite에
  영속돼 재시작에도 유지된다.
- 키오스크·폰은 ``GET /appliances``로 같은 목록을 받는다 — 폰에서 추가하면
  키오스크에도 뜬다.

클라이언트 하드코딩은 서버가 죽었을 때의 폴백으로만 남는다(오프라인 우선).
"""

from __future__ import annotations

import threading
from dataclasses import dataclass


class BuiltinApplianceError(ValueError):
    """내장 가전을 덮어쓰거나 지우려 할 때."""


@dataclass(frozen=True)
class ApplianceButtonDef:
    id: str
    label: str
    x: int
    y: int


@dataclass(frozen=True)
class ApplianceDef:
    appliance_id: str
    name: str
    # 클라이언트가 아이콘을 고르는 힌트 문자열("microwave"/"induction"/…).
    # 모르는 값이면 클라이언트가 기본 아이콘을 쓴다 — 서버는 그림을 모른다.
    icon: str
    rows: int
    cols: int
    buttons: tuple[ApplianceButtonDef, ...]
    is_custom: bool = False


# ── 내장 가전 — docs/button-maps/*.json과의 일치를 테스트가 고정한다 ─────────
BUILTIN_MICROWAVE = ApplianceDef(
    appliance_id="microwave",
    name="전자레인지",
    icon="microwave",
    rows=4,
    cols=3,
    buttons=(
        ApplianceButtonDef("BT-01", "10초", 0, 0),
        ApplianceButtonDef("BT-02", "30초", 1, 0),
        ApplianceButtonDef("BT-03", "1분", 2, 0),
        ApplianceButtonDef("BT-04", "5분", 0, 1),
        ApplianceButtonDef("BT-10", "라면", 1, 1),
        ApplianceButtonDef("BT-07", "해동", 0, 2),
        ApplianceButtonDef("BT-08", "즉석밥", 1, 2),
        ApplianceButtonDef("BT-09", "냉동식품", 2, 2),
        ApplianceButtonDef("BT-06", "취소", 1, 3),
        ApplianceButtonDef("BT-05", "시작", 2, 3),
    ),
)

BUILTIN_INDUCTION = ApplianceDef(
    appliance_id="induction",
    name="인덕션",
    icon="induction",
    rows=3,
    cols=4,
    buttons=(
        ApplianceButtonDef("IN-01", "전원", 0, 0),
        ApplianceButtonDef("IN-02", "화력+", 1, 0),
        ApplianceButtonDef("IN-03", "화력-", 2, 0),
        ApplianceButtonDef("IN-04", "타이머", 3, 0),
        ApplianceButtonDef("IN-05", "1단", 0, 1),
        ApplianceButtonDef("IN-06", "3단", 1, 1),
        ApplianceButtonDef("IN-07", "5단", 2, 1),
        ApplianceButtonDef("IN-08", "보온", 3, 1),
        ApplianceButtonDef("IN-09", "시작", 2, 2),
        ApplianceButtonDef("IN-10", "취소", 3, 2),
    ),
)

BUILTIN_APPLIANCES: tuple[ApplianceDef, ...] = (
    BUILTIN_MICROWAVE,
    BUILTIN_INDUCTION,
)


class ApplianceRegistry:
    """내장 + 커스텀 가전 목록. store(SimpleLayDb)가 있으면 커스텀을 영속화.

    폰 편집기(등록)와 키오스크 폴링(조회)이 다른 스레드에서 오므로 락으로
    직렬화한다 — NodeRegistry와 같은 구조.
    """

    def __init__(self, store=None) -> None:
        self._store = store
        self._lock = threading.Lock()
        self._custom: dict[str, ApplianceDef] = {}
        if store is not None:
            for appliance in store.appliances():
                self._custom[appliance.appliance_id] = appliance

    def list(self) -> tuple[ApplianceDef, ...]:
        with self._lock:
            return BUILTIN_APPLIANCES + tuple(self._custom.values())

    def get(self, appliance_id: str) -> ApplianceDef | None:
        with self._lock:
            for builtin in BUILTIN_APPLIANCES:
                if builtin.appliance_id == appliance_id:
                    return builtin
            return self._custom.get(appliance_id)

    def register(self, appliance: ApplianceDef) -> None:
        """커스텀 가전 등록/교체. 내장 가전 id를 덮으려 하면 거부 —
        키오스크·의도 규칙이 내장 정의를 전제하므로 조용히 바뀌면 안 된다."""
        if any(
            b.appliance_id == appliance.appliance_id for b in BUILTIN_APPLIANCES
        ):
            raise BuiltinApplianceError(
                f"'{appliance.appliance_id}' is a built-in appliance"
            )
        with self._lock:
            self._custom[appliance.appliance_id] = appliance
            if self._store is not None:
                self._store.save_appliance(appliance)

    def delete(self, appliance_id: str) -> bool:
        """커스텀 가전 삭제. 내장이면 거부, 없으면 False."""
        if any(b.appliance_id == appliance_id for b in BUILTIN_APPLIANCES):
            raise BuiltinApplianceError(
                f"'{appliance_id}' is a built-in appliance"
            )
        with self._lock:
            existed = self._custom.pop(appliance_id, None) is not None
            if existed and self._store is not None:
                self._store.delete_appliance(appliance_id)
            return existed
