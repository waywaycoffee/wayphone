#!/usr/bin/env bash
# PoC：Redroid 映射在 127.0.0.1:5555；宿主机常残留 emulator-5554，勿依赖默认设备。
# 用法: scripts/adb-redroid.sh shell getprop ro.product.cpu.abilist
# 环境: REDROID_ADB_SERIAL 默认 127.0.0.1:5555
set -euo pipefail
_serial="${REDROID_ADB_SERIAL:-127.0.0.1:5555}"
exec adb -s "${_serial}" "$@"
