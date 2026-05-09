# Layer C1（FFmpeg → PlainTransport → 浏览器仅观看）经验总结

本文记录 **webrtc-sfu-pilot** 在 ECS / Docker 上跑 C1 时，曾出现的 **「FFmpeg 在推、UDP 有量，但 SFU 侧 `rtpBytesReceived` 不涨、浏览器黑屏」** 的排查结论与操作习惯，避免以后再踩 **`git pull` 与容器内代码不同步** 这类坑。

---

## 1. C1 在验证什么

- **不经过**浏览器摄像头，用 **FFmpeg** 向 **mediasoup `PlainTransport`** 打 **RTP**，SFU **`produce`** 后，浏览器只 **`consume`**（「仅观看」）。
- 目标：证明 **RTP → SFU → WebRTC 观看端** 整条链路可用。

---

## 2. 典型现象（如何描述问题）

| 观察 | 含义 |
|------|------|
| 宿主机 `ffmpeg` 在跑，或 `tcpdump` 能看到发往 ingest 端口的 RTP | 推流侧大致正常 |
| `PlainTransport` 统计里 **`bytesReceived` 很大**，但 **`rtpBytesReceived` 长期为 0** | UDP 到了 transport，**RTP 层没有按预期被 mediasoup 计入**（常与 **RTCP / mux**、或 **旧 server 逻辑** 有关） |
| 浏览器 **黑屏**，`framesDecoded=0` | 上游 ingest 未形成有效 producer 统计时，观看端自然无解码帧 |

**注意：** 浏览器里看到的 **RTP payload type** 与 FFmpeg 的 **`-payload_type`** 不必相同；**ingest 侧 PT** 必须与 FFmpeg 一致。**先解决 `rtpBytesReceived`**，再谈解码兼容性（H264 profile / VP8 等）。

---

## 3. 根因一：`git pull` 更新了宿主机，但容器里仍是旧 `server.cjs`

### 为什么会这样

- **`git pull`** 只更新**仓库工作区**里的文件（例如 `experiments/webrtc-sfu-pilot/server.cjs`）。
- Docker 镜像在 **`docker compose build`**（或 `docker build`）时，通过 **`Dockerfile` 里的 `COPY server.cjs`** 把**当时**的 `server.cjs` **拷贝进镜像层**。
- 之后 **`docker compose up`** 若沿用**旧镜像**，容器内 **`/app/server.cjs`** 不会随宿主机 `git pull` 自动变。

### 曾出现的误判

- **`.env`** 里已设置 **`MEDIASOUP_INGEST_RTCP_MUX=0`**，`docker exec … printenv` 也显示 `0`。
- 但 **`docker compose logs`** 里**始终没有**与新逻辑对应的日志（例如 **`rtcpMux=false`**、**`ingest_rtcp_port=…`**）。
- 这时要怀疑：**镜像里的 `server.cjs` 仍是旧版本**，而不是「环境变量没进容器」。

### 建议操作

```bash
cd experiments/webrtc-sfu-pilot
git pull
docker compose build --no-cache
docker compose up -d --force-recreate
```

### 快速对指纹（可选）

在宿主机与容器内各搜一段**仅新版本才有**的字符串，应一致：

```bash
grep -n 'ingest_rtcp_port' server.cjs
docker compose ps -q   # 取容器 id
docker exec <容器id> grep -n 'ingest_rtcp_port' /app/server.cjs
```

不一致 → **必须重新 build**，不能只 `up`。

---

## 4. 根因二：FFmpeg 与 PlainTransport 的 **RTCP** 约定（mux vs 分流）

### 结论（与 mediasoup-demo 对齐）

- 在 **`.env`** 中推荐 **`MEDIASOUP_INGEST_RTCP_MUX=0`**：**RTP 端口与 RTCP 端口分离**。
- **`server.cjs`** 中对应 **`createPlainTransport({ rtcpMux: false })`**，并打出 **`ingest_rtcp_port`** 供 FFmpeg URL 使用 **`rtcpport=…`**（与 **mediasoup-demo** 式 **三端口** 一致）。
- **`run-c1-ffmpeg-ingest.sh --local`** 应在日志解析到 RTCP 端口时，自动把**第三参数**传给 **`ffmpeg-ingest-h264.sh` / `ffmpeg-ingest-vp8.sh`**。

### 为何默认 `RTCP_MUX=1` 时可能「UDP 有量、rtp 不涨」

部分环境下 **FFmpeg 与 mediasoup 对「同端口 mux RTCP」** 的契合度不如 **显式 RTP + RTCP 两端口**。表现为 **底层 UDP 统计上涨**，但 **RTP 计入 `rtpBytesReceived` 仍为零**；改为 **分流 + 重建镜像** 后，`rtpBytesReceived` 开始持续增长，浏览器方可解码出画面。

---

## 5. 根因三：`run-c1-ffmpeg-ingest.sh` 版本与 `pipefail`

旧脚本在 **`set -euo pipefail`** 下对 **`ingest_rtcp_port=`** 做 **grep**，当 **`MEDIASOUP_INGEST_RTCP_MUX=1`**（默认无该行日志）时 **grep 退出码为 1**，整段脚本提前退出，**FFmpeg 从未启动**，表现为 **`run-c1` 立刻回到 shell**，而手动跑 **`ffmpeg-ingest-h264.sh`** 却正常。

修复后应：**仅在需要时解析 RTCP 端口**；**ingest codec 未 export 时默认与仓库一致（如 h264）**；**日志收集**避免重复拼接。

