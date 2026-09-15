"""조작부 사진 인식 게이트웨이 확인용 스크립트 — 서버 기능이 아니다.

서버(POST /panel-scan)와 **같은 요청 문구·같은 초안 변환**을 쓴다. 그래서 여기서
나온 초안이 곧 서버가 만들 초안이다. 확인하는 것:

1. 키·주소로 모델 목록과 크레딧이 보이는가
2. Chat Completions가 사진 입력을 받는가, 걸린 시간은 얼마인가
3. 응답이 버튼맵 초안으로 바뀌는가(축 순서가 맞는지 격자를 눈으로 확인)

키는 코드·명령줄에 쓰지 않는다. 환경 변수로만 받는다:

    $env:SIMPLELAY_VISION_BASE_URL = "https://<게이트웨이>/v1/gateway"
    $env:SIMPLELAY_VISION_API_KEY  = "<키>"
    .\\.venv\\Scripts\\python.exe scripts\\vision_gateway_probe.py --image panel.jpg --model <모델 id>

출력에 키를 찍지 않는다. 원문 응답은 --save로 로컬 파일에만 남긴다(커밋 금지).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# scripts/에서 바로 실행해도 서버 모듈을 쓰도록 리포 루트를 경로에 넣는다
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from rpi.vision import (  # noqa: E402
    HttpVisionClient,
    HttpVisionClientConfig,
    PanelScanError,
    VisionUnavailable,
    build_draft,
    parse_controls,
    sniff_image_mime,
)
from rpi.vision.client import USER_AGENT


def _get(url: str, key: str, timeout: float) -> tuple[int, dict | str]:
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {key}", "Accept": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            raw, status = res.read().decode("utf-8"), res.status
    except urllib.error.HTTPError as exc:
        raw, status = exc.read().decode("utf-8", "replace"), exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return 0, f"연결 실패: {exc.__class__.__name__}"
    try:
        return status, json.loads(raw)
    except json.JSONDecodeError:
        return status, raw


class _RecordingOpener:
    """원문 응답을 --save로 남기기 위해 한 번 가로챈다."""

    def __init__(self) -> None:
        self.raw: bytes | None = None

    def __call__(self, request, timeout):
        response = urllib.request.urlopen(request, timeout=timeout)
        body = response.read()
        self.raw = body
        response.close()

        class _Replay:
            def __enter__(self_inner):
                return self_inner

            def __exit__(self_inner, *exc):
                return False

            def read(self_inner):
                return body

        return _Replay()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--image", help="조작부 사진(jpg/png/webp)")
    parser.add_argument("--model", help="모델 id (--credits-only가 아니면 필수)")
    parser.add_argument("--credits-only", action="store_true", help="모델 목록·크레딧만 확인하고 끝낸다")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--save", help="원문 응답을 저장할 로컬 경로(선택, 커밋 금지)")
    args = parser.parse_args()

    raw_base = os.environ.get("SIMPLELAY_VISION_BASE_URL", "")
    raw_key = os.environ.get("SIMPLELAY_VISION_API_KEY", "")
    base = raw_base.strip().strip('"').strip("'").rstrip("/")
    key = raw_key.strip().strip('"').strip("'")
    if not base or not key:
        print("SIMPLELAY_VISION_BASE_URL / SIMPLELAY_VISION_API_KEY 환경 변수를 먼저 설정하세요.")
        return 2
    # 키 값은 찍지 않는다. 붙여넣기 실수(공백·따옴표·줄바꿈)만 드러낸다.
    print(
        f"[0] 주소: {base} · 키 길이 {len(key)}자"
        f"{' · 앞뒤 공백/따옴표 제거함' if key != raw_key else ''}"
        f"{' · 키에 공백 포함(확인 필요)' if any(c.isspace() for c in key) else ''}"
    )

    status, models = _get(f"{base}/models/?type=llm", key, args.timeout)
    if status == 200 and isinstance(models, dict):
        ids = [m.get("id") for m in models.get("data", [])]
        found = f", '{args.model}' 포함: {args.model in ids}" if args.model else ""
        print(f"[1] 모델 목록 OK — {len(ids)}개{found}")
    else:
        print(f"[1] 모델 목록 실패: HTTP {status} — 응답: {str(models)[:300]}")
    status, credits = _get(f"{base}/credits/", key, args.timeout)
    print(f"    크레딧 조회: HTTP {status} — {str(credits)[:300]}")
    if args.credits_only:
        return 0

    if not args.model:
        print("[2] --model을 지정하세요 (모델 id)")
        return 2
    if not args.image or not os.path.isfile(args.image):
        print(f"[2] 사진 파일이 없습니다: {os.path.abspath(args.image) if args.image else '(--image 미지정)'}")
        return 2
    with open(args.image, "rb") as fh:
        image = fh.read()
    mime = sniff_image_mime(image)
    if mime is None:
        print("[2] JPEG·PNG·WebP 사진만 보낼 수 있습니다")
        return 2
    print(f"    사진: {args.image} ({len(image) // 1024} KB, {mime})")

    opener = _RecordingOpener()
    client = HttpVisionClient(
        HttpVisionClientConfig(base_url=base, api_key=key, model=args.model, timeout_seconds=args.timeout),
        opener=opener,
    )
    started = time.monotonic()
    try:
        content = client.describe_panel(image, mime)
    except VisionUnavailable as exc:
        print(f"[2] 사진 요청 실패 ({time.monotonic() - started:.1f}초, HTTP {exc.status}): {exc}")
        return 1
    finally:
        if args.save and opener.raw is not None:
            with open(args.save, "wb") as fh:
                fh.write(opener.raw)
            print(f"    원문 저장: {args.save}")
    payload = json.loads(opener.raw or b"{}")
    print(f"[2] 사진 요청 OK — {time.monotonic() - started:.1f}초, usage={payload.get('usage')}")

    try:
        controls, dropped = parse_controls(content)
        draft = build_draft(controls, dropped)
    except PanelScanError as exc:
        print(f"[3] 초안 실패: {exc}")
        print(f"    원문 앞부분: {content[:500]}")
        return 1
    print(f"[3] 초안 OK — {draft.rows}행 x {draft.cols}열, 버튼 {len(draft.buttons)}개")
    for b in draft.buttons:
        flag = "" if b.label_from_model else " (임시 이름)"
        print(f"    ({b.x},{b.y}) {b.kind:6} {b.label}{flag}  box={[round(v) for v in b.box]}")
    for note in draft.dropped:
        print(f"    뺀 항목: {note}")
    print("    ↑ 격자 칸(열,행)이 사진 속 실제 배치와 같은지 눈으로 확인하세요(축 순서 검증)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
