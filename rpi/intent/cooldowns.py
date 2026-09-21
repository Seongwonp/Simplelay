"""가전·목적·시간대별 다시 묻기 기한. 서비스의 상태 락 안에서 사용한다."""
import json
from collections.abc import Callable
from datetime import datetime


class SuggestionCooldowns:
    def __init__(
        self,
        load: Callable[[], str | None] | None = None,
        save: Callable[[str], None] | None = None,
    ) -> None:
        self._save = save
        raw = load() if load else None
        self._until = {
            key: datetime.fromisoformat(value)
            for key, value in (json.loads(raw) if raw else {}).items()
        }
        if any(value.tzinfo is None for value in self._until.values()):
            raise ValueError('suggestion cooldown deadlines must be timezone-aware')

    @staticmethod
    def key(purpose: str, band: str, appliance_id: str | None) -> str:
        return json.dumps([appliance_id, purpose.strip(), band], ensure_ascii=False)

    def blocked(self, key: str, now: datetime) -> bool:
        until = self._until.get(key)
        return until is not None and now < until

    def remember(self, key: str, until: datetime, now: datetime) -> None:
        updated = {k: v for k, v in self._until.items() if v > now}
        updated[key] = until
        self._replace(updated)

    def forget(self, key: str) -> None:
        self._replace({k: v for k, v in self._until.items() if k != key})

    def _replace(self, updated: dict[str, datetime]) -> None:
        # 저장 실패를 성공으로 응답하지 않는다. 메모리도 이전 상태로 유지.
        if self._save:
            self._save(json.dumps({k: v.isoformat() for k, v in updated.items()}))
        self._until = updated
