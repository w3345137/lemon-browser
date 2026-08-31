#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: measure-energy.sh <label> <samples> <pid> [pid ...]" >&2
  exit 2
fi

label="$1"
samples="$2"
shift 2

top_args=(-l "$samples" -s 1 -stats pid,cpu,power,mem,command)
pid_csv=""
for pid in "$@"; do
  top_args+=(-pid "$pid")
  pid_csv="${pid_csv:+$pid_csv,}$pid"
done

top "${top_args[@]}" | awk -v label="$label" -v targets="$pid_csv" '
BEGIN {
  split(targets, ids, ",")
  for (i in ids) wanted[ids[i]] = 1
}

function memoryMB(raw, value) {
  value = raw + 0
  if (raw ~ /G$/) return value * 1024
  if (raw ~ /K$/) return value / 1024
  if (raw ~ /B$/ && raw !~ /[KMG]B?$/) return value / 1048576
  return value
}

function finishSnapshot() {
  if (!insideSnapshot) return
  totalCPU += snapshotCPU
  totalPower += snapshotPower
  totalMemory += snapshotMemory
  sampleCount++
  snapshotCPU = snapshotPower = snapshotMemory = 0
}

/^Processes:/ {
  finishSnapshot()
  insideSnapshot = 1
  next
}

$1 ~ /^[0-9]+$/ && wanted[$1] {
  snapshotCPU += $2 + 0
  snapshotPower += $3 + 0
  snapshotMemory += memoryMB($4)
}

END {
  finishSnapshot()
  if (sampleCount == 0) exit 3
  printf("{\"label\":\"%s\",\"samples\":%d,\"avg_cpu_percent\":%.2f,\"avg_power_index\":%.2f,\"avg_memory_mb\":%.1f}\n",
         label, sampleCount, totalCPU / sampleCount, totalPower / sampleCount, totalMemory / sampleCount)
}
'
