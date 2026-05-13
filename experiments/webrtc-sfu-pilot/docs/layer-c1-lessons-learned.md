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

---

## 11. Redroid Android 9：串流分层找因（先断在哪一层）

换 **Android 9** 后仍要**按层验证**，避免把「掌厅 native 崩溃」与「SFU / RTP 不通」混在一起猜。

| 顺序 | 验证什么 | 通过标准 | 失败时优先怀疑 |
|------|----------|----------|----------------|
| **0** | 版本 | `adb shell getprop ro.build.version.sdk` → **28** | `.env` 里 `REDROID_IMAGE` 未生效、容器未重建 |
| **B** | Layer B（两 Tab 摄像头） | Tab2 能看到 Tab1 画面 | `MEDIASOUP_ANNOUNCED_IP`、安全组 **UDP 40000–49999**、浏览器是否 `127.0.0.1` 转发（见 `docs/webrtc-sfu-pilot.md` §3.2） |
| **C1 彩条** | FFmpeg→PlainTransport（无 adb） | `rtpBytesReceived` 涨、`framesDecoded>0` | 镜像未 **build**、**RTCP mux**、**run-c1 端口** 不是当次（§3–§5、§10） |
| **C1 adb** | `screenrecord`→FFmpeg→SFU | 同上，且画面为云机内容 | `adb` 非 **device**、多台且**无** `127.0.0.1:5555` 又未 **`ANDROID_SERIAL`/`C1_ADB_SERIAL`**、`screenrecord` 断流（`c1:diagnose:adb`）、掌厅未前台则可能只是桌面 |

**ECS 上一键前置汇总**（在 `experiments/webrtc-sfu-pilot`）：

```bash
# 多设备时一般自动选 127.0.0.1:5555；要模拟器则: export C1_ADB_SERIAL=emulator-5554
npm run c1:streaming:check
```

再按上表从 **B → 彩条 → adb** 做人工步骤；**彩条通、adb 不通** → 问题在 **采集/Redroid**；**彩条也不通** → 先修 **SFU / ingest / 网络**，不要先怪 Android 版本。

---

## 12. 黑屏 / 仅闪一帧：分层自检 A → B → C（与「pgrep ffmpeg」脱钩）

**ECS / 无 nvm、无 npm**：**不要**强依赖 **`source …/nvm.sh`**（文件可能不存在）。C1 自检直接用 **`bash scripts/run-c1-ffmpeg-ingest.sh --local`** 与 **`bash scripts/c1-sfu-stats-after-viewer.sh`**，无需在宿主机安装 **`apt install npm`**。若 **`git pull` 已最新仍缺脚本**，本机需 **`git push`** 后再拉；临时用 **`docker compose logs … | grep`** 见下文 A 步或 **`docs/aliyun-ecs-pilot.md` §4.1** 表。

目标：**先证明浏览器这条 WebRTC 腿能持续收 SFU 下发的视频 RTP**，再证明 **ADB→FFmpeg 能持续把 RTP 打进 PlainTransport**。二者分开验证，避免把「进程在跑」当成「码流在涨」。

### A. 彩条（无 ADB）：确认 SFU → 浏览器

1. **停掉**宿主机上所有往 ingest 端口打的旧 `ffmpeg`（避免打到过期端口）。
2. 容器已 **`MEDIASOUP_INGEST_TEST=1`**，`.env` 与 **`export MEDIASOUP_INGEST_CODEC=h264`**（或容器一致）对齐。
3. 在 **`experiments/webrtc-sfu-pilot`**：`npm run c1:ingest -- --local`（走 **`ffmpeg-ingest-h264.sh` 彩条**）。
4. 浏览器打开 **`http://<EIP>:3000/`**，**只点「仅观看」**，等约 8 秒。
5. **SSH**：`npm run c1:diag:sfu`（或 `bash scripts/c1-sfu-stats-after-viewer.sh`）。**多次点「仅观看」** 时 tail 里会叠多段统计，易把「旧段正常、新段全 0」拼在一起误判；请用 **`bash scripts/c1-sfu-stats-after-viewer.sh --last-consume`**（默认 tail 800，不够则 **`--last-consume 2000`**）或 **`npm run c1:diag:sfu:last`**，只看**最后一次** `consume:` 之后的块。关注：
   - **`FFmpeg→SFU`**：`packetCount` / `byteCount` 在 **1.5s 与 5s** 两行里是否**明显变大**（持续 ingest 时应持续上涨；若长期卡在几十，见下文 B）。
   - **`SFU-to-browser`**：`consumer outbound-rtp packetCount` 是否 **> 0**。
6. **浏览器**：打开 **`chrome://webrtc-internals`**，选中当前连接，看 **ICE / selected candidate pair** 是否为 **succeeded**，**inbound-rtp**（video）**bytesReceived** 是否随时间上涨。

