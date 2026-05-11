#!/usr/bin/env bash
# 浏览器点「仅观看」后，从 pilot 容器日志里筛 C1 关键统计（PlainTransport / Producer / Consumer）。
# 须在 experiments/webrtc-sfu-pilot 目录执行（与 docker compose 同级）。
#
# 用法:
#   bash scripts/c1-sfu-stats-after-viewer.sh          # 默认拉最近 200 行再 grep
#   bash scripts/c1-sfu-stats-after-viewer.sh 400    # 最近 400 行
#   bash scripts/c1-sfu-stats-after-viewer.sh --follow
#     先打开页面并点「仅观看」，再执行；Ctrl+C 结束。
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

TAIL_N=200
FOLLOW=0
for a in "$@"; do
  case "${a}" in
    --follow | -f) FOLLOW=1 ;;
    *)
      if [[ "${a}" =~ ^[0-9]+$ ]]; then
        TAIL_N="${a}"
      else
        echo "unknown arg: ${a} (use number for tail lines, or --follow)" >&2
        exit 1
      fi
      ;;
  esac
done

echo "========== C1：SFU 侧统计（来自 resumeConsumer 后 1.5s/5s 等采样）==========" >&2
echo "建议顺序: ① 停掉其它 ingest 的 ffmpeg（避免混端口）② 打开 http://…:3000/ ③ 只点「仅观看」④ 等约 8s ⑤ 执行本脚本。" >&2
echo "判读: FFmpeg→SFU 的 packetCount 在多次点击间应持续增长；若长期卡在几十且 SFU-to-browser 为 0 → 先查 ingest 管道或 ICE（见 docs/layer-c1-lessons-learned.md §12）。" >&2
echo "" >&2

PATTERN='PlainTransport stats|FFmpeg→SFU|SFU-to-browser|ingest producer getStats|consume:'

if [[ "${FOLLOW}" == 1 ]]; then
  echo "--- docker compose logs -f（过滤 C1 行）---" >&2
  set +o pipefail
  docker compose logs -f --tail=0 webrtc-sfu-pilot 2>&1 | grep -E "${PATTERN}" || true
  set -o pipefail
else
  set +o pipefail
  docker compose logs --tail="${TAIL_N}" --no-color webrtc-sfu-pilot 2>&1 | grep -E "${PATTERN}" | tail -n 120 || true
  set -o pipefail
fi
