# scripts — 개발 PC 도구·옛 배포 파일

> 역할: 개발 PC에서 돌리는 빌드·점검·그래프 도구. 서버 기능이 아니다.

| 파일 | 무엇 | 상태 |
| --- | --- | --- |
| [`deploy_kiosk.ps1`](deploy_kiosk.ps1) | 키오스크를 **웹으로** 빌드해 보드에 복사(백엔드가 `/kiosk`로 서빙 — 브라우저 시뮬레이터용) | 사용 |
| [`greyscale_goldens.py`](greyscale_goldens.py) | 골든 이미지를 흑백으로 바꿔 색 없이 위계가 서는지 보기 | 사용 |
| [`thinq_probe.py`](thinq_probe.py) | ThinQ 실물 확인(기기 목록·프로필·상태, 확인 질문 뒤 한 번만 제어) — 절차는 [ThinQ 실물 확인 절차](../docs/ThinQ-실물-확인-절차.md) | 사용 |
| [`vision_gateway_probe.py`](vision_gateway_probe.py) | 조작부 사진 인식 게이트웨이 확인(서버와 같은 요청·초안 변환) | 사용 |
| [`plots/`](plots/) | 실측 기록 → 그래프(정지 지연·성공률·오프셋 분산·전력 판정, 합성 데이터 생성) | 사용 |
| [`setup_rpi.sh`](setup_rpi.sh) · [`simplelay.service`](simplelay.service) · [`simplelay-kiosk.service`](simplelay-kiosk.service) · [`simplelay.logrotate`](simplelay.logrotate) | **옛 systemd 배포 방식**(8월, 일반 라즈베리파이 OS 기준 — 저장소를 받아 systemd로 백엔드·브라우저 키오스크 실행) | **현행 아님 — 현행은 [deploy/](../deploy/README.md)의 컨테이너 방식. 사용 여부 확인 필요(지우지 않음)** |

옛 systemd 파일에는 예전 핀 번호·환경 변수 예시가 들어 있다. 현재 기본값은 [환경 변수](../docs/환경변수.md)를 기준으로 본다.
