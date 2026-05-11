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

**部署指纹（前后端一致）**：只在 **`package.json` 的 `pilotVersion`** 改一处；**`npm run build:client`** 会先跑 **`scripts/sync-pilot-version.cjs`**，把 **`public/index.html`** 里占位 **`pilot-00000000sync`** 全部替换为该值（含 `<meta name="pilot-frontend-version">` 与 `app.mjs` 的 `?v=`）。**`public/app.mjs`** 运行时读 meta，仓库内不写死版本串。**`server.cjs`** 的 **`__pilot_version`** 也读 `package.json`。**Dockerfile** 在 `COPY public` 后执行 **`npm run build:client`**，镜像内会自动对齐。`.env` 里**不要**写 **`PILOT_VERSION`**，除非要临时覆盖。

**本地跑 SFU**：请用 **`npm start`**（会先执行 **`prestart` → `build:client`**，同步版本并打包 `mediasoup-client.esm.js`）。不要直接 **`node server.cjs`**，否则 `index.html` 可能仍是占位 **`pilot-00000000sync`** 且缺少 bundle。

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

**掌厅 APK 路径**：放在 **`source app/10086_10.2.1.apk`**（相对本目录 `experiments/webrtc-sfu-pilot/`；目录名含空格，路径请加引号）。  
- 在 **本目录** 安装：`adb -s 127.0.0.1:5555 install -r -g "source app/10086_10.2.1.apk"`  
- 在 **仓库根目录** 安装：`adb -s 127.0.0.1:5555 install -r -g "experiments/webrtc-sfu-pilot/source app/10086_10.2.1.apk"`  
（`*.apk` 已写入仓库根 `.gitignore`，勿 `git add` APK。）  

**掌厅启动后系统弹窗「Allow … access all device logs?」**：多设备时先 **`export ANDROID_SERIAL=127.0.0.1:5555`**。仅等待并自动点 **「Allow one-time access」**：**`npm run adb:dismiss-log-dialog`**（你已自行 `am start` 后执行）；一键 **启动掌厅再点允许**：**`npm run adb:start-zhangting-dismiss-log-dialog`**。实现见 **`scripts/adb-dismiss-log-access-dialog.sh`**（解析 `android:id/log_access_dialog_allow_button` 的 `bounds`；解析失败时用 **`LOG_DIALOG_FALLBACK_X` / `LOG_DIALOG_FALLBACK_Y`**，默认 `360`/`1042` 对应 720×1280 实测）。若应用仍 **SIGSEGV** 秒退，属 APK/Redroid native 问题，授权脚本无法修复。

**彩条 → Redroid/真机画面（掌厅等）**：宿主机需 **`adb devices` 为 `device`**（与 Redroid 同机时常为 `127.0.0.1:5555`）。可先 **`npm run c1:check:adb`** 自检。在同一目录执行 **`npm run c1:ingest:adb -- --local`**（等价于 `C1_INGEST_SOURCE=adb` + `run-c1`），将用 **`scripts/ffmpeg-ingest-h264-adb-screenrecord.sh`**：`adb exec-out screenrecord --output-format=h264` 管道进 FFmpeg，**libx264 baseline** 重编码后仍发往 **同一 PlainTransport RTP 端口**（ingest 仅 H264；若 `.env` 为 VP8 请改 **h264** 与 Router 一致）。多设备时 **`export ANDROID_SERIAL=序列号`**；分辨率/码率见脚本内 **`SCREENRECORD_*`** 环境变量。`screenrecord` 行为随 ROM 变化，若黑屏先看 **`adb exec-out screenrecord --output-format=h264 -`** 是否在本机可持续出字节。

**ingest 自行断开**（`pgrep ffmpeg` 突然无输出）：多为 **adb 管道 EOF**（`screenrecord` 结束、设备断连、Redroid 限制）。可改用 **`npm run c1:ingest:adb:loop`**（`scripts/run-c1-ingest-adb-loop.sh`）：退出后 **`C1_INGEST_LOOP_SLEEP` 秒（默认 2）** 自动重拉 `run-c1` 并再起 FFmpeg。**注意**：若 **SFU 容器重启、RTP 端口变了**，循环只会重启 FFmpeg，仍可能打到旧端口；此时应 **停掉 loop → 再起 pilot → 再起 loop**。排错时用 **`ADB_SCREENRECORD_STDERR=/dev/stderr`**。

