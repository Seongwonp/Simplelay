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

import re
import threading
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from enum import Enum
from typing import TYPE_CHECKING

from rpi.commands.models import ControlRoute

if TYPE_CHECKING:  # pragma: no cover
    from rpi.services.thinq.bindings import ThinqBinding


class BuiltinApplianceError(ValueError):
    """내장 가전을 덮어쓰거나 지우려 할 때."""


class RevisionConflictError(ValueError):
    """내가 본 판 이후에 다른 기기가 먼저 바꿔 놓았다.

    자동으로 병합하지도, 자동으로 덮어쓰지도 않는다 -- 무엇을 살릴지는
    사람이 정할 일이다. 서버 내용을 유지한 채 거절하고, 클라이언트가
    "다른 기기에서 변경되어 서버 내용을 가져왔어요"라고 알린다.
    """

    def __init__(self, appliance_id: str, current_revision: int) -> None:
        self.appliance_id = appliance_id
        self.current_revision = current_revision
        super().__init__(
            f"appliance '{appliance_id}' changed elsewhere "
            f"(now revision {current_revision})"
        )


class ApplianceCategory(str, Enum):
    """가전의 **종류**. 개별 기기의 식별자(appliance_id)와 다른 개념이다.

    같은 종류를 여러 대 등록할 수 있다 -- 거실 에어컨과 안방 에어컨은
    `category`가 같고 `appliance_id`가 다르다.

    값은 **안정적인 문자열**이다. 화면에 보일 이름이나 아이콘은 여기서
    파생될 뿐, 반대 방향으로 추측하지 않는다(이름에 "에어컨"이 들어갔다고
    종류를 정하지 않는다 -- "에어컨 옆 선풍기" 같은 이름이 틀리게 된다).
    """

    MICROWAVE = "microwave"
    AIR_CONDITIONER = "air_conditioner"
    WASHING_MACHINE = "washing_machine"
    INDUCTION = "induction"
    RICE_COOKER = "rice_cooker"
    AIR_PURIFIER = "air_purifier"
    #: 인터폰(시연 v3 ③ 방문자 문 열기, 2026-10-06 갭 S6). 버튼식 — 문열림 버튼을 누른다.
    INTERCOM = "intercom"
    OTHER = "other"

    @classmethod
    def parse(cls, raw: str | None) -> "ApplianceCategory":
        """모르는 값은 **거절하지 않는다.**

        앞선 버전의 폰이 새 종류를 보낼 수 있다. 거절하면 그 기기는 가전을
        등록할 수 없게 되고, 크래시하면 목록 전체를 못 읽는다. 모르면
        `other`로 받아 두고 이름·버튼은 그대로 살린다.
        """
        if not raw:
            return cls.OTHER
        try:
            return cls(raw)
        except ValueError:
            return cls.OTHER


#: 예전 `icon` 값에서 종류를 되살리는 **명시적** 표.
#:
#: 이름으로 추측하지 않는 것과 같은 이유로, 알려진 값만 옮긴다. 목록에
#: 없으면 `other`다 -- 커스텀 가전이 보내던 "custom"이 여기 없는 것도
#: 의도한 것이다(그 값은 종류를 담은 적이 없다).
_LEGACY_ICON_TO_CATEGORY = {
    "microwave": ApplianceCategory.MICROWAVE,
    "induction": ApplianceCategory.INDUCTION,
    "aircon": ApplianceCategory.AIR_CONDITIONER,
    "air_conditioner": ApplianceCategory.AIR_CONDITIONER,
}


def category_from_legacy_icon(icon: str | None) -> ApplianceCategory:
    """구버전 클라이언트가 보낸 `icon`에서 종류를 되살린다."""
    if not icon:
        return ApplianceCategory.OTHER
    return _LEGACY_ICON_TO_CATEGORY.get(icon, ApplianceCategory.OTHER)


