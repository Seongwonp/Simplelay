"""방 안 사람 감지 판단(2026-10-25) — 있음·자리 비움·외출·돌아옴, 오탐·죽은 감지기."""

from rpi.services.room_presence import AWAY, IDLE, PRESENT, UNKNOWN, RoomPresence


class _Clock:
    def __init__(self) -> None:
        self.t = 1_000_000.0

    def __call__(self) -> float:
        return self.t


def _room(clock, **kw):
    return RoomPresence(now=clock, arrive_frames=3, dim_after_s=60, away_after_s=600, stale_s=20, **kw)


class _Feed:
    def __init__(self, room, clock) -> None:
        self.room, self.clock, self.n = room, clock, 0

    def frame(self, persons: int, advance: float = 2.0):
        self.clock.t += advance
        self.n += 1
        return self.room.observe({"ts": self.clock.t, "persons": persons, "frames": self.n})


def test_starts_empty_and_needs_consecutive_frames_to_arrive():
    clock = _Clock()
    room = _room(clock)
    feed = _Feed(room, clock)
    feed.frame(0)
    assert room.snapshot().state == IDLE
    feed.frame(1)
    feed.frame(1)
    assert room.snapshot().state == IDLE, "두 장으로는 아직 돌아온 게 아니다"
    assert feed.frame(1) == PRESENT
    assert room.snapshot().arrived_at == clock.t


def test_single_false_positive_does_not_wake_the_screen():
    clock = _Clock()
    room = _room(clock)
    feed = _Feed(room, clock)
    for persons in (0, 1, 0, 1, 1, 0, 1):
        feed.frame(persons)
    assert room.snapshot().state == IDLE


def test_dims_then_goes_away_after_long_absence():
    clock = _Clock()
    room = _room(clock)
    feed = _Feed(room, clock)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().state == PRESENT
    feed.frame(0, advance=59)
    assert room.snapshot().state == PRESENT
    assert feed.frame(0, advance=5) == IDLE
    assert feed.frame(0, advance=600) == AWAY


def test_brief_miss_while_present_keeps_present():
    clock = _Clock()
    room = _room(clock)
    feed = _Feed(room, clock)
    for _ in range(3):
        feed.frame(1)
    feed.frame(0)
    feed.frame(1)  # 이미 있는 동안은 한 장만 보여도 '있음'이 이어진다
    assert room.snapshot().state == PRESENT


def test_coming_back_from_away_marks_a_new_arrival():
    clock = _Clock()
    room = _room(clock)
    feed = _Feed(room, clock)
    for _ in range(3):
        feed.frame(1)
    first = room.snapshot().arrived_at
    feed.frame(0, advance=700)
    assert room.snapshot().state == AWAY
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().state == PRESENT
    assert room.snapshot().arrived_at != first


def test_dead_or_stale_detector_is_unknown_never_sleep():
    clock = _Clock()
    room = _room(clock)
    assert room.observe(None) is None or room.snapshot().state == UNKNOWN
    assert room.snapshot().state == UNKNOWN
    clock.t += 5
    room.observe({"ts": clock.t - 30, "persons": 0, "frames": 1})
    assert room.snapshot().state == UNKNOWN


def test_same_frame_is_not_counted_twice():
    clock = _Clock()
    room = _room(clock)
    for _ in range(5):
        clock.t += 1
        room.observe({"ts": clock.t, "persons": 1, "frames": 7})
    assert room.snapshot().state == IDLE, "감지기가 멈춰 같은 장면을 다시 써도 '연속 3장'이 되지 않는다"


def test_room_route_reports_off_without_detector(monkeypatch):
    from fastapi.testclient import TestClient

    import rpi.api.room_presence_wiring as wiring
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_ROOM_PRESENCE_FILE", raising=False)
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    wiring.get_room_presence.cache_clear()
    try:
        body = TestClient(app).get("/presence/room").json()
    finally:
        wiring.get_room_presence.cache_clear()
    assert body["enabled"] is False
    assert body["sleep_screen"] is False


def test_greeting_table_weekday_weekend_and_name():
    """10/26 다시 쓴 인사 — '다녀오셨어요'에 때에 맞는 한마디, 아침은 아침 인사, 이름은 앞에."""
    from datetime import datetime

    from rpi.services.room_presence import greeting_for

    assert greeting_for(datetime(2026, 10, 26, 19, 0), "성원") == "성원님, 다녀오셨어요. 오늘도 수고 많으셨어요."  # 월
    assert greeting_for(datetime(2026, 10, 25, 19, 0)) == "다녀오셨어요. 편안한 저녁 보내세요."  # 일
    assert greeting_for(datetime(2026, 10, 26, 14, 0)) == "다녀오셨어요."
    assert greeting_for(datetime(2026, 10, 26, 8, 0)) == "좋은 아침이에요."
    assert greeting_for(datetime(2026, 10, 26, 23, 30)) == "늦게 오셨네요. 편히 쉬세요."


