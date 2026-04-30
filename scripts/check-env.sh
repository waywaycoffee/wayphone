#!/usr/bin/env bash
# 在 ECS 上检查：Docker、KVM 是否适合跑 docker-android
set -euo pipefail

echo "=== OS ==="
uname -a
echo

echo "=== Docker ==="
if command -v docker >/dev/null 2>&1; then
  docker --version
else
  echo "未安装 Docker。Ubuntu 可参考: https://docs.docker.com/engine/install/ubuntu/"
  exit 1
fi
echo

echo "=== 虚拟化标志 (仅参考，云机未必给嵌套 KVM) ==="
if grep -q -E 'vmx|svm' /proc/cpuinfo 2>/dev/null; then
  head -1 /proc/cpuinfo | cut -c1-120; echo "...(有 vmx/svm 标志)"
else
  echo "cpuinfo 中未看到常见 vmx/svm（仍可能有厂商虚拟化，以 /dev/kvm 为准）"
fi
echo

echo "=== /dev/kvm ==="
if [ -c /dev/kvm ]; then
  ls -la /dev/kvm
  echo "结论: 可尝试 budtmo/docker-android（见 docker-compose.emulator.yml + docker compose -f ）"
else
  echo "无 /dev/kvm — 典型云 ECS 上很常见。"
  echo "结论: 请用默认的 Redroid（ docker compose up -d ）"
fi
echo

if command -v kvm-ok >/dev/null 2>&1; then
  echo "=== kvm-ok ==="
  kvm-ok 2>&1 || true
fi
