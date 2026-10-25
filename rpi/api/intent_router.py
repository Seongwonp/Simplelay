"""Read-only intent proposal endpoint; no executor is called here."""
import asyncio

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator

from rpi.intent.llm_intent import LlmIntentConfig, build_choices, understand, unknown
from rpi.intent.proposals import ProposalConflict, get_proposal_store
from rpi.routines.wiring import get_routine_store
from .deps import get_service, get_appliance_registry, get_node_registry, builtin_appliances_visible
from .readiness_view import readiness_view

router = APIRouter()


class UnderstandRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    text: str = Field(min_length=1, max_length=200)

    @field_validator('text')
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError('text must not be blank')
        return value.strip()


def _propose(text, config, service, registry, nodes):
    appliances = tuple(a for a in registry.list_all()
                       if a.is_custom or a.thinq is not None or builtin_appliances_visible())
    controller = service.thinq_controller if hasattr(service, 'thinq_controller') else None
    support = {}

    def profile(a):
        if a.appliance_id not in support:
            support[a.appliance_id] = controller.profile_support(a.appliance_id) if controller else {}
        return support[a.appliance_id]

    try:
        choices = build_choices(appliances, get_routine_store().list(),
            lambda a: readiness_view(a, service, nodes)[2],
            lambda a: service.revision_options(a.appliance_id), profile)
        return understand(text, choices, config)
    except Exception:  # Registry/profile unavailable is not permission to guess or execute.
        return unknown('llm')


@router.post('/intent/understand')
async def intent_understand(body: UnderstandRequest, service=Depends(get_service),
                           registry=Depends(get_appliance_registry), nodes=Depends(get_node_registry)):
    config = LlmIntentConfig.from_env()
    if not config.url:
        return unknown('off')
    result = await asyncio.to_thread(_propose, body.text, config, service, registry, nodes)
    if result.get('understood') and result.get('action'):
        # 키오스크도 같은 질문을 띄울 수 있게 60초 동안 둔다. 실행은 하지 않는다(먼저 고른 클라이언트가 실행).
        proposal = get_proposal_store().add(result['question'], result['label'], result['action'])
        result = {**result, 'proposal_id': proposal.id}
    return result


def _view(p):
    return {'id': p.id, 'question': p.question, 'label': p.label, 'action': p.action,
            'created_at': p.created_at, 'state': p.state}


class ResolveRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    result: Literal['yes', 'no']


@router.get('/intent/proposals')
def intent_proposals():
    """아직 정하지 않은(60초 안) 휴대폰 말 확인 질문. 읽기만 한다."""
    return [_view(p) for p in get_proposal_store().pending()]


@router.get('/intent/proposals/{proposal_id}')
def intent_proposal(proposal_id: str):
    """폰 확인 창이 상태를 본다(pending·yes·no·expired·replaced). 없으면 404."""
    p = get_proposal_store().get(proposal_id)
    if p is None:
        raise HTTPException(status_code=404, detail='이미 지난 질문이에요.')
    return _view(p)


@router.post('/intent/proposals/{proposal_id}/resolve')
def intent_proposal_resolve(proposal_id: str, body: ResolveRequest):
    """먼저 고른 쪽 한 번만(원자적). 서버는 실행하지 않는다 — 'yes'를 이긴 클라이언트가 action을 기존 경로로 보낸다."""
    try:
        p = get_proposal_store().resolve(proposal_id, body.result)
    except KeyError:
        raise HTTPException(status_code=404, detail='이미 지난 질문이에요.') from None
    except ProposalConflict:
        raise HTTPException(status_code=409, detail='다른 곳에서 이미 정했어요.') from None
    return _view(p)
