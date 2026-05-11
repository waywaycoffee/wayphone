#!/usr/bin/env bash
# One-shot: mount binderfs + create binder/hwbinder/vndbinder + symlinks under /dev.
# For Ubuntu 24.04+ kernels with CONFIG_ANDROID_BINDER_DEVICES="" (see docs/redroid-notes.md).
# 持久化（fstab + 开机 systemd）: sudo bash scripts/install-wayphone-binder-persistence.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

modprobe binder_linux 2>/dev/null || true

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${DIR}/binderfs-init"

if [[ ! -x "$BIN" ]]; then
  apt-get update -qq
  apt-get install -y gcc linux-libc-dev
  gcc -O2 -Wall -o "$BIN" "${DIR}/binderfs-init.c"
fi

exec "$BIN"
