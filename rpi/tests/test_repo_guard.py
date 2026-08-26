"""공개 리포에 플랫폼 벤더 고유 명칭이 새로 들어오는 것을 막는 가드.

한 번 청소하고 끝내면 시간이 지나며 다시 스며든다. 이 테스트는 추적 중인(=공개되는)
파일만 훑어서 금지어가 허용되지 않은 위치에 나타나면 실패한다.

금지어를 이 파일에 그대로 적으면 이 파일 자체가 유출이 되므로 조각으로 조립한다.

일부러 넣지 않은 것:
- D-Bus: freedesktop의 공개 IPC 표준이다
- vector db: 일반 기술 용어다
- 회사명 단독: 대회 주최·후원 관계는 공개 정보이고 작업 규칙 문서도 그 표현을 쓴다.
  **팀 결정으로 그대로 둔다** -- 막아야 할 것은 회사명이 아니라 내부 구현 세부다.
  네임스페이스 형태(버스 이름·오브젝트 경로)는 아래에서 계속 잡는다

플랫폼 이름 자체는 무관한 오픈소스 선형대수 라이브러리 이름과 철자가
겹친다. 처음엔 그래서 검사에서 뺐는데, 그 사이 문서에 플랫폼 이름이 그대로 들어간
문장이 실제로 남아 있었다. 이제는 검사하되 그 라이브러리 이름만 먼저 지우고 본다.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]

# 조각 조립 -- 이 소스에 금지어가 통째로 등장하지 않게 한다.
# 벤더 네임스페이스는 점 형태(버스 이름)와 슬래시 형태(오브젝트 경로) 둘 다 쓰인다.
# 점 형태만 검사하면 오브젝트 경로가 그대로 빠져나간다 -- 실제로 그렇게 놓친 적이 있다.
_FORBIDDEN_TERMS = (
    "eco" + "ai",
    "abus" + "ctl",
    "at" + "las",
    "com." + "lg",
    "com/" + "lg",
    "scar" + "thgap",
    "exa" + "one",
    "thin" + "q",
)

# 무관한 오픈소스 라이브러리 이름 -- 플랫폼 이름을 검사하기 전에 지운다
_UNRELATED_LOOKALIKES = ("lib" + "at" + "las",)

# 이름을 부르는 것 자체가 목적인 위치 -- 여기서 지우면 기능이 깨진다.
# (이 목록의 경로에도 조각 조립을 쓴다. 안 그러면 이 파일이 스스로 위반이 되고,
#  자기 자신을 통째로 검사에서 빼면 정작 여기 들어온 유출을 못 잡는다.)
_ALLOWED_ALWAYS = (
    # flutter 크로스빌드 툴이 만드는 플랫폼 디렉터리. 안드로이드의 android/와 같은
    # 자리라 이름이 고정이고, 기기 설치용 앱 ID도 여기서 나온다
    "rpi5-touchscreen-app/" + "at" + "las/",
    # 위 앱 ID로 결정되는 산출물 경로를 적어둔 빌드 안내
    "rpi5-touchscreen-app/README.md",
    # 무시할 로컬 전용 폴더의 이름을 적어야 하는 파일 -- 이름을 빼면 무시가 안 된다
    ".gitignore",
    # 같은 로컬 전용 폴더와 빌드 구조를 가리키는 작업 규칙 문서
    "CLAUDE.md",
)

# 아직 정리되지 않은 파일을 한시적으로 담는 곳. **지금은 비어 있다** -- 정리가 끝났다.
# 앞으로 대량 정리를 다시 하게 되면 여기에 경로를 넣어 단계적으로 줄여나가면 된다.
# 비어 있는 상태를 유지하는 것이 정상이고, 뭔가 들어간다면 그건 갚아야 할 빚이다.
_MIGRATION_DEBT: set[str] = set()


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
    for lookalike in _UNRELATED_LOOKALIKES:
        text = text.replace(lookalike, "")
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
