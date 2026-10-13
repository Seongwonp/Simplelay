# 2026-10-08 ActClient — 응답 기한 뒤 abort 전송 실패가 기한 초과 오류를 덮던 결함

## 결함(리뷰 LOW)
- `rpi/services/act_client.py` `_send`의 쓰기 실패 처리에서 `self._pending[1].done()`이면 `.exception()`을 불러 예외를 회수했다.
- 응답 기한 경로에서는 `asyncio.wait_for`가 이미 future를 **취소**했다. 이어서 abort 쓰기가 실패하면 취소된 future의 `.exception()`이 `asyncio.CancelledError`를 던진다.
- `CancelledError`는 `BaseException`이라 `execute`/`verify_pass`의 `except Exception`을 빠져나가, 호출자가 `ActLinkTimeoutError` 대신 `CancelledError`를 받았다.

## 수리
- `done() and not cancelled()`일 때만 `.exception()`을 부른다. `_send` 한 곳이라 `execute`·`verify_pass` 두 경로가 함께 고쳐진다.

## 검증
- `rpi/tests/test_act_client.py` 회귀 2건(`FailsAfterFirstWriter`: 첫 줄은 보내고 두 번째 쓰기부터 `OSError`): execute·verify_pass 각각 기한 초과 뒤 abort 쓰기 실패 → `ActLinkTimeoutError`와 `_pending` 해제를 확인.
- **수정 전 2건 모두 실패**(`AssertionError: CancelledError()`), 수정 뒤 통과.
- `PYTHONUTF8=1 .venv/Scripts/python.exe -m pytest -q rpi rpi4` → **2,536 통과**(골든 없음), `rpi/tests/test_repo_guard.py` 5 통과.
- 모의 writer 수준의 시험이다. 실물 UART 단선으로는 확인하지 않았다.

# 추가: 늦게 실패한 옛 drain이 새 링크를 내리던 결함(리뷰 LOW)

## 결함
- `_send`의 쓰기 실패 처리가 `link_up`·writer 동일성을 보지 않고 `_mark_link_down`을 불렀다.
- 읽기 루프가 EOF로 링크를 내리고 옛 writer를 닫은 뒤 진행 중이던 옛 `drain()`이 늦게 실패하면: `link_drops`가 두 번 세어졌다. 재연결 간격(기본 0.5s) 뒤에 실패하면 **새 링크**를 내렸다 — 새 `estop_latched`·`act_info`를 지우고, 새 writer를 닫고, 새 reader에 예외를 넣었다.

## 수리
- `_send` 진입 시 `writer, reader`를 붙잡고 그 writer로 쓴다. 실패하면 `self.link_up and self._writer is writer`일 때만 링크를 내리고, 예외는 붙잡은 `reader`에 넣는다. 원래 예외는 그대로 호출자에게 올린다.

## 검증
- `rpi/tests/test_act_client_reconnect.py` 회귀 2건(`test_stale_drain_failure_does_not_tear_down_new_link_or_double_count`): 재연결 뒤 실패 → 새 링크 유지·걸림 상태·구성 보존·새 writer 열림·새 reader 정상·`link_drops` 1 / 재연결 전 실패 → `link_drops` 1.
- **수정 전 2건 모두 실패**(`assert 2 == 1`, 로그에 link down 두 번), 수정 뒤 통과.
- `PYTHONUTF8=1 .venv/Scripts/python.exe -m pytest -q rpi rpi4` → **2,538 통과**(골든 없음), `rpi/tests/test_repo_guard.py` 5 통과.
- 모의 writer 수준의 시험이다. 실물 UART 단선으로는 확인하지 않았다.
