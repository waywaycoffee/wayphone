#!/usr/bin/env bash
# Layer C 前置自检：Redroid(ADB)、可选 SFU HTTP。在 ECS 或本机执行；非强制通过才允许开发。
set -euo pipefail

echo "=== Layer C prereqs ==="

if command -v adb >/dev/null 2>&1; then
  echo "[adb] $(adb version | head -1)"
  adb devices -l || true
else
  echo "[adb] not installed (install android-platform-tools or use SDK adb)"
fi

if command -v docker >/dev/null 2>&1; then
  echo "[docker] $(docker --version)"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'cloudphone-redroid'; then
    echo "[docker] cloudphone-redroid container: running"
  else
    echo "[docker] cloudphone-redroid: not running (start: docker compose up -d in repo root)"
  fi
else
  echo "[docker] not in PATH"
fi

SFU_PORT="${PORT:-3000}"
if curl -sf -o /dev/null "http://127.0.0.1:${SFU_PORT}/"; then
  echo "[sfu] http://127.0.0.1:${SFU_PORT}/ responds"
else
  echo "[sfu] no HTTP on 127.0.0.1:${SFU_PORT} (optional for C0; needed for B/C1)"
fi

echo "=== done ==="
echo "See docs/layer-c-roadmap.md for C0 → C1 → C2 milestones."
