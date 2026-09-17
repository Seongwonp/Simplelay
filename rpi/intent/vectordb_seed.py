"""유사도 계층에 넣을 예시를 규칙에서 만들어 채운다.

조회 쪽만 배선돼 있고 채워 넣는 쪽이 없으면 이 계층은 **항상 미스**라 계속 다음
단계로 넘어간다. 동작은 안전하지만(규칙·LLM이 받아준다) 계층이 노는 상태다.

시드 원천이 왜 규칙인가: 규칙에는 이미 "같은 목적의 다른 표현"이 별칭으로 정리돼
있다. 그게 정확히 유사도 검색이 배워야 할 어휘다. 규칙이 정확 매칭으로 잡는 것은
어차피 규칙이 먼저 처리하므로(deps.py의 계층 순서), 여기 넣는 값어치는 **별칭 목록에
없는 변형**까지 끌어오는 데 있다 -- "즉석밥 좀 데워줄래요"처럼.

정규화된 키가 아니라 **원문 표현**을 넣는다. 규칙은 공백·문장부호를 지운 키로
매칭하지만("즉석밥데워줘"), 임베딩은 사람이 쓰는 문장 그대로여야 의미가 제대로 잡힌다.
"""

from __future__ import annotations

import logging
from collections.abc import Mapping, Sequence

from .dbus_vectordb import VectordbClient, VectordbClientError, seed_examples
from .rules import RuleBasedIntentResolver

_log = logging.getLogger(__name__)

DEFAULT_DB_NAME = "simplelay"


def examples_from_rules(
    rules: Mapping[str, Sequence[str]] | None = None,
    aliases: Mapping[str, str] | None = None,
) -> dict[str, tuple[str, ...]]:
    """규칙 + 별칭을 "표현 -> 버튼 시퀀스" 예시로 펼친다.

    별칭은 대표 표현의 시퀀스를 그대로 물려받는다. 대표 표현이 규칙에 없는 별칭은
    조용히 건너뛴다 -- 시드 때문에 서버가 못 뜨는 것이 더 나쁘다.
    """
    rule_map = RuleBasedIntentResolver.DEFAULT_RULES if rules is None else rules
    alias_map = RuleBasedIntentResolver.DEFAULT_ALIASES if aliases is None else aliases

    examples: dict[str, tuple[str, ...]] = {
        purpose: tuple(buttons) for purpose, buttons in rule_map.items()
    }
    for alias, canonical in alias_map.items():
        buttons = examples.get(canonical)
        if buttons is None:
            _log.warning("별칭 %r의 대표 표현 %r이 규칙에 없어 건너뜀", alias, canonical)
            continue
        examples[alias] = buttons
    return examples


def seed_vectordb(
    client: VectordbClient,
    examples: Mapping[str, Sequence[str]] | None = None,
    db_name: str = DEFAULT_DB_NAME,
) -> int:
    """DB를 준비하고 예시를 넣는다. 넣은 개수를 돌려준다.

    Add/Search에는 DB 이름 인자가 없다 -- "현재 로드된 DB" 개념이라 먼저 만들어
    두어야 한다. 이미 있는 DB에 CreateDB를 부르면 어떻게 되는지는 실기기 미확인이라,
    실패해도 "이미 있는 것"으로 보고 진행한다. 진짜 문제라면 바로 뒤의 AddText가
    실패하면서 드러난다.
    """
    try:
        client.create_db(db_name)
        _log.info("벡터DB %r 생성", db_name)
    except VectordbClientError as exc:
        _log.info("벡터DB %r 생성 건너뜀(이미 있는 것으로 봄): %s", db_name, exc)

    payload = examples_from_rules() if examples is None else dict(examples)
    ids = seed_examples(client, payload)
    _log.info("벡터DB에 예시 %d건 시드", len(ids))
    return len(ids)
