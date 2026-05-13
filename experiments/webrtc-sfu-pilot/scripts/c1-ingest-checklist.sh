#!/usr/bin/env bash
# C1 Ingest 侧四步排查：可打印可执行命令（在 experiments/webrtc-sfu-pilot 目录运行）。
#   bash scripts/c1-ingest-checklist.sh
#   bash scripts/c1-ingest-checklist.sh --tcpdump   # 若本机有权限，代跑 tcpdump（最长约 12s）
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

RUN_TCPDUMP=0
for a in "$@"; do
  case "${a}" in
    --tcpdump) RUN_TCPDUMP=1 ;;
    -h | --help)
      echo "用法: bash scripts/c1-ingest-checklist.sh [--tcpdump]"
      echo "  --tcpdump  尝试执行 tcpdump（最长约 12s；无包时多为 stdin 未出 H264，非权限）"
      exit 0
      ;;
    *)
      echo "unknown arg: ${a} (use --tcpdump or --help)" >&2
      exit 1
      ;;
  esac
done

echo "========== C1 Ingest 四步排查（宿主机 · ${REPO_DIR}）=========="
echo ""

echo "① 看「正在跑 adb ingest 的 SSH 终端」stderr"
echo "   若出现下列整行 → 推流已断（adb 管道结束 / FFmpeg 随之 EOF）："
echo "   ingest 管道结束: adb_exit=... ffmpeg_exit=..."
echo "   说明: 该行由 scripts/ffmpeg-ingest-h264-adb-screenrecord.sh 打印，不会进 docker logs。"
echo "   adb_exit≠0 → adb devices、screenrecord、Redroid；ffmpeg_exit≠0 → FFMPEG_LOGLEVEL=info"
echo ""

echo "② 本机是否有 FFmpeg ingest 进程"
set +e
_FF_OUT=$(pgrep -af ffmpeg 2>/dev/null || true)
set -e
if [[ -z "${_FF_OUT}" ]]; then
  echo "   结果: (无 ffmpeg) → ingest 未启动或已退出。请另开终端跑:"
  echo "     bash scripts/c1-ingest-safe.sh adb-loop"
  RTP_FROM_PGREP=""
else
  echo "   pgrep -af ffmpeg:"
  echo "${_FF_OUT}" | sed 's/^/     /'
  RTP_FROM_PGREP=$(echo "${_FF_OUT}" | grep -oE 'rtp://127\.0\.0\.1:[0-9]+' | head -1 | sed 's/.*://' || true)
  if [[ -n "${RTP_FROM_PGREP}" ]]; then
    echo "   从命令行解析 RTP 端口: ${RTP_FROM_PGREP}（须与 ③ 日志一致；recreate pilot 后会变）"
  fi
fi
echo ""

echo "③ Pilot 日志中的 RTP / RTCP（最近 400 行）"
set +e
_LOG=$(docker compose logs --tail=400 --no-color webrtc-sfu-pilot 2>&1 || true)
set -e
_LOG_INGEST=$(echo "${_LOG}" | grep -E 'ingest_rtcp_port=|mediasoup RTP tuple:|手动: bash scripts/ffmpeg-ingest' | tail -n 8 || true)
if [[ -z "${_LOG_INGEST}" ]]; then
  echo "   (未匹配到 — 容器是否运行？可: docker compose logs --tail=800 webrtc-sfu-pilot | grep RTP)"
else
  echo "${_LOG_INGEST}" | sed 's/^/     /'
fi
RTP_FROM_LOG=""
_TUPLE=$(echo "${_LOG}" | sed -n 's/.*mediasoup RTP tuple:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n 1)
if [[ -n "${_TUPLE}" ]]; then
  RTP_FROM_LOG="${_TUPLE##*:}"
  echo "   从日志解析 RTP 端口: ${RTP_FROM_LOG}（tuple=${_TUPLE}）"
fi
echo ""

RTP_FOR_DUMP="${RTP_FROM_PGREP:-}"
if [[ -z "${RTP_FOR_DUMP}" ]]; then
  RTP_FOR_DUMP="${RTP_FROM_LOG:-}"
fi

if [[ -n "${RTP_FOR_DUMP}" ]]; then
  echo "④ RTP 口是否有 UDP 包（无包 = SFU 收不到媒体 / ingest 已停或打错口）"
  _TD="timeout 12 tcpdump -ni lo udp port ${RTP_FOR_DUMP} -c 25"
  echo "   执行:"
  echo "     ${_TD}"
  echo "   判读: 0 packets 常见于 ADB→FFmpeg stdin 尚未持续出 H264（screenrecord 堵/段首），FFmpeg 可能暂不往 RTP 打 UDP；对照 ingest 终端 frame= / 是否出现 ingest 管道结束。"
  if [[ "${RUN_TCPDUMP}" == 1 ]]; then
    echo "   (--tcpdump) 正在运行（最长约 12s）…"
    set +e
    set +o pipefail
    _td_out=$(eval "${_TD}" 2>&1)
    _td_rc=$?
    set -o pipefail
    echo "${_td_out}" | sed 's/^/     /'
    if [[ "${_td_rc}" -ne 0 ]]; then
      if [[ "${_td_rc}" -eq 124 ]]; then
        echo "     (timeout 结束: exit 124 — 窗口内包很少或 FFmpeg 尚未发 RTP，不一定是权限问题)"
      else
        echo "     (tcpdump/timeout 退出码=${_td_rc} — 未安装 tcpdump、无抓包权限或参数错误)"
      fi
    fi
    set -e
  else
    echo "   若要本脚本代跑: bash scripts/c1-ingest-checklist.sh --tcpdump"
  fi
  if [[ -n "${RTP_FROM_PGREP}" && -n "${RTP_FROM_LOG}" && "${RTP_FROM_PGREP}" != "${RTP_FROM_LOG}" ]]; then
    echo "   警告: pgrep 端口(${RTP_FROM_PGREP}) ≠ 日志端口(${RTP_FROM_LOG}) → 可能打到旧口，先 stop 再起 ingest 或 pilot-recreate"
  fi
else
  echo "④ 无法给出 tcpdump 端口（无 ffmpeg 且无日志 tuple）。先启动 ingest 或拉大 docker logs tail。"
fi
echo ""

echo "⑤ 卡死时硬恢复（重建 PlainTransport 元组 + 单路 adb-loop）"
echo "     cd ${REPO_DIR}"
echo "     bash scripts/c1-ingest-safe.sh stop"
echo "     bash scripts/c1-ingest-safe.sh --recreate-pilot adb-loop"
echo "   浏览器: 硬刷新 → 只点一次「仅观看」→ 等 ≥8s"
echo "     bash scripts/c1-sfu-stats-after-viewer.sh --last-consume 2000"
echo ""
echo "（等价 npm: npm run c1:diag:ingest）"
echo ""
echo "⑥ comedia（adb 多段重启 ffmpeg 后易 mismatch）"
echo "     bash scripts/c1-ingest-comedia-check.sh"
echo "     npm run c1:check:comedia"
echo ""
echo "⑦ ffmpeg 目的 RTP 口是否与 pilot 日志最新 tuple 一致（防旧进程打旧口）"
echo "     bash scripts/c1-ingest-ffmpeg-rtp-vs-pilot-log.sh"
