"""공개 문서·배포 설정의 회귀 검사(실물 검증 증거가 아님)."""
from pathlib import Path
import re

import pytest

from rpi.verifier.outlet import OutletLink, parse_outlet_channels
from rpi.controller.serial_motion import InMemoryLinePipe
from rpi4.services.target_binding import TargetBinder, parse_l3_none_targets

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("source", ["docs/archive/본선-시연-시나리오-v3.md", "docs/결선-운영-런북.md", "deploy/act-v3.env.example"])
def test_v3_documented_bindings_accept_registered_appliances(source):
    text = (ROOT / source).read_text(encoding="utf-8")
    channels = re.search(r"SIMPLELAY_OUTLET_CHANNELS=([a-z0-9_:,]+)", text)
    none = re.search(r"SIMPLELAY_L3_NONE_TARGETS=([a-z0-9_,]+)", text)
    binder = TargetBinder(
        l3_mode="real", outlet=OutletLink(InMemoryLinePipe().host),
        channels=parse_outlet_channels(channels.group(1)), press_appliance="home_mw",
        l3_none_targets=parse_l3_none_targets(none.group(1) if none else ""),
        make_operation=lambda view, ch: view.sensor(),
    )
    assert binder.bind("home_mw").ct_channel == 0
    assert binder.bind("washer").ct_channel == 1
    assert binder.bind("intercom").l3 == "none"
    assert binder.bind("intercom").operation is None


def test_executor_image_includes_adc_dependencies():
    text = (ROOT / "deploy/backend.Dockerfile").read_text(encoding="utf-8")
    assert '"adafruit-circuitpython-ads1x15' in text
    assert '"adafruit-blinka' in text


@pytest.mark.parametrize("path,required,removed", [
    # 10/10 팀원 확인: 갠트리·모션 펌웨어도 Touch Bridge와 공유 — "컨셉만 이어받고"(과소 서술)는 다시 들어오지 않는다.
    ("docs/reuse-boundary.md", "구동 계층은 Touch Bridge와 공유한다", "컨셉만 이어받고"),
    ("docs/reuse-boundary.md", "XY FIT0482 ×2", "FIT0482 ×3"),
    ("docs/가산점-증거-대장.md", "실제 앱 문맥 호출은 미검증", "실제 앱 문맥에서도 허용 조건은 같다"),
    ("README.md", "L1", "전류·음향 센서로 실제 실행을"),
    ("docs/archive/본선-시연-시나리오-v3.md", "소프트웨어 정지 요청", "같은 정지를 요청하지만"),
    ("docs/archive/본선-시연-시나리오-v3.md", "폰이 추적하는 실행", "실행 중이 아니면 듣지 않는다"),
    ("docs/archive/본선-시연-시나리오-v3.md", "10/6", "부분 실물(가짜 모듈)에서는 버튼을 누를 외부 수단이 없다"),
    ("docs/archive/본선-시연-시나리오-v3.md", "패널", "15.8형 패널에서 띠를 눈으로 보지는 않았다"),
    ("docs/submission/개발완료보고서-초안.md", "기록기", "XY 이동 전체와 Z 누름을 함께 덮는다"),
])
def test_document_claims_match_verified_scope(path, required, removed):
    text = (ROOT / path).read_text(encoding="utf-8")
    assert required in text
    assert removed not in text
