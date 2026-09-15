"""공간 존재 + 노드 전원 상태 기계 — **감지 단계가 곧 전원 단계**다.

`presence.py`의 `PresenceStore`는 "있다/없다/모른다" 하나만 안다. 그걸로는
제안 보류까지는 되지만, 노드를 언제 깨우고 화면을 언제 켜고 **액추에이터
전원을 언제 넣을지**는 정할 수 없다. 여기서는 공간을 방 이름이 아니라
**거리**로 다룬다:

- S0 귀가: 폰 지오펜스가 "집에 도착 중"을 알린다 → 허브가 제안 후보를
  미리 계산한다. 노드는 IDLE 그대로다(아직 아무도 앞에 없다).
- S1 진입(≈5 m): 레이더 먼 구역에 사람 → 노드가 깨어나고(ROOM_PRESENT)
  시간대·이력 기반 제안을 만든다.
- S2 근접(≈1 m): 레이더 가까운 구역 → 화면을 켜고 제안을 보인다(APPROACHING).
- AT_DEVICE: 가까운 구역에 **머무르면** 승인 대기·실행. 액추에이터 전원은
  **여기서만** 들어간다.

왜 액추에이터 전원을 AT_DEVICE에만 묶는가: 아무도 앞에 없는데 모터 드라이버가
통전돼 있으면 대기 전력도 낭비지만, 오동작 한 번이 **보는 사람 없는 물리
조작**이 된다. 가까이 스쳐 지나가는 사람(체류 < ``at_device_dwell_s``)에게도
전원을 넣지 않는다.

입력은 평범한 관측값이다 — 레이더·지오펜스 드라이버는 이 모듈 밖이다.
거리 문턱·체류 시간·전력 수치는 **설계 초기값(추측/측정 필요)**이며, 실측
(오탐·체류 시간·실제 소비 전력) 후 조정한다.

시계: 주입받는 단조 시계(``Callable[[], float]``)만 쓴다. 벽시계는 NTP 보정·
수동 변경으로 뒤로 갈 수 있고, 그러면 체류·타임아웃 판정이 뒤집힌다.

락 규칙: 락은 하나이고 항상 최내곽(leaf)이다. 이 모듈은 어떤 콜백도 밖으로
부르지 않는다 — 전이는 ``Transition`` 값으로 **돌려주고**, 실제 화면·전원
조작은 호출자가 락 밖에서 수행한다.
"""

from __future__ import annotations

import math
import threading
import time
from collections import deque
from dataclasses import dataclass
from enum import Enum
from types import MappingProxyType
from typing import Callable, Mapping


class NodeState(str, Enum):
    """노드 단계. 순서가 곧 전원 단계의 오름차순이다."""

    #: 아무도 없다. 레이더만 산다.
    IDLE = "idle"
    #: 먼 구역(≈5 m)에 사람. 노드는 깨어 있지만 화면은 꺼져 있다.
    ROOM_PRESENT = "room_present"
    #: 가까운 구역(≈1 m). 화면을 켜고 제안을 보인다.
    APPROACHING = "approaching"
    #: 가까운 구역에 머물렀다. 승인 대기·실행 — 액추에이터 전원 허용.
    AT_DEVICE = "at_device"


_ORDER: tuple[NodeState, ...] = (
    NodeState.IDLE,
    NodeState.ROOM_PRESENT,
    NodeState.APPROACHING,
    NodeState.AT_DEVICE,
)


@dataclass(frozen=True)
class PowerProfile:
    state: NodeState
    radar: bool
    node_awake: bool
    screen_on: bool
    actuator_powered: bool
    #: (min, max) 와트. **설계 추정치 — 실측 전**이다. 발표·문서에 사실로 쓰지 않는다.
    estimated_watts: tuple[float, float]


