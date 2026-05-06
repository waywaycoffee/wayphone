#!/usr/bin/env bash
# 「第一步」外网访问：把本机 ws-scrcpy（默认 8000）暴露为公网 HTTPS
# 前置：另一终端已运行 bash scripts/run-cloud-app-lab.sh，且 adb 有 device
# 用法: bash scripts/step1-public-tunnel.sh [cloudflare|ngrok]
#   cloudflare（默认）: 无需账号，每次启动域名会变，仅适合实验
#   ngrok: 需先执行 ngrok config add-authtoken <你的token>

set -euo pipefail
PORT="${WS_SCRCPY_PORT:-8000}"
MODE="${1:-cloudflare}"
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

if ! command -v lsof >/dev/null 2>&1; then
  echo "[step1] 需要 lsof（macOS 自带，若缺失请安装 Xcode CLT）"
  exit 1
fi

if ! lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[step1] 本机 ${PORT} 端口没有在监听。请先另开终端执行:"
  echo "        cd \"$(cd "$(dirname "$0")/.." && pwd)\" && bash scripts/run-cloud-app-lab.sh"
  exit 1
fi

case "${MODE}" in
  cloudflare|cf)
    if ! command -v cloudflared >/dev/null 2>&1; then
      echo "[step1] 未找到 cloudflared，请执行: brew install cloudflare/cloudflare/cloudflared"
      exit 1
    fi
    # 默认 http2：避免首连 QUIC 在部分网络/VPN 下超时刷 ERR（不影响最终成功时也会吓人）
    # 若要强制 QUIC: CLOUDFLARED_PROTOCOL=quic bash scripts/step1-public-tunnel.sh
    CF_PROTO="${CLOUDFLARED_PROTOCOL:-http2}"
    echo "[step1] Cloudflare Quick Tunnel → 本机 http://127.0.0.1:${PORT}（边缘协议: ${CF_PROTO}）"
    echo "[step1] 终端里会出现 https://xxxx.trycloudflare.com ，手机开 4G 打开即可（Ctrl+C 结束隧道）"
    echo "[step1] 若偶发 Failed to dial quic… 随后有 Registered tunnel connection，属自动重试成功，可忽略。"
    exec cloudflared tunnel --url "http://127.0.0.1:${PORT}" --protocol "${CF_PROTO}"
    ;;
  ngrok)
    if ! command -v ngrok >/dev/null 2>&1; then
      echo "[step1] 未找到 ngrok: brew install ngrok/ngrok/ngrok"
      exit 1
    fi
    echo "[step1] ngrok → 若报错 4018，先到 https://dashboard.ngrok.com/get-started/your-authtoken 配置:"
    echo "        ngrok config add-authtoken <token>"
    exec ngrok http "${PORT}"
    ;;
  *)
    echo "用法: $0 [cloudflare|ngrok]"
    exit 1
    ;;
esac
