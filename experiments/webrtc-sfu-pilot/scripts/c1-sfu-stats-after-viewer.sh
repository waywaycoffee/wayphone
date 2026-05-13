#!/usr/bin/env bash
# 浏览器点「仅观看」后，从 pilot 容器日志里筛 C1 关键统计（PlainTransport / Producer / Consumer）。
# 须在 experiments/webrtc-sfu-pilot 目录执行（与 docker compose 同级）。
#
# 用法:
#   bash scripts/c1-sfu-stats-after-viewer.sh          # 默认拉最近 200 行再 grep
#   bash scripts/c1-sfu-stats-after-viewer.sh 400    # 最近 400 行
#   bash scripts/c1-sfu-stats-after-viewer.sh --last-consume   # 只保留「最后一次 consume:」之后的块（避免多次点仅观看混在 tail 里误读）
#   bash scripts/c1-sfu-stats-after-viewer.sh --last-consume 800
#   bash scripts/c1-sfu-stats-after-viewer.sh --follow
#     先打开页面并点「仅观看」，再执行；Ctrl+C 结束。
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

TAIL_N=200
FOLLOW=0
LAST_CONSUME=0
for a in "$@"; do
  case "${a}" in
    --follow | -f) FOLLOW=1 ;;
    --last-consume) LAST_CONSUME=1 ;;
    *)
      if [[ "${a}" =~ ^[0-9]+$ ]]; then
        TAIL_N="${a}"
      else
        echo "unknown arg: ${a} (use number for tail lines, --follow, or --last-consume)" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ "${LAST_CONSUME}" == 1 ]] && [[ "${TAIL_N}" -eq 200 ]]; then
  TAIL_N=800
  echo "提示: --last-consume 默认改用 --tail=800；仍截断可再加大: bash $0 --last-consume 2000" >&2
fi

echo "========== C1：SFU 侧统计（来自 resumeConsumer 后 1.5s/5s 等采样）==========" >&2
echo "建议顺序: ① 停掉其它 ingest 的 ffmpeg（避免混端口）② 打开 http://…:3000/ ③ 只点「仅观看」④ 等约 8s ⑤ 执行本脚本。" >&2
echo "判读: FFmpeg→SFU 的 packetCount 在多次点击间应持续增长；若长期卡在几十且 SFU-to-browser 为 0 → 先查 ingest 管道或 ICE（见 docs/layer-c1-lessons-learned.md §12）。" >&2
if [[ "${LAST_CONSUME}" == 1 ]]; then
  echo "模式: --last-consume（仅显示日志里最后一次「consume:」之后的 Layer C1 行，避免多次点「仅观看」把旧块和新块拼在一起误判）。" >&2
else
  echo "提示: 默认输出可能混合多次「仅观看」的旧 producer 与新 producer；只看当前一次请加:  bash $0 --last-consume 2000" >&2
fi
echo "" >&2

PATTERN='PlainTransport stats|FFmpeg→SFU|SFU-to-browser|ingest producer getStats|consume:'

_filter_last_consume_block() {
  # stdin: 已 grep 的多行；只输出「最后一次 | consume:」及其后的 | Layer C1 | 行
  awk '
    /\| consume:/ { buf=$0 "\n"; next }
    /\| Layer C1 / { buf=buf $0 "\n"; next }
    END {
      if (buf != "") print buf
      else print "(本窗口内无 consume: 行 — 请先点「仅观看」或加大 tail，例如: bash scripts/c1-sfu-stats-after-viewer.sh --last-consume 2000)"
    }
  '
}

if [[ "${FOLLOW}" == 1 ]]; then
  echo "--- docker compose logs -f（过滤 C1 行）---" >&2
  set +o pipefail
  docker compose logs -f --tail=0 webrtc-sfu-pilot 2>&1 | grep -E "${PATTERN}" || true
  set -o pipefail
else
  set +o pipefail
  _pipe=$(docker compose logs --tail="${TAIL_N}" --no-color webrtc-sfu-pilot 2>&1 | grep -E "${PATTERN}" || true)
  if [[ "${LAST_CONSUME}" == 1 ]]; then
    echo "${_pipe}" | _filter_last_consume_block
  else
    echo "${_pipe}" | tail -n 120
  fi
  set -o pipefail
fi
