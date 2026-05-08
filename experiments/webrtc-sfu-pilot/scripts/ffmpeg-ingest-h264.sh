#!/usr/bin/env bash
# Layer C1：向 mediasoup PlainTransport 发送 H264 测试图案（需与服务端打印的 PT/SSRC 一致）。
# 用法（ECS，先启动 MEDIASOUP_INGEST_TEST=1 的 server，复制日志里的 IP:PORT）：
#   chmod +x scripts/ffmpeg-ingest-h264.sh
#   ./scripts/ffmpeg-ingest-h264.sh 127.0.0.1 41234
# MEDIASOUP_INGEST_RTCP_MUX=0 时服务端会打印第三参 RTCP 端口（对齐 mediasoup-demo）：
#   ./scripts/ffmpeg-ingest-h264.sh 127.0.0.1 41234 41235
set -euo pipefail
HOST=${1:-127.0.0.1}
PORT=${2:?usage: "$0 <host> <rtp_port> [rtcp_port] — RTP 端口见日志 mediasoup RTP tuple；第三参见 ingest_rtcp_port"}
RTCP_PORT=${3:-${INGEST_RTCP_PORT:-$PORT}}
PT=${INGEST_PT:-96}
SSRC=${INGEST_SSRC:-111222333}
# 默认不写 localport：避免 35500 被上次未退出的 FFmpeg 占用 → bind failed: Address already in use。
# PlainTransport comedia 不要求固定源口。仅 MEDIASOUP_INGEST_PLAIN_CONNECT=1 且须与 connect 一致时再：
#   export MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT=35500
LOCALPORT=${MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT:-${INGEST_FFMPEG_LOCAL_PORT:-}}
if [[ -n "${LOCALPORT}" && "${LOCALPORT}" != "0" ]]; then
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${RTCP_PORT}&localport=${LOCALPORT}"
  echo "向 ${RTP_URL} 持续发送 H264（已绑定 localport=${LOCALPORT}）。请保持本终端运行；结束请 Ctrl+C。" >&2
else
  RTP_URL="rtp://${HOST}:${PORT}?pkt_size=1200&rtcpport=${RTCP_PORT}"
  echo "向 ${RTP_URL} 持续发送 H264（RTP=${PORT} RTCP=${RTCP_PORT}；未指定 localport）。Ctrl+C 结束。" >&2
fi

# repeat-headers=1：周期性带 SPS/PPS，避免浏览器/WebRTC 解码器收不到参数集而一直黑屏
# -bf 0、固定 GOP：减少 PlainTransport ingest 与「无法向 FFmpeg 要关键帧」时的首帧解码问题
# -force_key_frames expr:gte(t,0)：首帧即 IDR，便于刚连上就 consume（勿用 -rtpflags +latm，与 RFC6184 H264 不符）
# rtcpport=PORT + localport 在 URL：mediasoup rtcpMux；Linux 上 muxer -localport 常无效
exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=640x480:rate=30" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 \
  -bf 0 -g 30 -keyint_min 30 \
  -force_key_frames "expr:gte(t,0)" \
  -x264-params "repeat-headers=1:aud=1:bframes=0" \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp -pkt_size 1200 \
  "${RTP_URL}"