class ButtonKind(str, Enum):
    """조작부 한 칸의 **구동 방식**. 누르는 것과 돌리는 것은 다른 엔드이펙터 동작이다."""

    BUTTON = "button"
    DIAL = "dial"

    @classmethod
    def parse(cls, raw: str | None) -> "ButtonKind":
        """모르는 값은 **거절한다.** 종류(category)와 달리 여기서 추측하면
        다이얼을 누르거나 버튼을 돌리는 물리 동작이 된다."""
        if raw is None or not str(raw).strip():
            return cls.BUTTON
        value = str(raw).strip().lower()
        for kind in cls:
            if kind.value == value:
                return kind
        raise ValueError(f"unknown button kind '{raw}' (button|dial)")


# ── 버튼맵 확장 필드의 물리 상한 — 설계 초기값, 하드웨어 실측 후 조정 ──────────
#: 누름 유지 시간(ms). 짧으면 접점이 안 붙고, 길면 '길게 누르기' 기능이 된다.
PRESS_MS_RANGE = (30, 3000)
#: 갠트리 좌표(mm). 프레임 안쪽만 의미가 있다 -- 음수·무한대는 계산 오류다.
MM_RANGE = (0.0, 600.0)
#: 다이얼 한 바퀴(또는 조작 범위)의 딸깍 수.
DETENTS_RANGE = (2, 60)
#: 가전당 목적별 시퀀스 수.
MAX_FUNCTIONS = 30
#: 시퀀스 한 개의 단계 수. 실행 상한(schemas.MAX_BUTTONS_PER_RUN)과 같아야
#: 한다 -- 등록은 되는데 실행에서 거절되는 기능이 생기지 않게(테스트가 고정).
MAX_FUNCTION_STEPS = 20

_DIAL_STEP = re.compile(r"^(?P<label>.+):(?P<turns>[+-]\d{1,2})$")


@dataclass(frozen=True)
class FunctionStep:
    """목적별 시퀀스의 한 단계. ``turns``가 None이면 누름, ±N이면 다이얼 N 딸깍."""

    label: str
    turns: int | None = None


def parse_function_step(raw: str) -> FunctionStep:
    """``"시작"`` → 누름, ``"출력:+2"`` → 다이얼 2딸깍(부호 필수).

    부호를 필수로 둔 이유: 라벨 자체에 숫자가 들어가는 버튼("1분")과
    회전 단계를 문자열만으로 헷갈리지 않게 한다.
    """
    text = str(raw).strip()
    match = _DIAL_STEP.match(text)
    if match:
        return FunctionStep(match.group("label").strip(), int(match.group("turns")))
    return FunctionStep(text)


@dataclass(frozen=True)
class ApplianceButtonDef:
    id: str
    label: str
    #: 편집기 격자 칸 번호(정수). 화면 배치용이며 물리 좌표가 아니다.
    x: int
    y: int
    kind: ButtonKind = ButtonKind.BUTTON
    #: 다이얼 전용 -- 딸깍 수. 누름 버튼에는 없다.
    detents: int | None = None
    #: 누름 유지 시간. None이면 하드웨어 프로필 기본값을 쓴다.
    press_ms: int | None = None
    #: 갠트리 좌표(mm). **자동 캘리브레이션 또는 수동 티칭으로만** 채운다 --
    #: 격자 칸에서 계산하지 않는다(부착 위치마다 다르다).
    x_mm: float | None = None
    y_mm: float | None = None
    behavior: str = "unknown"

    @property
    def calibrated(self) -> bool:
        return self.x_mm is not None and self.y_mm is not None


