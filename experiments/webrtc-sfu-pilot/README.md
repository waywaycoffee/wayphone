# webrtc-sfu-pilot

**Layer A + B**：mediasoup **Worker / Router** + **WebSocket 信令** + 浏览器 **`mediasoup-client`**，实现 **摄像头 → SFU → 另一 Tab / 另一台浏览器** 的最小闭环。

**不是**：Redroid / 安卓画面采集、触控回注、商用房间与鉴权（**Layer C** 见仓库根目录 **`docs/layer-c-roadmap.md`**）。

## 本地运行

```bash
npm install
npm run build:client
npm start
# 或 PORT=3010 npm start
```

浏览器打开 `http://127.0.0.1:3000/`（端口以终端日志为准）：

1. **Tab 1**：点「发布摄像头」，允许摄像头。  
2. **Tab 2**：点「仅观看」，应出现经 SFU 转发的远端画面。

**局域网其它设备**访问时，在服务端进程环境设置 **`MEDIASOUP_ANNOUNCED_IP=<服务器局域网IP>`**，否则 WebRTC 可能无法连通。

用浏览器直接打开 **`http://公网IP:3000`** 时，多数环境**无法「发布摄像头」**（`navigator.mediaDevices` 被禁用）；请用 **`http://127.0.0.1:3000` + SSH 端口转发**，或 **HTTPS**，见 **`docs/webrtc-sfu-pilot.md` §3.2**。

## Docker（Linux，可选）

```bash
export MEDIASOUP_ANNOUNCED_IP=192.168.x.x
docker compose up --build
```

国内镜像对 **`library/node`** 出现 **403 / not found** 时，可换基础镜像再构建（示例）：

```bash
export NODE_IMAGE=docker.m.daocloud.io/library/node:20-bookworm
docker compose up --build
```

详见 **`docs/aliyun-ecs-pilot.md` §2.4.1**。

### Layer C1 PoC（FFmpeg → PlainTransport，浏览器「仅观看」）

不经过浏览器摄像头，验证 **RTP → SFU → consume**：

```bash
sudo apt-get install -y ffmpeg   # ECS 宿主机
export MEDIASOUP_INGEST_TEST=1
export MEDIASOUP_ANNOUNCED_IP=你的EIP
docker compose up -d --build
docker compose logs --tail=30
```

**推荐（默认）**：在 **与 Docker 同一台 ECS 宿主机**、**本目录**执行 **`bash scripts/run-c1-ffmpeg-ingest.sh`**（或 **`npm run c1:ingest`**）。脚本会读取 **`docker compose logs`**（及容器 `docker logs`），解析当次 **`ffmpeg-ingest-h264.sh <host> <port>`** 或 **`mediasoup RTP tuple:`**，再启动 FFmpeg，**避免容器重启后端口变化还要手抄**。  
**备选**：终端里若已打印 **`bash scripts/ffmpeg-ingest-h264.sh …`**，也可原样执行（排错、或无 compose 时）。浏览器打开页面后 **只点「仅观看」**。说明：**`docs/layer-c-roadmap.md`** §C1.1。

### 公网 HTTPS 一条链接（可发摄像头）

不依赖 SSH 转发时：用 **Caddy** 在 443 上自动证书，浏览器打开 `https://你的域名/`。仓库内 **`docker-compose.caddy.yml`** + **`Caddyfile`**；**`MEDIASOUP_ANNOUNCED_IP` 仍填 EIP**。完整步骤：**`docs/aliyun-ecs-pilot.md` §4.2**。

若已 `cd` 本目录仍出现 **`no configuration file provided`**（常见于 **Snap** 安装的 Docker），请用：

```bash
bash ./docker-up.sh
# 或见 docs/aliyun-ecs-pilot.md 中的绝对路径 docker compose 命令
```

若 **`docker compose` 报 `open …/docker-compose.yml: no such file or directory`**（而 `ls` 能看到该文件），多为 **Snap 读不到 `/opt` 等目录**；把本仓库放到 **`$HOME/wayphone`** 下再跑 compose，或换 **APT 官方 Docker**（见 `docs/aliyun-ecs-pilot.md` §2.1）。

使用 **host 网络**；需 Linux 且 Docker 支持 `network_mode: host`。

云机安全组、防火墙端口、`MEDIASOUP_ANNOUNCED_IP` 与 Redroid 并行说明：仓库根目录 **[docs/linux-cloud-lab.md](../../docs/linux-cloud-lab.md)**。

## 仓库根目录 smoke

```bash
bash scripts/smoke-webrtc-sfu-pilot.sh
PORT=3010 bash scripts/smoke-webrtc-sfu-pilot.sh
```

## 依赖

- Node.js ≥ 18（与 [mediasoup 安装要求](https://mediasoup.org/documentation/v3/mediasoup/installation/) 一致）。  
- `npm run build:client` 使用 **esbuild** 生成 `public/mediasoup-client.esm.js`（已加入 `.gitignore`，勿手抄进仓库）。
