#!/usr/bin/env bash
# Layer C1：向 mediasoup PlainTransport 发送 VP8 测试图案（需 MEDIASOUP_INGEST_CODEC=vp8 且 PT/SSRC 与 server 一致）。
# 用法：bash scripts/ffmpeg-ingest-vp8.sh 127.0.0.1 41234
set -euo pipefail
HOST=${1:-127.0.0.1}
PORT=${2:?usage: "$0 <host> <rtp_port>"}
PT=${INGEST_PT:-96}
SSRC=${INGEST_SSRC:-111222333}

echo "向 rtp://${HOST}:${PORT} 持续发送 VP8（与 H264 二选一；黑屏/framesDecoded=0 时优先试本脚本）。Ctrl+C 结束。" >&2

# rtcpport=PORT：与 mediasoup PlainTransport rtcpMux 一致
# libvpx：低延迟、禁用 alt-ref 减少首帧等待
exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=640x480:rate=15" -pix_fmt yuv420p \
  -c:v libvpx -deadline realtime -cpu-used 16 \
  -auto-alt-ref 0 -lag-in-frames 0 \
  -b:v 2M -maxrate 2M -bufsize 4M \
  -g 30 -keyint_min 30 \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp "rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}"
