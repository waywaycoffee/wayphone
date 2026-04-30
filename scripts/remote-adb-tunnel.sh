#!/usr/bin/env bash
# 在你自己的电脑上运行（把 ECS 上 5555 转到本机）
# 用法: ./remote-adb-tunnel.sh 用户@ECS公网或弹性IP
#
# 另开终端: adb connect 127.0.0.1:5555
# 再使用 scrcpy 等（需本机已安装 scrcpy）

set -euo pipefail
if [ "${1:-}" = "" ]; then
  echo "用法: $0 user@你的ECS公网"
  exit 1
fi
echo "将 ECS 的 127.0.0.1:5555 转发到本机 5555。保持此窗口不关闭，另开终端执行: adb connect 127.0.0.1:5555"
exec ssh -N -L 5555:127.0.0.1:5555 "$1"