**习惯：** 在 ECS 上 **`git pull`** 后确认 **`scripts/run-c1-ffmpeg-ingest.sh`** 已更新；推流前 **`export MEDIASOUP_INGEST_CODEC=h264`**（或 `vp8`）与容器 **`MEDIASOUP_INGEST_CODEC`** 一致。

---

## 6. 其他常见点（简要）

| 主题 | 建议 |
|------|------|
| **UDP hairpin** | 与 Docker **同一台 ECS 宿主机**上跑 FFmpeg 时，目标用 **`127.0.0.1:<RTP端口>`**，避免长期用本机 EIP 打自己 |
| **H264 黑屏 / `framesDecoded=0`**（在 **`rtpBytesReceived` 已涨** 的前提下） | 尝试 **`MEDIASOUP_INGEST_CODEC=vp8`** 做对照 |
| **`.env` 与 compose 默认值** | 历史在 `.env` 里 **pin** 了 `MEDIASOUP_INGEST_CODEC` / `PILOT_VERSION` 时，会与 `docker-compose.yml` 预期不一致；可用仓库内 **`pilot-env-unpin-compose-defaults.sh`**、**`pilot-env-ensure-h264-ingest.sh`**、**`pilot-c1-h264-bootstrap.sh`** 等脚本纠偏 |

---

## 7. 部署与验收清单（可照抄）

1. **`git pull`**（宿主机与仓库路径正确：`experiments/webrtc-sfu-pilot`）。
2. 确认 **`.env`**：`MEDIASOUP_INGEST_TEST=1`、`MEDIASOUP_ANNOUNCED_IP`、**`MEDIASOUP_INGEST_RTCP_MUX=0`**（C1 FFmpeg 推荐）、**`MEDIASOUP_INGEST_CODEC`** 与宿主机 export 一致。
3. **`docker compose build --no-cache && docker compose up -d --force-recreate`**（**改过 `server.cjs` 必做**）。
4. 日志中出现 **`Layer C1 PlainTransport rtcpMux=false`** 与 **`ingest_rtcp_port=…`**（与 mux=0 配置一致）。
5. **`bash scripts/run-c1-ffmpeg-ingest.sh --local`**（或按日志手动三参 FFmpeg）。
6. **`docker compose logs`** 中 **`rtpBytesReceived` 持续上涨**；浏览器 **仅观看** 后 **`framesDecoded` > 0**。
7. 一键辅助：**`npm run pilot:ingest-debug`**（需仓库内已包含该 npm script）。

---

## 8. 一句话记忆

**`git pull` 更新的是磁盘上的仓库；容器里跑的是镜像里 `COPY` 进去的那份代码。改 `server.cjs` 后必须 `build` + `recreate`。C1 FFmpeg ingest 推荐 RTCP 分流（`MEDIASOUP_INGEST_RTCP_MUX=0`）并与脚本三端口对齐。**

---

## 9. 相关文档

- 路线图：**`docs/layer-c-roadmap.md`**（仓库根目录）§C1  
- 试点总说明：**`docs/webrtc-sfu-pilot.md`**（仓库根目录）  
- 本目录 README：**`../README.md`** §Layer C1  

---

## 10. 复发时复位顺序（彩条曾通、现在又黑 / `rtpBytesReceived` 不涨）

**不要**用「几小时前的」`41595` 等端口手抄跑 FFmpeg；**容器每重建一次端口就变**，必须用当次日志或 **`run-c1`**。

在 **`experiments/webrtc-sfu-pilot`** 目录依次执行：

```bash
git pull origin main

# 核对 .env（无则 export）：INGEST_TEST=1、ANNOUNCED_IP=EIP、RTCP 分流、codec 一致
grep -E '^MEDIASOUP_INGEST_TEST|^MEDIASOUP_ANNOUNCED_IP|^MEDIASOUP_INGEST_RTCP_MUX|^MEDIASOUP_INGEST_CODEC' .env 2>/dev/null || true

docker compose build --no-cache
docker compose up -d --force-recreate

docker compose logs --tail=120 webrtc-sfu-pilot | grep -E 'rtcpMux=false|ingest_rtcp_port|mediasoup RTP tuple'
```

确认日志里 **有** `rtcpMux=false` 与 **`ingest_rtcp_port=…`**（与 **`.env` 里 `MEDIASOUP_INGEST_RTCP_MUX=0`** 一致）。若没有，回到 **§3**（镜像仍是旧 `server.cjs`）。

**停掉**宿主机上所有旧 `ffmpeg` / 旧 ingest 终端后：

```bash
export MEDIASOUP_INGEST_CODEC=h264
npm run c1:ingest -- --local
```

另开 SSH：**仅观看** 后看 **`rtpBytesReceived` 是否持续上涨**：

```bash
docker compose logs --tail=80 webrtc-sfu-pilot | grep -E 'PlainTransport stats|FFmpeg→SFU|rtpBytesReceived'
```

- **仍不涨**：对照 **§4 RTCP mux**、**§5 run-c1 脚本**；宿主机 **`tcpdump -ni lo udp port <RTP端口>`** 是否在 ingest 运行时有包。  
- **在涨仍黑屏**：再试 **`MEDIASOUP_INGEST_CODEC=vp8`** + **`npm run c1:ingest`**（§6）；并查云安全组 **UDP 40000–49999** 与 **`MEDIASOUP_ANNOUNCED_IP=EIP`**。