**结论**：彩条下 **A 全过** → 浏览器腿与 ingest 端口/RTCP/codec 基本可信。**彩条过、ADB 不过** → 优先 **ADB `exec-out`、screenrecord、FFmpeg stdin/x264 节奏**，而不是再调 `MEDIASOUP_ANNOUNCED_IP`。

### B. 「只有几十包」：ADB 段长与日志

- **短段 + 易对比**：`npm run c1:ingest:adb:short`（等价 **`SCREENRECORD_TIME_LIMIT=20`** + **`run-c1 … --local`**）。配合 **`npm run c1:ingest:adb:loop`** 时可在 `.env` 或 shell 里 **`export SCREENRECORD_TIME_LIMIT=20`** 再跑 loop，缩短段间空窗。
- **看管道是否在动**：`npm run c1:ingest:adb:short:v`（**`ADB_SCREENRECORD_STDERR=/dev/stderr`** + **`FFMPEG_LOGLEVEL=info`**），看终端里 **`frame=` / `fps=`** 是否持续增长；若卡住，重点查 **screenrecord 是否只吐一小块 H264**、**FFmpeg 是否在等 stdin**。
- **SFU 侧**：再次 **`npm run c1:diag:sfu`**，看 **`FFmpeg→SFU` 的 `packetCount` 在数秒～数十秒内是否持续增长**；若一直卡在几十，与 **§2「bytesReceived 大、rtpBytesReceived 不涨」** 对照（RTCP mux / PT / 旧镜像）。

### C. Producer 有 RTP 但 consumer 仍为 0

- **webrtc-internals**：ICE、DTLS、**inbound-rtp video**。
- **云安全组**：入站 **UDP 40000–49999**；**`MEDIASOUP_ANNOUNCED_IP`** 为浏览器可达的 **公网 EIP**。
- **容器重启**：ingest **RTP 端口会变**，必须 **kill 旧 ffmpeg** 后按**当次** `docker compose logs` 里的 **`mediasoup RTP tuple` / `ingest_rtcp_port`** 再 **`npm run c1:ingest`** / **`c1:ingest:adb`**。

**一键命令索引**（均在试点目录）：`npm run c1:diag:sfu`、`npm run c1:diag:sfu:last`、`npm run c1:diag:ingest`、`npm run c1:ingest:adb:short`、`npm run c1:ingest:adb:short:v`、`npm run pilot:ingest-debug`、`npm run c1:streaming:check`。

**自动化「停干净 → 可选重建 pilot → 单路 ingest」**（避免双 ffmpeg、comedia 绑死旧源口）：`bash scripts/c1-ingest-safe.sh`（子命令 `stop` / `status` / `pilot-recreate` / `colorbar` / `adb` / `adb-loop`，可选 `--recreate-pilot`）；无 npm 时同上。Cursor 持久说明见 **`.cursor/rules/c1-ingest-safe.mdc`**。

---

## 13. Ingest 侧四步排查（可执行清单）

**一键打印命令与当前状态**（须在 **`experiments/webrtc-sfu-pilot`**）：

```bash
npm run c1:diag:ingest
# 或: bash scripts/c1-ingest-checklist.sh
# 可选代跑 4s tcpdump: bash scripts/c1-ingest-checklist.sh --tcpdump
```

脚本会依次说明并尽量自动检查：

| 步 | 做什么 | 说明 |
|----|--------|------|
| **①** | 看 **跑 adb ingest 的 SSH 终端** stderr | 若出现 **`ingest 管道结束: adb_exit=… ffmpeg_exit=…`** → 推流已断；**该行不在 docker logs**，由 **`ffmpeg-ingest-h264-adb-screenrecord.sh`** 打印。 |
| **②** | **`pgrep -af ffmpeg`** | 无进程 → ingest 未起或已挂；有则核对 **`rtp://127.0.0.1:<端口>`** 是否与日志一致。 |
| **③** | **`docker compose logs`** 里 **RTP tuple / RTCP / 手动行** | 与 **②** 端口不一致 → 可能打旧口，先 **`c1-ingest-safe.sh stop`** 再 **`adb-loop`** 或 **`--recreate-pilot`**。 |
| **④** | **`tcpdump -ni lo udp port <RTP>`** | 脚本打印可复制的 **`timeout 4 tcpdump …`**；无包 → 本机 loopback 上无 RTP。 |
| **⑤** | **硬恢复** | **`stop`** → **`bash scripts/c1-ingest-safe.sh --recreate-pilot adb-loop`** → 浏览器硬刷新、单次「仅观看」→ **`c1:diag:sfu:last`**。 |

与 **`npm run pilot:ingest-debug`** 的关系：**`pilot:ingest-debug`** 偏 compose 与日志摘要；**`c1:diag:ingest`** 偏 **ingest 存活 / 端口对齐 / tcpdump / 恢复命令**。