def test_greets_only_after_a_long_absence_and_not_again_within_the_gap():
    """찍힐 때마다 인사하지 않는다(10/25 사용자) — 잠깐 자리 비움은 조용히, 외출 뒤에도 몇 시간에 한 번."""
    clock = _Clock()
    room = RoomPresence(now=clock, arrive_frames=3, dim_after_s=60, away_after_s=600, stale_s=20, greet_gap_s=3600,
                        greet_after_s=600)
    feed = _Feed(room, clock)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().greet is False  # 켜진 뒤 첫 등장(자리 비움에서)
    feed.frame(0, advance=120)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().greet is False  # 잠깐 자리 비움 — 화면만
    feed.frame(0, advance=700)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().greet is True  # 오래 비웠다 돌아옴
    feed.frame(0, advance=700)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().greet is False, "한 시간 안에 또 인사하지 않는다"


def test_no_greeting_unless_gone_for_three_hours():
    """10/26 사용자 — 3시간 이상 안 보이다 돌아왔을 때만 인사. 1시간 외출(자리 비움 판정은 지났어도)은 화면만 켠다."""
    clock = _Clock()
    room = RoomPresence(now=clock, arrive_frames=3, dim_after_s=600, away_after_s=3600, stale_s=20)
    feed = _Feed(room, clock)
    for _ in range(3):
        feed.frame(1)
    feed.frame(0, advance=3700)          # 1시간 남짓 — 외출 판정은 지났다
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().greet is False
    feed.frame(0, advance=3 * 3600 + 60)  # 3시간 넘게
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().greet is True


def test_arrival_remembers_where_it_came_back_from():
    clock = _Clock()
    room = _room(clock)
    feed = _Feed(room, clock)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().arrived_from == IDLE  # 켜진 뒤 첫 등장은 자리 비움에서 돌아온 것
    feed.frame(0, advance=700)
    for _ in range(3):
        feed.frame(1)
    assert room.snapshot().arrived_from == AWAY


def test_absence_is_republished_every_cycle_so_the_store_does_not_expire_back_to_unknown():
    """Codex 검토 10/25 — 부재를 바뀔 때 한 번만 적으면 저장소 TTL(60초) 뒤 '모름'이 돼 제안 보류가 풀렸다."""
    import rpi.api.deps as deps
    from rpi.api.room_presence_wiring import _publish

    clock = _Clock()
    room = _room(clock)
    _Feed(room, clock).frame(0)
    assert room.snapshot().state == IDLE
    store = deps.get_presence_store()
    _publish(room)
    assert store.current().present is False


def test_camera_switch_writes_the_flag_the_detector_obeys(tmp_path, monkeypatch):
    """카메라 끄기(가이드라인 '전체 제어', 2026-10-25) — 끄면 표시 파일이 생기고 판단은 읽지 않는다."""
    from fastapi.testclient import TestClient

    import rpi.api.room_presence_wiring as wiring
    from rpi.main import app

    monkeypatch.setenv("SIMPLELAY_ROOM_PRESENCE_FILE", str(tmp_path / "presence_cam.json"))
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    wiring.get_room_presence.cache_clear()
    try:
        client = TestClient(app)
        off = client.post("/presence/room/camera", json={"enabled": False}).json()
        assert off["camera_enabled"] is False
        assert (tmp_path / "presence_camera_off").exists()
        on = client.post("/presence/room/camera", json={"enabled": True}).json()
        assert on["camera_enabled"] is True
        assert not (tmp_path / "presence_camera_off").exists()
    finally:
        wiring.get_room_presence.cache_clear()


def test_camera_switch_without_detector_is_refused(monkeypatch):
    from fastapi.testclient import TestClient

    import rpi.api.room_presence_wiring as wiring
    from rpi.main import app

    monkeypatch.delenv("SIMPLELAY_ROOM_PRESENCE_FILE", raising=False)
    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    wiring.get_room_presence.cache_clear()
    try:
        assert TestClient(app).post("/presence/room/camera", json={"enabled": False}).status_code == 409
    finally:
        wiring.get_room_presence.cache_clear()


def test_profile_name_is_cleaned_and_kept_on_the_hub(monkeypatch):
    from fastapi.testclient import TestClient

    from rpi.main import app

    monkeypatch.setenv("SIMPLELAY_ALLOW_UNAUTHENTICATED", "1")
    client = TestClient(app)
    assert client.put("/profile", json={"name": "  성원  "}).json() == {"name": "성원"}
    assert client.get("/profile").json() == {"name": "성원"}
    assert client.put("/profile", json={"name": "가" * 11}).status_code == 422
    assert client.put("/profile", json={"name": None}).json() == {"name": None}
