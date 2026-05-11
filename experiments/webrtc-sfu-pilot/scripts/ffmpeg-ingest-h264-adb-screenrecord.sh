#!/usr/bin/env bash
# Layer C1 扩展：ADB screenrecord（H264 raw）→ FFmpeg 重编码 → 与彩条脚本相同的 RTP 出口（mediasoup PlainTransport ingest）。
# 前置：宿主机已 adb devices 为 device；Redroid/真机已打开掌厅或任意待投画面。
# 用法与 ffmpeg-ingest-h264.sh 相同（host/port/[rtcp]、INGEST_PT、INGEST_SSRC 等）：
#   多设备时自动 127.0.0.1:5555；或 export ANDROID_SERIAL / C1_ADB_SERIAL
#   bash scripts/ffmpeg-ingest-h264-adb-screenrecord.sh 127.0.0.1 41234
#   bash scripts/ffmpeg-ingest-h264-adb-screenrecord.sh 127.0.0.1 41234 41235
#
# 可选环境变量：
#   ADB_BIN              默认 adb
#   SCREENRECORD_SIZE    默认 720x1280
#   SCREENRECORD_BITRATE 默认 6000000
#   SCREENRECORD_TIME_LIMIT  秒；部分 ROM 最长 180。默认 0 表示不传该参数（由系统默认）。
#   SCREENRECORD_PROBE_SIZE     FFmpeg -probesize，默认 32M（管道上 SPS 可能较晚，过小会「unspecified size」且无输出流）
#   SCREENRECORD_ANALYZE_US     FFmpeg -analyzeduration（微秒），默认 20M
#   ADB_SCREENRECORD_STDERR     默认 discard：adb screenrecord 的 stderr 不进终端；设为 /dev/stderr 便于排错
#   FFMPEG_LOGLEVEL          默认 warning；排错可 export FFMPEG_LOGLEVEL=info
#
# 说明：screenrecord 行为随 Android/Redroid 版本变化；若管道断流，可缩短 TIME_LIMIT 用外层循环重启（另做）。
# 退出时：脚本会向 stderr 打印 adb / ffmpeg 的退出码（常见：adb=0 ffmpeg=0 为 stdin 正常 EOF；ffmpeg 非 0 多为编码/RTP；adb 非 0 多为设备断连）。
set -euo pipefail

usage() {
  cat <<'EOF' >&2
ffmpeg-ingest-h264-adb-screenrecord.sh — ADB screenrecord → FFmpeg → RTP（C1 PlainTransport）

位置参数（推荐，与 ffmpeg-ingest-h264.sh 一致）:
  <host> <rtp_port> [rtcp_port]

可选长选项（须写在位置参数之前；与 run-c1 自动传参二选一）:
  --url rtp://HOST:PORT[?...&rtcpport=N...]   解析 HOST / RTP 口 / RTCP 口（无 rtcpport 时与第三参或 INGEST_RTCP_PORT 或 RTP 口相同）
  --width W --height H                       设置录屏分辨率 WxH（须同时给）
  --bitrate 3000000 | 3M | 6m              screenrecord --bit-rate，单位 bit/s；后缀 M/m 表示兆 bit/s
  --adb                                      无操作（本脚本始终走 ADB）

示例:
  bash scripts/ffmpeg-ingest-h264-adb-screenrecord.sh 127.0.0.1 45078 42835
  bash scripts/ffmpeg-ingest-h264-adb-screenrecord.sh --width 540 --height 960 --bitrate 3M -- 127.0.0.1 45078 42835
EOF
}

