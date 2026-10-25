"""Read-only intent proposal endpoint; no executor is called here."""
import asyncio

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field, field_validator

from rpi.intent.llm_intent import LlmIntentConfig, build_choices, understand, unknown
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
    return await asyncio.to_thread(_propose, body.text, config, service, registry, nodes)
