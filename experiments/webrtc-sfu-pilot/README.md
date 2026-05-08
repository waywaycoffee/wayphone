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

## 本地维护 `.env` 并上传到 ECS（跟仓库走）

仓库根目录 **`.gitignore` 已忽略 `.env`**：你在本机改 **`experiments/webrtc-sfu-pilot/.env`** 不会进 Git，**不要** `git add .env`；与 **`docker-compose.yml` / `server.cjs` 默认值** 的同步由你在本机文件里控制，再上传到服务器即可。

**本机（克隆仓库后，在试点目录）：**

```bash
cd experiments/webrtc-sfu-pilot
cp .env.pilot.example .env
# 用编辑器改 .env：至少 MEDIASOUP_ANNOUNCED_IP、MEDIASOUP_INGEST_TEST=1、MEDIASOUP_INGEST_CODEC=h264 等
```

**上传到 ECS（把 `root`、`EIP`、路径换成你的）：**

```bash
scp experiments/webrtc-sfu-pilot/.env root@EIP:/opt/wayphone/experiments/webrtc-sfu-pilot/.env
# 或 rsync：
# rsync -avz experiments/webrtc-sfu-pilot/.env root@EIP:/opt/wayphone/experiments/webrtc-sfu-pilot/.env
```

**ECS 上（SSH 登录后）：**

```bash
cd /opt/wayphone && git pull origin main
cd experiments/webrtc-sfu-pilot
docker compose config | grep -E 'MEDIASOUP_|PILOT_VERSION'
docker compose build --no-cache && docker compose up -d --force-recreate
```

**注意**：`.env` 里若写 **`PILOT_VERSION=`**，会盖住 compose 默认，容易出现「仓库已 bump、**`curl __pilot_version` 仍是旧字母**」；一般**不要写**，除非你要长期固定展示名。前端 **`FRONTEND_BUILD`** 在 **`public/app.mjs`** 里，随 **`docker compose build`** 进镜像，**不读** `.env`。

## Docker（Linux，可选）

若本目录存在 **`.env`** 且写过 **`PILOT_VERSION=`** / **`MEDIASOUP_INGEST_CODEC=`**，会**永久盖住** `docker-compose.yml` 里的默认值，表现为版本字母「追不上」、ingest _codec 与预期不一致。可执行：

```bash
bash scripts/pilot-env-unpin-compose-defaults.sh --dry-run   # 先看会删哪些行
bash scripts/pilot-env-unpin-compose-defaults.sh
```

**先固定整条 C1 为 H264**（去掉历史 `vp8` 再写入 `h264`）：

```bash
bash scripts/pilot-env-ensure-h264-ingest.sh --dry-run
bash scripts/pilot-env-ensure-h264-ingest.sh
```

再 **`docker compose build --no-cache && docker compose up -d --force-recreate`**。新环境可复制 **`cp .env.pilot.example .env`** 只改 `MEDIASOUP_ANNOUNCED_IP` 等；宿主机跑 FFmpeg 前仍建议 **`export MEDIASOUP_INGEST_CODEC=h264`**，与容器一致。

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

不经过浏览器摄像头，验证 **RTP → SFU → consume**。

#### 推荐：一条命令整理 `.env` + 固定 **H264**（解决「.env 与仓库不同步、总有 VP8」）

在 **`experiments/webrtc-sfu-pilot`** 目录（把 **`8.163.51.24`** 换成你的 **EIP / 浏览器可达 IP**）：

```bash
bash scripts/pilot-c1-h264-bootstrap.sh 8.163.51.24
# 可选：Router 只留 H264，彻底避免 VP8 进协商
bash scripts/pilot-c1-h264-bootstrap.sh 8.163.51.24 --router-h264-only
```

然后按脚本结尾提示执行 **`docker compose build --no-cache`**、**`run-c1`**。  
说明：**`git pull` 不会改你服务器上的 `.env`**；以后每次大改试点，可再跑一次 bootstrap，或只用 **`pilot-env-unpin-compose-defaults.sh`** / **`pilot-env-ensure-h264-ingest.sh`** 做局部修正。

---

手动方式（等价于心智模型）：

```bash
sudo apt-get install -y ffmpeg   # ECS 宿主机
export MEDIASOUP_INGEST_TEST=1
export MEDIASOUP_ANNOUNCED_IP=你的EIP
docker compose up -d --build
docker compose logs --tail=30
```

**推荐（默认）**：在 **与 Docker 同一台 ECS 宿主机**、**本目录**执行 **`bash scripts/run-c1-ffmpeg-ingest.sh`**（或 **`npm run c1:ingest`**）。脚本会读取 **`docker compose logs`**（及容器 `docker logs`），解析当次 **`ffmpeg-ingest-h264.sh <host> <port>`** 或 **`mediasoup RTP tuple:`**，再启动 FFmpeg，**避免容器重启后端口变化还要手抄**。  
**备选**：终端里若已打印 **`bash scripts/ffmpeg-ingest-h264.sh …`** 或 **`ffmpeg-ingest-vp8.sh`**，也可原样执行（排错、或无 compose 时）。浏览器打开页面后 **只点「仅观看」**。说明：**`docs/layer-c-roadmap.md`** §C1.1。

**黑屏但日志里 `transport.getStats` 有 bytes、`framesDecoded=0`**：多为 FFmpeg→H264→Chrome 解码不兼容；可设 **`MEDIASOUP_INGEST_CODEC=vp8`** 并 **`run-c1-ffmpeg-ingest.sh`**。**同 ECS 宿主机**上 FFmpeg 请打 **`127.0.0.1:端口`**（脚本默认如此），勿长期用「本机 EIP」——云上 **UDP hairpin** 常导致 SFU 收不到 RTP。ECS 的 **`ffmpeg` 需带 libvpx**（一般 `apt install ffmpeg` 即可）。

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
