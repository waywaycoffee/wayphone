#!/usr/bin/env bash
# 将 binderfs 挂载写入 fstab，并在开机后自动执行 setup-binder-devices（ioctl 创建节点 + 符号链接）。
# 需 root；WAYPHONE_ROOT 默认 /opt/wayphone（与 PoC 文档一致）。
# 用法: sudo WAYPHONE_ROOT=/opt/wayphone bash scripts/install-wayphone-binder-persistence.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行。" >&2
  exit 1
fi

WAYPHONE_ROOT="${WAYPHONE_ROOT:-/opt/wayphone}"
MODULE_FILE="/etc/modules-load.d/wayphone-binder.conf"
FSTAB_MARK="# wayphone-binderfs (redroid)"
SERVICE_DST="/etc/systemd/system/wayphone-binderfs.service"

if [[ ! -d "${WAYPHONE_ROOT}" ]]; then
  echo "error: WAYPHONE_ROOT 不是目录: ${WAYPHONE_ROOT}" >&2
  exit 1
fi
if [[ ! -f "${WAYPHONE_ROOT}/scripts/setup-binder-devices.sh" ]]; then
  echo "error: 未找到 ${WAYPHONE_ROOT}/scripts/setup-binder-devices.sh" >&2
  exit 1
fi

echo "binder_linux" >"${MODULE_FILE}"
chmod 0644 "${MODULE_FILE}"
echo "已写 ${MODULE_FILE}"

install -d -m 0755 /dev/binderfs

if ! grep -qE '[[:space:]]/dev/binderfs[[:space:]]' /etc/fstab; then
  {
    echo "${FSTAB_MARK}"
    echo "binder /dev/binderfs binder nofail 0 0"
  } >>/etc/fstab
  echo "已追加 fstab: binder -> /dev/binderfs (nofail)"
else
  echo "fstab 已含 /dev/binderfs 挂载，跳过"
fi

sed "s|__WAYPHONE_ROOT__|${WAYPHONE_ROOT}|g" "${WAYPHONE_ROOT}/deploy/wayphone-binderfs.service.in" >"${SERVICE_DST}"
chmod 0644 "${SERVICE_DST}"
echo "已安装 systemd: ${SERVICE_DST}"

systemctl daemon-reload
systemctl enable wayphone-binderfs.service
echo "已 enable wayphone-binderfs.service"

# 当前会话立即跑一次（不依赖重启）
systemctl start wayphone-binderfs.service || true
bash "${WAYPHONE_ROOT}/scripts/setup-binder-devices.sh"

echo ""
echo "完成。验证: ls -la /dev/binder; systemctl status wayphone-binderfs.service"
echo "重启后: fstab 会挂载 /dev/binderfs，oneshot 会确保 BINDER_CTL_ADD 与 /dev/binder 链接。"