POWER_PROFILES: Mapping[NodeState, PowerProfile] = MappingProxyType(
    {
        NodeState.IDLE: PowerProfile(
            NodeState.IDLE,
            radar=True,
            node_awake=False,
            screen_on=False,
            actuator_powered=False,
            estimated_watts=(0.3, 0.5),
        ),
        NodeState.ROOM_PRESENT: PowerProfile(
            NodeState.ROOM_PRESENT,
            radar=True,
            node_awake=True,
            screen_on=False,
            actuator_powered=False,
            estimated_watts=(0.8, 0.8),
        ),
        NodeState.APPROACHING: PowerProfile(
            NodeState.APPROACHING,
            radar=True,
            node_awake=True,
            screen_on=True,
            actuator_powered=False,
            estimated_watts=(2.0, 2.0),
        ),
        NodeState.AT_DEVICE: PowerProfile(
            NodeState.AT_DEVICE,
            radar=True,
            node_awake=True,
            screen_on=True,
            actuator_powered=True,
            estimated_watts=(5.0, 5.0),
        ),
    }
)


@dataclass(frozen=True)
class PresenceConfig:
    """설계 초기값 — 실측(오탐·체류 시간) 후 조정한다.

    enter/exit를 따로 두는 이유(히스테리시스): 문턱 하나로는 경계에 선 사람의
    거리 잡음이 매 틱 들어갔다 나갔다를 만들고, 그때마다 화면이 깜빡이고 전원이
    붙었다 떨어진다.
    """

    far_enter_m: float = 5.0
    far_exit_m: float = 5.5
    near_enter_m: float = 1.0
    near_exit_m: float = 1.3
    #: near 구역에 끊김 없이 이만큼 머물면 AT_DEVICE.
    at_device_dwell_s: float = 1.5
    #: 감지가 끊긴 뒤 IDLE로 내려가기까지.
    lost_timeout_s: float = 30.0
    #: S0 귀가 신호 유효 시간.
    arrival_hint_ttl_s: float = 600.0

    def __post_init__(self) -> None:
        # 구역이 겹치거나 뒤집히면 상태 기계가 조용히 이상하게 돈다 — 생성
        # 시점에 시끄럽게 막는다.
        if not (0.0 < self.near_enter_m <= self.near_exit_m):
            raise ValueError("near_enter_m은 0보다 크고 near_exit_m 이하여야 합니다")
        if not (self.near_exit_m <= self.far_enter_m <= self.far_exit_m):
            raise ValueError(
                "near_exit_m ≤ far_enter_m ≤ far_exit_m 순서여야 합니다"
            )
        if self.at_device_dwell_s < 0 or self.lost_timeout_s <= 0:
            raise ValueError("체류 시간은 0 이상, 감지 두절 기한은 0보다 커야 합니다")
        if self.arrival_hint_ttl_s <= 0:
            raise ValueError("arrival_hint_ttl_s는 0보다 커야 합니다")


#: 전이에 실리는 동작의 **정해진 어휘**. 호출자는 이 문자열만 해석하면 된다.
ACTIONS: frozenset[str] = frozenset(
    {
        "precompute_suggestions",
        "wake_node",
        "generate_suggestions",
        "screen_on",
        "show_suggestion",
        "enable_actuator_power",
        "disable_actuator_power",
        "screen_off",
        "sleep_node",
    }
)


@dataclass(frozen=True)
class Transition:
    at_s: float
    previous: NodeState
    current: NodeState
    reason: str
    #: 순서대로 수행할 동작. 어휘는 ``ACTIONS``로 제한된다.
    actions: tuple[str, ...]


# 한 단계 전이마다의 동작. 액추에이터 전원 동작은 AT_DEVICE로 들어가고
# 나오는 두 간선에만 있다 — 다른 경로로 전원이 붙거나 떨어지지 않게 한 곳에 둔다.
_STEP_ACTIONS: Mapping[tuple[NodeState, NodeState], tuple[str, ...]] = MappingProxyType(
    {
        (NodeState.IDLE, NodeState.ROOM_PRESENT): ("wake_node", "generate_suggestions"),
        (NodeState.ROOM_PRESENT, NodeState.APPROACHING): ("screen_on", "show_suggestion"),
        (NodeState.APPROACHING, NodeState.AT_DEVICE): ("enable_actuator_power",),
        (NodeState.AT_DEVICE, NodeState.APPROACHING): ("disable_actuator_power",),
        (NodeState.APPROACHING, NodeState.ROOM_PRESENT): ("screen_off",),
        (NodeState.ROOM_PRESENT, NodeState.IDLE): ("sleep_node",),
    }
)

