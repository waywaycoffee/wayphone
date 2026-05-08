#!/usr/bin/env bash
# Layer C1 全链路 H264：在本目录生成/整理 .env，去掉盖住 compose 的旧 pin，固定 ingest=h264，并打印 compose 生效值。
# 用法（在 experiments/webrtc-sfu-pilot）:
#   bash scripts/pilot-c1-h264-bootstrap.sh 8.163.51.24
#   bash scripts/pilot-c1-h264-bootstrap.sh 8.163.51.24 --router-h264-only
#   bash scripts/pilot-c1-h264-bootstrap.sh --dry-run 8.163.51.24   # 仅打印将执行的步骤，不写 .env
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
ENVF=".env"
EXAMPLE=".env.pilot.example"

DRY=0
H264_ONLY=0
ANNOUNCED_IP=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --router-h264-only) H264_ONLY=1 ;;
    -*)
      echo "未知参数: $a" >&2
      exit 1
      ;;
    *)
      if [[ -n "$ANNOUNCED_IP" ]]; then
        echo "只接受一个 IP 参数；多余: $a" >&2
        exit 1
      fi
      ANNOUNCED_IP="$a"
      ;;
  esac
done

if [[ -z "$ANNOUNCED_IP" ]]; then
  echo "用法: $0 <MEDIASOUP_ANNOUNCED_IP> [--router-h264-only]" >&2
  echo "  MEDIASOUP_ANNOUNCED_IP = 浏览器访问 WebRTC 媒体面时能路由到的 IP（公网 PoC 一般为 ECS EIP）" >&2
  echo "  --router-h264-only   = Router 只注册 H264，杜绝 VP8 混进协商" >&2
  echo "示例: $0 8.163.51.24 --router-h264-only" >&2
  exit 1
fi

if [[ ! -f "$EXAMPLE" ]]; then
  echo "缺少 ${EXAMPLE}，请 git pull 获取仓库内示例。" >&2
  exit 1
fi

if [[ "$DRY" == "1" ]]; then
  echo "[--dry-run] 将: 确保存在 .env；写入 MEDIASOUP_ANNOUNCED_IP / INGEST_TEST=1；"
  echo "  可选 MEDIASOUP_ROUTER_VIDEO_H264_ONLY=1；调用 unpin + ensure-h264。"
  exit 0
fi

if [[ ! -f "$ENVF" ]]; then
  cp -a "$EXAMPLE" "$ENVF"
  echo "已从 ${EXAMPLE} 创建 ${ENVF}"
fi

strip_key() {
  local key="$1"
  grep -vE "^[[:space:]]*${key}=" "$ENVF" >"${ENVF}.tmp" || true
  mv "${ENVF}.tmp" "$ENVF"
}

strip_key MEDIASOUP_ANNOUNCED_IP
{
  echo ""
  echo "# pilot-c1-h264-bootstrap $(date -Iseconds)"
  echo "MEDIASOUP_ANNOUNCED_IP=${ANNOUNCED_IP}"
} >>"$ENVF"

strip_key MEDIASOUP_INGEST_TEST
echo "MEDIASOUP_INGEST_TEST=1" >>"$ENVF"

if [[ "$H264_ONLY" == "1" ]]; then
  strip_key MEDIASOUP_ROUTER_VIDEO_H264_ONLY
  echo "MEDIASOUP_ROUTER_VIDEO_H264_ONLY=1" >>"$ENVF"
  echo "已写入 MEDIASOUP_ROUTER_VIDEO_H264_ONLY=1"
fi

bash "${REPO_DIR}/scripts/pilot-env-unpin-compose-defaults.sh"
bash "${REPO_DIR}/scripts/pilot-env-ensure-h264-ingest.sh"

echo ""
echo "=== docker compose 合并后的关键项（请以这里为准）==="
docker compose config 2>/dev/null | grep -E 'MEDIASOUP_ANNOUNCED_IP|MEDIASOUP_INGEST_TEST|MEDIASOUP_INGEST_CODEC|MEDIASOUP_ROUTER_VIDEO_H264_ONLY|PILOT_VERSION' || true

echo ""
echo "=== 下一步（在 ${REPO_DIR}）==="
echo "  docker compose build --no-cache && docker compose up -d --force-recreate"
echo "  docker compose logs --tail=25 webrtc-sfu-pilot | grep -E 'PlainTransport|MEDIASOUP_INGEST_CODEC|ingest PT'"
echo "  # 确认日志为 H264、PT=103 后，宿主机："
echo "  export MEDIASOUP_INGEST_CODEC=h264"
echo "  bash scripts/run-c1-ffmpeg-ingest.sh --local"
echo "  # 浏览器打开 http://${ANNOUNCED_IP}:3000 仅「仅观看」"