**多台 `adb devices` 时**：**必须先 `export ANDROID_SERIAL=127.0.0.1:5555`** 再跑 **`c1:ingest:adb` / `c1:ingest:adb:loop`**。勿写成 **`pidof … && npm run …`** 且未在同一 shell 里 export——子进程 **继承不到** 你以为设过的变量（若 export 写在上一行但未执行/在别的终端则仍为空）。loop 脚本在 **>1 台 device 且未设 ANDROID_SERIAL** 时会 **直接退出** 并提示，避免每 2 秒刷屏。

**查「为什么退出」**（`git pull` 后）：ADB ingest 脚本在管道结束时会向 stderr 打一行 **`ingest 管道结束: adb_exit=… ffmpeg_exit=…`**。再配合：**`ADB_SCREENRECORD_STDERR=/dev/stderr`**（看 screenrecord 报错）、**`FFMPEG_LOGLEVEL=info`**（看 FFmpeg 细节）、宿主机 **`dmesg | tail`**（是否 OOM killer）、**`adb devices`**（是否仍 `device`）。常见：**screenrecord 自行结束**（部分 ROM 时长/策略）→ adb 侧先关 → FFmpeg stdin EOF → 进程退出。

**RTCP 有包、RTP 口 tcpdump 无包**：多为 **screenrecord→FFmpeg stdin 断流**（非 SFU/NVENC/SELinux）。一键采样：**`export ANDROID_SERIAL=127.0.0.1:5555`** 后 **`npm run c1:diagnose:adb`**（`scripts/diagnose-adb-screenrecord.sh`，默认录约 12s 到 `/tmp/diag-screenrecord-*.h264` 并扫 stderr 关键字）。

**黑屏但日志里 `transport.getStats` 有 bytes、`framesDecoded=0`**：多为 FFmpeg→H264→Chrome 解码不兼容；可设 **`MEDIASOUP_INGEST_CODEC=vp8`** 并 **`run-c1-ffmpeg-ingest.sh`**。**同 ECS 宿主机**上 FFmpeg 请打 **`127.0.0.1:端口`**（脚本默认如此），勿长期用「本机 EIP」——云上 **UDP hairpin** 常导致 SFU 收不到 RTP。ECS 的 **`ffmpeg` 需带 libvpx**（一般 `apt install ffmpeg` 即可）。

**`video-bytes` 只有约 1 万且 1s/3s 几乎不涨**：多表示 **SFU 侧 ingest 没在持续收 RTP**（或端口/进程不是当前这次启动的），不是单纯「解码慢」。请 **先** 在 ECS 上看容器日志（仅观看后约 2s 会打两行）：  
`docker compose logs --tail=80 webrtc-sfu-pilot | grep -E 'PlainTransport stats|FFmpeg→SFU|rtpBytesReceived'`  
- 若 **`rtpBytesReceived` 几乎为 0**：宿主机 **`npm run c1:ingest:adb` / `c1:ingest` 是否仍在跑**、**端口是否与本次 `docker compose` 日志里的 `mediasoup RTP tuple` 一致**（容器重启后端口会变，须重跑 `run-c1`）。  
- 若 **`rtpBytesReceived` 在涨** 但浏览器仍 `framesDecoded=0`：再试 **`MEDIASOUP_INGEST_CODEC=vp8`** + 彩条 **`npm run c1:ingest`** 验证链路；ADB  ingest 目前仅 H264。

#### C1 实践经验（排障与部署习惯）

曾出现：**FFmpeg 在推、PlainTransport `bytesReceived` 很大，但 `rtpBytesReceived=0`、浏览器黑屏**。常见组合原因包括：**镜像内仍是旧 `server.cjs`（只 `git pull` 未 `build`）**、**ingest 建议 `MEDIASOUP_INGEST_RTCP_MUX=0` 与 FFmpeg 三端口对齐**、**`run-c1` 脚本版本过旧（`pipefail` + grep）**。

**完整总结（现象表、根因、清单、验证命令）见：** [`docs/layer-c1-lessons-learned.md`](docs/layer-c1-lessons-learned.md)。

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
