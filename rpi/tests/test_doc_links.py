"""추적 중인 마크다운의 상대 링크가 실제 파일을 가리키는지 본다.

2026-10-13 문서 정리(devlog → docs/devlog/, 옛 문서 → docs/archive/) 때 만들었다. 그전에는
문서 링크를 검사하는 시험이 없어서, 파일을 옮기거나 이름을 바꾸면 링크가 조용히 깨졌다.

검사 범위:
- `git ls-files`로 얻은 추적 중인 `.md` 파일만 본다(공개되는 것 기준).
- 인라인 링크 `[글](대상)`·이미지 `![글](대상)`·참조 정의 `[이름]: 대상`.
- 외부 URL(`http:`·`https:`·`mailto:` 등 스킴이 있는 것)과 앵커만 있는 링크(`#…`)는 뺀다.
  대상의 `#앵커`·`?질의`는 떼고 파일만 본다(앵커 존재는 검사하지 않는다).
- 백틱 코드(`…`)와 펜스 코드 블록 안의 글은 링크로 보지 않는다.
- 대상은 그 문서가 있는 폴더 기준 상대 경로(`/`로 시작하면 저장소 루트 기준)이고,
  추적 중인 파일이나 추적 파일을 담은 폴더여야 한다.

허용 목록은 두지 않는다. 깨진 링크는 고친다.
"""

from __future__ import annotations

import posixpath
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote

_REPO_ROOT = Path(__file__).resolve().parents[2]

_FENCE = re.compile(r"^\s*(```|~~~)")
_CODE_SPAN = re.compile(r"(`+)(?:(?!\1).)+?\1")
# [글](대상) — 글 안의 중첩 대괄호 한 단계까지, 대상은 <…> 또는 괄호 짝 한 단계까지
_INLINE = re.compile(
    r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(<[^>]*>|(?:[^()\s]|\([^()\s]*\))+)(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)"
)
_REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def tracked_files(root: Path = _REPO_ROOT) -> list[str]:
    out = subprocess.run(
        ["git", "-c", "core.quotepath=off", "ls-files", "-z"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout
    return [p for p in out.decode("utf-8").split("\0") if p]


def iter_link_targets(text: str):
    """(줄 번호, 원래 대상 문자열)을 낸다. 코드 블록·백틱 안은 건너뛴다."""
    in_fence = False
    fence_mark = ""
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = _FENCE.match(line)
        if m:
            mark = m.group(1)
            if not in_fence:
                in_fence, fence_mark = True, mark
            elif mark == fence_mark:
                in_fence = False
            continue
        if in_fence:
            continue
        # 4칸 들여쓴 코드 블록은 목록 이어쓰기와 구분이 어려워 따로 다루지 않는다
        body = _CODE_SPAN.sub(lambda s: " " * len(s.group(0)), line)
        for m in _INLINE.finditer(body):
            yield lineno, m.group(1)
        m = _REF_DEF.match(body)
        if m:
            yield lineno, m.group(1)


def resolve_target(md_path: str, raw: str) -> str | None:
    """검사할 저장소 상대 경로. 검사 대상이 아니면 None."""
    target = raw.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1].strip()
    if not target or target.startswith("#") or _SCHEME.match(target):
        return None
    target = target.split("#", 1)[0].split("?", 1)[0]
    if not target:
        return None
    target = unquote(target).replace("\\", "/")
    if target.startswith("/"):
        joined = target.lstrip("/")
    else:
        joined = posixpath.join(posixpath.dirname(md_path), target)
    return posixpath.normpath(joined)


def find_broken_links(root: Path = _REPO_ROOT) -> list[str]:
    files = tracked_files(root)
    tracked = set(files)
    dirs: set[str] = set()
    for f in files:
        parts = f.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    broken: list[str] = []
    for md in files:
        if not md.lower().endswith(".md"):
            continue
        path = root / md
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, raw in iter_link_targets(text):
            resolved = resolve_target(md, raw)
            if resolved is None:
                continue
            if resolved in tracked or resolved in dirs or resolved == ".":
                continue
            broken.append(f"{md}:{lineno}: ({raw}) -> {resolved}")
    return broken


def test_tracked_markdown_relative_links_resolve() -> None:
    broken = find_broken_links()
    assert not broken, "깨진 상대 링크 %d개:\n%s" % (len(broken), "\n".join(broken))


def test_link_parser_skips_code_urls_and_anchors() -> None:
    text = "\n".join(
        [
            "[a](docs/x.md#s) [b](https://e.com/y.md) [c](#top) `[d](nope.md)`",
            "```",
            "[e](inside-fence.md)",
            "```",
            "![img](../pic.png \"제목\") [f](<경로 공백.md>)",
            "[ref]: ./ref.md",
        ]
    )
    got = [resolve_target("docs/a.md", raw) for _, raw in iter_link_targets(text)]
    assert [g for g in got if g is not None] == [
        "docs/docs/x.md",
        "pic.png",
        "docs/경로 공백.md",
        "docs/ref.md",
    ]
