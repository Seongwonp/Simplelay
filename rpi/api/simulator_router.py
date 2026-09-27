"""Rehearsal UI, available only when the actual default controller is synthetic."""
import pathlib
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import HTMLResponse

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


@router.get('/parking', response_class=HTMLResponse)
def parking_panel(controller=Depends(require_simulator)):
    return (pathlib.Path(__file__).parent.parent / 'touchscreen' / 'parking.html').read_text(encoding='utf-8')


@router.get('/parking/state')
def parking_state(controller=Depends(require_simulator)):
    return controller.parking_rehearsal.snapshot()


@router.post('/parking/event')
def parking_event(body: RehearsalEvent, controller=Depends(require_simulator)):
    from rpi.services.parking_rehearsal import StaleRehearsal
    from rpi4.parking_simulator import Mapping, Point
    try:
        mapping = (Mapping(Point(body.stop_x, body.stop_y),
                           Point(body.park_x, 0 if body.edge == 'top' else 1), body.edge)
                   if body.event == 'new' else None)
        return controller.parking_rehearsal.event(body.session, body.revision, body.event,
                                                 action_id=body.action_id, mapping=mapping)
    except StaleRehearsal as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