def validate_functions(
    buttons: "Sequence[ApplianceButtonDef]",
    functions: "Mapping[str, Sequence[str]]",
) -> None:
    """목적별 시퀀스가 **이 가전의 실제 조작부로 실행 가능한가**를 등록 시점에 거른다.

    실행 시점에 알게 되면 이미 앞 단계를 누른 뒤다 -- 반쯤 설정된 가전이 남는다.
    """
    if len(functions) > MAX_FUNCTIONS:
        raise ValueError(f"at most {MAX_FUNCTIONS} functions")
    by_label = {b.label: b for b in buttons}
    for purpose, steps in functions.items():
        name = str(purpose).strip()
        if not name:
            raise ValueError("function name must not be blank")
        if len(name) > 200:
            raise ValueError("function name must be at most 200 characters")
        if not steps:
            raise ValueError(f"function '{name}' has no steps")
        if len(steps) > MAX_FUNCTION_STEPS:
            raise ValueError(
                f"function '{name}' has {len(steps)} steps (limit {MAX_FUNCTION_STEPS})"
            )
        for raw in steps:
            step = parse_function_step(raw)
            button = by_label.get(step.label)
            if button is None:
                raise ValueError(f"function '{name}' refers to unknown button '{step.label}'")
            if step.turns is None and button.kind is ButtonKind.DIAL:
                raise ValueError(
                    f"'{step.label}' is a dial — use a turn step like '{step.label}:+1'"
                )
            if step.turns is not None:
                if button.kind is not ButtonKind.DIAL:
                    raise ValueError(f"'{step.label}' is a button and cannot be turned")
                if step.turns == 0 or abs(step.turns) > (button.detents or 0):
                    raise ValueError(
                        f"turn {step.turns:+d} for '{step.label}' is outside "
                        f"±{button.detents} detents"
                    )


@dataclass(frozen=True)
class ApplianceDef:
    appliance_id: str
    name: str
    rows: int
    cols: int
    buttons: tuple[ApplianceButtonDef, ...]
    #: 이 기기의 **종류**. 도메인의 단일 진실원천이다.
    #: 없던 시절의 정의는 `other`로 살아남는다 -- 이름·버튼은 그대로 둔다.
    category: ApplianceCategory = ApplianceCategory.OTHER
    is_custom: bool = False
    #: 저장할 때마다 오르는 판 번호. 다른 기기가 먼저 바꿨는지 가리는
    #: 유일한 근거다 -- 시각으로 비교하면 기기 시계가 어긋날 때 조용히
    #: 틀린다. 내장 가전은 바뀌지 않으므로 0으로 둔다.
    revision: int = 0
    #: 목적 → 단계 목록(``validate_functions``로 검증된 것만). 순서를 보존한다.
    functions: tuple[tuple[str, tuple[str, ...]], ...] = ()
    #: 버튼 mm 좌표를 만든 보정 결과의 버전. 좌표가 무효화되면 None.
    calibration_version: str | None = None
    #: 제어 경로(U1-a). 기본은 물리(갠트리·노드). ``thinq``면 버튼이 없고
    #: ``thinq`` 등록 정보(기기 ID·동작 대응표)로만 실행한다.
    control_path: ControlRoute = ControlRoute.PHYSICAL
    thinq: "ThinqBinding | None" = None
    # ── 정지 대기·보관(2026-09-30, rpi/services/stop_park.py가 검증) ──
    #: 정지(취소) 버튼 id. 실행이 끝나고 가전이 동작하는 동안 캐리지가 이 버튼 위에서 기다린다.
    stop_button: str | None = None
    #: 정지까지 누를 횟수 1~3(예: 전자레인지 1회 일시정지·2회 취소).
    stop_presses: int = 1
    #: 보관 위치(갠트리 mm). 버튼·표시창을 가리지 않는 모서리.
    park_xy: tuple[float, float] | None = None
    #: 사진 매핑 기록(사진 크기·프레임 모서리·버튼 px). 사진 파일은 서버에 두지 않는다.
    panel_mapping: "dict | None" = field(default=None, hash=False, compare=False)

    def function_steps(self, purpose: str) -> tuple[FunctionStep, ...] | None:
        """등록한 기능 이름 → 단계. 정확히 같은 이름이 먼저, 없으면 본체 공통 말 다듬기(`rpi/intent/normalize.py`)로
        같은 키가 되는 이름이 **하나뿐일 때만**(2026-10-19 — '밥 하기'·'밥하기 해 줘'). 부정·정지어는 다듬어 맞추지 않는다."""
        key = purpose.strip()
        for name, steps in self.functions:
            if name == key:
                return tuple(parse_function_step(s) for s in steps)
        from rpi.intent.normalize import normalize_utterance, refuses_matching  # noqa: PLC0415

        normalized = normalize_utterance(purpose)
        if not normalized or refuses_matching(purpose):
            return None
        hits = [steps for name, steps in self.functions if normalize_utterance(name) == normalized]
        if len(hits) != 1:
            return None
        return tuple(parse_function_step(s) for s in hits[0])

    @property
    def icon(self) -> str:
        """구버전 클라이언트를 위한 **파생 출력**.

        따로 저장하지 않는다 -- 두 필드를 각각 고칠 수 있게 두면 곧
        어긋나고, 어느 쪽이 진짜인지 알 수 없게 된다. 종류가 진실원천이고
        이건 거기서 나온 그림 힌트다.
        """
        return self.category.value


