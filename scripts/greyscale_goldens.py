#!/usr/bin/env python3
"""골든을 흑백 사본으로 바꿔 **색 없이도 위계가 서는지** 본다.

왜 필요한가: 색을 먼저 정하면 판단이 색으로 흘러간다. 제목·현재 상태·주
행동이 회색조에서 3초 안에 구분되지 않으면, 그건 색으로 가릴 문제가 아니라
크기·위치·굵기·여백으로 고칠 문제다. 구조가 선 다음에 팔레트를 얹는다.

앱 런타임에는 넣지 않는다 -- 검토용 보조 도구다. 결과물도 저장소에 넣지
않는다(기본 출력 경로가 .gitignore된 곳이다).

의존성 없이 표준 라이브러리만 쓴다. 8비트 비인터레이스 PNG(RGB/RGBA/회색)만
다루는데, Flutter 골든이 전부 그 형태다.

사용:
    py scripts/greyscale_goldens.py app/test/goldens
    py scripts/greyscale_goldens.py app/test/goldens --out dev-docs/bw
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import zlib

# 사람 눈의 밝기 가중치(Rec. 709). 단순 평균을 쓰면 파랑이 실제보다 밝게,
# 초록이 어둡게 나와 대비 판단이 어긋난다.
_R, _G, _B = 0.2126, 0.7152, 0.0722

_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _chunks(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "PNG이 아니다"
    i = 8
    while i < len(data):
        (length,) = struct.unpack(">I", data[i:i + 4])
        kind = data[i + 4:i + 8]
        yield kind, data[i + 8:i + 8 + length]
        i += 8 + length + 4  # 길이·종류·본문·CRC


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _unfilter(raw: bytes, width: int, height: int, bpp: int) -> bytearray:
    """스캔라인마다 앞에 붙은 필터 바이트를 되돌린다 (PNG 스펙 9절)."""
    stride = width * bpp
    out = bytearray(stride * height)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = raw[pos:pos + stride]
        pos += stride
        base = y * stride
        prev = base - stride
        for x in range(stride):
            v = line[x]
            a = out[base + x - bpp] if x >= bpp else 0
            b = out[prev + x] if y > 0 else 0
            c = out[prev + x - bpp] if (y > 0 and x >= bpp) else 0
            if ftype == 1:
                v += a
            elif ftype == 2:
                v += b
            elif ftype == 3:
                v += (a + b) >> 1
            elif ftype == 4:
                v += _paeth(a, b, c)
            elif ftype != 0:
                raise ValueError(f"알 수 없는 필터 {ftype}")
            out[base + x] = v & 0xFF
    return out


def _png(width: int, height: int, grey: bytearray) -> bytes:
    """회색조 8비트 PNG로 다시 묶는다."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # 필터 없음 -- 크기보다 단순함이 낫다
        raw += grey[y * width:(y + 1) * width]

    def chunk(kind: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


def desaturate(src: pathlib.Path, dst: pathlib.Path) -> None:
    data = src.read_bytes()
    idat = bytearray()
    width = height = depth = ctype = 0
    for kind, body in _chunks(data):
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(
                ">IIBBBBB", body)
            if depth != 8 or interlace != 0 or ctype not in _CHANNELS:
                raise ValueError(
                    f"{src.name}: 8비트 비인터레이스 PNG만 다룬다 "
                    f"(depth={depth} type={ctype} interlace={interlace})")
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break

    bpp = _CHANNELS[ctype]
    pixels = _unfilter(zlib.decompress(bytes(idat)), width, height, bpp)

    grey = bytearray(width * height)
    if bpp == 1:  # 이미 회색조
        grey[:] = pixels
    else:
        for i in range(width * height):
            p = i * bpp
            if ctype == 4:  # 회색 + 알파
                grey[i] = pixels[p]
            else:
                grey[i] = int(
                    _R * pixels[p] + _G * pixels[p + 1] + _B * pixels[p + 2])

    dst.write_bytes(_png(width, height, grey))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src", help="골든 폴더")
    ap.add_argument("--out", default="dev-docs/bw",
                    help="출력 폴더 (기본: dev-docs/bw — git 제외 경로)")
    args = ap.parse_args()

    src = pathlib.Path(args.src)
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    files = sorted(src.glob("*.png"))
    if not files:
        print(f"PNG이 없다: {src}", file=sys.stderr)
        return 1

    failed = 0
    for f in files:
        try:
            desaturate(f, out / f.name)
            print(f"  {f.name}")
        except Exception as exc:  # 한 장이 이상해도 나머지는 계속 본다
            failed += 1
            print(f"  {f.name}: {exc}", file=sys.stderr)

    print(f"\n{len(files) - failed}장 -> {out}")
    if failed:
        print(f"{failed}장 실패", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
