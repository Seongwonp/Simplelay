"""``/kiosk`` — Flutter 키오스크 웹 빌드를 백엔드가 같은 오리진에서 서빙한다.

왜 같은 오리진인가: 키오스크가 ``/status``·``/events``·``/suggestions``를 부르는데
백엔드에 CORS 미들웨어가 없다. 다른 포트에서 서빙하면 브라우저가 전부 막는다.

왜 "없을 수도 있는" 처리를 하나: Flutter 빌드는 라즈베리파이에서 만들 수 없어(툴체인이
없다) PC에서 복사해 넣는다. 즉 **기기에 처음 설치한 직후에는 없다.** 그때 404가 뜨면
cage+Chromium 화면이 브라우저 오류 페이지로 남는데, 시연장에서 그건 최악이다.
"""

from __future__ import annotations

import pathlib

from fastapi import FastAPI
from fastapi.testclient import TestClient

from rpi.main import KIOSK_WEB_DIR_ENV, kiosk_web_dir, mount_kiosk


def _client(app: FastAPI) -> TestClient:
    return TestClient(app)


class TestKioskWebDir:
    def test_defaults_beside_the_repo(self, monkeypatch):
        monkeypatch.delenv(KIOSK_WEB_DIR_ENV, raising=False)
        assert kiosk_web_dir().name == "kiosk-web"

    def test_env_var_wins(self, monkeypatch, tmp_path: pathlib.Path):
        monkeypatch.setenv(KIOSK_WEB_DIR_ENV, str(tmp_path))
        assert kiosk_web_dir() == tmp_path


class TestMissingBuild:
    def test_serves_guidance_instead_of_404(self, tmp_path: pathlib.Path):
        app = FastAPI()
        built = mount_kiosk(app, tmp_path)  # 빈 디렉터리 = 빌드 없음

        assert built is False
        response = _client(app).get("/kiosk")
        assert response.status_code == 200
        # 무엇을 해야 하는지 화면에 적혀 있어야 한다 -- 기기 앞에서 보는 사람이
        # 로그를 뒤지지 않아도 되게
        assert "deploy_kiosk" in response.text
        assert "/ui" in response.text


class TestBuildPresent:
    def _fake_build(self, root: pathlib.Path) -> None:
        root.mkdir(parents=True, exist_ok=True)
        (root / "index.html").write_text("<h1>키오스크</h1>", encoding="utf-8")
        (root / "flutter_bootstrap.js").write_text("// build", encoding="utf-8")

    def test_serves_index_at_root(self, tmp_path: pathlib.Path):
        self._fake_build(tmp_path)
        app = FastAPI()
        built = mount_kiosk(app, tmp_path)

        assert built is True
        response = _client(app).get("/kiosk/")
        assert response.status_code == 200
        assert "키오스크" in response.text

    def test_serves_build_assets(self, tmp_path: pathlib.Path):
        # Flutter 웹은 index.html 외에 부트스트랩·canvaskit·assets를 함께 받는다.
        # index만 되고 나머지가 404면 화면이 하얗게 뜬다.
        self._fake_build(tmp_path)
        app = FastAPI()
        mount_kiosk(app, tmp_path)

        response = _client(app).get("/kiosk/flutter_bootstrap.js")
        assert response.status_code == 200

    def test_does_not_shadow_the_api(self, tmp_path: pathlib.Path):
        # mount는 경로 앞쪽을 가로챈다 -- /kiosk 아래만 먹어야 하고
        # 기존 라우트를 덮으면 안 된다
        self._fake_build(tmp_path)
        app = FastAPI()

        @app.get("/health")
        async def health() -> dict:
            return {"ok": True}

        mount_kiosk(app, tmp_path)

        assert _client(app).get("/health").json() == {"ok": True}
