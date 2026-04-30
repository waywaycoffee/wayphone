#!/usr/bin/env bash
# ECS 上一键：拉镜像并启动（默认 DEPLOY_MODE=auto，见 .env.example）
# 用法（在项目根目录）:
#   bash scripts/deploy-ecs.sh
#   DEPLOY_MODE=redroid bash scripts/deploy-ecs.sh
#   DEPLOY_MODE=emulator bash scripts/deploy-ecs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if [ -f ".env" ]; then
  # shellcheck disable=SC1091
  set -a && source ".env" && set +a
fi

DEPLOY_MODE="${DEPLOY_MODE:-auto}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[deploy] 未找到 docker。请先安装:"
  echo "        sudo bash scripts/install-docker-ubuntu.sh"
  echo "        再将当前用户加入 docker 组并重新登录。"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[deploy] 无法连接 Docker daemon。请确认:"
  echo "        - 当前用户已在 docker 组内并已重新登录，或临时使用: sudo $0"
  exit 1
fi

if [ ! -f ".env" ] && [ -f ".env.example" ]; then
  echo "[deploy] 提示: 可选复制配置  cp .env.example .env"
fi

deploy_redroid() {
  echo "[deploy] 启动 Redroid（无 KVM 的 ECS 默认路径）..."
  docker compose pull
  docker compose up -d
  echo ""
  docker compose ps
  echo ""
  echo "本机验证 ADB（仅在 ECS 上自测）:"
  echo "  sudo apt-get install -y android-tools-adb   # 可选"
  echo "  adb connect 127.0.0.1:${REDROID_HOST_PORT:-5555}"
  echo ""
  echo "从你电脑经 SSH 隧道连接（勿对公网开放 5555）:"
  echo "  ssh -N -L ${REDROID_HOST_PORT:-5555}:127.0.0.1:${REDROID_HOST_PORT:-5555} user@ECS"
  echo "  adb connect 127.0.0.1:${REDROID_HOST_PORT:-5555}"
}

deploy_emulator() {
  if [ ! -c /dev/kvm ]; then
    echo "[deploy] 宿主机无 /dev/kvm，无法部署 budtmo/docker-android。"
    echo "        请使用: DEPLOY_MODE=redroid bash scripts/deploy-ecs.sh"
    exit 1
  fi
  echo "[deploy] 启动 docker-android（需 KVM）..."
  docker compose -f docker-compose.emulator.yml pull
  docker compose -f docker-compose.emulator.yml up -d
  echo ""
  docker compose -f docker-compose.emulator.yml ps
  echo ""
  echo "浏览器仅通过本机 SSH 隧道访问（勿对公网开放 6080）:"
  echo "  ssh -N -L ${EMULATOR_WEB_PORT:-6080}:127.0.0.1:${EMULATOR_WEB_PORT:-6080} user@ECS"
  echo "  打开 http://127.0.0.1:${EMULATOR_WEB_PORT:-6080}"
}

case "${DEPLOY_MODE}" in
  redroid)
    deploy_redroid
    ;;
  emulator)
    deploy_emulator
    ;;
  auto)
    if [ -c /dev/kvm ]; then
      echo "[deploy] auto: 检测到 /dev/kvm → 使用 docker-android"
      deploy_emulator
    else
      echo "[deploy] auto: 未检测到 /dev/kvm → 使用 Redroid"
      deploy_redroid
    fi
    ;;
  *)
    echo "无效的 DEPLOY_MODE=${DEPLOY_MODE}，请使用 auto | redroid | emulator"
    exit 1
    ;;
esac
