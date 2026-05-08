#!/usr/bin/env bash
# Layer C1：向 mediasoup PlainTransport 发送 VP8 测试图案（需 MEDIASOUP_INGEST_CODEC=vp8 且 PT/SSRC 与 server 一致）。
# 用法：bash scripts/ffmpeg-ingest-vp8.sh 127.0.0.1 41234
set -euo pipefail
HOST=${1:-127.0.0.1}
PORT=${2:?usage: "$0 <host> <rtp_port>"}
PT=${INGEST_PT:-96}
SSRC=${INGEST_SSRC:-111222333}
# 默认不写 localport（见 ffmpeg-ingest-h264.sh）。connect 固定源口时再 export MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT=35500
LOCALPORT=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-${INGEST_FFMPEG_LOCAL_PORT:-}}
if [[ -n "${LOCALPORT}" && "${LOCALPORT}" != "0" ]]; then
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}&localport=${LOCALPORT}"
  echo "向 ${RTP_URL} 持续发送 VP8（localport=${LOCALPORT}）。Ctrl+C 结束。" >&2
else
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}"
  echo "向 ${RTP_URL} 持续发送 VP8（未指定 localport）。Ctrl+C 结束。" >&2
fi

# rtcpport=PORT：与 mediasoup PlainTransport rtcpMux 一致
# localport 放在 rtp:// 查询串：Linux 上 -f rtp -localport 常不生效（tcpdump 仍见随机源口）
# libvpx：低延迟、禁用 alt-ref 减少首帧等待
exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=640x480:rate=15" -pix_fmt yuv420p \
  -c:v libvpx -deadline realtime -cpu-used 16 \
  -auto-alt-ref 0 -lag-in-frames 0 \
  -b:v 2M -maxrate 2M -bufsize 4M \
  -g 30 -keyint_min 30 \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp -pkt_size 1200 \
  "${RTP_URL}"
