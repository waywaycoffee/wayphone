#!/usr/bin/env bash
# 第 5 步（新 ARM ECS）：clone 后拉最新代码并安装 Binder fstab + systemd。
# 用法（在仓库根、root）:
#   sudo bash scripts/bootstrap-arm-ecs-binder-persistence.sh
# 或指定路径:
#   sudo WAYPHONE_ROOT=/root/wayphone bash scripts/bootstrap-arm-ecs-binder-persistence.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行。" >&2
  exit 1
fi

ROOT="${WAYPHONE_ROOT:-}"
if [[ -z "${ROOT}" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if [[ ! -d "${ROOT}/.git" ]] || [[ ! -f "${ROOT}/scripts/install-wayphone-binder-persistence.sh" ]]; then
  echo "error: WAYPHONE_ROOT 无效或不是本仓库: ${ROOT}" >&2
  echo "  请先: git clone https://github.com/waywaycoffee/wayphone.git /opt/wayphone" >&2
  echo "  再:   cd /opt/wayphone && sudo WAYPHONE_ROOT=/opt/wayphone bash scripts/bootstrap-arm-ecs-binder-persistence.sh" >&2
  exit 1
fi

cd "${ROOT}"
export WAYPHONE_ROOT="${ROOT}"
git pull --ff-only origin main || git pull --ff-only

bash "${ROOT}/scripts/install-wayphone-binder-persistence.sh"

echo ""
echo "下一步: cd ${ROOT} && docker compose up -d   # Redroid"
echo "        cd ${ROOT}/experiments/webrtc-sfu-pilot && 配置 .env 后 docker compose up -d"
