#!/usr/bin/env bash
set -euo pipefail

# One sweep at a time. A slow sweep delays the next start instead of overlapping.
while :; do
  started=$(date +%s)
  gitclub-mirror-sweep || true
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -lt 300 ]; then
    sleep "$((300 - elapsed))"
  fi
done
