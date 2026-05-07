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
LOCALPORT=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-${INGEST_FFMPEG_LOCAL_PORT:-35500}}

echo "向 rtp://${HOST}:${PORT} 持续发送 H264（URL localport=${LOCALPORT}；默认 SFU comedia）。请保持本终端运行；结束请 Ctrl+C。" >&2

# repeat-headers=1：周期性带 SPS/PPS，避免浏览器/WebRTC 解码器收不到参数集而一直黑屏
# -bf 0、固定 GOP：减少 PlainTransport  ingest 与「无法向 FFmpeg 要关键帧」时的首帧解码问题
# rtcpport=PORT + localport 在 URL：mediasoup rtcpMux；Linux 上 muxer -localport 常无效
exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=640x480:rate=15" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 \
  -bf 0 -g 30 -keyint_min 30 \
  -x264-params "repeat-headers=1:aud=1" \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp -pkt_size 1200 \
  "rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}&localport=${LOCALPORT}"
