#!/usr/bin/env python3
"""Prints the UDID of the newest available iOS simulator whose name starts with argv[1] (e.g. "iPhone", "iPad")."""
import json, subprocess, sys, re

prefix = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))

def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)

best = None
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith(prefix):
            key = (version(runtime), "Pro" in d["name"], d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], runtime)
if not best:
    sys.exit(f"no simulator found for {prefix}")
print(best[1])
print(f"picked {best[2]} on {best[3]}", file=sys.stderr)