_STEP_REASONS: Mapping[tuple[NodeState, NodeState], str] = MappingProxyType(
    {
        (NodeState.IDLE, NodeState.ROOM_PRESENT): "entered_far",
        (NodeState.ROOM_PRESENT, NodeState.APPROACHING): "entered_near",
        (NodeState.APPROACHING, NodeState.AT_DEVICE): "near_dwell",
        (NodeState.AT_DEVICE, NodeState.APPROACHING): "left_near",
        (NodeState.APPROACHING, NodeState.ROOM_PRESENT): "left_near",
        (NodeState.ROOM_PRESENT, NodeState.IDLE): "left_far",
    }
)


class _Zone(int, Enum):
    """레이더가 본 **물리적** 구역. 노드 단계와 따로 둔다 — 실행 중에는
    단계가 AT_DEVICE에 고정돼도 사람이 떠난 사실은 기록해야 하기 때문이다."""

    OUT = 0
    FAR = 1
    NEAR = 2


_HISTORY_MAXLEN = 100


class PresenceStateMachine:
    """거리 관측을 노드 단계·전원 동작으로 바꾼다.

    실행 고정(pin): 실행 중(``begin_execution`` ~ ``end_execution``)에는 단계를
    AT_DEVICE 아래로 내리지 않고 액추에이터 전원도 끊지 않는다. 버튼을 누르는
    도중에 전원이 빠지면 갠트리가 어중간한 위치에 멈추고, 눌림 판정도 깨진다.
    사람이 떠났다는 사실은 구역으로 기록해 두었다가 ``end_execution``에서
    한꺼번에 반영한다.

    **긴급 정지는 이 경로가 아니다.** 이 상태 기계의 고정은 "사람이 떠났다"는
    일상적 사유로 전원을 끊지 않는다는 뜻일 뿐이며, 긴급 정지는 별도의 안전
    경로(제어권 중재자·정지 경로)가 이 모듈과 무관하게 즉시 수행한다.
    """

    def __init__(
        self,
        config: PresenceConfig | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._config = config or PresenceConfig()
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._state = NodeState.IDLE
        self._zone = _Zone.OUT
        # 마지막으로 범위 안(OUT이 아닌)에서 감지한 시각. 감지 두절 판정의 기준.
        self._last_detection_at: float | None = None
        # near 구역에 끊김 없이 들어와 있기 시작한 시각. 감지 없음(None) 한 번이면
        # 지운다 — 액추에이터 전원의 근거이므로 보지 못한 시간을 체류로 치지 않는다.
        self._near_since: float | None = None
        self._executing = False
        self._arrival_hint_at: float | None = None
        self._history: deque[Transition] = deque(maxlen=_HISTORY_MAXLEN)

    # ── 조회 ──

    @property
    def config(self) -> PresenceConfig:
        return self._config

    @property
    def state(self) -> NodeState:
        with self._lock:
            return self._state

    @property
    def profile(self) -> PowerProfile:
        with self._lock:
            return POWER_PROFILES[self._state]

    @property
    def executing(self) -> bool:
        with self._lock:
            return self._executing

    def arrival_hint_active(self) -> bool:
        with self._lock:
            return self._hint_active_locked(self._monotonic())

    def history(self) -> list[Transition]:
        """최근 전이(최대 100건). 사본을 돌려준다."""
        with self._lock:
            return list(self._history)

    # ── S0 귀가 신호 ──

    def phone_arriving(self) -> Transition | None:
        """폰 지오펜스의 "집에 도착 중" 신호.

        노드는 IDLE을 떠나지 않는다 — 아직 앞에 아무도 없으니 화면·노드를 깨울
        근거가 없다. 허브가 제안 후보를 미리 계산하라는 동작만 싣는다.

        ``None``을 돌려주는 경우:
        - TTL 안에 이미 신호를 받았다(지오펜스가 경계에서 여러 번 울려도 한 번만
          계산한다).
        - 노드가 이미 깨어 있다(사람이 먼저 들어왔다). 이때는 ROOM_PRESENT 진입의
          ``generate_suggestions``가 이미 같은 일을 했으므로 신호만 기록한다.
        """
        with self._lock:
            now = self._monotonic()
            if self._hint_active_locked(now):
                return None
            self._arrival_hint_at = now
            if self._state is not NodeState.IDLE:
                return None
            transition = Transition(
                at_s=now,
                previous=NodeState.IDLE,
                current=NodeState.IDLE,
                reason="arrival_hint",
                actions=("precompute_suggestions",),
            )
            self._history.append(transition)
            return transition

    # ── 관측·시간 ──

    def observe(self, distance_m: float | None) -> list[Transition]:
        """레이더 한 틱의 관측. ``None``은 이번 틱에 감지 없음.

        음수·NaN·무한대·숫자가 아닌 값은 센서 잡음으로 보고 **아무 상태도 바꾸지
        않고** 무시한다. 잘못된 한 틱이 전원 동작을 만들거나 예외로 감지 루프를
        죽이면 안 된다.
        """
        with self._lock:
            if distance_m is not None and not _valid_distance(distance_m):
                return []
            now = self._monotonic()
            out: list[Transition] = []
            if distance_m is None:
                self._near_since = None
                self._check_lost_locked(now, out)
                return out

            self._zone = self._next_zone_locked(float(distance_m))
            if self._zone is _Zone.OUT:
                self._last_detection_at = None
            else:
                self._last_detection_at = now
            if self._zone is _Zone.NEAR:
                if self._near_since is None:
                    self._near_since = now
            else:
                self._near_since = None

            if self._executing:
                # 고정: 구역만 기록하고 단계는 end_execution에서 반영한다.
                return out
            self._reconcile_locked(now, out, suffix="")
            self._check_dwell_locked(now, out)
            return out

    def tick(self) -> list[Transition]:
        """관측 없이 시간만 흐른 경우의 판정 — 체류 승격과 감지 두절 강등."""
        with self._lock:
            now = self._monotonic()
            out: list[Transition] = []
            self._check_lost_locked(now, out)
            self._check_dwell_locked(now, out)
            return out

    # ── 실행 고정 ──

    def begin_execution(self) -> None:
        """AT_DEVICE에서만 허용. 그 밖에서는 액추에이터 전원이 없으므로 실행을
        받으면 안 된다 — 반환값 대신 예외로 시끄럽게 막는다."""
        with self._lock:
            if self._state is not NodeState.AT_DEVICE:
                raise RuntimeError(
                    f"실행은 AT_DEVICE에서만 시작할 수 있습니다 (현재 {self._state.value})"
                )
            if self._executing:
                raise RuntimeError("이미 실행 중입니다")
            self._executing = True

    def end_execution(self) -> list[Transition]:
        """고정을 풀고, 실행 중 미뤄 둔 강등을 반영한다. 실행 중이 아니면 빈 목록."""
        with self._lock:
            out: list[Transition] = []
            if not self._executing:
                return out
            self._executing = False
            now = self._monotonic()
            suffix = "_after_execution"
            if self._zone is not _Zone.OUT and self._is_lost_locked(now):
                self._apply_lost_locked(now, out, reason="lost_timeout" + suffix)
                return out
            self._reconcile_locked(now, out, suffix=suffix)
            return out

    # ── 내부(락 보유 상태에서만 호출) ──

    def _hint_active_locked(self, now: float) -> bool:
        return (
            self._arrival_hint_at is not None
            and now - self._arrival_hint_at < self._config.arrival_hint_ttl_s
        )

    def _next_zone_locked(self, distance: float) -> _Zone:
        """히스테리시스: 들어갈 때는 enter 문턱, 나갈 때는 exit 문턱."""
        cfg = self._config
        near_limit = cfg.near_exit_m if self._zone is _Zone.NEAR else cfg.near_enter_m
        far_limit = (
            cfg.far_exit_m if self._zone in (_Zone.FAR, _Zone.NEAR) else cfg.far_enter_m
        )
        if distance <= near_limit:
            return _Zone.NEAR
        if distance <= far_limit:
            return _Zone.FAR
        return _Zone.OUT

    def _target_locked(self) -> NodeState:
        if self._zone is _Zone.OUT:
            return NodeState.IDLE
        if self._zone is _Zone.FAR:
            return NodeState.ROOM_PRESENT
        # near: AT_DEVICE는 체류로만 들어간다. 이미 AT_DEVICE면 유지한다.
        if self._state is NodeState.AT_DEVICE:
            return NodeState.AT_DEVICE
        return NodeState.APPROACHING

    def _reconcile_locked(self, now: float, out: list[Transition], suffix: str) -> None:
        """구역이 가리키는 단계까지 **한 단계씩** 옮긴다. 단계를 건너뛰는 이동도
        간선마다 따로 전이를 만든다 — 그래야 동작 어휘가 간선 표 한 곳에서만
        정해지고, 호출자는 순서대로 수행하기만 하면 된다."""
        target = self._target_locked()
        while self._state is not target:
            i = _ORDER.index(self._state)
            nxt = _ORDER[i + 1] if _ORDER.index(target) > i else _ORDER[i - 1]
            self._step_locked(now, nxt, out, suffix)

    def _step_locked(
        self, now: float, nxt: NodeState, out: list[Transition], suffix: str
    ) -> None:
        edge = (self._state, nxt)
        transition = Transition(
            at_s=now,
            previous=self._state,
            current=nxt,
            reason=_STEP_REASONS[edge] + suffix,
            actions=_STEP_ACTIONS[edge],
        )
        self._state = nxt
        self._history.append(transition)
        out.append(transition)

    def _check_dwell_locked(self, now: float, out: list[Transition]) -> None:
        if (
            self._state is NodeState.APPROACHING
            and self._zone is _Zone.NEAR
            and self._near_since is not None
            and now - self._near_since >= self._config.at_device_dwell_s
        ):
            self._step_locked(now, NodeState.AT_DEVICE, out, suffix="")

    def _is_lost_locked(self, now: float) -> bool:
        return (
            self._last_detection_at is not None
            and now - self._last_detection_at >= self._config.lost_timeout_s
        )

    def _check_lost_locked(self, now: float, out: list[Transition]) -> None:
        if self._executing or self._zone is _Zone.OUT:
            return
        if self._is_lost_locked(now):
            self._apply_lost_locked(now, out, reason="lost_timeout")

    def _apply_lost_locked(self, now: float, out: list[Transition], reason: str) -> None:
        """감지 두절은 사람이 어디로 갔는지 모르는 상태다 — 단계를 하나씩 밟지
        않고 한 전이로 IDLE까지 내린다. 동작은 켜져 있던 것만 끈다(끄는 순서:
        액추에이터 → 화면 → 노드)."""
        previous = self._state
        self._zone = _Zone.OUT
        self._last_detection_at = None
        self._near_since = None
        if previous is NodeState.IDLE:
            return
        was = POWER_PROFILES[previous]
        actions: list[str] = []
        if was.actuator_powered:
            actions.append("disable_actuator_power")
        if was.screen_on:
            actions.append("screen_off")
        if was.node_awake:
            actions.append("sleep_node")
        transition = Transition(
            at_s=now,
            previous=previous,
            current=NodeState.IDLE,
            reason=reason,
            actions=tuple(actions),
        )
        self._state = NodeState.IDLE
        self._history.append(transition)
        out.append(transition)


def _valid_distance(value: object) -> bool:
    # bool은 int의 하위형이라 True가 1.0 m로 읽힌다 — 명시적으로 막는다.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return math.isfinite(value) and value >= 0.0
