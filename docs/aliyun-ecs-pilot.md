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

浏览器（你本机或手机 4G）：`http://EIP:3000/`  

- **Tab 1**：「发布摄像头」  
- **Tab 2**：「仅观看」  

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
| `no configuration file provided: not found` | 当前目录没有 compose 文件。先 `cd /opt/wayphone/experiments/webrtc-sfu-pilot`，再 `ls docker-compose.yml` 确认存在后执行 `docker compose up --build`。 |

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
