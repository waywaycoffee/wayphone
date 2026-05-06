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

若 `docker logs` / logcat 出现 **`Binder driver '/dev/binder' could not be opened`**，说明 **容器内看不到 binder 设备**。在 ECS **宿主机**上先确认：

```bash
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
ls -la /dev/binder /dev/hwbinder /dev/vndbinder
```

三者在且 compose 里已映射 **`devices: /dev/binder` 等**（见根目录 `docker-compose.yml`）后，再 **`docker compose up -d`**。仅 `privileged: true` 在部分 Docker/内核组合下仍不会自动注入上述节点。

## 中国移动掌厅（仅备忘，不构成兼容性承诺）

- **包名**：`com.greenpoint.android.mc10086.activity`  
- **安装**：请使用 **官方渠道 APK**；勿使用来源不明的安装包。  
- **深链示例**（App 已安装后由 `adb shell am start` 等唤起）：`com.greenpoint://android.mc10086.activity?url=https%3A%2F%2F...`（`url` 需按实际编码）。

在部分 **模拟器 / 非标准环境** 上曾出现 **16KB 页** 与 native 库加载问题；云 Redroid 以 **实测** 为准。
