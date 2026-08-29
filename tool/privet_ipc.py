"""Minimal named-pipe IPC client for privetd (Windows).

Frame format (spec 09 §3): [u32 big-endian length][UTF-8 JSON envelope].
Envelope: {"protocol_version":1,"request_id":"...","request":{"method":...,"params":...}}
"""
import ctypes
import json
import struct
import sys
import uuid

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
FILE_ATTRIBUTE_NORMAL = 0x80
ERROR_PIPE_BUSY = 231
PIPE_READMODE_MESSAGE = 2
PIPE_WAIT = 0
NMPWAIT_USE_DEFAULT_WAIT = 0


def connect(pipe_name):
    for _ in range(200):
        handle = kernel32.CreateFileW(
            pipe_name, GENERIC_READ | GENERIC_WRITE, 0, None, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, None)
        if handle != -1 and handle != 0:
            return handle
        if ctypes.get_last_error() != ERROR_PIPE_BUSY:
            raise SystemExit(f"pipe {pipe_name} connect failed: {ctypes.get_last_error()}")
        kernel32.WaitNamedPipeW(pipe_name, NMPWAIT_USE_DEFAULT_WAIT)
    raise SystemExit(f"pipe {pipe_name} never became available")


def write_frame(handle, payload: bytes):
    header = struct.pack(">I", len(payload))
    buf = ctypes.create_string_buffer(header + payload)
    written = ctypes.c_uint32(0)
    ok = kernel32.WriteFile(handle, buf, len(buf.raw), ctypes.byref(written), None)
    if not ok:
        raise SystemExit(f"write failed: {ctypes.get_last_error()}")


def read_frame(handle) -> bytes:
    header = ctypes.create_string_buffer(4)
    read = ctypes.c_uint32(0)
    ok = kernel32.ReadFile(handle, header, 4, ctypes.byref(read), None)
    if not ok:
        raise SystemExit(f"read header failed: {ctypes.get_last_error()}")
    (length,) = struct.unpack(">I", header.raw)
    body = ctypes.create_string_buffer(length)
    # ReadFile on a message-mode pipe may return partial messages; loop.
    buf = bytearray()
    while len(buf) < length:
        chunk = ctypes.create_string_buffer(length - len(buf))
        got = ctypes.c_uint32(0)
        ok = kernel32.ReadFile(handle, chunk, length - len(buf), ctypes.byref(got), None)
        if not ok:
            raise SystemExit(f"read body failed: {ctypes.get_last_error()}")
        buf += chunk.raw[:got.value]
        if got.value == 0:
            break
    return bytes(buf[:length])


def call(pipe_name: str, method: str, params: dict = None) -> dict:
    handle = connect(pipe_name)
    try:
        envelope = {
            "protocol_version": 1,
            "request_id": f"cli-{uuid.uuid4().hex[:8]}",
            "request": {"method": method, **({"params": params} if params else {})},
        }
        write_frame(handle, json.dumps(envelope).encode("utf-8"))
        raw = read_frame(handle)
        return json.loads(raw.decode("utf-8"))
    finally:
        kernel32.CloseHandle(handle)


def main():
    pipe, method, params_json = sys.argv[1], sys.argv[2], sys.argv[3]
    params = json.loads(params_json) if params_json.strip() else None
    resp = call(pipe, method, params)
    print(json.dumps(resp, ensure_ascii=False))


if __name__ == "__main__":
    main()
