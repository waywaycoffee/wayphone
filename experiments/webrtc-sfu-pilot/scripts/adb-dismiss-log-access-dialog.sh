#!/usr/bin/env bash
# 等待并点击系统「允许访问设备日志」对话框里的「Allow one-time access」。
# 通过 uiautomator dump 解析 android:id/log_access_dialog_allow_button 的 bounds，
# 计算中心点后 adb shell input tap；解析失败时可用环境变量回退坐标。
#
# 用法（在 experiments/webrtc-sfu-pilot 目录，或多设备时先 export ANDROID_SERIAL）:
#   bash scripts/adb-dismiss-log-access-dialog.sh                    # 仅等待弹窗（你已自行 am start）
#   bash scripts/adb-dismiss-log-access-dialog.sh --start-zhangting # 先启动掌厅再等待弹窗并点允许
#   LOG_DIALOG_WAIT_SEC=20 bash scripts/adb-dismiss-log-access-dialog.sh
#
# 环境变量:
#   ANDROID_SERIAL              多设备时可不设（自动 127.0.0.1:5555）；改选见 C1_ADB_SERIAL
#   LOG_DIALOG_WAIT_SEC         最长等待秒数，默认 15
#   LOG_DIALOG_POLL_SEC         轮询间隔，默认 0.2
#   LOG_DIALOG_FALLBACK_X/Y     解析失败时回退 tap（默认 360/1042，对应 720x1280 实测）
#   ADB_BIN                     默认 adb
set -u

ADB_BIN=${ADB_BIN:-adb}
WAIT_SEC=${LOG_DIALOG_WAIT_SEC:-15}
POLL_SEC=${LOG_DIALOG_POLL_SEC:-0.2}
FB_X=${LOG_DIALOG_FALLBACK_X:-360}
FB_Y=${LOG_DIALOG_FALLBACK_Y:-1042}
REMOTE_XML=/sdcard/w_log_dialog_dump.xml
START_ZHANGTING=0

for arg in "$@"; do
  case "${arg}" in
    --start-zhangting) START_ZHANGTING=1 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
_def=$(bash "${REPO_DIR}/scripts/c1-default-android-serial.sh") || exit 1
eval "${_def}"

ADB_FLAGS=()
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  ADB_FLAGS+=(-s "${ANDROID_SERIAL}")
fi

if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit(f?0:1)}'; then
  echo "error: 无处于 device 状态的 adb。请 adb connect / 设置 ANDROID_SERIAL。" >&2
  "${ADB_BIN}" "${ADB_FLAGS[@]}" devices >&2
  exit 1
fi

_tmp=$(mktemp /tmp/w_log_dialog.XXXXXX.xml)
cleanup() { rm -f "${_tmp}"; }
trap cleanup EXIT

_parse_bounds_center() {
  # 输入一行含 bounds="[x1,y1][x2,y2]" 的 XML，输出 cx cy
  local line="$1"
  local b inner x1 y1 x2 y2 cx cy
  b=$(echo "${line}" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1) || return 1
  inner=${b#bounds=\"}
  inner=${inner%\"}
  inner=${inner//\]\[/ }
  inner=${inner//[\[\]]/}
  inner=${inner//,/ }
  read -r x1 y1 x2 y2 <<< "${inner}" || return 1
  cx=$(( (x1 + x2) / 2 ))
  cy=$(( (y1 + y2) / 2 ))
  echo "${cx} ${cy}"
}

_try_tap_from_dump() {
  if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" shell uiautomator dump "${REMOTE_XML}" 2>/dev/null; then
    return 1
  fi
  if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" pull "${REMOTE_XML}" "${_tmp}" 2>/dev/null; then
    return 1
  fi
  if ! grep -q 'log_access_dialog_allow_button' "${_tmp}"; then
    return 1
  fi
  local line cx cy
  line=$(grep 'log_access_dialog_allow_button' "${_tmp}" | head -1)
  if ! read -r cx cy <<< "$(_parse_bounds_center "${line}")"; then
    echo "提示: 解析 bounds 失败，使用回退坐标 (${FB_X},${FB_Y})" >&2
    cx=${FB_X}
    cy=${FB_Y}
  fi
  echo "$(date -Is) [adb-dismiss-log-dialog] 发现 log_access_dialog_allow_button，点击 (${cx},${cy})" >&2
  "${ADB_BIN}" "${ADB_FLAGS[@]}" shell input tap "${cx}" "${cy}"
  return 0
}

if [[ "${START_ZHANGTING}" == "1" ]]; then
  echo "$(date -Is) [adb-dismiss-log-dialog] 启动掌厅 StartPageActivity…" >&2
  "${ADB_BIN}" "${ADB_FLAGS[@]}" shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity >&2 || true
fi

_end=$(awk -v w="${WAIT_SEC}" 'BEGIN{print systime()+w}')
while [[ "$(date +%s)" -lt "${_end}" ]]; do
  if _try_tap_from_dump; then
    echo "$(date -Is) [adb-dismiss-log-dialog] 已点击「Allow one-time access」" >&2
    exit 0
  fi
  sleep "${POLL_SEC}"
done

echo "$(date -Is) [adb-dismiss-log-dialog] 在 ${WAIT_SEC}s 内未发现日志访问授权框（若应用未请求则属正常）" >&2
exit 0
