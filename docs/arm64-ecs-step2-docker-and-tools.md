# ARM64 Ubuntu ECS：Docker、Compose 与常用工具（第二步）

适用于 **阿里云 ARM 实例**（如 `ecs.g8y.*`）+ **Ubuntu 22.04/24.04 64 位 ARM 版**。在 ECS 上 **SSH 登录后**执行；**不要**从 x86 机器下载 `.deb` 再拷过来装 Docker（架构必须与本机一致）。

---

## 1. 架构自检（可选）

```bash
uname -m          # 期望: aarch64
dpkg --print-architecture   # 期望: arm64
```

---

## 2. Docker Engine + Compose 插件（推荐：仓库脚本）

本仓库脚本使用 Docker **官方 Ubuntu 源**，`deb [arch=$(dpkg --print-architecture) …]` 在 ARM64 上会自动选 **arm64** 包。

**若出现 `cd: /opt/wayphone: No such file or directory`，说明尚未 clone，必须先执行下面 `git clone`（URL 换成你的 fork）。**

```bash
sudo apt-get update
sudo apt-get install -y git curl
sudo mkdir -p /opt
sudo git clone https://github.com/waywaycoffee/wayphone.git /opt/wayphone   # 或你的 fork
cd /opt/wayphone
sudo bash scripts/install-docker-ubuntu.sh
```

**无 sudo 写 `/opt` 时**，可 clone 到主目录：`git clone … ~/wayphone && cd ~/wayphone && sudo bash scripts/install-docker-ubuntu.sh`。

安装结束后应看到类似：

- `Docker version 24.x` / `25.x` …
- `Docker Compose version v2.x …`

若尚未 clone 仓库，可只复制脚本内容：与 **`scripts/install-docker-ubuntu.sh`** 一致即可（见仓库）。

---

## 3. 将登录用户加入 `docker` 组

把 **`ubuntu`** 换成你实际 SSH 用户名（阿里云常见为 **`root`** 或 **`ubuntu`**）：

```bash
sudo usermod -aG docker "$USER"
# 或: sudo usermod -aG docker ubuntu
```

**退出 SSH 重新登录**（或执行 `newgrp docker`）后，再验证：

```bash
docker run --rm hello-world
docker compose version
```

日常尽量 **不要用 `sudo docker`**，避免生成 root 拥有的 volume 权限问题。

---

## 4. 工具链：`adb`、`ffmpeg`、`git`、`curl` 等（apt，ARM64）

```bash
sudo apt-get update
sudo apt-get install -y \
  adb \
  ffmpeg \
  git \
  curl \
  ca-certificates \
  unzip \
  python3 \
  cpu-checker
```

说明：

| 包 | 用途 |
|----|------|
| **adb** | Redroid / 真机调试（包名在 Ubuntu 上多为 `adb`） |
| **ffmpeg** | C1 ingest 管道 |
| **git** / **curl** | 拉代码、健康检查 |
| **unzip** | 查看 APK 内 `lib/` ABI（`unzip -l …apk \| grep lib/`） |
| **python3** | 部分脚本 / 排障 |
| **cpu-checker** | 可选：`kvm-ok`（仅当你要试 KVM/docker-android 时） |

若 **`apt install adb`** 提示找不到包，先启用 **`universe`**：

```bash
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y universe
sudo apt-get update
sudo apt-get install -y adb
```

---

## 5. 与 x86 的区别（备忘）

- **不要**在 ARM 机器上安装从 x86 下载的 **`.deb`**（Docker 或其它），会装不上或运行错误。
- **Docker 镜像**：拉取时会自动选 **`linux/arm64`** 变体（若 manifest 多架构）；个别老旧镜像仅有 **amd64**，在 ARM 上会拉失败，需换镜像或自构建。

---

## 6. 下一步

- Redroid / Binder：**`docs/redroid-notes.md`**（含 **fstab + `wayphone-binderfs.service` 持久化**：`sudo bash scripts/install-wayphone-binder-persistence.sh`）  
- 试点 **`webrtc-sfu-pilot`**：**`experiments/webrtc-sfu-pilot/README.md`**、`docs/aliyun-ecs-pilot.md`；**`MEDIASOUP_ANNOUNCED_IP`** 与 PoC 文档 EIP 一致（**`8.166.118.148`**）。  

PoC 主机 SSH 别名：**`docs/ssh-ecs-wayphone.config.example`**
