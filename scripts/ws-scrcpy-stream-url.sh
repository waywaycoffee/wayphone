#!/usr/bin/env bash
# 生成 ws-scrcpy「直连投屏」页面 URL（与上游 DeviceTracker 生成的 hash 一致）。
# 依赖 Node（用于 URLSearchParams，避免手写编码错误）。
#
# 用法:
#   bash scripts/ws-scrcpy-stream-url.sh [BASE_URL] [UDID]
# 环境变量:
#   WS_SCRCPY_BASE   若省略第一个参数则用之（默认 http://127.0.0.1:8000）
#   WS_SCRCPY_PORT   与 WS_SCRCPY_BASE 二选一逻辑由调用方决定
#   WS_SCRCPY_PLAYER 解码器 codeName，默认 broadway（对应 Broadway.js）
#   ANDROID_SERIAL   若省略 UDID 且 adb 仅一台 device，可省略第二个参数

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

BASE="${1:-${WS_SCRCPY_BASE:-http://127.0.0.1:${WS_SCRCPY_PORT:-8000}}}"
UDID="${2:-}"
PLAYER="${WS_SCRCPY_PLAYER:-broadway}"

if [ -z "${UDID}" ]; then
  UDID="${ANDROID_SERIAL:-}"
fi
if [ -z "${UDID}" ]; then
  UDID="$(adb devices 2>/dev/null | awk '/\tdevice$/{print $1; exit}')"
fi
if [ -z "${UDID}" ]; then
  echo "[ws-scrcpy-stream-url] 无法解析 UDID，请连接模拟器或传入第二个参数" >&2
  exit 1
fi

BASE="${BASE}" UDID="${UDID}" PLAYER="${PLAYER}" node <<'NODE'
const base = process.env.BASE || 'http://127.0.0.1:8000/';
const udid = process.env.UDID || '';
const player = process.env.PLAYER || 'broadway';
const u = new URL(base);
const host = u.hostname;
const port = u.port || (u.protocol === 'https:' ? '443' : '80');
const wsProto = u.protocol === 'https:' ? 'wss:' : 'ws:';
const ws = new URL(`${wsProto}//${host}:${port}/`);
ws.searchParams.set('action', 'proxy-adb');
ws.searchParams.set('remote', 'tcp:8886');
ws.searchParams.set('udid', udid);
const q = new URLSearchParams({ action: 'stream', udid, player, ws: ws.toString() });
const out = new URL(base);
out.hash = '!' + q.toString();
console.log(out.toString());
NODE