# 从 rtp://host:port?...&rtcpport= 解析（host 可为 IPv4）
_parse_rtp_url() {
  local _u="$1"
  [[ "${_u}" == rtp://* ]] || return 1
  local _r="${_u#rtp://}"
  _url_host="${_r%%:*}"
  local _rest="${_r#*:}"
  _url_port="${_rest%%\?*}"
  _url_port="${_url_port%%/*}"
  _url_rtcp=""
  case "${_u}" in
    *rtcpport=*) _url_rtcp="${_u#*rtcpport=}"; _url_rtcp="${_url_rtcp%%&*}" ;;
  esac
  [[ "${_url_port}" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "${_url_rtcp}" && ! "${_url_rtcp}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  return 0
}

_parse_bitrate_arg() {
  local b="$1"
  if [[ "${b}" =~ ^[0-9]+[Mm]$ ]]; then
    local n="${b%[Mm]}"
    echo $((n * 1000000))
  elif [[ "${b}" =~ ^[0-9]+$ ]]; then
    echo "${b}"
  else
    return 1
  fi
}

_url_host=""
_url_port=""
_url_rtcp=""
flag_w=""
flag_h=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --url)
      [[ $# -ge 2 ]] || { echo "error: --url 需要参数" >&2; exit 1; }
      _parse_rtp_url "$2" || { echo "error: 无法解析 --url（需要 rtp://HOST:PORT[&rtcpport=…]）: $2" >&2; exit 1; }
      shift 2
      ;;
    --width)
      [[ $# -ge 2 ]] || { echo "error: --width 需要参数" >&2; exit 1; }
      flag_w="$2"
      shift 2
      ;;
    --height)
      [[ $# -ge 2 ]] || { echo "error: --height 需要参数" >&2; exit 1; }
      flag_h="$2"
      shift 2
      ;;
    --bitrate)
      [[ $# -ge 2 ]] || { echo "error: --bitrate 需要参数" >&2; exit 1; }
      SCREENRECORD_BITRATE="$(_parse_bitrate_arg "$2")" || { echo "error: 无法解析 --bitrate: $2（用 3000000 或 3M）" >&2; exit 1; }
      shift 2
      ;;
    --adb) shift ;;
    --) shift; break ;;
    -*)
      echo "error: 未知选项: $1（本脚本为 host rtp_port [rtcp]；误把 --url 当第一个位置参数会导致 RTP 目标错乱）" >&2
      usage
      exit 1
      ;;
    *) break ;;
  esac
done

ADB_BIN=${ADB_BIN:-adb}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
_def=$(bash "${SCRIPT_DIR}/c1-default-android-serial.sh") || exit 1
eval "${_def}"
ANDROID_SERIAL=${ANDROID_SERIAL:-}
SCREENRECORD_SIZE=${SCREENRECORD_SIZE:-720x1280}
SCREENRECORD_BITRATE=${SCREENRECORD_BITRATE:-6000000}
if [[ -n "${flag_w:-}" && -n "${flag_h:-}" ]]; then
  SCREENRECORD_SIZE="${flag_w}x${flag_h}"
elif [[ -n "${flag_w:-}" || -n "${flag_h:-}" ]]; then
  echo "error: --width 与 --height 须同时指定" >&2
  exit 1
fi

if [[ $# -ge 2 ]]; then
  HOST=$1
  PORT=$2
  RTCP_PORT=${3:-${INGEST_RTCP_PORT:-$PORT}}
elif [[ -n "${_url_port}" ]]; then
  HOST="${_url_host:-127.0.0.1}"
  PORT="${_url_port}"
  RTCP_PORT="${_url_rtcp:-${INGEST_RTCP_PORT:-$PORT}}"
else
  echo "error: 缺少位置参数 <host> <rtp_port> [rtcp_port]，且未提供 --url。见: $0 --help" >&2
  exit 1
fi

PT=${INGEST_PT:-96}
SSRC=${INGEST_SSRC:-111222333}
SCREENRECORD_TIME_LIMIT=${SCREENRECORD_TIME_LIMIT:-0}
# screenrecord 比特率有限，凑满默认 32MB 探测可能要数分钟，RTP 长期为 0；先小探测再解码更稳。
SCREENRECORD_PROBE_SIZE=${SCREENRECORD_PROBE_SIZE:-2097152}
SCREENRECORD_ANALYZE_US=${SCREENRECORD_ANALYZE_US:-2000000}
ADB_SCREENRECORD_STDERR=${ADB_SCREENRECORD_STDERR:-discard}
FFMPEG_LOGLEVEL=${FFMPEG_LOGLEVEL:-warning}

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

# 未指定序列号且仅一台 device 时自动选用（ECS+Redroid 常见）
if [[ -z "${ANDROID_SERIAL}" ]]; then
  _one=$("${ADB_BIN}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')
  _count=$("${ADB_BIN}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{c++} END{print c+0}')
  if [[ "${_count}" -eq 1 && -n "${_one}" ]]; then
    ANDROID_SERIAL="${_one}"
    ADB_FLAGS=(-s "${ANDROID_SERIAL}")
    echo "提示: 自动使用 ANDROID_SERIAL=${ANDROID_SERIAL}（多设备时请事先 export ANDROID_SERIAL）" >&2
  elif [[ "${_count}" -gt 1 ]]; then
    echo "error: 多台 adb device 且 c1-default-android-serial 未能自动选用（无 127.0.0.1:5555）。请 export ANDROID_SERIAL 或 C1_ADB_SERIAL。" >&2
    "${ADB_BIN}" devices >&2
    exit 1
  fi
fi

RECORD_CMD=(exec-out screenrecord --output-format=h264 --bit-rate="${SCREENRECORD_BITRATE}" --size="${SCREENRECORD_SIZE}")
if [[ "${SCREENRECORD_TIME_LIMIT}" != "0" ]]; then
  RECORD_CMD+=(--time-limit="${SCREENRECORD_TIME_LIMIT}")
fi
RECORD_CMD+=(-)

echo "ADB → FFmpeg → RTP：${ADB_BIN} ${ADB_FLAGS[*]} ${RECORD_CMD[*]}" >&2
echo "RTP 目标: ${RTP_URL}  PT=${PT} SSRC=${SSRC}" >&2
echo "FFmpeg 探测: probesize=${SCREENRECORD_PROBE_SIZE} analyzeduration=${SCREENRECORD_ANALYZE_US}us（可调 SCREENRECORD_PROBE_SIZE / SCREENRECORD_ANALYZE_US）" >&2

ADB_ERR_REDIRECT=/dev/null
if [[ "${ADB_SCREENRECORD_STDERR}" != "discard" ]]; then
  ADB_ERR_REDIRECT="${ADB_SCREENRECORD_STDERR}"
fi

# screenrecord 输出为 annex B 字节流；经 libx264 重编码为 baseline + repeat-headers，与 ingest/浏览器更稳。
# stderr 默认丢弃；排错: ADB_SCREENRECORD_STDERR=/dev/stderr
# 不用 exec：以便打印 adb/ffmpeg 退出码（exec 时 shell 已替换，无法记录）。
set -o pipefail
set +e
"${ADB_BIN}" "${ADB_FLAGS[@]}" "${RECORD_CMD[@]}" 2>"${ADB_ERR_REDIRECT}" | ffmpeg -hide_banner -loglevel "${FFMPEG_LOGLEVEL}" \
  -probesize "${SCREENRECORD_PROBE_SIZE}" -analyzeduration "${SCREENRECORD_ANALYZE_US}" \
  -thread_queue_size 1024 \
  -fflags +genpts+discardcorrupt+igndts \
  -use_wallclock_as_timestamps 1 \
  -f h264 -i - \
  -an \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 \
  -bf 0 -g 30 -keyint_min 30 \
  -force_key_frames "expr:eq(mod(n,30),0)" \
  -x264-params "repeat-headers=1:aud=1:bframes=0:min-keyint=1:keyint=30" \
  -payload_type "${PT}" -ssrc "${SSRC}" \
  -f rtp -pkt_size 1200 \
  "${RTP_URL}"
# Ctrl+C / 信号打断时 PIPESTATUS 元素可能少于 2；set -u 下须先复制到数组再取下标，勿直接写 ff_rc=${PIPESTATUS 的第二项}
_ps=("${PIPESTATUS[@]}")
adb_rc=-1
ff_rc=-1
if [[ "${#_ps[@]}" -ge 1 ]]; then adb_rc="${_ps[0]}"; fi
if [[ "${#_ps[@]}" -ge 2 ]]; then ff_rc="${_ps[1]}"; fi
if [[ "${ff_rc}" == "-1" ]]; then ff_rc="${adb_rc}"; fi
if [[ "${ff_rc}" == "-1" ]]; then ff_rc=255; fi
set -e
echo "$(date -Is) ingest 管道结束: adb_exit=${adb_rc} ffmpeg_exit=${ff_rc}（adb 先结束→FFmpeg 常因 stdin EOF 退出；adb 非 0→查设备连接/screenrecord；ffmpeg 非 0→开 FFMPEG_LOGLEVEL=info）" >&2
exit "${ff_rc}"
