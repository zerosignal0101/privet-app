"""Query the phone's embedded privetd over its unix socket via adb.

The daemon socket is app-private, so this pushes a framed request into the
sandbox, pipes it into `nc -U <socket>` under `run-as`, and pulls the framed
response from the app's own directory (run-as can't write /data/local/tmp).
"""
import json
import struct
import subprocess
import sys
import uuid

REQ = "/data/local/tmp/privet_req.bin"
APP_FILES = "/data/user/0/app.privet.privet_app/files/privet"
SOCK = f"{APP_FILES}/privet.sock"
RESP = f"{APP_FILES}/privet_resp.bin"

LOCAL_REQ = r"C:\Users\zsig\AppData\Local\Temp\privet_req.bin"
LOCAL_RESP = r"C:\Users\zsig\AppData\Local\Temp\privet_resp.bin"

ADB = ["adb"]


def sh(parts, use_exec_out=False):
    """Run an adb command; parts is the full argv list (host-level, e.g. push)."""
    p = subprocess.run(ADB + parts, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"adb failed ({p.returncode}): {p.stderr.decode()}")
    return p.stdout


def device_sh(command: str, use_exec_out=False):
    """Run a full device command via `adb shell`, passing it as ONE arg so the
    device shell (not adb's arg-joiner) owns the quoting."""
    return sh((["exec-out"] if use_exec_out else ["shell"]) + [command])


def frame(payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + payload


def unframe(data: bytes) -> list:
    out = []
    pos = 0
    while pos + 4 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        pos += 4
        out.append(json.loads(data[pos:pos + length].decode("utf-8")))
        pos += length
    return out


def call(method: str, params: dict = None):
    env = {
        "protocol_version": 1,
        "request_id": f"cli-{uuid.uuid4().hex[:8]}",
        "request": {"method": method, **({"params": params} if params else {})},
    }
    with open(LOCAL_REQ, "wb") as f:
        f.write(frame(json.dumps(env).encode()))
    sh(["push", LOCAL_REQ, REQ])
    device_sh(f"run-as app.privet.privet_app sh -c 'rm -f {RESP}; "
              f"nc -U {SOCK} < {REQ} > {RESP}'")
    raw = device_sh(f"run-as app.privet.privet_app cat {RESP}", use_exec_out=True)
    return unframe(raw)


def main():
    method = sys.argv[1]
    params = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].strip() else None
    for msg in call(method, params):
        print(json.dumps(msg, ensure_ascii=False))


if __name__ == "__main__":
    main()
