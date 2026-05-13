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
#   UIAUTOMATOR_DUMP_XML        uiautomator dump 设备端路径（Redroid 上 /sdcard 常不可写，默认 /data/local/tmp/…）
#   LOG_DIALOG_DEBUG=1        超时退出前打印一次「uiautomator dump」原始输出（排障）
#   ADB_BIN                     默认 adb
set -u

ADB_BIN=${ADB_BIN:-adb}
WAIT_SEC=${LOG_DIALOG_WAIT_SEC:-15}
POLL_SEC=${LOG_DIALOG_POLL_SEC:-0.2}
FB_X=${LOG_DIALOG_FALLBACK_X:-360}
FB_Y=${LOG_DIALOG_FALLBACK_Y:-1042}
# Redroid：/sdcard 下 dump 可能失败；优先可写 tmp（可被 UIAUTOMATOR_DUMP_XML 覆盖）
REMOTE_XML="${UIAUTOMATOR_DUMP_XML:-/data/local/tmp/w_log_dialog_dump.xml}"
START_ZHANGTING=0

for arg in "$@"; do
  case "${arg}" in
    --start-zhangting) START_ZHANGTING=1 ;;
    -h|--help)
      sed -n '2,31p' "$0" | sed 's/^# \?//'
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

# 把设备上的 XML 拉到宿主机 _tmp；成功则文件非空且像 UI dump
_fetch_xml_from_device_path() {
  local p="$1"
  : >"${_tmp}"
  "${ADB_BIN}" "${ADB_FLAGS[@]}" exec-out shell cat "${p}" >"${_tmp}" 2>/dev/null || return 1
  [[ -s "${_tmp}" ]] || return 1
  head -c 240 "${_tmp}" | grep -q '<' || return 1
  return 0
}

_try_tap_from_dump() {
  local dump_out path
  "${ADB_BIN}" "${ADB_FLAGS[@]}" shell mkdir -p /data/local/tmp 2>/dev/null || true

  # 1) 显式路径（与 REMOTE_XML 一致）
  "${ADB_BIN}" "${ADB_FLAGS[@]}" shell uiautomator dump "${REMOTE_XML}" >/dev/null 2>&1 || true
  if _fetch_xml_from_device_path "${REMOTE_XML}"; then
    :
  else
    # 2) 无参 dump，从输出解析「dumped to: …xml」（各 ROM 文案略有差异）
    dump_out=$("${ADB_BIN}" "${ADB_FLAGS[@]}" shell uiautomator dump 2>&1) || dump_out=""
    path=$(
      echo "${dump_out}" | tr -d '\r' | sed -n 's/.*[Dd]umped to:[[:space:]]*\([^[:space:]]*\.xml\).*/\1/p' | tail -n 1
    )
    if [[ -z "${path}" ]]; then
      path=$(echo "${dump_out}" | tr -d '\r' | grep -oE '/[A-Za-z0-9_./-]+\.xml' | tail -n 1)
    fi
    if [[ -n "${path}" ]] && _fetch_xml_from_device_path "${path}"; then
      :
    else
      # 3) 常见默认文件名（先 dump 再 cat）
      "${ADB_BIN}" "${ADB_FLAGS[@]}" shell uiautomator dump >/dev/null 2>&1 || true
      if ! _fetch_xml_from_device_path /sdcard/window_dump.xml; then
        if ! _fetch_xml_from_device_path /storage/emulated/0/window_dump.xml; then
          return 1
        fi
      fi
    fi
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
if [[ "${LOG_DIALOG_DEBUG:-0}" == "1" ]]; then
  echo "$(date -Is) [adb-dismiss-log-dialog] LOG_DIALOG_DEBUG: uiautomator dump 输出如下 —" >&2
  "${ADB_BIN}" "${ADB_FLAGS[@]}" shell uiautomator dump 2>&1 | tail -n 8 >&2 || true
fi
exit 0
