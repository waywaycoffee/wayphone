#!/usr/bin/env bash
# Mac 本机「云应用」实验：Android 模拟器 + 浏览器操控（ws-scrcpy）
# 前置：Android Studio 模拟器已启动，且 adb devices 能看到设备
# 用法（项目根目录）: bash scripts/run-cloud-app-lab.sh
#
# 说明：experiments/ws-scrcpy 内对 Node 24 做了小改动（node-pty 版本 + RemoteShell.ts）。
#      若你删掉目录重新 git clone，需保留本仓库里这两处修改或改用 Node 20 LTS 安装原版依赖。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="${ROOT}/experiments/ws-scrcpy"

PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

if ! command -v adb >/dev/null 2>&1; then
  echo "[lab] 未找到 adb，请安装: brew install android-platform-tools"
  exit 1
fi

if ! adb devices | awk 'NR>1 && $2=="device"{found=1} END{exit !found}'; then
  echo "[lab] 没有已连接的 Android 设备。请先启动模拟器，再执行: adb devices"
  exit 1
fi

if [ ! -f "${LAB}/package.json" ]; then
  echo "[lab] 缺少 ${LAB}，请先:"
  echo "      mkdir -p ${ROOT}/experiments && git clone --depth 1 https://github.com/NetrisTV/ws-scrcpy.git \"${LAB}\""
  exit 1
fi

if [ ! -d "${LAB}/node_modules" ]; then
  echo "[lab] 首次安装依赖（跳过 optional，加快安装）..."
  (cd "${LAB}" && npm install --omit=optional --no-audit --no-fund)
fi

PORT="${WS_SCRCPY_PORT:-8000}"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "你的Mac局域网IP")"

OLD_PID="$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "${OLD_PID}" ]; then
  echo "[lab] 端口 ${PORT} 已被占用（进程 PID: ${OLD_PID}），说明 ws-scrcpy 多半已在运行，无需再开第二个。"
  echo "[lab] 本机/同网手机直接打开: http://${LAN_IP}:${PORT}/"
  echo "[lab] 若你要「重启」ws-scrcpy: bash scripts/stop-ws-scrcpy.sh  （不要用 pkill -f node）"
  exit 0
fi

echo "[lab] 启动网页控制台（默认端口见终端输出，一般为 ${PORT}）"
echo "[lab] 同网手机浏览器打开: http://${LAN_IP}:${PORT}/"
echo "[lab] 外网穿透（第一步）: WS_SCRCPY_PORT=${PORT} bash scripts/step1-public-tunnel.sh        # 默认 cloudflared"
echo "[lab] 或: WS_SCRCPY_PORT=${PORT} bash scripts/step1-public-tunnel.sh ngrok   # 需先 ngrok config add-authtoken"
echo ""

cd "${LAB}"
exec npm start
