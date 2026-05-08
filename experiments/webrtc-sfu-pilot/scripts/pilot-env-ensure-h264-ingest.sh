#!/usr/bin/env bash
# 整条 Layer C1 先固定 H264：更新本目录 .env，去掉 vp8 / 旧 pin，并写入 MEDIASOUP_INGEST_CODEC=h264。
# 与 pilot-env-unpin-compose-defaults.sh 互补：本脚本「明确写上 h264」，避免别处又 export vp8 后忘记改 .env。
# 用法（在 experiments/webrtc-sfu-pilot）:
#   bash scripts/pilot-env-ensure-h264-ingest.sh
#   bash scripts/pilot-env-ensure-h264-ingest.sh --dry-run
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
ENVF=".env"
DRY=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && DRY=1; done

touch "$ENVF"

strip_ingest_codec() {
  grep -viE '^[[:space:]]*#.*' "$ENVF" | grep -qE '^MEDIASOUP_INGEST_CODEC=' || return 0
  grep -viE '^MEDIASOUP_INGEST_CODEC=' "$ENVF" >"${ENVF}.tmp" || true
  mv "${ENVF}.tmp" "$ENVF"
}

if [[ "$DRY" == "1" ]]; then
  echo "[--dry-run] 当前 .env 中与 ingest codec 相关的行:"
  grep -nE 'MEDIASOUP_INGEST_CODEC|MEDIASOUP_ROUTER_VIDEO_H264_ONLY' "$ENVF" 2>/dev/null || echo "(无)"
  echo "将: 删除 MEDIASOUP_INGEST_CODEC=*，追加 MEDIASOUP_INGEST_CODEC=h264；可选追加 H264-only Router。"
  exit 0
fi

BAK="${ENVF}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$ENVF" "$BAK"
echo "已备份: $BAK"

strip_ingest_codec

{
  echo ""
  echo "# pilot-env-ensure-h264-ingest.sh $(date -Iseconds) — 整条 C1 用 H264，勿与 vp8 混用"
  echo "MEDIASOUP_INGEST_CODEC=h264"
} >>"$ENVF"

echo "已写入 MEDIASOUP_INGEST_CODEC=h264 到 ${ENVF}"
echo "可选（Router 只留 H264，浏览器与 ingest 都不会再走 VP8）：取消下行注释或手动追加"
echo "  MEDIASOUP_ROUTER_VIDEO_H264_ONLY=1"
echo ""
echo "下一步:"
echo "  docker compose config | grep MEDIASOUP_INGEST_CODEC"
echo "  docker compose build --no-cache && docker compose up -d --force-recreate"
echo "  # 宿主机 FFmpeg："
echo "  export MEDIASOUP_INGEST_CODEC=h264 && bash scripts/run-c1-ffmpeg-ingest.sh --local"