# ── 내장 가전 — docs/button-maps/*.json과의 일치를 테스트가 고정한다 ─────────
BUILTIN_MICROWAVE = ApplianceDef(
    appliance_id="microwave",
    name="전자레인지",
    category=ApplianceCategory.MICROWAVE,
    rows=4,
    cols=3,
    buttons=(
        ApplianceButtonDef("BT-01", "10초", 0, 0, behavior="idempotent"),
        ApplianceButtonDef("BT-02", "30초", 1, 0, behavior="idempotent"),
        ApplianceButtonDef("BT-03", "1분", 2, 0, behavior="idempotent"),
        ApplianceButtonDef("BT-04", "5분", 0, 1, behavior="idempotent"),
        ApplianceButtonDef("BT-10", "라면", 1, 1, behavior="unknown"),
        ApplianceButtonDef("BT-07", "해동", 0, 2, behavior="unknown"),
        ApplianceButtonDef("BT-08", "즉석밥", 1, 2, behavior="unknown"),
        ApplianceButtonDef("BT-09", "냉동식품", 2, 2, behavior="unknown"),
        ApplianceButtonDef("BT-06", "취소", 1, 3, behavior="toggle"),
        ApplianceButtonDef("BT-05", "시작", 2, 3, behavior="toggle"),
    ),
)

BUILTIN_INDUCTION = ApplianceDef(
    appliance_id="induction",
    name="인덕션",
    category=ApplianceCategory.INDUCTION,
    rows=3,
    cols=4,
    buttons=(
        ApplianceButtonDef("IN-01", "전원", 0, 0, behavior="toggle"),
        ApplianceButtonDef("IN-02", "화력+", 1, 0, behavior="unknown"),
        ApplianceButtonDef("IN-03", "화력-", 2, 0, behavior="unknown"),
        ApplianceButtonDef("IN-04", "타이머", 3, 0, behavior="unknown"),
        ApplianceButtonDef("IN-05", "1단", 0, 1, behavior="unknown"),
        ApplianceButtonDef("IN-06", "3단", 1, 1, behavior="unknown"),
        ApplianceButtonDef("IN-07", "5단", 2, 1, behavior="unknown"),
        ApplianceButtonDef("IN-08", "보온", 3, 1, behavior="unknown"),
        ApplianceButtonDef("IN-09", "시작", 2, 2, behavior="toggle"),
        ApplianceButtonDef("IN-10", "취소", 3, 2, behavior="toggle"),
    ),
)

BUILTIN_APPLIANCES: tuple[ApplianceDef, ...] = (
    BUILTIN_MICROWAVE,
    BUILTIN_INDUCTION,
)


def _calibration_key(appliance_id: str) -> str:
    return f"calibration:{appliance_id}"


def _stop_park_key(appliance_id: str) -> str:
    return f"stop_park:{appliance_id}"


def _encode_stop_park(fields: Mapping[str, object]) -> str:
    import json  # noqa: PLC0415

    park = fields.get("park_xy")
    return json.dumps(
        {
            "stop_button": fields.get("stop_button"),
            "stop_presses": int(fields.get("stop_presses") or 1),
            "park_xy": None if park is None else [float(park[0]), float(park[1])],  # type: ignore[index]
            "panel_mapping": fields.get("panel_mapping"),
        },
        ensure_ascii=False,
    )


def _decode_stop_park(raw: str) -> dict:
    import json  # noqa: PLC0415

    data = json.loads(raw)
    park = data.get("park_xy")
    return {
        "stop_button": data.get("stop_button"),
        "stop_presses": int(data.get("stop_presses") or 1),
        "park_xy": None if park is None else (float(park[0]), float(park[1])),
        "panel_mapping": data.get("panel_mapping"),
    }


