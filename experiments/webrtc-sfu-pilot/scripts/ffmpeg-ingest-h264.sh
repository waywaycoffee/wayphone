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

echo "向 rtp://${HOST}:${PORT} 持续发送 H264（正常会长时间无新输出，不是死机）。请保持本终端运行，浏览器打开试点页并点「仅观看」；结束请 Ctrl+C。" >&2

# repeat-headers=1：周期性带 SPS/PPS，避免浏览器/WebRTC 解码器收不到参数集而一直黑屏
# -bf 0、固定 GOP：减少 PlainTransport  ingest 与「无法向 FFmpeg 要关键帧」时的首帧解码问题
# rtcpport=PORT：mediasoup PlainTransport 默认 rtcpMux=true，RTP/RTCP 同 UDP 口；FFmpeg 默认 RTCP 走 port+1 会导致 SFU 收流异常/黑屏
exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=640x480:rate=15" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 \
  -bf 0 -g 30 -keyint_min 30 \
  -x264-params "repeat-headers=1:aud=1" \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp "rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}"
