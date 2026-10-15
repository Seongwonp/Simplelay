"""모든 HTTP 경로가 API 키 검사(`require_api_key`)를 거치는지 본다 — 허용 목록만 예외.

왜 필요한가: 인증은 `rpi/main.py`에서 라우터를 붙일 때 `dependencies=[Depends(require_api_key)]`로 건다.
라우터를 새로 만들거나 경로를 `app`에 직접 붙일 때 이 한 줄을 빠뜨리면 그 경로는 LAN에 키 없이 열린다.
`test_auth.py`는 대표 경로 몇 개의 동작을 보지만 **새로 늘어난 경로**는 보지 않는다. 이 시험은 앱에 등록된
경로 전체를 훑어, 의존성 나무(라우터·경로·하위 의존성)에 `require_api_key`가 없는 경로가 허용 목록 밖에
있으면 실패한다.

허용 목록은 `rpi/main.py`·`rpi/api/auth.py`·`rpi/api/pairing.py`·`rpi/api/twin_router.py`에서 의도적으로
키 없이 연 경로다. 목록의 각 항목은 **이유**와, 키 대신 거는 검사가 있으면 그 검사 이름을 함께 적는다
(예: 연결 창 열기·승인은 `_local_screen` — 같은 허브 화면에서만).

경로 펼치기: FastAPI 판에 따라 `include_router`가 경로를 복사해 붙이기도(`APIRoute`) 하고, 포함 정보만 남겨 두고
요청 때 펼치기도 한다. 뒤의 경우를 위해 `effective_route_contexts()`가 있으면 그것으로 펼친다. 펼치기가 판 변경으로
조용히 깨지면 검사할 경로가 0개가 되어 통과해 버리므로, OpenAPI 명세의 모든 동작이 펼친 목록에 있는지와
보호된 경로 수의 하한을 함께 본다.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, FastAPI

from rpi.api.auth import require_api_key
from rpi.main import app

# (메서드, 경로) → (이유, 키 대신 반드시 있어야 하는 검사 이름 또는 None)
INTENTIONALLY_PUBLIC: dict[tuple[str, str], tuple[str, str | None]] = {
    ("GET", "/health"): ("생존·버전만 — 상세는 키가 필요한 /health/detail (main.py)", None),
    ("GET", "/ui"): ("옛 HTML 키오스크 화면 파일 — 데이터 호출은 키 경로를 쓴다 (main.py)", None),
    ("GET", "/kiosk"): ("키오스크 웹 빌드가 없을 때의 안내 화면 (main.py mount_kiosk)", None),
    ("GET", "/twin"): ("디지털 트윈 화면 파일 — 상태·재생은 키가 필요한 /twin/* (twin_router.py)", None),
    ("GET", "/twin-motion.js"): ("디지털 트윈 화면 스크립트 (twin_router.py)", None),
    # 폰 연결(페어링) — 키를 아직 모르는 폰이 키를 받아 가는 길이다. 창 열기·승인은 허브 화면(루프백)에서만.
    ("POST", "/pair/session"): ("연결 창 열기", "_local_screen"),
    ("GET", "/pair/session"): ("연결 창 상태", "_local_screen"),
    ("DELETE", "/pair/session"): ("연결 창 닫기", "_local_screen"),
    ("POST", "/pair/approve"): ("허브 화면의 연결 승인", "_local_screen"),
    ("POST", "/pair"): ("폰이 6자리 코드로 연결 요청 — 5분 창·허브 화면 승인이 따로 막는다 (pairing.py)", None),
    ("POST", "/pair/result"): ("폰이 받은 일회용 토큰으로 결과 조회 (pairing.py)", None),
}

# 프레임워크가 붙이는 API 문서 경로(`/docs`·`/redoc`·`/openapi.json`). 의존성 나무가 없는 일반 경로라
# 키 없이 열려 있다. 경로·스키마 목록만 보이고 상태·제어는 없지만, 막을지는 **결정 대기**다
# (2026-10-15 코드 구조 정리 때 발견·보고, 이 시험은 지금 상태를 기록할 뿐 고치지 않는다).
FRAMEWORK_DOC_PATHS = frozenset({"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"})

# 정적 파일 묶음(mount). 키오스크 웹 빌드가 있을 때 `/kiosk`가 여기로 붙는다(같은 출처 서빙).
PUBLIC_MOUNTS = frozenset({"/kiosk"})

# 10/15 기준 키가 필요한 경로는 120개를 넘는다. 펼치기가 깨져 0개를 검사하는 일을 막는 하한.
MIN_PROTECTED_ROUTES = 100


def _flatten(routes):
    for route in routes:
        expand = getattr(route, "effective_route_contexts", None)
        if callable(expand):
            yield from expand()
        else:
            yield route


def _calls(dependant) -> list:
    out = [dependant.call]
    for sub in dependant.dependencies:
        out.extend(_calls(sub))
    return out


def _guard_names(dependant) -> set[str]:
    return {getattr(call, "__name__", "") for call in _calls(dependant)[1:]}


def classify(target: FastAPI):
    """(보호된 (메서드, 경로) 집합, 보호 안 된 [(메서드, 경로, 검사 이름들)], 의존성 나무가 없는 경로·mount 경로)."""
    protected: set[tuple[str, str]] = set()
    open_routes: list[tuple[str, str, set[str]]] = []
    other_paths: set[str] = set()
    for route in _flatten(target.routes):
        dependant = getattr(route, "dependant", None)
        path = getattr(route, "path", "")
        if dependant is None:
            other_paths.add(path)
            continue
        is_protected = require_api_key in _calls(dependant)
        for method in sorted(route.methods or ()):
            if is_protected:
                protected.add((method, path))
            else:
                open_routes.append((method, path, _guard_names(dependant)))
    return protected, open_routes, other_paths


def unexpected_open_routes(target: FastAPI) -> list[str]:
    """허용 목록 밖에서 키 검사 없이 열린 경로, 허용 목록 안이지만 대신 걸 검사가 빠진 경로."""
    _protected, open_routes, other_paths = classify(target)
    problems = []
    for method, path, guards in open_routes:
        allowed = INTENTIONALLY_PUBLIC.get((method, path))
        if allowed is None:
            problems.append(f"{method} {path}: require_api_key 없음")
        elif allowed[1] is not None and allowed[1] not in guards:
            problems.append(f"{method} {path}: 대신 걸어야 할 {allowed[1]} 없음")
    for path in sorted(other_paths - FRAMEWORK_DOC_PATHS - PUBLIC_MOUNTS):
        problems.append(f"{path}: 의존성 나무가 없는 경로(정적·직접 등록) — 인증을 검사할 수 없음")
    return problems


def test_every_route_requires_api_key_except_allow_list():
    problems = unexpected_open_routes(app)
    assert not problems, (
        "키 검사 없이 열린 경로가 있다. 라우터를 붙일 때 dependencies=[Depends(require_api_key)]를 걸거나, "
        "일부러 연 것이면 INTENTIONALLY_PUBLIC에 이유와 함께 적을 것:\n" + "\n".join(f"  {p}" for p in problems)
    )


def test_route_walk_covers_every_documented_operation():
    """펼치기가 판 변경으로 깨져도 조용히 통과하지 않게 — OpenAPI의 모든 동작이 펼친 목록에 있어야 한다."""
    protected, open_routes, _other = classify(app)
    walked = protected | {(m, p) for m, p, _g in open_routes}
    spec = app.openapi()
    documented = {
        (method.upper(), path)
        for path, item in spec["paths"].items()
        for method in item
        if method.upper() in {"GET", "POST", "PUT", "PATCH", "DELETE"}
    }
    missing = sorted(documented - walked)
    assert not missing, f"OpenAPI에는 있는데 경로 펼치기에서 빠진 동작: {missing}"
    assert len(protected) >= MIN_PROTECTED_ROUTES, (
        f"키가 필요한 경로가 {len(protected)}개뿐이다 — 경로 펼치기가 깨졌는지 확인할 것"
    )


def test_allow_list_has_no_stale_entries():
    """허용 목록이 실제보다 부풀면 나중에 생긴 진짜 구멍을 덮는다. 없는 경로·이제 보호되는 경로는 지운다.

    `/kiosk` 안내 화면은 키오스크 웹 빌드가 없을 때만 경로로 붙는다(빌드가 있으면 mount) — 그래서 뺀다.
    """
    protected, open_routes, _other = classify(app)
    open_keys = {(m, p) for m, p, _g in open_routes}
    stale = sorted(
        key for key in INTENTIONALLY_PUBLIC
        if key not in open_keys and key != ("GET", "/kiosk")
    )
    assert not stale, f"허용 목록에 있지만 키 없이 열린 경로가 아니다(지울 것): {stale}"
    newly_protected = sorted(key for key in INTENTIONALLY_PUBLIC if key in protected)
    assert not newly_protected, f"이제 키가 필요한 경로다(허용 목록에서 지울 것): {newly_protected}"


def test_checker_flags_a_router_added_without_the_dependency():
    """검사 자체가 살아 있는지 — 키 검사를 빠뜨린 라우터를 붙인 앱에서는 그 경로를 잡아야 한다."""
    probe = FastAPI()
    guarded = APIRouter()
    forgotten = APIRouter(prefix="/forgotten")

    @guarded.get("/guarded")
    def _guarded():
        return {}

    @forgotten.post("/execute")
    def _forgotten():
        return {}

    probe.include_router(guarded, dependencies=[Depends(require_api_key)])
    probe.include_router(forgotten)

    problems = unexpected_open_routes(probe)
    assert any("/forgotten/execute" in p for p in problems), problems
    assert not any("/guarded" in p for p in problems), problems
