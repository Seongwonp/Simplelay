"""공개 리포에 들어오면 안 되는 것을 막는 가드.

두 가지를 본다:

1. **플랫폼 벤더 고유 명칭** -- 파일 내용과 **파일 이름** 둘 다.
2. **문서·비밀 파일이 새로 추적되는 것** -- 내용 검사가 닿지 않는 종류다.

한 번 청소하고 끝내면 시간이 지나며 다시 스며든다. 이 테스트는 추적 중인(=공개되는)
파일만 훑어서 금지어가 허용되지 않은 위치에 나타나면 실패한다.

`.gitignore`는 **이미 추적되는 파일을 보호하지 않는다.** 그래서 무시 목록이 아니라
`git ls-files`(실제로 공개되는 것)를 기준으로 본다.

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
    # 스마트홈 제품명(thin+q)은 2026-09-22 팀 결정으로 목록에서 뺐다 -- 공개 제품명이고
    # 공식 공개 API(ThinQ Connect) 연동이 검토 대상이 되어 문서가 이름을 불러야 한다.
    # 플랫폼 내부 인터페이스·버스 이름(위 항목들)은 계속 막는다.
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
    # .gitignore와 같은 이유 -- 도커 빌드 컨텍스트에서 뺄 로컬 전용 폴더 이름을 적는다
    ".dockerignore",
    # 작업 규칙 문서(루트 CLAUDE.md)는 2026-10-14부터 여기 두지 않는다. 허용 목록에 있던 동안
    # 키오스크 구조 설명에 플랫폼 이름이 그대로 남았는데 가드가 잡지 못했다. 규칙 문서는
    # 로컬 전용 폴더를 이름 대신 "비공개 자료 폴더"로 부르면 되므로 예외가 필요 없다.
)

# 허용 목록에 다시 들어오면 안 되는 문서 -- 이름을 부를 필요가 없는데 공개되는 문서다.
_NEVER_ALLOWED = ("CLAUDE.md", "README.md")

# 아직 정리되지 않은 파일을 한시적으로 담는 곳. **지금은 비어 있다** -- 정리가 끝났다.
# 앞으로 대량 정리를 다시 하게 되면 여기에 경로를 넣어 단계적으로 줄여나가면 된다.
# 비어 있는 상태를 유지하는 것이 정상이고, 뭔가 들어간다면 그건 갚아야 할 빚이다.
_MIGRATION_DEBT: set[str] = set()


# 내용 검사가 닿지 않는 종류 -- 발표 자료·제공 문서·키 파일. 이런 것은 대개
# 통째로 비공개이거나 안에 무엇이 들었는지 diff로 확인할 수 없다.
# `.gitignore`는 이미 추적 중인 파일을 지켜주지 않으므로 여기서 따로 잡는다.
_FORBIDDEN_SUFFIXES = (
    ".pptx", ".ppt", ".pdf", ".docx", ".doc", ".xlsx", ".xls",
    ".hwp", ".hwpx", ".zip", ".7z", ".rar",
    ".pem", ".p12", ".pfx", ".key", ".keystore", ".jks", ".env",
)

# 규칙이 생기기 **전부터** 추적되던 파일. 새로 늘어나는 것만 막는 것이 이
# 목록의 목적이다.
#
# 여기 적혀 있다고 안전해진 것이 아니다 -- 이미 커밋 이력에 들어가 있고,
# `.gitignore`로도 되돌릴 수 없다. **이 파일을 다시 stage 하거나 갱신하지
# 않는다.** 이력에서 지우는 것은 되돌릴 수 없는 작업이라 사용자가 결정한다.
# 2026-10-06: 유일한 예외였던 발표 자료의 추적을 끊었다(git rm --cached, 로컬 파일은 남김).
# 이제 예외는 없다 -- 문서 파일이 다시 추적되면 이 가드가 막는다. 과거 커밋 이력에는 남아 있다.
_PRE_EXISTING_DOCUMENTS: frozenset[str] = frozenset()


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


def test_no_vendor_terms_in_tracked_file_names():
    """파일 **이름**도 공개된다. 내용만 보면 이름으로 새는 것을 못 잡는다."""
    offenders = {
        path: terms
        for path in _tracked_files()
        if not _is_allowed_always(path)
        and (terms := sorted(t for t in _FORBIDDEN_TERMS if t in path.lower()))
    }
    assert not offenders, (
        "추적되는 파일 이름에 플랫폼 벤더 고유 명칭이 들어갔다. 파일을 옮기거나, "
        "옮길 수 없는 이유가 있으면 _ALLOWED_ALWAYS에 근거와 함께 추가할 것:\n"
        + "\n".join(f"  {p}: {t}" for p, t in sorted(offenders.items()))
    )


def test_no_new_document_or_secret_files_are_tracked():
    """발표 자료·제공 문서·키 파일이 새로 추적되면 실패.

    내용 검사(_terms_in)는 바이너리를 읽지 못하고 조용히 건너뛴다. 그래서
    금지어 가드만으로는 PPTX·PDF 한 장이 통째로 공개되는 것을 못 막는다.
    """
    tracked = {
        path
        for path in _tracked_files()
        if path.lower().endswith(_FORBIDDEN_SUFFIXES)
    }
    unexpected = sorted(tracked - _PRE_EXISTING_DOCUMENTS)
    assert not unexpected, (
        "문서·비밀 파일이 공개 저장소에 추적되고 있다. `git rm --cached <파일>`로 "
        "추적을 풀고 .gitignore에 넣을 것. 이미 커밋했다면 이력에도 남아 있으므로 "
        "그 처리는 따로 판단할 것:\n" + "\n".join(f"  {p}" for p in unexpected)
    )


def test_pre_existing_document_list_has_no_stale_entries():
    """정리가 끝난 파일이 목록에 남아 있으면 실패 -- _MIGRATION_DEBT와 같은 이유다.
    목록이 부풀어 오른 채 굳으면 나중에 들어온 진짜 유출을 덮어버린다."""
    tracked = set(_tracked_files())
    stale = sorted(_PRE_EXISTING_DOCUMENTS - tracked)
    assert not stale, (
        "아래 파일은 이제 추적되지 않는다. _PRE_EXISTING_DOCUMENTS에서 지울 것:\n"
        + "\n".join(f"  {p}" for p in stale)
    )


def test_rule_and_entry_documents_are_not_exempt():
    """작업 규칙 문서·저장소 입구 문서는 허용 목록 밖이어야 한다(2026-10-14).

    CLAUDE.md를 허용 목록에 둔 동안 금지어가 그대로 남아도 가드가 통과했다.
    접두사 비교라 목록에 같은 이름이 다시 들어오면 이 시험이 실패한다.
    """
    exempt = [path for path in _NEVER_ALLOWED if _is_allowed_always(path)]
    assert not exempt, f"허용 목록에서 빼야 할 문서: {exempt}"
