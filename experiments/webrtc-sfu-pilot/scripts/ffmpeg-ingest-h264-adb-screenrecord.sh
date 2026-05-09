#!/usr/bin/env bash
# Layer C1 扩展：ADB screenrecord（H264 raw）→ FFmpeg 重编码 → 与彩条脚本相同的 RTP 出口（mediasoup PlainTransport ingest）。
# 前置：宿主机已 adb devices 为 device；Redroid/真机已打开掌厅或任意待投画面。
# 用法与 ffmpeg-ingest-h264.sh 相同（host/port/[rtcp]、INGEST_PT、INGEST_SSRC 等）：
#   export ANDROID_SERIAL=127.0.0.1:5555   # 多设备时
#   bash scripts/ffmpeg-ingest-h264-adb-screenrecord.sh 127.0.0.1 41234
#   bash scripts/ffmpeg-ingest-h264-adb-screenrecord.sh 127.0.0.1 41234 41235
#
# 可选环境变量：
#   ADB_BIN              默认 adb
#   SCREENRECORD_SIZE    默认 720x1280
#   SCREENRECORD_BITRATE 默认 6000000
#   SCREENRECORD_TIME_LIMIT  秒；部分 ROM 最长 180。默认 0 表示不传该参数（由系统默认）。
#
# 说明：screenrecord 行为随 Android/Redroid 版本变化；若管道断流，可缩短 TIME_LIMIT 用外层循环重启（另做）。
set -euo pipefail

HOST=${1:-127.0.0.1}
PORT=${2:?usage: "$0 <host> <rtp_port> [rtcp_port] — 与 ffmpeg-ingest-h264.sh 一致"}
RTCP_PORT=${3:-${INGEST_RTCP_PORT:-$PORT}}
PT=${INGEST_PT:-96}
SSRC=${INGEST_SSRC:-111222333}

ADB_BIN=${ADB_BIN:-adb}
ANDROID_SERIAL=${ANDROID_SERIAL:-}
SCREENRECORD_SIZE=${SCREENRECORD_SIZE:-720x1280}
SCREENRECORD_BITRATE=${SCREENRECORD_BITRATE:-6000000}
SCREENRECORD_TIME_LIMIT=${SCREENRECORD_TIME_LIMIT:-0}

LOCALPORT=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-${INGEST_FFMPEG_LOCAL_PORT:-}}
if [[ -n "${LOCALPORT}" && "${LOCALPORT}" != "0" ]]; then
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${RTCP_PORT}&localport=${LOCALPORT}"
else
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${RTCP_PORT}"
fi

ADB_FLAGS=()
if [[ -n "${ANDROID_SERIAL}" ]]; then
  ADB_FLAGS+=(-s "${ANDROID_SERIAL}")
fi

if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit(f?0:1)}'; then
  echo "error: 无处于 device 状态的 adb 目标。请 adb connect / adb devices。ANDROID_SERIAL=${ANDROID_SERIAL:-"(未设)"}" >&2
  "${ADB_BIN}" "${ADB_FLAGS[@]}" devices >&2
  exit 1
fi

RECORD_CMD=(exec-out screenrecord --output-format=h264 --bit-rate="${SCREENRECORD_BITRATE}" --size="${SCREENRECORD_SIZE}")
if [[ "${SCREENRECORD_TIME_LIMIT}" != "0" ]]; then
  RECORD_CMD+=(--time-limit="${SCREENRECORD_TIME_LIMIT}")
fi
RECORD_CMD+=(-)

echo "ADB → FFmpeg → RTP：${ADB_BIN} ${ADB_FLAGS[*]} ${RECORD_CMD[*]}" >&2
echo "RTP 目标: ${RTP_URL}  PT=${PT} SSRC=${SSRC}" >&2

# screenrecord 输出为 annex B 字节流；经 libx264 重编码为 baseline + repeat-headers，与 ingest/浏览器更稳。
# 去掉 adb 侧 stderr 污染管道（部分机型打印警告）。
set -o pipefail
"${ADB_BIN}" "${ADB_FLAGS[@]}" "${RECORD_CMD[@]}" 2>/dev/null | exec ffmpeg -hide_banner -loglevel warning \
  -probesize 524288 -analyzeduration 500000 \
  -fflags +genpts+discardcorrupt+igndts \
  -f h264 -i - \
  -an \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 \
  -bf 0 -g 30 -keyint_min 30 \
  -force_key_frames "expr:gte(n,n_forced*30)" \
  -x264-params "repeat-headers=1:aud=1:bframes=0" \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp -pkt_size 1200 \
  "${RTP_URL}"
