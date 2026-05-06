#!/usr/bin/env bash
# Mac 上一键：先拉起中国移动掌厅，再打开浏览器进入 ws-scrcpy 直连投屏（像「点开就是云应用」）
#
# 说明：
# - 必须在「本机」执行：会调 adb + 打开本机浏览器。手机用户只点链接时，无法替你执行本机 adb。
# - 掌厅官方「云化 / 活动页」深度链接示例（scheme + host 对应包名 com.greenpoint.android.mc10086.activity）:
#     com.greenpoint://android.mc10086.activity?url=https%3A%2F%2Fwx.10086.cn%2F...
#   模拟器里可: adb shell am start -a android.intent.action.VIEW -d '整条URI' -p com.greenpoint.android.mc10086.activity
#   也可设环境变量 CM10086_VIEW_URL 为本脚本在拉起掌厅后追加打开（见脚本内）。
#
# 用法：
#   bash scripts/open-cloud-10086.sh
#   WS_SCRCPY_BASE=http://192.168.212.72:8000 bash scripts/open-cloud-10086.sh   # 与浏览器访问主机一致
#   bash scripts/open-cloud-10086.sh --print-only    # 只打印直连 URL，不打开浏览器
#
# 依赖：PATH 上有 adb；本机 ws-scrcpy 已在跑（默认端口 8000）；模拟器已连接。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

PRINT_ONLY=0
while [ "${1:-}" != "" ]; do
  case "$1" in
    --print-only|-p) PRINT_ONLY=1; shift ;;
    --help|-h)
      sed -n '1,25p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $1  （支持: --print-only）"
      exit 1
      ;;
  esac
done

PKG="com.greenpoint.android.mc10086.activity"
ACT="com.mc10086.cmcc.base.StartPageActivity"
PORT="${WS_SCRCPY_PORT:-8000}"
# 浏览器访问用的「页面主机」，需与 ws 里一致；本机默认 127.0.0.1
BASE="${WS_SCRCPY_BASE:-http://127.0.0.1:${PORT}}"
UDID="${ANDROID_SERIAL:-}"
if [ -z "${UDID}" ]; then
  UDID="$(adb devices | awk '/\tdevice$/{print $1; exit}')"
fi
if [ -z "${UDID}" ]; then
  echo "[open-cloud-10086] 未检测到 device 状态的 adb 设备，请先启动模拟器。"
  exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "[open-cloud-10086] 未找到 adb"
  exit 1
fi

echo "[open-cloud-10086] 启动掌厅 (${PKG}) …"
adb -s "${UDID}" shell am start -n "${PKG}/${ACT}" >/dev/null 2>&1 \
  || adb -s "${UDID}" shell monkey -p "${PKG}" -c android.intent.category.LAUNCHER 1

# 可选：若你已知掌厅内某页的 intent / https scheme，可设置后直达（多数页需自己逆向/抓链接）
if [ -n "${CM10086_VIEW_URL:-}" ]; then
  echo "[open-cloud-10086] 尝试用 VIEW 打开: ${CM10086_VIEW_URL}"
  adb -s "${UDID}" shell am start -a android.intent.action.VIEW -d "${CM10086_VIEW_URL}" -p "${PKG}" 2>/dev/null || true
fi

sleep "${CM10086_LAUNCH_WAIT:-2}"

STREAM_URL="$(bash "${SCRIPT_DIR}/ws-scrcpy-stream-url.sh" "${BASE}" "${UDID}")"

if [ "${PRINT_ONLY}" = 1 ]; then
  echo "${STREAM_URL}"
  exit 0
fi

if ! command -v open >/dev/null 2>&1; then
  echo "${STREAM_URL}"
  echo "[open-cloud-10086] 非 macOS 或无 open 命令，请手动复制上方 URL 到浏览器"
  exit 0
fi

echo "[open-cloud-10086] 打开直连投屏页 …"
open "${STREAM_URL}"
