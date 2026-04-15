"""Transport abstractions for CableCanvas host.

The v1 implementation exposes a simple TCP server-side accept helper.
Swapping transports later (e.g., direct USB) should be done in this module.
"""

from __future__ import annotations

import socket
from collections.abc import Iterator
from contextlib import contextmanager


@contextmanager
def accept_single_client(host: str, port: int) -> Iterator[socket.socket]:
    """Bind a TCP server socket, accept one client, and yield its connection."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(1)
        print(f"[transport] listening on {host}:{port}")
        conn, addr = server.accept()
        with conn:
            print(f"[transport] client connected from {addr[0]}:{addr[1]}")
            yield conn

