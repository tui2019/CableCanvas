"""Frame protocol for CableCanvas host.

Current wire format (v1):
    [4 bytes magic: CCF1][4 bytes big-endian payload length][payload bytes]
"""

from __future__ import annotations

import struct
from typing import BinaryIO

MAGIC = b"CCF1"
HEADER_STRUCT = struct.Struct(">4sI")


def write_frame(output_stream: BinaryIO, payload: bytes) -> None:
    """Write a single frame to the stream and flush it."""
    header = HEADER_STRUCT.pack(MAGIC, len(payload))
    output_stream.write(header)
    output_stream.write(payload)
    output_stream.flush()
