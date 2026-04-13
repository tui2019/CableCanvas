#!/usr/bin/env python3
import argparse
import signal
import time
from pathlib import Path

from protocol import write_frame
from transport import accept_single_client


def parse_args():
    parser = argparse.ArgumentParser(
        description="Send repeated JPEG frames to CableCanvas client."
    )
    parser.add_argument("--host", default="127.0.0.1", help="Host bind address.")
    parser.add_argument("--port", type=int, default=27183, help="Host bind port.")
    parser.add_argument("--image", required=True, help="Path to a JPEG image.")
    parser.add_argument("--fps", type=float, default=10.0, help="Frames per second.")
    return parser.parse_args()


def load_jpeg(path: str) -> bytes:
    image_path = Path(path)
    data = image_path.read_bytes()
    if len(data) < 4 or data[0:2] != b"\xff\xd8":
        raise ValueError(f"{image_path} does not look like a JPEG file.")
    return data


def main():
    args = parse_args()
    frame = load_jpeg(args.image)
    frame_interval = 1.0 / max(args.fps, 0.1)
    running = True

    def stop_handler(_signum, _frame_obj):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGTERM, stop_handler)

    print(
        f"[sender] ready: {len(frame)} bytes/frame at {args.fps:.2f} FPS on "
        f"{args.host}:{args.port}"
    )

    with accept_single_client(args.host, args.port) as conn:
        conn_file = conn.makefile("wb")
        sent = 0
        while running:
            start = time.perf_counter()
            write_frame(conn_file, frame)
            sent += 1
            elapsed = time.perf_counter() - start
            sleep_time = frame_interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)
            if sent % 30 == 0:
                print(f"[sender] sent {sent} frames")

    print("[sender] stopped")


if __name__ == "__main__":
    main()

