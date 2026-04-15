#!/usr/bin/env python3
"""CableCanvas v1 frame sender.

This process accepts one client and repeatedly sends the same JPEG frame.
"""

from __future__ import annotations

import argparse
import signal
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from protocol import write_frame
from transport import accept_single_client

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 27183
DEFAULT_FPS = 10.0
MIN_FPS = 0.1


@dataclass(frozen=True)
class SenderConfig:
    host: str
    port: int
    image_path: Path
    fps: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send repeated JPEG frames to CableCanvas client."
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help="Host bind address.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Host bind port.")
    parser.add_argument("--image", required=True, help="Path to a JPEG image.")
    parser.add_argument("--fps", type=float, default=DEFAULT_FPS, help="Frames per second.")
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> SenderConfig:
    return SenderConfig(
        host=args.host,
        port=args.port,
        image_path=Path(args.image),
        fps=max(args.fps, MIN_FPS),
    )


def load_jpeg(image_path: Path) -> bytes:
    data = image_path.read_bytes()
    if len(data) < 4 or data[0:2] != b"\xff\xd8":
        raise ValueError(f"{image_path} does not look like a JPEG file.")
    return data


def stream_frames(
    frame: bytes,
    config: SenderConfig,
    should_continue: Callable[[], bool],
) -> None:
    frame_interval = 1.0 / config.fps
    with accept_single_client(config.host, config.port) as conn:
        conn_file = conn.makefile("wb")
        sent_count = 0
        while should_continue():
            loop_start = time.perf_counter()
            write_frame(conn_file, frame)
            sent_count += 1
            elapsed = time.perf_counter() - loop_start
            sleep_time = frame_interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)
            if sent_count % 30 == 0:
                print(f"[sender] sent {sent_count} frames")


def main() -> None:
    config = build_config(parse_args())
    frame = load_jpeg(config.image_path)
    running = True

    def stop_handler(_signum: int, _frame_obj) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGTERM, stop_handler)

    print(
        f"[sender] ready: {len(frame)} bytes/frame at {config.fps:.2f} FPS on "
        f"{config.host}:{config.port}"
    )
    stream_frames(frame=frame, config=config, should_continue=lambda: running)
    print("[sender] stopped")


if __name__ == "__main__":
    main()
