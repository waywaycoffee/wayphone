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
# 默认不写 localport：避免 35500 被上次未退出的 FFmpeg 占用 → bind failed: Address already in use。
# PlainTransport comedia 不要求固定源口。仅 MEDIASOUP_INGEST_PLAIN_CONNECT=1 且须与 connect 一致时再：
#   export MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT=35500
LOCALPORT=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-${INGEST_FFMPEG_LOCAL_PORT:-}}
if [[ -n "${LOCALPORT}" && "${LOCALPORT}" != "0" ]]; then
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}&localport=${LOCALPORT}"
  echo "向 ${RTP_URL} 持续发送 H264（已绑定 localport=${LOCALPORT}）。请保持本终端运行；结束请 Ctrl+C。" >&2
else
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${PORT}"
  echo "向 ${RTP_URL} 持续发送 H264（未指定 localport，由内核选源 UDP 口；SFU comedia 可学源口）。请保持本终端运行；结束请 Ctrl+C。" >&2
fi

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
  "${RTP_URL}"
