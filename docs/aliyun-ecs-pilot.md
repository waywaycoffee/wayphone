# 阿里云 ECS：先跑通测试（与本仓库一致）

目标：**在阿里云 Linux 上把本仓库里「能客观验证」的两块先跑通**——① WebRTC SFU 试点（Layer B）；②（可选）Redroid 容器。不承诺掌厅业务结果，以实测为准。

更通用的防火墙与「并发」话术澄清：见 **[linux-cloud-lab.md](linux-cloud-lab.md)**（含 **§7**）。  
**同一套代码在 x86 本地 Linux（无云安全组、局域网为主）**：见 **[local-x86-linux.md](local-x86-linux.md)**。

---

## 0. 开什么机器（最小可验证）

- **镜像**：**Ubuntu 22.04 LTS** 64 位（与仓库文档一致，少踩坑）。  
- **规格**：**2 核 4 GB** 起可试跑 **mediasoup 试点**（`npm install` 编 native 会吃 CPU/内存）；若要同机再跑 **Redroid**，建议 **4 核 8 GB** 起，并以 [redroid-doc](https://github.com/remote-android/redroid-doc) 与实测为准。  
- **架构**：**x86 或 ARM** 均以厂商说明 + **Redroid / Docker 特权容器** 是否可行为准，**不要**把「某架构必过掌厅」当购买依据。  
- **网络**：分配 **弹性公网 IP（EIP）**（或明确你从办公网/VPN 访问的 **内网 IP**）；后面 `MEDIASOUP_ANNOUNCED_IP` 填 **浏览器访问 ECS 时实际连到的那个 IP**。

> **规格族 / 轻量应用服务器**：是否支持 Redroid 所需的内核与容器能力，以阿里云文档 + 你开一台 PoC **跑 `docker compose` 能否稳定起容器** 为准；不在此写死「必买某款」。

---

## 1. 安全组（必配）

在 ECS 绑定的**安全组**入方向放行（可按需收紧来源 IP）：

| 协议 | 端口 | 用途 |
|------|------|------|
| TCP | 22 | SSH |
| TCP | 3000 | SFU 试点 HTTP/WebSocket（若改 `PORT` 则同步改） |
| UDP | 40000–49999 | mediasoup RTP（若改 `MEDIASOUP_RTC_*` 则与安全组一致） |

**系统防火墙**（若开启了 `ufw`/`firewalld`）需与安全组**同时**放行，见 [linux-cloud-lab.md §2](linux-cloud-lab.md)。

---

## 2. 登录 ECS 并装 Docker

先装常用工具：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
```

### 2.1 方式一：APT（Docker 官方仓库，与本仓库 README 一致）

安装步骤见 [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)。装好后执行：

```bash
docker --version
docker compose version
sudo usermod -aG docker "$USER"
```

**重新登录 SSH** 后当前用户才能无 `sudo` 跑 `docker`（或临时 `newgrp docker`）。

### 2.2 方式二：Snap（`snap install docker`）

若你已用或打算用 **Snap** 安装：

```bash
sudo snap install docker
```

然后确认：

```bash
docker --version
docker compose version
```

- 若 **`docker compose`** 不存在，可再装插件类包或改用 **`docker-compose`**（以你系统上 `snap list` / 官方 [docker snap](https://snapcraft.io/docker) 说明为准）。  
- **特权容器 + `network_mode: host`**（本仓库 `webrtc-sfu-pilot` 的 compose 会用到）在个别 Snap/内核组合上可能行为与 APT 版略有差异；若 `docker compose up` 与网络相关报错，可优先换 **§2.1 APT 官方 Docker** 再试。  
- **`usermod: group 'docker' does not exist'`**：Snap 版 Docker **常常不会创建**系统里的 `docker` 组。**当前用户是 `root` 时可直接忽略**「加入 docker 组」这一步，照常执行 `docker` / `docker compose` 即可。若要用**普通用户**免 `sudo` 跑 Docker，Snap 与 APT 行为不同：可一直使用 `sudo docker …`，或改用 **§2.1 APT 官方安装**（会创建 `docker` 组后再 `usermod`），或查阅当前 Snap 版本文档中的权限说明。  
- **路径与沙箱（很重要）**：Snap 严格沙箱下，`docker` / `docker compose` 使用的路径往往**只对 `$HOME` 等少数目录可见**。仓库放在 **`/opt/wayphone`** 时，你在 shell 里 `ls` 能看到 `docker-compose.yml`，但 compose 仍可能报 **`open …/docker-compose.yml: no such file or directory`**——这不是文件丢了，而是 **Docker 进程读不到 `/opt`**。**处理**：把代码放到 **`$HOME/wayphone`**（`root` 一般为 `/root/wayphone`），或改用 **§2.1 APT 官方 Docker**（无此限制）。

### 2.3 从 Snap Docker 迁到 APT 官方 Docker（`docker ps` 卡死、无 `docker.service` 时）

**说明**：卸 Snap 会丢掉 **Snap 管的那套 Docker 数据**（镜像/容器层在 snap 目录下）；若仍能通过 **`docker ps`** 导出镜像再迁，可先 `docker save`；**已卡死无法执行 docker** 时只能接受重建镜像与容器。正式迁移前可在控制台 **创建快照**。

在 ECS 上 **整段按顺序执行**（与 [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/) 一致；`root` 可省略部分 `sudo`）：

```bash
# 1) 停掉并移除 Snap Docker（若提示 in use，可先 reboot 再来这两行）
sudo snap stop docker
sudo snap remove docker

# 2) 卸 Ubuntu 自带的旧 docker.io（若有），避免冲突
sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true

# 3) 安装 Docker 官方仓库与 Engine + Compose 插件
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4) 启用并自检
sudo systemctl enable --now docker
sudo systemctl status docker --no-pager
timeout 15 docker ps
docker compose version
```

成功后请回到 **`/root/wayphone`**（或你的 compose 目录）重新 **`docker compose up -d`** 拉起 **Redroid / webrtc-sfu-pilot**。若 **`VERSION_CODENAME`** 与 Docker 仓库不兼容（少见），以 [官方文档](https://docs.docker.com/engine/install/ubuntu/) 的 **「Install using the convenience script」或发行版对照表** 为准。

### 2.4 国内 ECS 拉 Docker Hub 超时（`registry-1.docker.io … i/o timeout`）

阿里云等国内线路访问 **Docker Hub** 常不稳定。为 Docker 配置 **镜像加速器**（控制台与 ECS 命令如下，便于长期照做）。

#### 控制台在哪里、复制什么

1. 登录 **阿里云控制台** → 打开 **容器镜像服务 ACR**。  
2. 左侧 **镜像工具** → **镜像加速器**。  
3. 页面 **「加速器地址」** 会显示一条 **专属 URL**（形如 `https://xxxxxxxx.mirror.aliyuncs.com`，**每账号不同**，勿照抄他人）。  
4. 页面下方 **操作系统** 选 **Ubuntu**，可按官方给出的命令操作（与下面 ECS 命令等价）。

**说明**：加速器仅加速 **Docker Hub 等配置的仓库拉取**；控制台顶部提示：若仍慢，可能与运营商网络有关，可考虑 **ACR 自建镜像 / 海外同步** 等（见 ACR 文档）。

#### 在 ECS 上配置（Docker Engine ≥ 1.10；推荐已装 APT 官方 Docker，见 §2.1）

将 **`https://xxxxxxxx.mirror.aliyuncs.com`** 换成你在 **镜像加速器** 页复制的 **整段地址**：

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": ["https://xxxxxxxx.mirror.aliyuncs.com"]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
docker info | grep -A5 'Registry Mirrors'
```

- 若 **`/etc/docker/daemon.json` 已存在其它键**（如 `log-driver`），**不要**用 `tee` 整文件覆盖；用编辑器 **合并** `registry-mirrors` 数组。  
- 生效后重试 **`docker compose pull`** / **`docker pull`**。

---


## 3. 拉代码

公开仓库示例（与本仓库当前默认远程一致；若你 fork 了请改 URL）：

```bash
sudo mkdir -p /opt/wayphone
sudo chown "$USER":"$USER" /opt/wayphone
git clone https://github.com/waywaycoffee/wayphone.git /opt/wayphone
cd /opt/wayphone
```

私有库请改用 **SSH**（`git@github.com:...`）或在 ECS 上配置 **credential / token**。下文路径 **`/opt/wayphone`** 可按你实际目录替换。

**若你使用 Snap 版 Docker（§2.2）**：为避免 `/opt` 对 Docker 不可见，建议直接把仓库克隆到用户目录，例如：

```bash
mkdir -p "$HOME"
git clone https://github.com/waywaycoffee/wayphone.git "$HOME/wayphone"
cd "$HOME/wayphone"
```

下文凡写 **`/opt/wayphone`**，在 Snap 场景请自行换成 **`$HOME/wayphone`**（或你已 `git clone` 到的、位于 `$HOME` 下的路径）。

---

## 4. 先跑通 A：WebRTC SFU 试点（建议第一步）

**必须先完成 §3**（本机已有 `/opt/wayphone` 且内含 `experiments/webrtc-sfu-pilot/docker-compose.yml`）。若不确定，先执行：

```bash
test -f /opt/wayphone/experiments/webrtc-sfu-pilot/docker-compose.yml && echo OK || echo "请先 git clone 到 /opt/wayphone（见 §3）"
```

在 ECS 上（有 EIP 时把下面 `EIP` 换成公网 IP；仅内网访问则换成内网 IP）：

```bash
cd /opt/wayphone/experiments/webrtc-sfu-pilot
export MEDIASOUP_ANNOUNCED_IP=EIP
export PORT=3000
docker compose up --build
```

**说明**：`docker compose` 必须在**含有 `docker-compose.yml` 的目录**里执行；在 `~` 根目录直接跑会出现 `no configuration file provided: not found`。

**已在 `cd` 到上述目录后仍报 `no configuration file provided`（常见于 Snap 安装的 Docker）**时，可先试**绝对路径**或仓库内脚本（二选一）；**若 `docker compose … config` 又报 `open …docker-compose.yml: no such file or directory`（而 `ls` 同一路径存在）**，说明是 **Snap 读不到 `/opt`**，不要用绝对路径硬扛——请 **§3** 把仓库放到 **`$HOME/wayphone`**，或改用 **§2.1 APT 官方 Docker**。

在仓库根为 **`/opt/wayphone`**（Snap 用户请改为 **`$HOME/wayphone`**）时：

```bash
export MEDIASOUP_ANNOUNCED_IP=EIP
export PORT=3000
docker compose --project-directory /opt/wayphone/experiments/webrtc-sfu-pilot \
  -f /opt/wayphone/experiments/webrtc-sfu-pilot/docker-compose.yml up --build
```

或（`git pull` 拿到 `docker-up.sh` 之后；路径同样按上替换）：

```bash
chmod +x /opt/wayphone/experiments/webrtc-sfu-pilot/docker-up.sh
export MEDIASOUP_ANNOUNCED_IP=EIP
export PORT=3000
bash /opt/wayphone/experiments/webrtc-sfu-pilot/docker-up.sh
```

先自检 compose 能否被解析：

```bash
docker compose --project-directory /opt/wayphone/experiments/webrtc-sfu-pilot \
  -f /opt/wayphone/experiments/webrtc-sfu-pilot/docker-compose.yml config
```

浏览器（你本机或手机 4G）：`http://EIP:3000/` 可验证页面与信令是否通。  
**「发布摄像头」需要安全上下文**：多数浏览器在 **`http://公网IP`** 下会禁用 **`navigator.mediaDevices`**，表现为发布失败。PoC 请在本机 **`ssh -L 3000:127.0.0.1:3000 root@EIP`** 后用 **`http://127.0.0.1:3000/`** 打开，或上 **HTTPS**；说明见 **`docs/webrtc-sfu-pilot.md` §3.2**。

- **Tab 1**：「发布摄像头」  
- **Tab 2**：「仅观看」  

**外网浏览器打不开（连接超时 / 无法访问）**：先在 **ECS 上**执行 `curl -sI http://127.0.0.1:3000`（或 `curl -sI http://127.0.0.1:${PORT:-3000}`）。若 **本机通、外网不通**，依次查：① **安全组入方向 TCP 3000** 是否对 `0.0.0.0/0` 或你的办公网 IP 放行；② 该实例是否已绑定你正在访问的 **EIP**；③ 系统 **`ufw status`** / **firewalld** 是否拦截（见 [linux-cloud-lab.md §2](linux-cloud-lab.md)）。

若只有信令没有画面：多半是 **`MEDIASOUP_ANNOUNCED_IP` 与 EIP 不一致** 或 **UDP 段未放行**，见 `docs/webrtc-sfu-pilot.md` 与 `linux-cloud-lab.md` §5。

**无 Docker 时用 Node**（需 `python3`、`build-essential` 以便编 mediasoup）：

```bash
sudo apt-get install -y python3 build-essential
cd /opt/wayphone/experiments/webrtc-sfu-pilot
npm install
npm run build:client
export MEDIASOUP_ANNOUNCED_IP=EIP
export PORT=3000
node server.cjs
```

### 4.1 常见错误

| 现象 | 原因与处理 |
|------|------------|
| `cd: .../webrtc-sfu-pilot: No such file or directory` | 未克隆仓库或路径不对。执行 **§3** 的 `git clone`，或 `ls /opt` / `find / -maxdepth 4 -name webrtc-sfu-pilot -type d 2>/dev/null` 找到实际目录后再 `cd`。 |
| `no configuration file provided: not found` | ① 当前目录没有 compose 文件：先 `cd …/webrtc-sfu-pilot`，`ls docker-compose.yml`。② **已 cd 仍有此报错**：多为 **Snap 版 Docker** 未正确识别工程目录，见上文 **绝对路径** / **`docker-up.sh`**。仍失败可改用 **APT 官方 Docker**（§2.1）。 |
| `open …/docker-compose.yml: no such file or directory`（但同一台机器上 `ls` 该路径存在） | **Snap 版 Docker** 沙箱下守护进程**看不到**仓库所在目录（常见为 **`/opt/...`**）。**绝对路径无法修复**。把仓库放到 **`$HOME/wayphone`** 后再 compose，或改用 **§2.1 APT 官方 Docker**。 |
| 浏览器打不开 `http://EIP:3000` | **ECS 上** `curl -sI http://127.0.0.1:3000` 若 **200/304**：服务在跑，问题在 **云安全组 / 本机防火墙 / EIP 是否绑在这台实例**。若 **curl 也失败**：容器未起或 `PORT` 不一致，看 `docker compose` 日志。 |

---

## 5. 再试 B：Redroid（可选，与 SFU 独立）

```bash
cd /opt/wayphone
docker compose up -d
```

根目录 `docker-compose.yml` 默认 **ADB 5555 只绑 `127.0.0.1`**，不直接暴露公网。从本机连上云安卓用 **SSH 端口转发**：见 **`scripts/remote-adb-tunnel.sh`** 与 **`docs/redroid-notes.md`**。

**说明**：当前仓库 **未** 把 Redroid 画面自动接入 mediasoup（Layer C 另做）；你在阿里云上「跑通」到 **ADB 能装 App / 能起容器** 即可算环境就绪。

---

## 6. 费用与后续

- 控制台关注 **ECS + EIP + 流量/带宽** 计费；PoC 结束及时 **关机或释放** 实例，避免空跑。  
- 掌厅与合规：仅用 **官方渠道 APK**，勿使用不明来源安装包。

---

## 7. 自检命令（可选）

在 **ECS 上**（推荐；脚本默认访问 `127.0.0.1`）已 `git clone` 且 **3000** 已监听、`MEDIASOUP_ANNOUNCED_IP` 已正确时：

```bash
cd /opt/wayphone
PORT=3000 bash scripts/smoke-webrtc-sfu-pilot.sh
```

若在你**个人电脑**上跑 smoke 而服务在云上，需改脚本或改用隧道把本机某端口转到 ECS:3000；否则请始终在 **ECS 内**执行上述命令。
