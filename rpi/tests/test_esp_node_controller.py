"""EspNodeController tests — httpx.MockTransport instead of a real node."""

import json

import httpx
import pytest

from rpi.controller import ButtonStatus, ExecutionStatus
from rpi.services.esp_node_controller import EspNodeController, EspNodeError


def _client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_execute_sends_buttons_to_the_nodes_execute_endpoint():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"success": True, "retry": 0})

    controller = EspNodeController("http://192.168.1.42:8080", client=_client(handler))
    controller.execute(["해동", "시작"])

    assert seen["url"] == "http://192.168.1.42:8080/execute"
    assert seen["body"] == {"buttons": ["해동", "시작"]}


def test_execute_success_marks_all_buttons_succeeded():
    controller = EspNodeController(
        "http://node",
        client=_client(lambda r: httpx.Response(200, json={"success": True, "retry": 0})),
    )

    result = controller.execute(["해동", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [b.button for b in result.buttons] == ["해동", "시작"]
    assert all(b.status is ButtonStatus.SUCCEEDED for b in result.buttons)


def test_execute_failure_marks_last_button_failed_with_retry_count():
    controller = EspNodeController(
        "http://node",
        client=_client(lambda r: httpx.Response(200, json={"success": False, "retry": 2})),
    )

    result = controller.execute(["해동", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.buttons[0].status is ButtonStatus.SUCCEEDED
    assert result.buttons[1].status is ButtonStatus.FAILED
    assert result.buttons[1].attempts == 3  # retry + 1


def test_base_url_trailing_slash_is_stripped():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"success": True, "retry": 0})

    controller = EspNodeController("http://node/", client=_client(handler))
    controller.execute(["시작"])

    assert seen["url"] == "http://node/execute"


def test_non_200_response_raises_esp_node_error():
    controller = EspNodeController(
        "http://node",
        client=_client(lambda r: httpx.Response(500, text="internal error")),
    )

    with pytest.raises(EspNodeError, match="500"):
        controller.execute(["시작"])


def test_network_error_raises_esp_node_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    controller = EspNodeController("http://node", client=_client(handler))

    with pytest.raises(EspNodeError, match="could not reach"):
        controller.execute(["시작"])


def test_close_closes_an_owned_client():
    controller = EspNodeController("http://node")  # no injected client -> owns one
    controller.close()
    assert controller._client.is_closed


def test_close_does_not_close_an_injected_client():
    client = _client(lambda r: httpx.Response(200, json={"success": True, "retry": 0}))
    controller = EspNodeController("http://node", client=client)

    controller.close()

    assert not client.is_closed
    client.close()
