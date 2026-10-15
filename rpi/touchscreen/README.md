# rpi/touchscreen — 옛 HTML 키오스크와 시뮬레이터·트윈 화면 파일

> **`index.html`·`kiosk.sh`는 옛 HTML 키오스크(8월 프로토타입)다 — 현행 키오스크는 [`rpi5-touchscreen-app/`](../../rpi5-touchscreen-app/README.md).**
> 백엔드가 `/ui`로 여전히 서빙하지만(제안·상태·정지만, 접근성 개편 미반영) 결선 구성에서 쓰지 않는다.

| 파일 | 무엇 | 서빙 |
| --- | --- | --- |
| `index.html` · `kiosk.sh` · `simplelay-kiosk.desktop` | 옛 HTML 키오스크와 그 브라우저 자동 실행 스크립트(옛 systemd 방식, [scripts/README](../../scripts/README.md)) | `/ui` (키 없이 — 화면 파일만) |
| `simulator.html` · `routine.html` · `parking.html` · `parking-motion.js` | 시뮬레이터 조작 패널·루틴 리허설·정지 대기 화면 | `/simulator/*` (키 필요) |
| `twin.html` · `twin-motion.js` | 디지털 트윈(CoreXY 움직임 미리보기·재생) | `/twin` 화면 파일만 키 없이, 상태·재생은 `/twin/*` 키 필요 |

`*.test.cjs`(`rpi/tests/`)가 트윈·미리보기 스크립트를 시험한다.
