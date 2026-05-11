#!/usr/bin/env bash
# 为子脚本导出 ANDROID_SERIAL。PoC Redroid 在 127.0.0.1:5555；宿主机常残留 emulator-5554，
# 故只要 Redroid 在线，默认固定到 127.0.0.1:5555（显式等价于 adb -s 127.0.0.1:5555）。
# 用法: eval "$(bash "$(dirname "$0")/c1-default-android-serial.sh")"
# 已设置 ANDROID_SERIAL 时无输出且 exit 0。
# 改选其它设备: export C1_ADB_SERIAL=emulator-5554（须在 adb devices 的 device 列表中）
set -euo pipefail
ADB_BIN=${ADB_BIN:-adb}
REDROID_SERIAL="${REDROID_ADB_SERIAL:-127.0.0.1:5555}"

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  exit 0
fi

_serials=()
while IFS= read -r _s; do
  [[ -n "${_s}" ]] && _serials+=("${_s}")
done < <("${ADB_BIN}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')

_n="${#_serials[@]}"

if [[ -n "${C1_ADB_SERIAL:-}" ]]; then
  _pick=""
  for _c in "${_serials[@]}"; do
    if [[ "${_c}" == "${C1_ADB_SERIAL}" ]]; then
      _pick="${C1_ADB_SERIAL}"
      break
    fi
  done
  if [[ -n "${_pick}" ]]; then
    printf 'export ANDROID_SERIAL=%q\n' "${_pick}"
    echo "c1-default-android-serial: 已按 C1_ADB_SERIAL 选用 ANDROID_SERIAL=${_pick}" >&2
    exit 0
  fi
fi

for _c in "${_serials[@]}"; do
  if [[ "${_c}" == "${REDROID_SERIAL}" ]]; then
    printf 'export ANDROID_SERIAL=%q\n' "${REDROID_SERIAL}"
    if [[ "${_n}" -gt 1 ]]; then
      echo "c1-default-android-serial: 多台 device（${_n}），已固定 ANDROID_SERIAL=${REDROID_SERIAL}（Redroid）。改选: export C1_ADB_SERIAL=… 或 ANDROID_SERIAL=…" >&2
    else
      echo "c1-default-android-serial: 已固定 ANDROID_SERIAL=${REDROID_SERIAL}（与 adb -s 等价）。" >&2
    fi
    exit 0
  fi
done

exit 0
