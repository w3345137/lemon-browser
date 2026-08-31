#!/usr/bin/env bash

set -euo pipefail

# 统计浏览器主进程及 WebKit / GPU / Networking 相关进程的 RSS，单位 MB。
# 用法：
#   Scripts/measure-browser-memory.sh Lemon
#   Scripts/measure-browser-memory.sh Safari

name="${1:-Lemon}"

/usr/bin/python3 - "$name" <<'PY'
import subprocess, sys

needle = sys.argv[1]
ps = subprocess.check_output(["ps", "-axo", "pid=,rss=,comm="], text=True)
rows = []
for line in ps.splitlines():
    parts = line.split(None, 2)
    if len(parts) < 3:
        continue
    pid, rss, comm = parts[0], parts[1], parts[2]
    label = comm.split("/")[-1]
    related = (
        needle.lower() in comm.lower()
        or (needle == "Lemon" and "com.workbuddy.lumen" in comm.lower())
        or (needle == "Safari" and label in {"Safari", "com.apple.WebKit.WebContent", "com.apple.WebKit.GPU", "com.apple.WebKit.Networking"})
    )
    if needle == "Safari" and "Lemon" in comm:
        related = False
    if related and int(rss) > 0:
        rows.append((int(pid), int(rss), label))

total = sum(rss for _, rss, _ in rows) / 1024
print(f"browser={needle}")
print(f"process_count={len(rows)}")
print(f"rss_mb={total:.1f}")
for pid, rss, label in sorted(rows, key=lambda item: item[1], reverse=True)[:12]:
    print(f"  {rss/1024:7.1f} MB  pid={pid}  {label}")
PY
