"""Isolated rehearsal server: python -m rpi.simulator_main --port 8765.

Default loopback only. Use --host 0.0.0.0 explicitly for phones on your LAN.
No production database, remote node, GPIO, serial device or model API is used.

``SIMPLELAY_LOCAL_APPLIANCES``(phone-registered appliance ids, comma separated) is kept as given,
so appliances registered for the rehearsal run on the simulator instead of answering 412
(2026-10-06, demo v3 gap S2). Built-in visibility still follows ACT_MODE=simulator.
"""
import argparse
import os
from collections.abc import MutableMapping


def prepare_environment(env: MutableMapping[str, str]) -> None:
    """리허설 런처가 고정하는 환경. 등록 가전을 로컬(시뮬레이터) 대상으로 밝히는
    ``SIMPLELAY_LOCAL_APPLIANCES``는 지우지 않는다 — 지우면 폰에서 등록한 가전이 모두 412였다."""
    env["SIMPLELAY_ACT_MODE"] = "simulator"
    # The simulator is a separate ephemeral workspace, never production history.
    env.pop("SIMPLELAY_DB_PATH", None)
    env["SIMPLELAY_GPIO_ENABLED"] = "false"
    env["SIMPLELAY_SENSORS_ENABLED"] = "false"
    env["SIMPLELAY_LLM_MODE"] = "mock"
    env.pop("SIMPLELAY_LLM_BASE_URL", None)
    env.pop("SIMPLELAY_VISION_BASE_URL", None)
    env["SIMPLELAY_VECTORDB_SEED"] = "false"
    env["SIMPLELAY_DEV_MODE"] = "false"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    prepare_environment(os.environ)
    from rpi.main import app

    def reject_remote(_address):
        raise ValueError("Simulator server does not connect to remote actuator nodes")

    # Both API and service use the same cached registry, with remote IO disabled.
    import rpi.api.deps as deps
    deps._node_controller_factory = lambda: reject_remote
    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
