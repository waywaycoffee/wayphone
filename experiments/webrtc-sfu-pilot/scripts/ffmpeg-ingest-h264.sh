#!/usr/bin/env bash
# Layer C1：向 mediasoup PlainTransport 发送 H264 测试图案（需与服务端打印的 PT/SSRC 一致）。
# 用法（ECS，先启动 MEDIASOUP_INGEST_TEST=1 的 server，复制日志里的 IP:PORT）：
#   chmod +x scripts/ffmpeg-ingest-h264.sh
#   ./scripts/ffmpeg-ingest-h264.sh 127.0.0.1 41234
set -euo pipefail
HOST=${1:-127.0.0.1}
PORT=${2:?usage: "$0 <host> <rtp_port> — port from server log \"Send RTP to\""}
PT=${INGEST_PT:-96}
SSRC=${INGEST_SSRC:-111222333}

exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=640x480:rate=15" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp "rtp://${HOST}:${PORT}?pkt_size=1200"
