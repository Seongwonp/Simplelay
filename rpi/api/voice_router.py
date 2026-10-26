"""키오스크 녹음 요청을 호스트 STT와 기존 의도 제안 흐름에 잇는다."""
import asyncio
import os

import httpx
from fastapi import APIRouter, Depends, HTTPException

from .deps import get_appliance_registry, get_node_registry, get_service
from .intent_router import understand_text

router = APIRouter()

STT_UNAVAILABLE = "말하기 기능을 사용할 수 없어요. 잠시 뒤 다시 눌러 주세요."


class SttClient:
    def __init__(self, url=None):
        self.url = (url if url is not None else os.environ.get(
            "SIMPLELAY_STT_URL", "http://127.0.0.1:8091"
        )).strip().rstrip("/")

    async def listen(self, seconds):
        if self.url.lower() in {"", "off", "none", "disabled"}:
            raise RuntimeError(STT_UNAVAILABLE)
        async with httpx.AsyncClient(timeout=httpx.Timeout(25.0)) as client:
            response = await client.post(f"{self.url}/listen", json={"seconds": seconds})
        if response.status_code == 409:
            raise HTTPException(status_code=409, detail="이미 듣고 있어요.")
        response.raise_for_status()
        return response.json()


def get_stt_client():
    return SttClient()


@router.post("/voice/listen")
async def voice_listen(stt=Depends(get_stt_client), service=Depends(get_service),
                       registry=Depends(get_appliance_registry), nodes=Depends(get_node_registry)):
    try:
        heard = await asyncio.wait_for(stt.listen(5), timeout=25)
    except HTTPException:
        raise
    except (asyncio.TimeoutError, httpx.HTTPError, OSError, RuntimeError, ValueError):
        raise HTTPException(status_code=503, detail=STT_UNAVAILABLE) from None
    text = str(heard.get("text") or "").strip()
    reason = str(heard.get("reason") or ("ok" if text else "no_speech"))
    if not text:
        return {"text": "", "proposal": None, "reason": reason}
    result = await understand_text(text, service, registry, nodes)
    proposal = result.get("proposal")
    return {"text": text, "proposal": proposal, "reason": "ok" if proposal else "not_understood"}
