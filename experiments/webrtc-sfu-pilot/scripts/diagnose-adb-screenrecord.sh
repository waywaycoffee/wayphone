#!/usr/bin/env bash
# Redroid ADB screenrecord → FFmpeg 上游断流排查（RTCP 活、RTP 死时跑）。
# 用法: cd experiments/webrtc-sfu-pilot && bash scripts/diagnose-adb-screenrecord.sh
# 环境: ANDROID_SERIAL（多设备必填）、ADB_BIN、SCREENRECORD_* 与 ingest 脚本一致
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"

ADB_BIN=${ADB_BIN:-adb}
ANDROID_SERIAL=${ANDROID_SERIAL:-}
SIZE=${SCREENRECORD_SIZE:-540x960}
BR=${SCREENRECORD_BITRATE:-3000000}
SEC=${DIAGNOSE_SCREENRECORD_SEC:-12}
OUT=/tmp/diag-screenrecord-$$.h264
ERR=/tmp/diag-screenrecord-$$.err

ADB_FLAGS=()
[[ -n "${ANDROID_SERIAL}" ]] && ADB_FLAGS+=(-s "${ANDROID_SERIAL}")

echo "=== 1) adb devices ==="
"${ADB_BIN}" devices || true

if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit(f?0:1)}'; then
  echo "✗ 无 device，请先 adb connect" >&2
  exit 1
fi

echo ""
echo "=== 2) 掌厅进程（无则先启动再录屏）==="
APP_PID=$("${ADB_BIN}" "${ADB_FLAGS[@]}" shell pidof com.greenpoint.android.mc10086.activity 2>/dev/null | tr -d '\r' || true)
if [[ -z "${APP_PID}" ]]; then
  echo "    ✗ 无进程 — screenrecord 可能只有桌面/黑屏，字节率极低，ingest 易「RTCP 活 RTP 死」。请先:"
  echo "      ${ADB_BIN} ${ADB_FLAGS[*]} shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity"
  echo "      等 3s 再 pidof / 重跑本脚本。"
else
  echo "    pid=${APP_PID}"
fi

echo ""
echo "=== 3) screenrecord ${SEC}s → ${OUT}（stderr→${ERR}）==="
echo "    参数: size=${SIZE} bit-rate=${BR}"
rm -f "${OUT}" "${ERR}"
set +e
timeout "${SEC}" "${ADB_BIN}" "${ADB_FLAGS[@]}" exec-out screenrecord \
  --output-format=h264 --bit-rate="${BR}" --size="${SIZE}" - >"${OUT}" 2>"${ERR}"
rc=$?
set -e

bytes=$(wc -c <"${OUT}" 2>/dev/null || echo 0)
# 124 = GNU timeout 到时结束子进程，属正常
echo "    exit=${rc}  bytes=${bytes}  (exit 124=timeout 正常；bytes 极小=无持续 H264)"
if [[ -s "${ERR}" ]]; then
  echo "    --- stderr (关键字: failed|error|killed|timeout|denied|display|not found) ---"
  grep -iE 'fail|error|kill|timeout|denied|display|not found|unable|invalid' "${ERR}" || tail -15 "${ERR}"
else
  echo "    (stderr 空)"
fi

echo ""
echo "=== 4) 建议 ==="
# 约 ≥40KB/s 才像「有在录屏」的粗门槛（可调）
min_ok=$((SEC * 40000))
if [[ "${bytes}" -lt 10000 ]]; then
  echo "    · 几乎无数据：检查 Redroid/adb connect、冻屏、或提高 DIAGNOSE_SCREENRECORD_SEC"
elif [[ "${bytes}" -lt "${min_ok}" ]]; then
  echo "    · bytes=${bytes} / ${SEC}s 偏低（低于约 ${min_ok} 的粗阈值）— 常见：掌厅未前台、launcher、或编码极慢；先 am start 掌厅再重跑"
else
  echo "    · screenrecord  stdout 量尚可；若 RTP 仍 0，查 FFmpeg 卡住、ingest 端口是否与 compose 一致"
fi
if [[ -z "${APP_PID:-}" ]]; then
  echo "    · 当前无掌厅进程，务必先启动应用再测 ingest。"
fi
echo "    · ingest: ADB_SCREENRECORD_STDERR=/dev/stderr + c1:ingest:adb:loop"
echo "    · 彩条 ingest 时 tcpdump RTP 口应有密包；ADB 时 0 包 → 上游 stdin 问题"
echo ""
echo "临时文件: ${OUT} ${ERR}（可 rm）"
