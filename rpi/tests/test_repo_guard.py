"""공개 리포에 플랫폼 벤더 고유 명칭이 새로 들어오는 것을 막는 가드.

한 번 청소하고 끝내면 시간이 지나며 다시 스며든다. 이 테스트는 추적 중인(=공개되는)
파일만 훑어서 금지어가 허용되지 않은 위치에 나타나면 실패한다.

금지어를 이 파일에 그대로 적으면 이 파일 자체가 유출이 되므로 조각으로 조립한다.

일반 용어라서 일부러 넣지 않은 것:
- D-Bus: freedesktop의 공개 IPC 표준이다
- vector db: 일반 기술 용어다
- 'platform' 단독: 무관한 오픈소스 선형대수 라이브러리(libatlas-base-dev)와 겹친다.
  벤더 네임스페이스로 쓰인 경우만 잡도록 접두어를 붙여 검사한다
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]

# 조각 조립 -- 이 소스에 금지어가 통째로 등장하지 않게 한다
_FORBIDDEN_TERMS = (
    "eco" + "ai",
    "abus" + "ctl",
    "com." + "platform",
    "com." + "lg",
    "scar" + "thgap",
    "exa" + "one",
    "thin" + "q",
)

# 바꿀 수 없는 위치 -- 빌드·설치 요구사항이라 이름을 바꾸면 동작이 깨진다.
#   flutter 크로스빌드 툴이 만드는 플랫폼 디렉터리(안드로이드의 android/와 같은 자리)와
#   기기 설치용 앱 ID, 그리고 그 앱 ID로 결정되는 산출물 경로를 적어둔 빌드 안내.
_ALLOWED_ALWAYS = (
    "rpi5-touchscreen-app/platform/",
    "rpi5-touchscreen-app/README.md",
)

# 아직 정리되지 않은 파일 -- 정리하면서 이 목록에서 지운다.
# 목록이 줄어드는 것이 곧 진행 상황이다. 새 파일이 여기 없이 금지어를 담으면 실패한다.
_MIGRATION_DEBT = {
    "CLAUDE.md",
    "docs/devlog_2026-08-26.md",
    "docs/inference-boundary.md",
    "docs/roadmap.md",
    "docs/결선로드맵.md",
    "rpi/api/deps.py",
    "rpi/controller/README.md",
    "rpi/controller/__init__.py",
    "rpi/controller/internal_gpio_gpio.py",
    "rpi/intent/__init__.py",
    "rpi/intent/dbus_internal_ai.py",
    "rpi/intent/dbus_vectordb.py",
    "rpi/tests/test_internal_gpio_gpio.py",
    "rpi/tests/test_dbus_internal_ai.py",
    "rpi/tests/test_deps.py",
    "rpi/tests/test_vectordb_intent.py",
}


def _tracked_files() -> list[str]:
    """git이 추적하는 파일 = 공개되는 파일. -z로 받아야 한글 경로가 이스케이프되지 않는다."""
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=_REPO_ROOT,
        capture_output=True,
        timeout=30,
    )
    if result.returncode != 0:
        pytest.skip("git ls-files를 실행할 수 없음 (git 저장소가 아니거나 git 미설치)")
    return [p for p in result.stdout.decode("utf-8").split("\0") if p]


def _terms_in(path: str) -> list[str]:
    try:
        text = (_REPO_ROOT / path).read_text(encoding="utf-8").lower()
    except (UnicodeDecodeError, OSError):
        return []  # 바이너리이거나 읽을 수 없는 파일은 검사 대상 밖
    return sorted(term for term in _FORBIDDEN_TERMS if term in text)


def _is_allowed_always(path: str) -> bool:
    return any(path.startswith(prefix) for prefix in _ALLOWED_ALWAYS)


def _offenders() -> dict[str, list[str]]:
    return {
        path: terms
        for path in _tracked_files()
        if not _is_allowed_always(path) and (terms := _terms_in(path))
    }


def test_no_new_vendor_terms_in_tracked_files():
    """허용 목록에 없는 곳에서 벤더 고유 명칭이 발견되면 실패."""
    unexpected = {
        path: terms
        for path, terms in _offenders().items()
        if path not in _MIGRATION_DEBT
    }
    assert not unexpected, (
        "공개되는 파일에 플랫폼 벤더 고유 명칭이 들어갔다. 일반적인 기능 설명으로 바꾸거나, "
        "바꿀 수 없는 이유가 있으면 _ALLOWED_ALWAYS에 근거와 함께 추가할 것:\n"
        + "\n".join(f"  {p}: {t}" for p, t in sorted(unexpected.items()))
    )


def test_migration_debt_list_has_no_stale_entries():
    """이미 정리된 파일이 목록에 남아 있으면 실패 -- 목록이 실제 상태를 반영하도록 강제한다.

    이게 없으면 목록이 한 번 부풀어 오른 뒤 영영 줄지 않고, 나중에 들어온 진짜 유출까지
    조용히 덮어버린다.
    """
    offending_paths = set(_offenders())
    stale = sorted(_MIGRATION_DEBT - offending_paths)
    assert not stale, (
        "아래 파일은 이제 깨끗하다. _MIGRATION_DEBT에서 지울 것:\n"
        + "\n".join(f"  {p}" for p in stale)
    )
