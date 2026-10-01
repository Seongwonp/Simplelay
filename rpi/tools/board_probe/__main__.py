import argparse
import os
from pathlib import Path

from .active import run_active
from .core import load_config, metadata, outside, run_check, save


def main():
    parser = argparse.ArgumentParser(description="로컬 보드 점검(기본 읽기 전용)")
    parser.add_argument("--active", action="store_true")
    parser.add_argument("--i-understand-active", action="store_true")
    args = parser.parse_args()
    if args.active and not args.i_understand_active:
        parser.error("--active에는 --i-understand-active가 필요합니다")
    output = outside(os.getenv("SIMPLELAY_PROBE_OUT", str(Path.home() / "simplelay-probe")))
    cfg = load_config(os.environ["SIMPLELAY_PROBE_CONFIG"])
    report = metadata()
    report["mode"] = "active" if args.active else "read_only"
    report["checks"] = [run_check(c, cfg["app_account"]) for c in cfg["checks"]]
    if args.active:
        report["active"] = run_active(cfg, args.i_understand_active)
    save(report, output)
    print("로컬 점검 기록 저장 완료")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
