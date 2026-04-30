#!/usr/bin/env bash
# 在阿里云 ECS / Ubuntu 上检查是否满足 budtmo/docker-android 的 KVM 前提
# 参考: https://github.com/budtmo/docker-android#quick-start
# 用法: bash scripts/check-kvm-docker-android.sh
set -u

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

echo "========== 1) 系统与架构 =========="
uname -a
echo "架构: $(dpkg --print-architecture 2>/dev/null || echo "未知")"
echo

echo "========== 2) CPU 虚拟化相关标志 (Intel vmx / AMD svm) =========="
if grep -E -m1 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1; then
  echo -e "${GRN}在 cpuinfo 中能看到 vmx 或 svm 之一。${NC}"
  grep -E 'vmx|svm' /proc/cpuinfo | head -1
else
  echo -e "${YEL}未在 cpuinfo 中看到 vmx/svm。云虚机里常见，最终以 /dev/kvm 与 kvm-ok 为准。${NC}"
fi
echo

echo "========== 3) KVM 内核模块是否加载 =========="
if command -v lsmod >/dev/null 2>&1; then
  if lsmod | grep -E '^kvm' ; then
    echo -e "${GRN}已加载 kvm 相关模块。${NC}"
  else
    echo -e "${YEL}未看到 kvm 模块（可能未加载或内核未带 kvm）。${NC}"
  fi
else
  echo "lsmod 不可用，跳过"
fi
echo

echo "========== 4) 设备节点 /dev/kvm（docker-android 必需）=========="
if [ -c /dev/kvm ]; then
  ls -la /dev/kvm
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    echo -e "${GRN}当前用户可读可写 /dev/kvm。${NC}"
  else
    echo -e "${YEL}当前用户可能对 /dev/kvm 无权限。可尝试: sudo usermod -aG kvm \"\$USER\" 后重新登录。${NC}"
  fi
else
  echo -e "${RED}无 /dev/kvm — 多数普通云 ECS 未开放嵌套虚拟化，docker-android 通常无法使用硬件加速模拟器。${NC}"
fi
echo

echo "========== 5) kvm-ok（需安装 cpu-checker）=========="
if ! command -v kvm-ok >/dev/null 2>&1; then
  echo "未安装 kvm-ok，可执行: sudo apt-get update && sudo apt-get install -y cpu-checker"
  echo
else
  set +e
  kvm-ok
  KVM_OK=$?
  set -e
  if [ "$KVM_OK" -eq 0 ]; then
    echo -e "${GRN}kvm-ok 通过。${NC}"
  else
    echo -e "${RED}kvm-ok 未通过。${NC}"
  fi
fi
echo

echo "========== 6) Docker（运行镜像前需要）=========="
if command -v docker >/dev/null 2>&1; then
  docker --version
  if docker info >/dev/null 2>&1; then
    echo -e "${GRN}docker 可正常执行（当前用户能连 daemon）。${NC}"
  else
    echo -e "${YEL}docker 已安装但当前用户可能无权限，试: sudo docker info 或加入 docker 组。${NC}"
  fi
else
  echo -e "${YEL}未安装 Docker。装好后见本仓库 README「Ubuntu 上安装 Docker」。${NC}"
fi
echo

echo "========== 结论（针对 docker-android）=========="
if [ -c /dev/kvm ]; then
  if ! command -v kvm-ok >/dev/null 2>&1; then
    echo -e "${YEL}已存在 /dev/kvm，但未安装 kvm-ok。请: sudo apt-get install -y cpu-checker && kvm-ok${NC}"
    exit 3
  fi
  set +e
  kvm-ok >/dev/null 2>&1
  KO=$?
  set -e
  if [ "$KO" -eq 0 ]; then
    echo -e "${GRN}可以本机为基尝试 budtmo/docker-android（再: docker compose -f docker-compose.emulator.yml up -d）。${NC}"
    exit 0
  fi
  echo -e "${YEL}有 /dev/kvm，但 kvm-ok 未通过；请查看上文 kvm-ok 输出、权限与内核模块。${NC}"
  exit 1
else
  echo -e "${RED}当前环境不像具备可用 KVM。docker-android 强依赖 /dev/kvm，可考虑：${NC}"
  echo "  - 改用支持嵌套虚拟化/裸金属的规格，或"
  echo "  - 使用本仓库默认 Redroid 思路（不依赖模拟器 KVM）。"
  echo "  文档: https://github.com/budtmo/docker-android#requirements"
  exit 2
fi
