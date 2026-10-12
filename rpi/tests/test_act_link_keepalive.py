"""무선(2026-10-12): RPi5→RPi4 socket:// 링크에 TCP keepalive를 켠다.

RPi4 랜선을 뽑고 Wi-Fi로 돌릴 때, 상대가 FIN 없이 사라지면 읽기가 영원히 기다리고 재연결이 안 됐다."""

from __future__ import annotations

import socket
from types import SimpleNamespace

from rpi.services.act_client_controller import TCP_KEEPALIVE, enable_tcp_keepalive


def _writer_with(sock: object) -> object:
    return SimpleNamespace(transport=SimpleNamespace(serial=SimpleNamespace(_socket=sock)))


def test_socket_link_gets_keepalive():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        assert sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE) == 0
        assert enable_tcp_keepalive(_writer_with(sock)) is True
        assert sock.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE) != 0
        if hasattr(socket, "TCP_KEEPIDLE"):
            assert sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE) == TCP_KEEPALIVE[0]


def test_serial_device_link_is_left_alone():
    assert enable_tcp_keepalive(_writer_with(None)) is False
    assert enable_tcp_keepalive(SimpleNamespace()) is False
