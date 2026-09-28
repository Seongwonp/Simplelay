"""Rehearsal UI, available only when the actual default controller is synthetic."""
import pathlib
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import HTMLResponse, Response

from .deps import get_service
from rpi.services.simulator_controller import SimulatorController

router = APIRouter(prefix="/simulator")


def require_simulator(service=Depends(get_service)):
    controller = service._controller
    if not isinstance(controller, SimulatorController):
        raise HTTPException(404, "simulator is not enabled")
    return controller


@router.get("", response_class=HTMLResponse)
def panel(controller=Depends(require_simulator)):
    return (pathlib.Path(__file__).parent.parent / "touchscreen" / "simulator.html").read_text(encoding="utf-8")


@router.get("/state")
def state(controller=Depends(require_simulator)):
    return controller.snapshot()


class RehearsalEvent(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    session: str = Field(min_length=1, max_length=64)
    revision: int = Field(ge=0)
    event: Literal['new', 'locate', 'begin', 'sequence_finished', 'stop', 'ack', 'fail', 'ended', 'estop', 'link_lost']
    action_id: int | None = None
    stop_x: float = Field(default=.8, ge=0, le=1, allow_inf_nan=False)
    stop_y: float = Field(default=.7, ge=0, le=1, allow_inf_nan=False)
    park_x: float = Field(default=.5, ge=0, le=1, allow_inf_nan=False)
    edge: Literal['top', 'bottom'] = 'top'
    end_x: float | None = Field(default=None, ge=0, le=1, allow_inf_nan=False)
    end_y: float | None = Field(default=None, ge=0, le=1, allow_inf_nan=False)


class RoutineEvent(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    session: str = Field(min_length=1, max_length=64)
    revision: int = Field(ge=0)
    event: Literal['reset', 'review', 'approve', 'success', 'failure', 'link_lost', 'stop', 'stop_confirmed']
    selected: list[Literal['purifier', 'fan']] | None = Field(default=None, max_length=2)


@router.get('/routine', response_class=HTMLResponse)
def routine_panel(controller=Depends(require_simulator)):
    return (pathlib.Path(__file__).parent.parent / 'touchscreen' / 'routine.html').read_text(encoding='utf-8')


@router.get('/routine/state')
def routine_state(controller=Depends(require_simulator)):
    return controller.routine_rehearsal.snapshot()


@router.post('/routine/event')
def routine_event(body: RoutineEvent, controller=Depends(require_simulator)):
    from rpi.services.parking_rehearsal import StaleRehearsal
    try:
        if body.event != 'review' and body.selected is not None:
            raise ValueError('선택 변경은 미리보기에서만 가능해요.')
        return controller.routine_rehearsal.event(body.session, body.revision, body.event, body.selected)
    except StaleRehearsal as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc


@router.get('/parking', response_class=HTMLResponse)
def parking_panel(controller=Depends(require_simulator)):
    return (pathlib.Path(__file__).parent.parent / 'touchscreen' / 'parking.html').read_text(encoding='utf-8')


@router.get('/parking/state')
def parking_state(controller=Depends(require_simulator)):
    return controller.parking_rehearsal.snapshot()


@router.get('/parking-motion.js')
def parking_motion_script(controller=Depends(require_simulator)):
    source = pathlib.Path(__file__).parent.parent / 'touchscreen' / 'parking-motion.js'
    return Response(source.read_text(encoding='utf-8'), media_type='text/javascript')


@router.post('/parking/event')
def parking_event(body: RehearsalEvent, controller=Depends(require_simulator)):
    from rpi.services.parking_rehearsal import StaleRehearsal
    from rpi4.parking_simulator import Mapping, Point
    try:
        if (body.end_x is None) != (body.end_y is None):
            raise ValueError('both mock end coordinates are required')
        position = Point(body.end_x, body.end_y) if body.end_x is not None else None
        mapping = (Mapping(Point(body.stop_x, body.stop_y),
                           Point(body.park_x, 0 if body.edge == 'top' else 1), body.edge)
                   if body.event == 'new' else None)
        return controller.parking_rehearsal.event(body.session, body.revision, body.event,
                                                 action_id=body.action_id, mapping=mapping,
                                                 sequence_position=position)
    except StaleRehearsal as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc


# ── 디지털 트윈(개념 모션) 화면 ─────────────────────────────────────────────
# 읽기 전용이다. 실행·정지는 기존 /execute-buttons·/stop을 그대로 쓴다.

@router.get('/twin', response_class=HTMLResponse)
def twin_panel(controller=Depends(require_simulator)):
    return (pathlib.Path(__file__).parent.parent / 'touchscreen' / 'twin.html').read_text(encoding='utf-8')


@router.get('/twin/state')
def twin_state(controller=Depends(require_simulator)):
    from rpi.services.twin_view import build_twin_state
    return build_twin_state(controller.snapshot())


@router.get('/twin/hardware')
def twin_hardware(controller=Depends(require_simulator)):
    from rpi.services.twin_view import build_hardware_summary
    return build_hardware_summary()


@router.get('/twin-motion.js')
def twin_motion_script(controller=Depends(require_simulator)):
    source = pathlib.Path(__file__).parent.parent / 'touchscreen' / 'twin-motion.js'
    return Response(source.read_text(encoding='utf-8'), media_type='text/javascript')
