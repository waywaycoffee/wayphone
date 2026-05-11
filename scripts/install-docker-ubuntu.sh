#!/usr/bin/env bash
# 在 Ubuntu 20.04/22.04/24.04 ECS 上一键安装 Docker Engine + Compose 插件（官方仓库）
# x86_64 / ARM64 通用：`deb [arch=$(dpkg --print-architecture) …]` 自动选对本机架构，勿用他架构 .deb。
# 用法: sudo bash scripts/install-docker-ubuntu.sh

set -euo pipefail

if [ "${EUID:-0}" -ne 0 ]; then
  echo "请使用 root 或 sudo 运行本脚本。"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo ""
echo "Docker 已安装:"
docker --version
docker compose version
echo ""
echo "请将 SSH 登录用户加入 docker 组（替换 YOUR_USER）:"
echo "  usermod -aG docker YOUR_USER"
echo "然后该用户重新登录 SSH，再执行一键部署脚本（不要用 sudo docker compose）。"
