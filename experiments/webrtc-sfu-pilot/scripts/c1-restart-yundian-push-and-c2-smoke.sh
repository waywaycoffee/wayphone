#!/usr/bin/env bash
# 停彩条/旧 ffmpeg → 掌厅深链打开「移动云盘」H5（可改 URL）→ 后台 ADB ingest 循环 → 本机 C2 smoke。
# 在 experiments/webrtc-sfu-pilot 目录执行（ECS 宿主机，与 docker / adb 同机）:
#   bash scripts/c1-restart-yundian-push-and-c2-smoke.sh
# 指定云盘/其它 H5（须与掌厅内可打开的链接一致；整段会作 url= 编码）:
#   ZHANGTING_YUNDIAN_H5_URL='https://yun.139.com/w/#/client' bash scripts/c1-restart-yundian-push-and-c2-smoke.sh
# 仍走启动页（排查深链失败时）:  ZHANGTING_OPEN_MODE=startpage bash scripts/c1-restart-yundian-push-and-c2-smoke.sh
# 仅停流、不启 ingest:  C1_SKIP_PUSH=1 bash scripts/c1-restart-yundian-push-and-c2-smoke.sh
# 前台单段 ingest（Ctrl+C 停；本脚本不会继续跑 c2）:  C1_PUSH_FOREGROUND=1 bash scripts/c1-restart-yundian-push-and-c2-smoke.sh
# 先起本目录 pilot（与 C2 curl 同机）:  PILOT_UP=1 bash scripts/c1-restart-yundian-push-and-c2-smoke.sh
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

if [[ "${PILOT_UP:-0}" == "1" ]]; then
  echo "$(date -Is) [yundian+c2] ⓪ PILOT_UP=1 → docker compose up -d（webrtc-sfu-pilot）…" >&2
  docker compose up -d
  echo "$(date -Is) [yundian+c2]    等待 pilot 监听 5s…" >&2
  sleep 5
fi

echo "$(date -Is) [yundian+c2] ① stop 旧 ingest（含彩条）…" >&2
bash "${REPO_DIR}/scripts/c1-ingest-safe.sh" stop

_def_out=$(bash "${REPO_DIR}/scripts/c1-default-android-serial.sh" 2>/dev/null) || true
if [[ -n "${_def_out}" ]]; then
  eval "${_def_out}"
fi
S="${ANDROID_SERIAL:-127.0.0.1:5555}"
ADB_BIN="${ADB_BIN:-adb}"
# 深链形态见 docs/redroid-notes.md「云化 / H5 深链」；url= 后须整段 URL 编码。
ZHANGTING_YUNDIAN_H5_URL="${ZHANGTING_YUNDIAN_H5_URL:-https://yun.139.com/}"
ZHANGTING_OPEN_MODE="${ZHANGTING_OPEN_MODE:-yundian}" # yundian | startpage

_open_zhangting_yundian() {
  if [[ "${ZHANGTING_OPEN_MODE}" == "startpage" ]]; then
    echo "$(date -Is) [yundian+c2] ② adb 掌厅 StartPageActivity（ZHANGTING_OPEN_MODE=startpage）…" >&2
    "${ADB_BIN}" -s "${S}" shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity >/dev/null 2>&1 || true
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "$(date -Is) [yundian+c2] warn: 无 python3，无法编码深链；改用 StartPageActivity。" >&2
    "${ADB_BIN}" -s "${S}" shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity >/dev/null 2>&1 || true
    return 0
  fi
  local enc data
  enc=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${ZHANGTING_YUNDIAN_H5_URL}") || enc=""
  if [[ -z "${enc}" ]]; then
    echo "$(date -Is) [yundian+c2] warn: URL 编码失败；改用 StartPageActivity。" >&2
    "${ADB_BIN}" -s "${S}" shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity >/dev/null 2>&1 || true
    return 0
  fi
  data="com.greenpoint://android.mc10086.activity?url=${enc}"
  echo "$(date -Is) [yundian+c2] ② adb 掌厅深链 → 云盘 H5（ZHANGTING_YUNDIAN_H5_URL 未编码原文）…" >&2
  if ! "${ADB_BIN}" -s "${S}" shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.view.mine.html5.SchemeDispatchActivity \
    -a android.intent.action.VIEW -d "${data}" >/dev/null 2>&1; then
    echo "$(date -Is) [yundian+c2] warn: SchemeDispatchActivity 失败，回退 StartPageActivity（请手点云盘）。" >&2
    "${ADB_BIN}" -s "${S}" shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity >/dev/null 2>&1 || true
  fi
  return 0
}

echo "$(date -Is) [yundian+c2] ② adb 打开移动云盘（掌厅 WebView；失败则回退启动页）…" >&2
"${ADB_BIN}" connect "${S}" 2>/dev/null || true
_open_zhangting_yundian || true

if [[ "${C1_SKIP_PUSH:-0}" == "1" ]]; then
  echo "$(date -Is) [yundian+c2] 跳过 ingest（C1_SKIP_PUSH=1）" >&2
else
  export C1_INGEST_SOURCE=adb
  export MEDIASOUP_INGEST_CODEC="${MEDIASOUP_INGEST_CODEC:-h264}"
  if [[ "${C1_PUSH_FOREGROUND:-0}" == "1" ]]; then
    echo "$(date -Is) [yundian+c2] ③ 前台 ADB ingest；结束后请另开终端: bash scripts/c2-smoke.sh" >&2
    exec bash "${REPO_DIR}/scripts/c1-ingest-safe.sh" adb
  fi
  echo "$(date -Is) [yundian+c2] ③ 后台 ADB ingest 循环 → /tmp/c1-adb-loop.log" >&2
  nohup bash "${REPO_DIR}/scripts/run-c1-ingest-adb-loop.sh" >>/tmp/c1-adb-loop.log 2>&1 &
  echo "$(date -Is) [yundian+c2]    PID=$!  查看: tail -f /tmp/c1-adb-loop.log" >&2
  sleep 5
fi

if [[ -f "${REPO_DIR}/.env" ]] && grep -qE '^[[:space:]]*PILOT_C2_ENABLED[[:space:]]*=[[:space:]]*1([[:space:]]|$)' "${REPO_DIR}/.env" 2>/dev/null; then
  :
else
  echo "$(date -Is) [yundian+c2] WARN: 本目录 .env 未见 PILOT_C2_ENABLED=1，/api/c2/* 可能 403/不可用；参考 .env.pilot.example 后 docker compose up -d --force-recreate" >&2
fi

echo "$(date -Is) [yundian+c2] ④ C2 smoke（须 pilot 已起；Redroid 在仓库根 compose）…" >&2
bash "${REPO_DIR}/scripts/c2-smoke.sh"
