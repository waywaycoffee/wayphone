# 自建「云手机」学习环境（适合阿里云 ECS）

目标：在云上跑一个可长期保留的 **Android 实例**，方便练 **安全组、SSH、Docker、端口转发、资源与进程管理**；不替代商业云手机，但够用来理解「远端的 Android 壳子」如何搭起来。

## 一键部署（ECS 上）

**前提**：Ubuntu ECS，已 SSH 登录；安全组放行 **22**（来源尽量收紧到你当前 IP）。

### A. 首次：安装 Docker（只需一次）

```bash
git clone https://github.com/<你的用户名>/cloudPhone.git
cd cloudPhone
sudo bash scripts/install-docker-ubuntu.sh
sudo usermod -aG docker "$USER"
# 退出 SSH 再登录，使 docker 组生效
```

### B. 启动云手机实例

```bash
cd cloudPhone
chmod +x scripts/*.sh
bash scripts/deploy-ecs.sh
```

- **`DEPLOY_MODE=auto`（默认）**：存在 **`/dev/kvm`** 则拉起 [docker-android](https://github.com/budtmo/docker-android)，否则拉起 **Redroid**。  
- **强制 Redroid**：`DEPLOY_MODE=redroid bash scripts/deploy-ecs.sh`  
- **强制 docker-android**（无 KVM 会失败）：`DEPLOY_MODE=emulator bash scripts/deploy-ecs.sh`

可选：`cp .env.example .env` 后改镜像、端口等。

### C. 从你电脑连接

- **Redroid**：`ssh -N -L 5555:127.0.0.1:5555 user@ECS`，再 `adb connect 127.0.0.1:5555`（若改了端口，与 `.env` 中 `REDROID_HOST_PORT` 一致）。  
- **docker-android**：`ssh -N -L 6080:127.0.0.1:6080 user@ECS`，浏览器打开 `http://127.0.0.1:6080`。

停止：`docker compose down` 或 `docker compose -f docker-compose.emulator.yml down`。

---

## 同步到 GitHub（在你自己的电脑上）

1. 在 [GitHub](https://github.com/new) 新建空仓库（不要勾选添加 README，避免冲突）。  
2. 在本项目目录执行（替换仓库地址）：

   ```bash
   cd /path/to/cloudPhone
   git init
   git add .
   git commit -m "Initial ECS deployable cloud phone lab"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

3. 之后在 ECS 上使用：`git clone https://github.com/<你的用户名>/<仓库名>.git`。

**勿将** `.env`（若含私密配置）、服务器密码提交仓库；仓库已包含 `.gitignore` 忽略 `.env`。

---

## 先选哪套（很重要）

| 情况 | 怎么做 |
|------|--------|
| 多数 **阿里云普通 ECS**（**没有** `/dev/kvm`） | 用本仓库 **默认的 Redroid**（`docker compose up`） |
| 少数机器有 **`/dev/kvm`** 且需要 **浏览器里直接看系统画面** | 再试 [docker-android](https://github.com/budtmo/docker-android)（`docker compose -f docker-compose.emulator.yml up`） |

**模拟器「品牌」**：[docker-android 官方机型列表](https://github.com/budtmo/docker-android#list-of-devices) 只有 **三星 Galaxy、Nexus、Pixel C**，**没有**小米 / 华为 / OPPO / vivo 等国产厂商皮肤。本仓库 **`docker-compose.emulator.yml`** 默认 **`EMULATOR_DEVICE=Samsung Galaxy S10`**（与上游 Quick Start 一致）；若不想用三星可改为 **`Nexus 5`** 等列表内名称。需要更接近国产 ROM 或厂商风控行为时，只能 **真机**、或看上游提到的 **Genymotion 等第三方**。本仓库默认 **Redroid** 是 **AOSP 容器**，也不是品牌系统。

**Docker 装好后**再跑：`bash scripts/check-env.sh`，看它建议你走哪条。

## 以 docker-android 为基时的 KVM 检查（在 ECS 上执行）

[budtmo/docker-android](https://github.com/budtmo/docker-android) 需要宿主机 **支持虚拟化** 且能使用 **`/dev/kvm`**（官方 Quick Start 使用 `--device /dev/kvm`）。在阿里云 **普通 ECS** 上，**常没有嵌套虚拟化**，因此**先别直接写生产方案**，在实例上按下面自测一遍。

**方式 A：一条命令（推荐）**

```bash
# 在已 clone 本仓库的目录下
chmod +x scripts/check-kvm-docker-android.sh
bash scripts/check-kvm-docker-android.sh
```

**方式 B：手工逐步执行（便于贴到工单或笔记）**

1. 看 CPU 里是否有 `vmx`（Intel）或 `svm`（AMD）：

   ```bash
   egrep -m1 'vmx|svm' /proc/cpuinfo
   ```

2. 看 KVM 模块是否加载：

   ```bash
   lsmod | grep "^kvm"
   ```

3. **关键**：是否有字符设备 `/dev/kvm`：

   ```bash
   ls -la /dev/kvm
   ```

4. 安装并运行 `kvm-ok`（与官方文档一致，需 `cpu-checker` 包）：

   ```bash
   sudo apt-get update
   sudo apt-get install -y cpu-checker
   sudo kvm-ok
   ```

   若输出为 **/dev/kvm exists** 且 **KVM acceleration can be used**，再考虑起 docker-android 镜像。

5. 若存在 `/dev/kvm` 但无权限，可把用户加入 `kvm` 组后**重新登录 SSH**：

   ```bash
   sudo usermod -aG kvm "$USER"
   ```

**若 3、4 步失败**：说明当前 **ECS 规格/虚拟化未暴露嵌套 KVM**，无法按官方方式在**该实例**上把 docker-android 当稳定基线；可换**支持嵌套虚拟化/裸金属**的实例，或回退到本仓库 **Redroid** 方案。详见 [docker-android Requirements / Quick Start](https://github.com/budtmo/docker-android#quick-start)。

## 1. Ubuntu 上安装 Docker（与阿里云官方 Ubuntu 镜像一致）

你的 ECS 是 **Ubuntu** 时，建议用 [Docker 官方仓库](https://docs.docker.com/engine/install/ubuntu/) 安装带 **Compose v2** 插件的版本（`docker compose` 子命令）。下面在 **20.04 / 22.04 / 24.04** 上均常用；若某条报错，以官方页为准。若你使用 **`snap install docker`**，见 **`docs/aliyun-ecs-pilot.md` §2.2**（含 `docker compose` 与 host 网络注意点）。

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

将当前用户加入 `docker` 组（**执行完后需要重新登录 SSH 才生效**）：

```bash
sudo usermod -aG docker "$USER"
# 或临时用: newgrp docker
```

验证（应能看到 `Docker Compose version v2.x`）：

```bash
docker --version
docker compose version
```

> **说明**：若你更想用发行版自带包 `apt install docker.io`，也能跑容器，但需自己确认 `docker compose` 是否已安装；本仓库以官方 `docker-compose-plugin` 为准。全程若未加组，可暂时 `sudo docker compose`。

## 2. 部署 Redroid（推荐默认方案）

在 **ECS 上**（与 `docker-compose.yml` 同目录）执行：

```bash
cd /path/to/cloudPhone
docker compose up -d
```

验证容器：

```bash
docker ps
docker logs cloudphone-redroid
```

> **安全**：`compose` 里已将 ADB 端口 `5555` 绑定在 **`127.0.0.1`**，不会从公网直连；学习阶段请**不要**改成对 `0.0.0.0` 开放 5555。

## 3. 在你自己的电脑上连上「云里的 Android」

1. 在一台有 **OpenSSH 客户端** 的电脑上，用仓库里的转发脚本，或自己执行：

   ```bash
   ssh -N -L 5555:127.0.0.1:5555 你的用户@ECS公网IP
   ```

   保持此终端不关。

2. 另开一个终端，安装 ADB 后（macOS: `brew install android-platform-tools`；Windows 可用 Android 平台工具包）：

   ```bash
   adb connect 127.0.0.1:5555
   adb devices
   ```

3. 有图像需求时，在本机安装 [scrcpy](https://github.com/Genymobile/scrcpy)（需要可显示桌面；仅练命令可一直用 `adb shell`/`adb`）。

你学到的东西：**公网不暴露 ADB、SSH 与本地端口转发、远程实例如何像「在本地 5555」一样使用**。

## 4.（可选）有 KVM 时：带 Web 界面的模拟器

仅当 `scripts/check-env.sh` 显示存在 **`/dev/kvm`** 时再试。

```bash
docker compose -f docker-compose.emulator.yml up -d
```

在 **本机** 做转发（**不要**把 6080 对全网开放）：

```bash
ssh -N -L 6080:127.0.0.1:6080 你的用户@ECS公网IP
```

浏览器打开 `http://127.0.0.1:6080` 体验 [noVNC 界面](https://github.com/budtmo/docker-android)（以镜像文档为准）。

## 5. 阿里云上建议顺手练的配置

- **安全组**：`22/SSH` 只给自己的办公网 IP 或至少限制网段；**不要** 对 `0.0.0.0/0` 放行 5555、5554、5037、6080 等 ADB/模拟器常用端口。  
- **学习路径**：`实例规格 / 磁盘 / 镜像` → `安全组与密钥` → `Docker 与 compose` → `只读 127.0.0.1` + **SSH 隧道** → 可在 ECS 上再装 `htop`/`ctop` 看 CPU 与容器资源。

## 6. 常见问题

- **Redroid 起不来、内核 5.15+**：可查阅 [redroid-doc](https://github.com/remote-android/redroid-doc) 中关于 `use_memfd` 等说明，或换用镜像标签。  
- **docker-android 闪退**：多半是 **无 KVM 或厂商未开放嵌套虚拟化**，回退到 Redroid 作为主线即可。

## 本仓库文档索引

- **阿里云 ECS 分步**：`docs/aliyun-ecs-pilot.md`  
- **PoC ARM ECS SSH 别名 `ecs_wayphone`（`8.166.118.148`）**：`docs/ssh-ecs-wayphone.config.example`  
- **ARM64 ECS：Docker + adb/ffmpeg 等（第二步照抄）**：`docs/arm64-ecs-step2-docker-and-tools.md`  
- **x86 本地 Linux（家用/机房，与 ECS 同一套 compose）**：`docs/local-x86-linux.md`  
- **Redroid / ADB / 掌厅备忘**：`docs/redroid-notes.md`  
- **WebRTC SFU 试点（mediasoup）**：`docs/webrtc-sfu-pilot.md`；试点代码在 **`experiments/webrtc-sfu-pilot`**（`npm install` 在该目录执行）。**仓库根目录**也有 **`package.json`**，可从 **`/opt/wayphone`** 直接 **`npm run c1:ingest:adb:loop`** 等（转发到 pilot），避免误在根目录跑 npm 报 **ENOENT**。  
- **Layer C（安卓画面进 SFU）路线图**：`docs/layer-c-roadmap.md`  
- **Linux 云机防火墙与容量口径**：`docs/linux-cloud-lab.md`

## 参考链接

- [Redroid 文档](https://github.com/remote-android/redroid-doc)  
- [budtmo/docker-android](https://github.com/budtmo/docker-android)  
- [scrcpy](https://github.com/Genymobile/scrcpy)  
