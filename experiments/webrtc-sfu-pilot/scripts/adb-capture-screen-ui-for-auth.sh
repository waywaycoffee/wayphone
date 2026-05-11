#!/usr/bin/env bash
# 截图 + uiautomator 层次 XML 落盘，便于拉回本机对照「是否卡在授权/权限框」与模拟点击坐标。
# 在 experiments/webrtc-sfu-pilot 或仓库根 npm run adb:capture-auth-debug
#
# 用法:
#   npm run adb:capture-auth-debug
#   OUT_DIR=/var/tmp/zhangting-debug bash scripts/adb-capture-screen-ui-for-auth.sh
#
# 拉回 Mac：脚本默认打印 root@8.163.51.24（本仓库 PoC ECS）；其它主机: AUTH_DEBUG_SCP_HOST=x.x.x.x
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"
_def=$(bash "${REPO_DIR}/scripts/c1-default-android-serial.sh") || exit 1
eval "${_def}"

ADB_BIN=${ADB_BIN:-adb}
SCP_HOST=${AUTH_DEBUG_SCP_HOST:-8.163.51.24}
OUT_DIR=${OUT_DIR:-/tmp/wayphone-auth-capture}
TS=$(date +%Y%m%d_%H%M%S)
STEM="zhangting-auth-${TS}"

ADB_FLAGS=()
[[ -n "${ANDROID_SERIAL:-}" ]] && ADB_FLAGS+=(-s "${ANDROID_SERIAL}")

mkdir -p "${OUT_DIR}"
PNG="${OUT_DIR}/${STEM}.png"
XML="${OUT_DIR}/${STEM}_uiautomator.xml"
HINT="${OUT_DIR}/${STEM}_grep-hints.txt"

if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit(f?0:1)}'; then
  echo "error: 无 adb device。请先 adb connect。" >&2
  exit 1
fi

echo "$(date -Is) screencap → ${PNG}" >&2
if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" exec-out screencap -p >"${PNG}"; then
  echo "error: screencap 失败" >&2
  exit 1
fi

REMOTE_XML="/sdcard/${STEM}.xml"
echo "$(date -Is) uiautomator dump → ${XML}" >&2
"${ADB_BIN}" "${ADB_FLAGS[@]}" shell uiautomator dump "${REMOTE_XML}" 2>/dev/null || true
if ! "${ADB_BIN}" "${ADB_FLAGS[@]}" pull "${REMOTE_XML}" "${XML}" 2>/dev/null; then
  echo "warn: uiautomator dump/pull 失败（部分 ROM 无 uiautomator）；仅保留截图 ${PNG}" >&2
  XML=""
else
  "${ADB_BIN}" "${ADB_FLAGS[@]}" shell rm -f "${REMOTE_XML}" 2>/dev/null || true
fi

if [[ -n "${XML}" && -f "${XML}" ]]; then
  {
    echo "=== grep 提示（在 ${STEM}_uiautomator.xml 内人工搜）==="
    grep -E 'log_access_dialog|permission|Permission|alert|Alert|允许|拒绝|Allow|Deny' "${XML}" 2>/dev/null | head -40 || true
  } >"${HINT}"
fi

echo "" >&2
echo "──────── 已生成（在 ECS 上）────────" >&2
echo "  PNG: ${PNG}"
[[ -n "${XML}" && -f "${XML}" ]] && echo "  XML: ${XML}" && echo "  摘要: ${HINT}"
echo "" >&2
echo "拉回本机对照（PoC ECS ${SCP_HOST}；改主机: AUTH_DEBUG_SCP_HOST=… 再跑；密钥路径按本机）:" >&2
echo "  scp -i ~/.ssh/miyao.pem root@${SCP_HOST}:${PNG} ~/Downloads/" >&2
[[ -n "${XML}" && -f "${XML}" ]] && echo "  scp -i ~/.ssh/miyao.pem root@${SCP_HOST}:${XML} ~/Downloads/" >&2
echo "" >&2
echo "对照实验建议:" >&2
echo "  1) 冷启掌厅后立即本脚本 → 看图/XML 是否已有系统授权框" >&2
echo "  2) 再 npm run adb:start-zhangting-dismiss-log-dialog → 再跑本脚本 → 是否消失" >&2
echo "  3) 若 rtpBytesReceived 仍冻结，与「无弹窗但 screenrecord 早停」并列看 ADB_SCREENRECORD_STDERR" >&2
