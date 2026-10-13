"""ThinQ 실물 확인 스크립트 — 서버 기능이 아니다(절차: docs/ThinQ-실물-확인-절차.md).

공식 SDK(``thinqconnect`` 1.0.14)로 **기기 목록 → 프로필 → 상태**를 읽는다. 기본은 읽기 전용이다.
``--control <가전> <동작> <값>``을 주면 확인 질문에 ``yes``라고 답했을 때만 **한 번** 보내고,
서버와 같은 실행기(``ThinqController``: 프로필 판정·원격 시작 조건·상태 재조회 확인)로 결과를
적는다. 자동 재전송은 없다.

비밀은 명령줄에 쓰지 않는다. PAT는 환경 변수 ``SIMPLELAY_THINQ_PAT`` 또는 저장소 밖 파일
``SIMPLELAY_THINQ_PAT_FILE``, 클라이언트 ID는 ``SIMPLELAY_THINQ_CLIENT_ID_FILE``(기본
``~/.simplelay/thinq_client_id``, 없으면 한 번 만들어 계속 쓴다)에서 읽는다.

원본 응답(기기 ID가 들어 있다)은 ``--out``(기본 ``~/.simplelay/thinq_probe/<시각>``) 폴더에만 쓴다.
저장소 안 폴더는 거절한다. 화면에는 기기 ID를 끝 4자만 보인다.

    .\\.venv\\Scripts\\python.exe scripts\\thinq_probe.py                      # 읽기 전용
    .\\.venv\\Scripts\\python.exe scripts\\thinq_probe.py --control air_purifier set_wind_strength HIGH
    .\\.venv\\Scripts\\python.exe scripts\\thinq_probe.py --fake-cloud http://127.0.0.1:8790   # 연습
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Callable
from pathlib import Path

# scripts/에서 바로 실행해도 서버 모듈을 쓰도록 리포 루트를 경로에 넣는다
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from rpi.commands import Command  # noqa: E402
from rpi.controller.models import ExecutionMode  # noqa: E402
from rpi.services.thinq.bindings import (  # noqa: E402
    AIR_PURIFIER_DEVICE_TYPE,
    DEHUMIDIFIER_DEVICE_TYPE,
    WASHER_DEVICE_TYPE,
    CapabilityError,
    air_purifier_binding,
    dehumidifier_binding,
    washer_binding,
)
from rpi.services.thinq.client import ThinqClientError  # noqa: E402
from rpi.services.thinq.config import (  # noqa: E402
    COUNTRY_ENV,
    _outside_repo,
    is_loopback_url,
    load_access_token,
    load_or_create_client_id,
)
from rpi.services.thinq.controller import ThinqController  # noqa: E402
from rpi.services.thinq.config import ThinqMode  # noqa: E402
from rpi.services.thinq.profile import DeviceProfile  # noqa: E402

KINDS = {
    "air_purifier": (AIR_PURIFIER_DEVICE_TYPE, air_purifier_binding),
    "washer": (WASHER_DEVICE_TYPE, washer_binding),
    "dehumidifier": (DEHUMIDIFIER_DEVICE_TYPE, dehumidifier_binding),
}
BINDING_BY_TYPE = {device_type: factory for device_type, factory in KINDS.values()}


def _mask(device_id: str) -> str:
    return f"…{device_id[-4:]}" if len(device_id) > 4 else "…"


def _write(out: Path, name: str, data) -> None:
    (out / name).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _support_lines(device_type: str, device_id: str, profile: dict) -> list[str]:
    factory = BINDING_BY_TYPE.get(device_type)
    if factory is None:
        return ["  (SimpleLay 동작 표가 없는 종류 — 읽기만)"]
    binding = factory(device_id)
    view = DeviceProfile(profile)
    lines = []
    for cap in binding.capabilities:
        key, spec, refusal = ThinqController._resolve(view, cap)
        if refusal is not None:
            lines.append(f"  {cap.action}({cap.label}): 프로필에 쓰기 속성 없음 → 실행 전 거절")
            continue
        allowed = [v for v in cap.allowed if spec is not None and spec.accepts(v)]
        missing = [v for v in cap.allowed if v not in allowed]
        lines.append(f"  {cap.action}({cap.label}) {cap.resource}.{key}: 허용 {allowed or '없음'}"
                     + (f", 프로필에 없음 {missing}" if missing else ""))
    if not lines:
        lines.append("  (쓰기 동작 없음 — 읽기 전용)")
    return lines


def main(argv: list[str] | None = None, *, input_fn: Callable[[str], str] = input) -> int:
    parser = argparse.ArgumentParser(description="ThinQ 실물 확인(기본 읽기 전용)")
    parser.add_argument("--out", help="원본 응답을 쓸 저장소 밖 폴더")
    parser.add_argument("--device", help="여러 대일 때 제어할 기기 ID")
    parser.add_argument("--control", nargs=3, metavar=("KIND", "ACTION", "VALUE"),
                        help=f"한 번 제어(확인 질문 뒤). KIND: {', '.join(KINDS)}")
    parser.add_argument("--confirm-seconds", type=float, default=10.0,
                        help="제어 뒤 상태 재조회로 확인할 시간(초)")
    parser.add_argument("--fake-cloud", help="연습용 모의 클라우드 주소(127.0.0.1) — 실제 클라우드 아님")
    args = parser.parse_args(argv)

    import os  # noqa: PLC0415

    try:
        from rpi.services.thinq.sdk_client import SdkThinqClient  # noqa: PLC0415

        out = Path(args.out) if args.out else (
            Path.home() / ".simplelay" / "thinq_probe" / time.strftime("%Y%m%d-%H%M%S"))
        out = _outside_repo(out, "원본 응답")
        if args.fake_cloud:
            if not is_loopback_url(args.fake_cloud):
                raise RuntimeError("--fake-cloud는 http://127.0.0.1:<포트>만 받습니다")
            from rpi.tools.fake_thinq_cloud import FAKE_CLOUD_TOKEN  # noqa: PLC0415

            token, mode, label = FAKE_CLOUD_TOKEN, ExecutionMode.MOCK, "모의 클라우드(실제 아님)"
        else:
            token = load_access_token()
            if not token:
                raise RuntimeError("PAT가 없습니다 — SIMPLELAY_THINQ_PAT 또는 저장소 밖 파일 "
                                   "SIMPLELAY_THINQ_PAT_FILE을 설정하세요")
            mode, label = ExecutionMode.REAL, "실제 ThinQ 클라우드"
        country = os.environ.get(COUNTRY_ENV, "KR").strip().upper() or "KR"
        client = SdkThinqClient(access_token=token, country=country,
                                client_id=load_or_create_client_id(), execution_mode=mode,
                                base_url=args.fake_cloud)
        del token
    except RuntimeError as exc:
        print(f"시작하지 못했어요: {exc}", file=sys.stderr)
        return 2

    try:
        out.mkdir(parents=True, exist_ok=True)
        print(f"[{label}] 국가 {country} — 원본 응답 저장 위치(저장소 밖): {out}")
        try:
            devices = client.list_devices()
        except ThinqClientError as exc:
            print(f"기기 목록을 읽지 못했어요: {exc.reason}", file=sys.stderr)
            return 1
        _write(out, "devices.json", [d.__dict__ for d in devices])
        summary = [f"{label} · {time.strftime('%Y-%m-%d %H:%M:%S')} · 기기 {len(devices)}대"]
        env_lines = []
        for index, device in enumerate(devices, 1):
            head = (f"[{index}] {device.device_type} 모델 {device.model_name or '?'} "
                    f"별칭 {device.alias or '?'} ID {_mask(device.device_id)}")
            print(head)
            summary.append(head)
            for name, call in (("profile", client.get_profile), ("state", client.get_status)):
                try:
                    data = call(device.device_id)
                    _write(out, f"{index}_{device.device_type}_{name}.json", data)
                except ThinqClientError as exc:
                    data = None
                    line = f"  {name}: 읽지 못함 — {exc.reason}"
                    print(line)
                    summary.append(line)
                if name == "profile" and data is not None:
                    for line in _support_lines(device.device_type, device.device_id, data):
                        print(line)
                        summary.append(line)
            for kind, (device_type, _) in KINDS.items():
                if device.device_type == device_type:
                    env_lines.append(f"SIMPLELAY_THINQ_DEVICE_{kind.upper()}={device.device_id}")
        (out / "summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
        (out / "env.txt").write_text("\n".join(env_lines) + "\n", encoding="utf-8")
        print(f"요약: {out / 'summary.txt'} · 환경 변수 후보(기기 ID 포함, 커밋 금지): {out / 'env.txt'}")

        if not args.control:
            print("읽기 전용으로 끝냈어요 — 제어는 보내지 않았어요.")
            return 0
        return _control_once(client, devices, args, out, input_fn)
    finally:
        client.close()


def _control_once(client, devices, args, out: Path, input_fn) -> int:
    kind, action, value = args.control
    if kind not in KINDS:
        print(f"모르는 가전 종류: {kind}", file=sys.stderr)
        return 2
    device_type, factory = KINDS[kind]
    candidates = [d for d in devices if d.device_type == device_type
                  and (args.device is None or d.device_id == args.device)]
    if len(candidates) != 1:
        print(f"{kind} 기기가 {len(candidates)}대예요 — --device로 하나를 고르세요", file=sys.stderr)
        return 2
    device = candidates[0]
    binding = factory(device.device_id)
    try:
        cap = binding.capability(action)
        command = binding.command(kind, action, {cap.arg: value})
    except CapabilityError as exc:
        print(f"보내지 않았어요: {exc}", file=sys.stderr)
        return 2
    answer = input_fn(f"{device.alias or kind}({_mask(device.device_id)})에 '{cap.label} "
                      f"{cap.value_label(value)}'을(를) 한 번 보낼까요? 보내려면 yes: ")
    if answer.strip().lower() != "yes":
        print("보내지 않았어요(확인 안 함).")
        return 1
    controller = ThinqController(client, lambda _id: binding, mode=ThinqMode.REAL
                                 if client.execution_mode is ExecutionMode.REAL else ThinqMode.FAKE_CLOUD,
                                 confirm_seconds=args.confirm_seconds, poll_interval=1.0)
    result = controller.execute_command(command)
    record = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "kind": kind, "action": action, "value": value,
        "status": result.status.value, "receipt": result.receipt.value,
        "confirmation": result.confirmation.value, "execution_mode": result.execution_mode.value,
        "detail": result.detail,
    }
    try:
        record["state_after"] = client.get_status(device.device_id)
    except ThinqClientError as exc:
        record["state_after_error"] = exc.reason
    _write(out, "control.json", record)
    print(f"결과: {record['status']} / {record['receipt']} / {record['confirmation']} "
          f"({record['execution_mode']}) — {record['detail']}")
    return 0 if result.status.value == "succeeded" else 1


if __name__ == "__main__":
    raise SystemExit(main())
