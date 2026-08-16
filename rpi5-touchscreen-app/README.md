# rpi5-touchscreen-app

RPi5(7인치 터치스크린)용 대기/제안/실행중/완료 UI. 기존 `rpi/touchscreen/index.html`(HTML/JS 프로토타입)을
Flutter Atlas 앱으로 포팅한 버전이다. UI 상태 전이·폴링 주기·API 엔드포인트는 원본과 동일하게 맞췄다.

## 로컬 서버 연동

`lib/services/kiosk_api_service.dart`가 `http://localhost:8000`의 `rpi/api` FastAPI 서버를
`/health`, `/suggestions`, `/status`, `/suggestions/{id}/approve`, `/suggestions/{id}/reject`, `/stop`
로 호출한다. RPi5에서는 FastAPI 서버가 같은 보드에서 별도 프로세스로 떠 있어야 한다.

## 빌드

일반 `flutter` 명령이 아니라 플랫폼 전용 툴체인이 필요하다(로컬 전용, 커밋 안 되는
`atlas_docker_env/` 안의 Docker 개발 컨테이너 사용):

```
docker compose -f atlas_docker_env/docker-compose.yml up -d
docker compose -f atlas_docker_env/docker-compose.yml exec atlas-dev bash
# 컨테이너 안에서:
cd /app  # atlas_docker_env가 마운트된 경로
# 이 프로젝트를 컨테이너에서 보이는 경로로 복사하거나 마운트한 뒤
arc build <프로젝트 경로>
```

빌드 결과는 `build/atlas/arm64/release/com.atlas.app.simplelay_touchscreen.ipk`.
실기기 설치는 `arc install`(기기 IP/포트 필요, 아직 미검증 — 실기기 켠 적 없음).

## 화면 4개

1. 대기 — 가전 아이콘, 연결 상태, 시계
2. 제안 — AI 제안 문구, 버튼맵 그리드(승인 전엔 하이라이트 없음 — 시퀀스는 승인 후 서버가 확정), 승인/거부, 10초 카운트다운
3. 실행 중 — 진행 바, 단계 목록, 전류/음향 센서 카드, 긴급 정지
4. 완료 — 성공/실패 아이콘, 3초 후 자동으로 대기 화면 복귀
