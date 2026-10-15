# rpi — RPi5 허브 백엔드 + 두 보드 공용 라이브러리

> 역할: RPi5 허브 백엔드(FastAPI) — 의도 해석·승인·제안·실행 상태·폰/키오스크 API. 폴더 이름 `rpi/`는 보드 하나로 설계하던 시절에서 왔다.
> **`controller/`·`verifier/`·`tools/fake_*`는 RPi4 실행기([`rpi4/`](../rpi4/README.md))도 import하는 공용 라이브러리다** — 모션 어댑터·센서 판정은 실제로는 RPi4에서 돈다.

전체 구조·요청 흐름·안전 계약이 사는 곳은 [코드 구조](../docs/코드-구조.md), 환경 변수는 [환경 변수](../docs/환경변수.md), 시험 지도는 [tests/README](tests/README.md).

## 폴더

| 폴더·파일 | 무엇 | 도는 곳 |
| --- | --- | --- |
| [`main.py`](main.py) | 앱 조립 — 라우터 붙이기(인증), 기동·종료 절차, 제안 주기 루프, `/health`·`/ui`·`/kiosk` | RPi5 |
| [`api/`](api/README.md) | HTTP 경로(라우터)·서비스(`SimpleLayService`)·의존성 조립(`deps.py`)·정지 전용 줄 | RPi5 |
| [`commands/`](commands/README.md) | 명령·승인 결속 모델(`ApprovedCommand`·지문), 물리 실행 결과의 확인 수준 | RPi5 |
| [`intent/`](intent/README.md) | 목적 → 버튼 순서 해석, 사용 기록·습관 패턴, 제안 서비스 | RPi5 |
| [`routines/`](routines/README.md) | 사용자 루틴(여러 가전 순서)·자동 실행 허용 규칙 | RPi5 |
| [`scenarios/`](scenarios/) | 여러 가전 시나리오 정의(데이터)와 트리거 → 제안(실행하지 않음) | RPi5 |
| [`services/`](services/README.md) | 링크 클라이언트·제어권·정지 단계 문장·ThinQ·날씨·저장 등 허브 서비스 | RPi5 (일부 공용) |
| [`controller/`](controller/README.md) | 폐루프 실행, **모션 보드 어댑터**(`serial_motion.py`)·CoreXY 기구 변환, 콘센트 전력 확인(`power_operation.py`) | **RPi4** (허브의 모의 실행에도 씀) |
| [`verifier/`](verifier/README.md) | 센서 판정 — 전류·소리·콘센트 CT·사이클 끝·종료음·잔여 전류 | **RPi4** |
| [`tools/`](tools/) | 가짜 모션 보드(`fake_mcu.py`)·가짜 콘센트 모듈(`fake_outlet.py`)·모의 ThinQ 클라우드·조그 도구·보드 점검 | 개발 PC·RPi4 |
| [`vision/`](vision/) · [`calibration/`](calibration/) | 조작부 사진 인식 요청, 사진 좌표 → 갠트리 좌표 변환 | RPi5 |
| [`bench/`](bench/) | 원시 센서 기록기(실측용) | RPi4 |
| [`simulator_main.py`](simulator_main.py) | 하드웨어 없는 리허설 서버(`python -m rpi.simulator_main`) — DB·노드·GPIO·시리얼·모델 API를 쓰지 않음 | 개발 PC |
| [`touchscreen/`](touchscreen/) | **옛 HTML 키오스크**(`index.html`·`kiosk.sh`)와 시뮬레이터·트윈 화면 파일. 현행 키오스크는 [`rpi5-touchscreen-app/`](../rpi5-touchscreen-app/README.md) | RPi5 |
| [`tests/`](tests/README.md) | 백엔드 시험(+ `rpi4/tests`) | 개발 PC |

## 실행·시험

Python 3.11 이상. 하드웨어 없이 전 기능이 모의로 돈다(실기기 의존은 전부 `SIMPLELAY_*` 환경 변수 게이트, 기본 모의).

```bash
python -m pip install -e '.[test]'
python -m pytest -q                         # 백엔드 + rpi4 (Windows는 PYTHONUTF8=1)
python -m rpi.simulator_main --port 8782    # 모의 리허설 서버
```

보드 배포는 [deploy/README](../deploy/README.md).
