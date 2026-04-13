import struct

MAGIC = b"CCF1"
HEADER_STRUCT = struct.Struct(">4sI")


def write_frame(output_stream, payload: bytes) -> None:
    header = HEADER_STRUCT.pack(MAGIC, len(payload))
    output_stream.write(header)
    output_stream.write(payload)
    output_stream.flush()

