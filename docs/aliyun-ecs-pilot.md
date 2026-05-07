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

云厂商侧第一道门是 **安全组**：未在入方向放行的端口，从公网访问会 **超时 / 无法连接**，与 ECS 里服务是否启动无关。  
**系统防火墙**（`ufw` / `firewalld`）是第二道门，需与安全组**同时**放行，见 [linux-cloud-lab.md §2](linux-cloud-lab.md)。

### 1.1 控制台操作路径（ECS）

1. 登录 [阿里云控制台](https://ecs.console.aliyun.com/) → **云服务器 ECS**。  
2. **实例与镜像** → **实例**，点目标实例 **ID** 进入详情。  
3. 打开 **安全组** 页签 → 点击已绑定的 **安全组 ID**（或 **配置规则**）。  
4. 选 **入方向** → **手动添加**（或 **快速添加规则** 后逐项核对），按下表 **逐条添加**。

> **轻量应用服务器**：入口在 **服务器列表** → 实例 **防火墙** / **安全**，语义与「入方向放行端口」一致，端口与下表相同。

### 1.2 需要添加的入方向规则（webrtc-sfu-pilot + SSH）

下面按 **阿里云 ECS 安全组 → 入方向 → 手动添加** 的常见表单项说明（不同控制台版本文案可能略有差异，字段含义一致即可）。

**通用字段（每条规则都类似）：**

| 表单项（控制台） | 建议填写 |
|------------------|----------|
| **规则方向** | **入方向** |
| **授权策略** | **允许** |
| **优先级** | 默认即可（若需与多条规则共存，按控制台说明：数字越小越优先等） |
| **协议类型** | 见下述三条规则（**SSH** / **自定义 TCP** / **自定义 UDP**） |
| **端口范围** | 见下述（须与 `PORT`、`MEDIASOUP_RTC_*` 一致，见 **§1.2.4**） |
| **授权对象** | PoC：`0.0.0.0/0`；收紧：你的公网 IP 写成 **`x.x.x.x/32`**，或办公网段 **`10.0.0.0/8`** 等 |
| **描述**（可选） | 自定义，如 `ssh`、`sfu-http-ws`、`mediasoup-udp` |

---

#### 1.2.1 规则 A：SSH（22）

| 表单项 | 填写值 |
|--------|--------|
| 协议类型 | **SSH(22)**；若无预设则选 **自定义 TCP**，端口 **22/22** |
| 端口范围 | **22/22**（单端口写 **`22/22`**，不要只写 `22` 若控制台要求「起止」格式） |
| 授权对象 | **`0.0.0.0/0`**（任意地点 SSH，方便但易被扫）；更安全填 **`你的办公公网IP/32`** |
| 用途 | 远程登录 ECS，执行 `docker`、`curl` 等 |

---

#### 1.2.2 规则 B：SFU 信令与页面（TCP，默认 3000）

`webrtc-sfu-pilot` 的 **HTTP + WebSocket** 监听 **`PORT`**（`docker-compose.yml` 里默认 **3000**）。

| 表单项 | 填写值（默认） | 若你改了 `PORT` |
|--------|----------------|-----------------|
| 协议类型 | **自定义 TCP** | 同上 |
| 端口范围 | **`3000/3000`** | **`你的PORT/你的PORT`**（例：`3010/3010`） |
| 授权对象 | **`0.0.0.0/0`**（PoC）或收紧为 **`x.x.x.x/32`** | 同上 |
| 用途 | 浏览器打开 **`http://EIP:PORT/`**、WebSocket 信令 | 与安全组端口必须相同 |

**与配置对齐**：在 ECS 上若使用 `export PORT=3010` 再 `docker compose up`，则此处必须是 **`3010/3010`**，否则公网无法打开页面。

---

#### 1.2.3 规则 C：mediasoup 媒体面（UDP，默认 40000–49999）

WebRTC **音视频 RTP** 走 UDP，端口范围由环境变量 **`MEDIASOUP_RTC_MIN_PORT`**、**`MEDIASOUP_RTC_MAX_PORT`** 决定（`docker-compose.yml` 默认 **40000**–**49999**）。

| 表单项 | 填写值（默认） | 若你改了 RTC 端口环境变量 |
|--------|----------------|---------------------------|
| 协议类型 | **自定义 UDP** | 同上 |
| 端口范围 | **`40000/49999`** | **`MIN/MAX`**，与 compose 中一致（例：仅开 **`40000/40100`** 则 min/max 都要改且范围要覆盖 Worker 实际分配） |
| 授权对象 | **`0.0.0.0/0`**（PoC；浏览器可能在任意网络） | 同上 |
| 用途 | 远端 **「仅观看」** 能收到画面；缺此规则常表现为 **有页面、无视频** |

**与配置对齐**：`docker-compose.yml` 片段为 `MEDIASOUP_RTC_MIN_PORT` / `MEDIASOUP_RTC_MAX_PORT`；你在 **`docker compose up`** 前 `export` 的取值，必须落在安全组 **同一段 UDP 端口** 内。只改一端会导致媒体不通。

---

#### 1.2.4 `PORT` / `MEDIASOUP_RTC_*` 与安全组一致性（必读）

| 环境变量（示例） | 作用 | 安全组必须 |
|------------------|------|------------|
| `PORT`（默认 3000） | HTTP、WebSocket | **入方向 TCP**，端口 **`PORT/PORT`** |
| `MEDIASOUP_RTC_MIN_PORT` / `MEDIASOUP_RTC_MAX_PORT`（默认 40000–49999） | mediasoup 收发包 | **入方向 UDP**，**`MIN/MAX`** 连续区间覆盖 |

修改方式示例（在 **`docker compose up` 前** 与 **安全组** 同时改）：

```bash
export PORT=3010
export MEDIASOUP_RTC_MIN_PORT=50000
export MEDIASOUP_RTC_MAX_PORT=50999
docker compose up -d --force-recreate
```

则安全组需增加或改为：**TCP `3010/3010`**、**UDP `50000/50999`**（并删除或避免与旧规则冲突，以控制台实际生效规则为准）。

---

#### 1.2.5 Redroid 与 TCP 5555（ADB）

本仓库根目录 **`docker-compose.yml`** 中 Redroid 的 ADB 默认只绑 **`127.0.0.1:5555`**，**不暴露公网**，因此 **一般不需要** 在安全组放行 **5555**。

若你自行把 ADB 改成 **`0.0.0.0:5555`** 或映射到宿主机公网端口，才需要 **入方向 TCP 5555**（或你映射的端口），并承担 **未授权访问云手机** 的风险；推荐继续用 **SSH 本地转发** 连 ADB（见 §5、`scripts/remote-adb-tunnel.sh`）。

---

#### 1.2.6 汇总对照表（便于复制核对）

| 名称 | 协议 | 端口范围（默认） | 授权对象（示例） | 用途 |
|------|------|------------------|------------------|------|
| SSH | TCP | **22/22** | `0.0.0.0/0` 或固定 IP/32 | 登录 ECS |
| SFU 页面/信令 | TCP | **`3000/3000`**（随 `PORT`） | `0.0.0.0/0` 或收紧 | HTTP + WebSocket |
| Caddy / Let’s Encrypt（可选，§4.2） | TCP | **`80/80`** | `0.0.0.0/0` 或收紧 | 证书签发校验 |
| Caddy HTTPS（可选，§4.2） | TCP | **`443/443`** | `0.0.0.0/0` 或收紧 | 公网 `https://` 访问试点 |
| mediasoup 媒体 | UDP | **`40000/49999`**（随 `MEDIASOUP_RTC_*`） | `0.0.0.0/0` 或收紧 | WebRTC RTP |
| ADB（仅当你主动暴露时） | TCP | **5555/5555** 或你的映射口 | 强烈不建议 `0.0.0.0/0` | 非默认；见 §1.2.5 |

**排错提示**：页面能开、无画面 → 先查 **UDP 规则** 与 **`MEDIASOUP_ANNOUNCED_IP` 是否为当前 EIP**。

### 1.3 配完后自检

在 **ECS 内**（SSH 登录后）确认服务监听：

```bash
curl -sI -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/
```

若返回 **200**（或 3xx），再在 **个人电脑** 上访问 `http://你的EIP:3000/`。  
若在 **本机** 对 `127.0.0.1:3000` 做 `curl`：**测的是本机**，不是 ECS——见 §4 中「外网浏览器打不开」一段。

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

#### 2.4.1 加速器已配置但仍 `403 Forbidden`（`docker.io/library/...`）

部分账号下，个人版加速器对 **Docker Hub 上某些镜像**（如 `hello-world`、`node:20-bookworm`）会返回 **403**，`docker compose build` 卡在 **`FROM node:...`** 即属此类。

**处理（任选或组合）：**

1. **`registry-mirrors` 写多条**，Docker 会依次尝试（第一条仍用你的阿里云地址；第二条请换成你信任的公开 Hub 镜像源，以下仅为格式示例）：  

```bash
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://xxxxxxxx.mirror.aliyuncs.com",
    "https://docker.1ms.run"
  ]
}
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

将 **`xxxxxxxx`** 换成你的专属前缀；**第二条** 若不可用可换其它公开镜像文档中提供的地址，或咨询你所在网络环境可用的 Hub 代理。

2. **ACR 控制台**：确认 **镜像加速 / 访问凭证** 是否要求 **`docker login`** 后再拉 Hub；按页面说明对 **Registry 地址** 登录（以控制台为准）。

3. **临时验证**：备份 `daemon.json` 后 **暂时去掉 `registry-mirrors`**，重启 Docker，再 **`docker pull node:20-bookworm`**。若直连可拉，说明问题在加速器策略，可长期用 **多 mirror** 或 **ACR 镜像同步** 自建 `node` 基础镜像。

4. **`webrtc-sfu-pilot` 仍拉不到 `node:20-bookworm`**：本仓库的 Dockerfile 支持 **`NODE_IMAGE` 构建参数**（`docker-compose.yml` 已传入）。在 ECS 上可换一条你能拉通的基础镜像再构建（第三方镜像源可能随时间变化，**以你环境实测为准**）：

```bash
cd /opt/wayphone/experiments/webrtc-sfu-pilot
export NODE_IMAGE=docker.m.daocloud.io/library/node:20-bookworm
export MEDIASOUP_ANNOUNCED_IP=你的EIP
export PORT=3000
docker compose build --no-cache
docker compose up -d
```

或单行：`NODE_IMAGE=docker.m.daocloud.io/library/node:20-bookworm docker compose up --build`。

仍失败时：在能访问 Docker Hub 的机器执行 **`docker pull node:20-bookworm && docker save -o node-20-bookworm.tar node:20-bookworm`**，将 tar 拷到 ECS 后 **`docker load -i node-20-bookworm.tar`**，再将 **`NODE_IMAGE=node:20-bookworm`** 且 **`daemon.json` 暂时不要指向会 403 的加速器**（或清空 `registry-mirrors` 后重启 Docker）。

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

**外网浏览器打不开（连接超时 / 无法访问）**：先在 **ECS 上**执行 `curl -sI http://127.0.0.1:3000`（或 `curl -sI http://127.0.0.1:${PORT:-3000}`）。若 **本机通、外网不通**，依次查：① **安全组** 是否按 **§1** 放行 **TCP 3000**（及 WebRTC 所需 **UDP 40000–49999**）；② 该实例是否已绑定你正在访问的 **EIP**；③ 系统 **`ufw status`** / **firewalld** 是否拦截（见 [linux-cloud-lab.md §2](linux-cloud-lab.md)）。**勿在个人电脑上对 `127.0.0.1:3000` 测 ECS**（除非已做 SSH `-L` 转发），见 **§1.3**。

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

### 4.2 公网 HTTPS「一条链接」访问试点（Caddy，今日可落地）

目标：手机/他人浏览器直接打开 **`https://某个主机名/`** 即可用页面 + **发布摄像头**（安全上下文），**不必**再 SSH 转发。试点前端已按页面协议自动选 **`wss://`**（见 `public/app.mjs`）。

**你需要：**

1. **主机名解析到当前 EIP**（二选一）  
   - **自有域名**：控制台把 **`A` 记录** 指到 ECS 的 **EIP**。  
   - **免备案 PoC（nip.io）**：公网 IP 把 **点改成横杠** 再加 **`.nip.io`**。  
     - 例：EIP `8.163.51.24` → 主机名 **`8-163-51-24.nip.io`**（全球 DNS 会解析回该 IP，无需买域名）。

2. **安全组入方向** 在 §1 基础上 **再放行**（Let’s Encrypt 与 HTTPS）：  
   - **TCP `80/80`**（证书签发 HTTP 校验）  
   - **TCP `443/443`**（HTTPS）  
   与 §1.2 一样，授权对象 PoC 可 `0.0.0.0/0`，后续再收紧。

3. **ECS 上已跑通** `webrtc-sfu-pilot`（`docker compose up -d`，监听 **`PORT`**，默认 3000）。**`MEDIASOUP_ANNOUNCED_IP` 仍填 EIP（数字 IP）**，不要改成域名——WebRTC 媒体面 UDP 仍指向该 IP；HTTPS 只解决「页面 + 信令」的安全上下文。

在同一目录启动 Caddy（与主 `docker-compose.yml` **分开** 的第二份 compose，项目名 `webrtc-sfu-caddy`，互不覆盖 SFU 容器）：

```bash
cd /opt/wayphone/experiments/webrtc-sfu-pilot
# 将下面域名换成你的 A 记录 或 nip.io 主机名
export CADDY_DOMAIN=8-163-51-24.nip.io
export UPSTREAM_PORT=3000
docker compose -f docker-compose.caddy.yml up -d
docker compose -f docker-compose.caddy.yml logs -f
```

浏览器访问：**`https://你的CADDY_DOMAIN/`**（首次 Let’s Encrypt 可能要等几十秒；失败时查 **80 是否放行**、**域名是否已解析到本机 EIP**、本机 **`ss -tlnp | grep -E ':80|:443'`** 是否被其它进程占用）。

停止 Caddy：`docker compose -f docker-compose.caddy.yml down`。

**说明**：证书依赖 **Let’s Encrypt** 与 ECS **出网**；若你网络环境拦截 ACME，可改用自有证书或换部署区再试。仓库内文件：**`Caddyfile`**、**`docker-compose.caddy.yml`**。

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
