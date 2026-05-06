#!/usr/bin/env bash
# 中国移动掌厅「应用云化」入口脚本 —— 对齐上游 ws-scrcpy（NetrisTV/ws-scrcpy）
# 仓库文档: docs/ws-scrcpy-10086-integration.md
#
# 用法（在 cloudPhone 项目根目录）:
#   bash scripts/cloud-10086.sh check        # 环境自检
#   bash scripts/cloud-10086.sh lab          # 打印推荐终端命令（双终端）
#   bash scripts/cloud-10086.sh launch-app   # 仅 adb 拉起官方掌厅
#   bash scripts/cloud-10086.sh stream-url   # 打印直连投屏 URL（ws-scrcpy 须已在运行）
#   bash scripts/cloud-10086.sh open         # 拉起掌厅 + 打开浏览器直连投屏页（等同 open-cloud-10086.sh）
#
# 常用环境变量: WS_SCRCPY_BASE  WS_SCRCPY_PORT  ANDROID_SERIAL  WS_SCRCPY_PLAYER  CM10086_VIEW_URL

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="${ROOT}/experiments/ws-scrcpy"
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

usage() {
  sed -n '2,15p' "$0"
}

PKG="com.greenpoint.android.mc10086.activity"
ACT="com.mc10086.cmcc.base.StartPageActivity"

resolve_udid() {
  if [ -n "${ANDROID_SERIAL:-}" ]; then
    echo "${ANDROID_SERIAL}"
    return
  fi
  adb devices 2>/dev/null | awk '/\tdevice$/{print $1; exit}'
}

cmd="${1:-}"
case "${cmd}" in
  check)
    echo "=== adb ==="
    adb devices -l || true
    echo ""
    UD="$(resolve_udid)"
    if [ -z "${UD}" ]; then
      echo "[check] 无 device，请先启动模拟器。"
      exit 1
    fi
    echo "=== PAGE_SIZE (expect 4096 for CM10086 + MMKV) ==="
    adb -s "${UD}" shell getconf PAGE_SIZE 2>/dev/null || true
    echo ""
    echo "=== ws-scrcpy ==="
    if [ ! -f "${LAB}/package.json" ]; then
      echo "[check] 缺少 ${LAB} ，请 clone NetrisTV/ws-scrcpy 并保留本仓库 Node/node-pty 补丁"
    else
      echo "[check] ${LAB} 存在"
      grep -q '"node-pty": "^1.1.0"' "${LAB}/package.json" 2>/dev/null && echo "[check] node-pty 已为 1.x（Node 24 兼容）" || echo "[check] 警告: 检查 package.json 中 node-pty 版本"
      [ -d "${LAB}/node_modules" ] && echo "[check] node_modules 已安装" || echo "[check] 首次请运行: bash scripts/run-cloud-app-lab.sh"
    fi
    echo ""
    echo "=== 端口 8000 ==="
    if command -v lsof >/dev/null 2>&1; then
      lsof -iTCP:8000 -sTCP:LISTEN 2>/dev/null || echo "[check] 8000 未监听（尚未启动 ws-scrcpy）"
    fi
    ;;
  lab)
    LAN="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<局域网IP>')"
    echo "终端 A — 启动 ws-scrcpy:"
    echo "  cd \"${ROOT}\" && bash scripts/run-cloud-app-lab.sh"
    echo ""
    echo "浏览器 — 设备列表:"
    echo "  http://127.0.0.1:8000/"
    echo "  http://${LAN}:8000/   （同网手机）"
    echo ""
    echo "直连投屏 URL（需先把模拟器上掌厅打开；可复制发给浏览器）:"
    echo "  cd \"${ROOT}\" && bash scripts/cloud-10086.sh stream-url"
    echo ""
    echo "终端 B — 外网穿透（可选）:"
    echo "  cd \"${ROOT}\" && bash scripts/step1-public-tunnel.sh"
    echo ""
    echo "一键掌厅 + 打开直连页:"
    echo "  cd \"${ROOT}\" && bash scripts/cloud-10086.sh open"
    ;;
  launch-app)
    UD="$(resolve_udid)"
    [ -n "${UD}" ] || { echo "[launch-app] 无 device"; exit 1; }
    echo "[launch-app] ${PKG}"
    adb -s "${UD}" shell am start -n "${PKG}/${ACT}" 2>/dev/null \
      || adb -s "${UD}" shell monkey -p "${PKG}" -c android.intent.category.LAUNCHER 1
    ;;
  stream-url)
    bash "${SCRIPT_DIR}/ws-scrcpy-stream-url.sh"
    ;;
  open)
    bash "${SCRIPT_DIR}/open-cloud-10086.sh"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "未知子命令: ${cmd}"
    usage
    exit 1
    ;;
esac
