#!/usr/bin/env bash
# 去掉本目录 .env 里「盖住 docker-compose.yml 默认值」的几项，避免 PILOT_VERSION / INGEST_CODEC 永远追不上仓库。
# 用法（在 experiments/webrtc-sfu-pilot）:
#   bash scripts/pilot-env-unpin-compose-defaults.sh
#   bash scripts/pilot-env-unpin-compose-defaults.sh --dry-run
# 默认会备份 .env 再删行；不删 MEDIASOUP_ANNOUNCED_IP 等仍须手填的项。
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
ENVF=".env"
DRY=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && DRY=1; done

# 与 docker-compose.yml 中 ${VAR:-default} 重叠、易导致「版本追不上」的键
STRIP_REGEX='^(PILOT_VERSION|MEDIASOUP_INGEST_CODEC|MEDIASOUP_WORKER_LOG_TAGS|DEBUG)='

if [[ ! -f "$ENVF" ]]; then
  echo "无 ${ENVF}，compose 已用内置默认。需要示例可复制: cp .env.pilot.example .env"
  exit 0
fi

if ! grep -qE "${STRIP_REGEX}" "$ENVF"; then
  echo "${ENVF} 中无待剥离键（${STRIP_REGEX}），无需修改。"
  exit 0
fi

echo "将剥离 ${ENVF} 中匹配: ${STRIP_REGEX}"
grep -nE "${STRIP_REGEX}" "$ENVF" || true

if [[ "$DRY" == "1" ]]; then
  echo "[--dry-run] 未写入。去掉 --dry-run 后执行以应用。"
  exit 0
fi

BAK="${ENVF}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$ENVF" "$BAK"
echo "已备份: $BAK"

grep -vE "${STRIP_REGEX}" "$ENVF" >"${ENVF}.tmp"
mv "${ENVF}.tmp" "$ENVF"
echo "已更新 ${ENVF}。请执行:"
echo "  docker compose config | grep -E 'PILOT_VERSION|MEDIASOUP_INGEST_CODEC'"
echo "  docker compose build --no-cache && docker compose up -d --force-recreate"
echo "  curl -s http://127.0.0.1:3000/__pilot_version"
