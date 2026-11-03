#!/usr/bin/env python3
"""Extract the existing 256 px PNG representation from MacSwitcher.icns into ICO."""
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[2]
source = root / "assets/MacSwitcher.icns"
target = root / "windows/assets/MacSwitcher.ico"
data = source.read_bytes()
if data[:4] != b"icns" or int.from_bytes(data[4:8], "big") != len(data):
    raise SystemExit("Invalid ICNS container header")
cursor = 8
png = None
while cursor + 8 <= len(data):
    kind = data[cursor:cursor + 4]
    size = int.from_bytes(data[cursor + 4:cursor + 8], "big")
    if size < 8 or cursor + size > len(data):
        raise SystemExit("Invalid ICNS chunk")
    payload = data[cursor + 8:cursor + size]
    if kind == b"ic08" and payload.startswith(b"\x89PNG\r\n\x1a\n"):
        png = payload
        break
    cursor += size
if png is None:
    raise SystemExit("The original 256 px embedded PNG (ic08) was not found")
target.parent.mkdir(parents=True, exist_ok=True)
entry = struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png), 22)
target.write_bytes(struct.pack("<HHH", 0, 1, 1) + entry + png)
print(f"Wrote {target} from unchanged ICNS PNG payload ({len(png)} bytes)")