def _encode_overlay(
    version: str, mapped: Mapping[str, tuple[float, float]], revision: int
) -> str:
    import json  # noqa: PLC0415

    return json.dumps(
        {
            "version": version,
            "coords": {k: [x, y] for k, (x, y) in mapped.items()},
            "revision": revision,
        },
        ensure_ascii=False,
    )


def _decode_overlay(raw: str) -> tuple[str, dict[str, tuple[float, float]], int]:
    """판 번호가 없는 옛 기록은 1판으로 읽는다 -- 보정이 한 번은 저장됐다는 뜻이다."""
    import json  # noqa: PLC0415

    data = json.loads(raw)
    return (
        str(data["version"]),
        {str(k): (float(v[0]), float(v[1])) for k, v in data["coords"].items()},
        int(data.get("revision", 1)),
    )


def merge_for_save(existing: ApplianceDef | None, incoming: ApplianceDef) -> ApplianceDef:
    """``register``가 저장할 모양을 미리 본다(라우터의 정지·보관 검증용). 규칙은 아래와 같다."""
    return _carry_calibration(existing, incoming)


#: 정지·보관 필드. 요청이 하나도 싣지 않으면 저장된 값을 이어받는다.
_STOP_PARK_FIELDS = ("stop_button", "stop_presses", "park_xy", "panel_mapping")


def _carry_stop_park(existing: ApplianceDef, incoming: ApplianceDef) -> dict:
    """옛 폰 편집기는 정지·보관을 모른다 — 이름 하나 고칠 때마다 지워지지 않게 이어받는다.
    정지 버튼이 사라졌으면 정지 버튼만 비운다."""
    if incoming.stop_button is not None or incoming.park_xy is not None or incoming.panel_mapping:
        return {}
    ids = {b.id for b in incoming.buttons}
    return {
        "stop_button": existing.stop_button if existing.stop_button in ids else None,
        "stop_presses": existing.stop_presses,
        "park_xy": existing.park_xy,
        "panel_mapping": existing.panel_mapping,
    }


def _carry_calibration(
    existing: ApplianceDef | None, incoming: ApplianceDef
) -> ApplianceDef:
    """폰 편집기 저장이 **보정으로 얻은 mm 좌표를 지우지 않게** 한다.

    폰은 mm 좌표를 모르고 격자만 보낸다. 그대로 덮으면 이름 하나 고칠 때마다
    보정을 다시 해야 한다. 규칙:

    - 같은 id가 **같은 격자 칸**에 남았으면 이전 mm 좌표를 이어받는다.
    - 칸을 옮긴 버튼은 이어받지 않는다 -- 옛 좌표로 누르면 엉뚱한 곳이다.
    - 요청이 mm 좌표를 직접 실었으면(수동 티칭) 그 값이 이긴다.
    - 보정 버전은 옮겨진 버튼이 하나도 없을 때만 유지한다.
    """
    from dataclasses import replace  # noqa: PLC0415

    if existing is None:
        return incoming
    previous = {b.id: b for b in existing.buttons}
    buttons: list[ApplianceButtonDef] = []
    carried = False
    lost = False
    for button in incoming.buttons:
        prev = previous.get(button.id)
        if not button.calibrated and prev is not None and prev.calibrated:
            if (prev.x, prev.y) == (button.x, button.y):
                button = replace(button, x_mm=prev.x_mm, y_mm=prev.y_mm)
                carried = True
            else:
                lost = True
        buttons.append(button)
    version = incoming.calibration_version
    if version is None and carried and not lost:
        version = existing.calibration_version
    return replace(incoming, buttons=tuple(buttons), calibration_version=version,
                   **_carry_stop_park(existing, incoming))


