"""검토 2026-10-19 (D): ``POST /acks``가 저장(SQLite) 실패를 삼키고 200만 돌려줘, 클라이언트는 '저장됨'과 구별할 수
없었다(재시작하면 확인이 사라진다). 이제 응답의 ``persisted``가 false다 — 200은 그대로(옛 클라이언트 호환, 이번 세션에는
적용됨).
"""

from __future__ import annotations

from rpi.api import deps
from rpi.tests.test_person_acks_1019 import _Clock, api  # noqa: F401 - 픽스처
from rpi.services.person_acks import PersonAckStore


class _BrokenDb:
    def load_setting(self, key):
        return None

    def save_setting(self, key, value):
        raise OSError("database is locked")


def test_post_acks_reports_persisted_true_when_saved(api):  # noqa: F811
    res = api.post("/acks", json={"care_seen_id": 0, "job_id": "j1", "answer": "moved"})
    assert res.status_code == 200
    assert res.json()["persisted"] is True
    assert "persisted" not in api.get("/acks").json()  # 조회는 저장 결과가 아니다(응답 모양 그대로)


def test_post_acks_reports_persisted_false_when_the_save_fails(api):  # noqa: F811
    broken = PersonAckStore(_Clock(), db=_BrokenDb())
    api.app.dependency_overrides[deps.get_person_acks] = lambda: broken
    try:
        res = api.post("/acks", json={"job_id": "j1", "answer": "moved"})
    finally:
        api.app.dependency_overrides.pop(deps.get_person_acks, None)
    assert res.status_code == 200  # 옛 클라이언트 호환
    body = res.json()
    assert body["persisted"] is False
    assert body["job_answers"] == {"j1": "moved"}  # 이번 세션에는 적용됐다


def test_store_without_db_reports_none():
    _, persisted = PersonAckStore(_Clock()).change_reporting(care_seen_id=1)
    assert persisted is None
