"""기기 쪽 D-Bus 서비스 식별자를 환경변수에서 읽는다.

이 값들은 우리 코드의 일부가 아니라 **배포되는 기기의 성질**이다. 소스에 박아두면
리포가 특정 플랫폼 빌드에 묶이고, 빌드가 바뀔 때마다 코드를 고쳐야 한다.
배포에서는 systemd 유닛의 ``EnvironmentFile``(기기에만 있고 저장소에는 없는 파일)이
주입한다 -- API 키가 쓰는 것과 같은 경로다.

기본값을 두지 않는 것은 의도적이다. 값이 없는데 조용히 동작하는 것보다, 무엇을
설정해야 하는지 이름을 짚어 즉시 실패하는 편이 낫다 -- 이 클라이언트들은 운영자가
환경변수로 명시적으로 켤 때만 만들어지므로, 켰다면 주소도 함께 줘야 맞다.
"""

from __future__ import annotations

import os

# CLI 실행 파일 이름. 기기가 제공하는 도구라 빌드에 따라 다를 수 있다.
ENV_DBUS_CLI = "SIMPLELAY_DBUS_CLI"
# 각 서비스의 버스 이름
ENV_AGENT_SERVICE = "SIMPLELAY_DBUS_AGENT_SERVICE"
ENV_VECTORDB_SERVICE = "SIMPLELAY_DBUS_VECTORDB_SERVICE"
ENV_PERIPHERAL_SERVICE = "SIMPLELAY_DBUS_PERIPHERAL_SERVICE"


class MissingPlatformConfigError(RuntimeError):
    """필수 서비스 식별자가 환경에 설정돼 있지 않을 때."""


def required(name: str, purpose: str) -> str:
    """환경변수를 읽되, 비어 있으면 무엇을 어디에 넣어야 하는지 짚어서 실패한다."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise MissingPlatformConfigError(
            f"{name} 환경변수가 설정돼 있지 않습니다 ({purpose}). "
            f"기기의 /etc/simplelay/environment 에 추가하세요."
        )
    return value


def object_path_for(service: str) -> str:
    """서비스 이름에서 기본 오브젝트 경로를 만든다.

    점을 슬래시로 바꾸고 앞에 슬래시를 붙이는 D-Bus 관례를 따른다
    (``a.b.C1`` → ``/a/b/C1``). 관례를 벗어나는 서비스를 만나면 각 설정의
    ``object_path``에 직접 넣어 우회할 수 있다.
    """
    return "/" + service.strip().replace(".", "/")
