# Redroid / 云安卓备忘

本仓库主线为 **Linux（含阿里云 ECS）+ Docker Redroid**；不再内置 **ws-scrcpy** 实验目录。

## ADB 经 SSH（5555 只在 ECS 本机时）

在**你自己的电脑**上（二选一）：

```bash
# 仓库脚本
bash scripts/remote-adb-tunnel.sh 你的用户@ECS公网IP

# 或等价
ssh -N -L 5555:127.0.0.1:5555 你的用户@ECS公网IP
```

另开终端：

```bash
adb connect 127.0.0.1:5555
adb devices
```

根目录 `docker-compose.yml` 默认将 **5555 绑在 `127.0.0.1`**，请勿随意改为对公网 `0.0.0.0` 开放。

## Binder 与容器反复重启（`/dev/binder` No such file）

若 `docker logs` / logcat 出现 **`Binder driver '/dev/binder' could not be opened`**，说明 **容器内（或宿主）没有可用的 classic binder 节点**。

### 先读内核配置（Ubuntu 24.04 云机常见）

```bash
grep CONFIG_ANDROID_BINDER /boot/config-"$(uname -r)" 2>/dev/null | grep -v '^#'
```

若出现 **`CONFIG_ANDROID_BINDER_DEVICES=""`**（空字符串），表示 **内核不会自动创建 `/dev/binder` / `hwbinder` / `vndbinder`**，即使 **`modprobe binder_linux devices=...`** 也可能 **没有** `/dev/binder`。此时应使用 **binderfs**（`CONFIG_ANDROID_BINDERFS=m` 时）：挂载后在 **`binder-control`** 上 **`BINDER_CTL_ADD`** 创建实例，再 **`/dev/binder` → `/dev/binderfs/binder`** 等符号链接。

本仓库提供一次性脚本（在 ECS **root** 下、仓库已 `git clone` 到例如 `/root/wayphone`）：

```bash
cd /root/wayphone
sudo bash scripts/setup-binder-devices.sh
ls -la /dev/binder /dev/hwbinder /dev/vndbinder
```

成功后再 **`docker compose up -d`**；根目录 `docker-compose.yml` 中 **`devices:`** 会把上述节点传入 Redroid。

若 **`/boot/config-*` 里根本没有 `CONFIG_ANDROID_BINDER_IPC`**，则当前内核 **不支持** Android binder，只能换镜像/内核或机型。

### 经典节点已预置的内核（少数环境）

若 **`CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`**（或等价），通常只需：

```bash
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
ls -la /dev/binder /dev/hwbinder /dev/vndbinder
```

三者在且 compose 里已映射 **`devices:`** 后，再 **`docker compose up -d`**。仅 `privileged: true` 在部分 Docker/内核组合下仍不会自动注入上述节点。

## 中国移动掌厅（仅备忘，不构成兼容性承诺）

- **包名**：`com.greenpoint.android.mc10086.activity`  
- **安装**：请使用 **官方渠道 APK**；勿使用来源不明的安装包。  
- **深链示例**（App 已安装后由 `adb shell am start` 等唤起）：`com.greenpoint://android.mc10086.activity?url=https%3A%2F%2F...`（`url` 需按实际编码）。

在部分 **模拟器 / 非标准环境** 上曾出现 **16KB 页** 与 native 库加载问题；云 Redroid 以 **实测** 为准。
