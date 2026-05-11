#!/usr/bin/env bash
# 多设备且未设置 ANDROID_SERIAL 时，自动选用 Redroid 常见序列号或 C1_ADB_SERIAL。
# 用法（在 bash 子脚本开头，于首次使用 adb 前）:
#   eval "$(bash "$(dirname "$0")/c1-default-android-serial.sh")"
# 已设置 ANDROID_SERIAL 时无输出且 exit 0；仅 1 台 device 时无输出且 exit 0。
# 覆盖自动选择: export ANDROID_SERIAL=…  或  export C1_ADB_SERIAL=emulator-5554（须在列表中）
set -euo pipefail
ADB_BIN=${ADB_BIN:-adb}

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  exit 0
fi

_serials=()
while IFS= read -r _s; do
  [[ -n "${_s}" ]] && _serials+=("${_s}")
done < <("${ADB_BIN}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')

_n="${#_serials[@]}"
if [[ "${_n}" -le 1 ]]; then
  exit 0
fi

_pick=""
if [[ -n "${C1_ADB_SERIAL:-}" ]]; then
  for _c in "${_serials[@]}"; do
    if [[ "${_c}" == "${C1_ADB_SERIAL}" ]]; then
      _pick="${C1_ADB_SERIAL}"
      break
    fi
  done
fi
if [[ -z "${_pick}" ]]; then
  for _c in "${_serials[@]}"; do
    if [[ "${_c}" == "127.0.0.1:5555" ]]; then
      _pick="${_c}"
      break
    fi
  done
fi

if [[ -n "${_pick}" ]]; then
  printf 'export ANDROID_SERIAL=%q\n' "${_pick}"
  echo "c1-default-android-serial: 多台 device（${_n}），已自动选用 ANDROID_SERIAL=${_pick}（改选: export ANDROID_SERIAL=… 或 C1_ADB_SERIAL）" >&2
  exit 0
fi

echo "error: 多台 adb device（${_n}），且未设置 ANDROID_SERIAL；列表中无 127.0.0.1:5555。请任选其一:" >&2
echo "  export ANDROID_SERIAL=<序列号>" >&2
echo "  export C1_ADB_SERIAL=<序列号>   # 须在 adb devices 的 device 列表中" >&2
"${ADB_BIN}" devices >&2
exit 1
