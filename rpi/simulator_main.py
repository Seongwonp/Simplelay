"""Isolated rehearsal server: python -m rpi.simulator_main --port 8765.

Default loopback only. Use --host 0.0.0.0 explicitly for phones on your LAN.
No production database, remote node, GPIO, serial device or model API is used.
"""
import argparse
import os


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    os.environ["SIMPLELAY_ACT_MODE"] = "simulator"
    # The simulator is a separate ephemeral workspace, never production history.
    os.environ.pop("SIMPLELAY_DB_PATH", None)
    os.environ["SIMPLELAY_GPIO_ENABLED"] = "false"
    os.environ["SIMPLELAY_SENSORS_ENABLED"] = "false"
    os.environ["SIMPLELAY_LLM_MODE"] = "mock"
    os.environ.pop("SIMPLELAY_LLM_BASE_URL", None)
    os.environ.pop("SIMPLELAY_VISION_BASE_URL", None)
    os.environ.pop("SIMPLELAY_LOCAL_APPLIANCES", None)
    os.environ["SIMPLELAY_VECTORDB_SEED"] = "false"
    os.environ["SIMPLELAY_DEV_MODE"] = "false"
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