class ApplianceRegistry:
    """내장 + 커스텀 가전 목록. store(SimpleLayDb)가 있으면 커스텀을 영속화.

    폰 편집기(등록)와 키오스크 폴링(조회)이 다른 스레드에서 오므로 락으로
    직렬화한다 — NodeRegistry와 같은 구조.

    **잠금 둘(2026-10-14 HIGH 재확인 2차 H-RR2).** 쓰기(등록·보정·삭제)는 판 번호 검사와 DB 쓰기를 묶어야 해서 쓰기 잠금
    (``_lock``)을 쥔 채 DB를 기다린다. 읽기(``get``·``list``·``list_all``·``system_appliances``)는 그 잠금을 잡지 않고
    짧은 메모리 잠금(``_mem_lock``)만 잡는다 — async 라우터(ThinQ 상태·기기 목록)가 이벤트 루프에서 읽어도 DB 대기에
    묶이지 않는다. 메모리는 DB가 성공한 **뒤에** 바꾸므로(DB 먼저 규칙) 저장 중의 읽기는 저장 전 값을 본다.
    """

    def __init__(self, store=None) -> None:
        self._store = store
        #: 쓰기 잠금 — 판 번호 검사·DB 쓰기·메모리 교체를 한 덩어리로(DB를 기다리는 동안 쥔다). 읽기는 잡지 않는다.
        self._lock = threading.Lock()
        #: 메모리 잠금 — 사전 읽기·교체 순간만(입출력 없음). 쓰기 잠금 안에서 잡을 수 있고 그 반대는 하지 않는다.
        self._mem_lock = threading.Lock()
        self._custom: dict[str, ApplianceDef] = {}
        # 서버 구성이 등록하는 **시스템 가전**(ThinQ 가전·모의 시나리오 가전).
        # 저장하지 않고, 폰 편집기로 덮거나 지울 수 없다. ``list()``(GET
        # /appliances)에는 나오지 않는다 -- 버튼 격자가 없는 가전을 기존 화면이
        # 그리게 하지 않기 위해서다. ``get()``과 ``list_all()``에서는 보인다.
        self._system: dict[str, ApplianceDef] = {}
        # 내장 가전의 보정 좌표. 내장 정의 자체는 바꾸지 않고(키오스크·규칙이
        # 전제한다) 부착 위치마다 다른 mm 좌표만 덧씌운다.
        # 내장 가전 보정: (보정 버전, 버튼 mm, 판 번호). 내장 정의 자체는 고정이라
        # 판 번호는 보정 저장마다 오른다 -- 폰 두 대가 서로를 조용히 덮지 않게.
        self._builtin_calibration: dict[
            str, tuple[str, dict[str, tuple[float, float]], int]
        ] = {}
        # 내장 가전의 정지·보관 필드(사진 매핑으로만 채운다). 보정 좌표와 따로 저장한다.
        self._builtin_stop_park: dict[str, dict] = {}
        if store is not None:
            for appliance in store.appliances():
                self._custom[appliance.appliance_id] = appliance
            loader = getattr(store, "load_setting", None)
            for builtin in BUILTIN_APPLIANCES:
                raw = loader(_calibration_key(builtin.appliance_id)) if loader else None
                if raw:
                    try:
                        self._builtin_calibration[builtin.appliance_id] = _decode_overlay(raw)
                    except Exception:  # 손상된 보정은 '보정 전'으로 — 틀린 좌표보다 낫다
                        import logging  # noqa: PLC0415

                        logging.getLogger(__name__).exception(
                            "skipping corrupt calibration for %r", builtin.appliance_id
                        )
                extra = loader(_stop_park_key(builtin.appliance_id)) if loader else None
                if extra:
                    try:
                        self._builtin_stop_park[builtin.appliance_id] = _decode_stop_park(extra)
                    except Exception:  # 손상되면 정지 대기 없음 — 틀린 위치보다 낫다
                        import logging  # noqa: PLC0415

                        logging.getLogger(__name__).exception(
                            "skipping corrupt stop/park for %r", builtin.appliance_id
                        )

    def list(self) -> tuple[ApplianceDef, ...]:
        with self._mem_lock:
            builtins = tuple(self._with_overlay(b) for b in BUILTIN_APPLIANCES)
            return builtins + tuple(self._custom.values())

    def get(self, appliance_id: str) -> ApplianceDef | None:
        with self._mem_lock:
            for builtin in BUILTIN_APPLIANCES:
                if builtin.appliance_id == appliance_id:
                    return self._with_overlay(builtin)
            found = self._custom.get(appliance_id)
            return found if found is not None else self._system.get(appliance_id)

    def list_all(self) -> tuple[ApplianceDef, ...]:
        with self._mem_lock:
            system = tuple(self._system.values())
        return self.list() + system

    def system_appliances(self) -> tuple[ApplianceDef, ...]:
        with self._mem_lock:
            return tuple(self._system.values())

    def register_system(self, appliance: ApplianceDef) -> ApplianceDef:
        """서버 구성이 가전을 등록한다(메모리만). 내장·커스텀 ID와 겹치면 거절."""
        aid = appliance.appliance_id
        if any(b.appliance_id == aid for b in BUILTIN_APPLIANCES):
            raise BuiltinApplianceError(f"'{aid}' is a built-in appliance")
        if appliance.control_path is ControlRoute.THINQ and appliance.thinq is None:
            raise ValueError(f"thinq appliance '{aid}' needs a thinq binding")
        with self._mem_lock:
            if aid in self._custom:
                raise BuiltinApplianceError(f"'{aid}' is already a custom appliance")
            self._system[aid] = appliance
            return appliance

    def unregister_system(self, appliance_id: str) -> bool:
        with self._mem_lock:
            return self._system.pop(appliance_id, None) is not None

    def _require_not_system(self, appliance_id: str) -> None:
        with self._mem_lock:
            if appliance_id in self._system:
                raise BuiltinApplianceError(
                    f"'{appliance_id}' is a system appliance (server configuration)"
                )

    def apply_calibration(
        self,
        appliance_id: str,
        *,
        version: str,
        coords: Mapping[str, tuple[float, float]],
        expected_revision: int | None = None,
        stop_park: "Mapping[str, object] | None" = None,
    ) -> ApplianceDef:
        """보정 결과(버튼 id → mm)를 **한 번에** 반영한다.

        ``stop_park``(선택, 사진 매핑): ``stop_button``·``stop_presses``·``park_xy``·
        ``panel_mapping``을 같은 판 번호로 함께 저장한다. 호출자가 검증한 뒤 부른다.

        새 보정은 새 변환 행렬이다. 이번에 포함되지 않은 버튼의 옛 mm 좌표는
        다른 행렬로 만든 값이라 섞으면 안 된다 -- 비운다.

        호출자(라우터)가 버튼 id·프레임 범위를 검증한 뒤 부른다. 없는
        가전이면 LookupError.
        """
        from dataclasses import replace  # noqa: PLC0415

        mapped = {bid: (float(x), float(y)) for bid, (x, y) in coords.items()}
        with self._lock:
            builtin = next(
                (b for b in BUILTIN_APPLIANCES if b.appliance_id == appliance_id), None
            )
            if builtin is not None:
                current = self._builtin_revision(appliance_id)
                if expected_revision is not None and expected_revision != current:
                    raise RevisionConflictError(appliance_id, current)
                revision = current + 1
                if self._store is not None and hasattr(self._store, "save_setting"):
                    if stop_park is not None:
                        self._store.save_setting(
                            _stop_park_key(appliance_id), _encode_stop_park(stop_park)
                        )
                    self._store.save_setting(
                        _calibration_key(appliance_id),
                        _encode_overlay(version, mapped, revision),
                    )
                with self._mem_lock:
                    if stop_park is not None:
                        self._builtin_stop_park[appliance_id] = dict(stop_park)
                    self._builtin_calibration[appliance_id] = (version, mapped, revision)
                    return self._with_overlay(builtin)

            existing = self._custom.get(appliance_id)
            if existing is None:
                raise LookupError(appliance_id)
            if expected_revision is not None and expected_revision != existing.revision:
                raise RevisionConflictError(appliance_id, existing.revision)
            updated = replace(
                existing,
                buttons=tuple(
                    replace(b, x_mm=mapped[b.id][0], y_mm=mapped[b.id][1])
                    if b.id in mapped
                    else replace(b, x_mm=None, y_mm=None)
                    for b in existing.buttons
                ),
                calibration_version=version,
                revision=existing.revision + 1,
                **{k: v for k, v in (stop_park or {}).items() if k in _STOP_PARK_FIELDS},
            )
            if self._store is not None:
                self._store.save_appliance(updated)  # DB 먼저 — register와 같은 규칙
            with self._mem_lock:
                self._custom[appliance_id] = updated
            return updated

    def _builtin_revision(self, appliance_id: str) -> int:
        overlay = self._builtin_calibration.get(appliance_id)
        return overlay[2] if overlay is not None else 0

    def _with_overlay(self, builtin: ApplianceDef) -> ApplianceDef:
        from dataclasses import replace  # noqa: PLC0415

        extra = self._builtin_stop_park.get(builtin.appliance_id)
        if extra:
            builtin = replace(
                builtin, **{k: v for k, v in extra.items() if k in _STOP_PARK_FIELDS}
            )
        overlay = self._builtin_calibration.get(builtin.appliance_id)
        if overlay is None:
            return builtin
        version, mapped, revision = overlay
        return replace(
            builtin,
            buttons=tuple(
                replace(b, x_mm=mapped[b.id][0], y_mm=mapped[b.id][1]) if b.id in mapped else b
                for b in builtin.buttons
            ),
            calibration_version=version,
            revision=revision,
        )

    def register(
        self, appliance: ApplianceDef, expected_revision: int | None = None
    ) -> ApplianceDef:
        """커스텀 가전 등록/교체. 내장 가전 id를 덮으려 하면 거부 —
        키오스크·의도 규칙이 내장 정의를 전제하므로 조용히 바뀌면 안 된다.

        ``expected_revision``: "내가 본 판은 이거였다". 그 사이 다른
        기기가 먼저 바꿨으면 RevisionConflictError로 거절하고 **서버
        내용을 유지한다.** 밝히지 않으면(None) 종전대로 통과시킨다 --
        최초 등록과 구버전 클라이언트의 경로다.
        """
        if any(
            b.appliance_id == appliance.appliance_id for b in BUILTIN_APPLIANCES
        ):
            raise BuiltinApplianceError(
                f"'{appliance.appliance_id}' is a built-in appliance"
            )
        self._require_not_system(appliance.appliance_id)
        with self._lock:
            existing = self._custom.get(appliance.appliance_id)
            current = existing.revision if existing is not None else 0
            if expected_revision is not None and expected_revision != current:
                raise RevisionConflictError(
                    appliance.appliance_id, current
                )
            from dataclasses import replace  # noqa: PLC0415

            stamped = replace(
                _carry_calibration(existing, appliance), revision=current + 1
            )
            # DB를 먼저 커밋한다 — 메모리를 먼저 바꾸면 DB 실패(500) 시
            # "지금은 조회되는데 재시작하면 사라지는" 가전이 생긴다
            # (교차 리뷰 #2). DB가 던지면 메모리는 그대로라 상태가 일치한다.
            if self._store is not None:
                self._store.save_appliance(stamped)
            with self._mem_lock:
                self._custom[appliance.appliance_id] = stamped
            return stamped

    def delete(
        self, appliance_id: str, expected_revision: int | None = None
    ) -> bool:
        """커스텀 가전 삭제. 내장이면 거부, 없으면 False.

        ``expected_revision``: "내가 본 판은 이거였다". 삭제도 수정과
        같은 검사를 받는다 -- 안 그러면 폰 A의 **오래된 삭제**가 폰 B의
        방금 수정을 무조건 지운다. "충돌은 서버 내용 유지"가 수정에만
        걸려 있으면 그 계약은 반쪽이다.

        없는 가전(False)은 충돌로 보지 않는다 -- 되돌려 놓으려던 상태가
        이미 성립했으므로 재전송이 멱등해야 한다.
        """
        if any(b.appliance_id == appliance_id for b in BUILTIN_APPLIANCES):
            raise BuiltinApplianceError(
                f"'{appliance_id}' is a built-in appliance"
            )
        self._require_not_system(appliance_id)
        with self._lock:
            existing = self._custom.get(appliance_id)
            existed = existing is not None
            if (
                existed
                and expected_revision is not None
                and expected_revision != existing.revision
            ):
                raise RevisionConflictError(
                    appliance_id, existing.revision
                )
            if existed and self._store is not None:
                self._store.delete_appliance(appliance_id)  # DB 먼저 — #2와 동일
            with self._mem_lock:
                self._custom.pop(appliance_id, None)
            return existed
