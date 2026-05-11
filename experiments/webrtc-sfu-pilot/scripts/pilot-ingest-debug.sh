#!/usr/bin/env bash
# 一键汇总 C1 ingest 配置与近期日志，减少手工 grep（在 experiments/webrtc-sfu-pilot 目录执行）。
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"

echo "========== MEDIASOUP（compose 生效值）=========="
docker compose config 2>/dev/null | grep -E 'MEDIASOUP_INGEST|MEDIASOUP_ROUTER|MEDIASOUP_ANNOUNCED_IP' || echo "(docker compose config 失败 — 是否已安装 Docker 并在本目录？)"

echo
echo "========== Layer C1 / PlainTransport / ingest PT =========="
docker compose logs --tail=250 webrtc-sfu-pilot 2>&1 \
  | grep -E 'Layer C1|ingest PT=|ingest_rtcp|rtcpMux|mediasoup RTP tuple|手动: bash scripts/ffmpeg-ingest|PlainTransport stats|rtpBytesReceived' \
  | tail -45 || true

echo
echo "========== 建议（自动化提示）=========="
MUX_LINE=$(docker compose config 2>/dev/null | grep MEDIASOUP_INGEST_RTCP_MUX || true)
if echo "${MUX_LINE}" | grep -qE 'MUX:[[:space:]]*("0"|0)$|MUX:[[:space:]]*"0"'; then
  echo "• 已启用 MEDIASOUP_INGEST_RTCP_MUX=0（RTP/RTCP 分端口，对齐 mediasoup-demo）。run-c1 会传第三参 RTCP。"
else
  echo "• 若 bytesReceived 大、rtpBytesReceived 始终为 0（尤其 VP8）：在 .env 加 MEDIASOUP_INGEST_RTCP_MUX=0，docker compose up -d --force-recreate，再 bash scripts/run-c1-ffmpeg-ingest.sh --local"
fi
echo "• 推流前: export MEDIASOUP_INGEST_CODEC=h264|vp8 与容器一致；INGEST_PT 以日志 ingest PT= 为准。"
echo "• 浏览器点「仅观看」后筛 C1 统计: npm run c1:diag:sfu（见 docs/layer-c1-lessons-learned.md §12）"
echo "• 本脚本: npm run pilot:ingest-debug 或 bash scripts/pilot-ingest-debug.sh"
