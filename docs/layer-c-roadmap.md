# Layer C：安卓画面 → WebRTC / mediasoup（路线图）

你已跑通 **Layer B**（浏览器摄像头 → SFU → 浏览器），说明 **mediasoup、信令、ICE、安全组 UDP** 可用。  
**Layer C** 要做的是：把 **Redroid / 真机里的显示输出** 变成 **可在浏览器里通过同一套 SFU 订阅的轨**，并（可选）把 **触控** 从 H5 回注到安卓。

本文档给出 **可验收的里程碑** 与 **技术路线对照**，避免把「能 ADB」误认为「已 Layer C」。

---

## 0. 前置（你应已具备）

| 项 | 说明 |
|----|------|
| Layer B | `experiments/webrtc-sfu-pilot` 双 Tab 或 HTTPS 下摄像头闭环 |
| Redroid | 根目录 `docker compose up -d`，容器稳定；binder 见 **`docs/redroid-notes.md`** |
| ADB | 本机 `ssh -L 5555:127.0.0.1:5555`，`adb connect 127.0.0.1:5555` |
| 网络 | `MEDIASOUP_ANNOUNCED_IP`、UDP 端口段与安全组已与 B 层一致 |

---

## 1. 里程碑划分（建议顺序）

### C0 — 先「看得见云机」（不进 SFU）

**目标**：在你自己的电脑上 **稳定看到 Redroid 的实时画面**（画质/延迟先不苛求）。**不要求**经过 mediasoup。

**常见做法（择一 PoC）**：

- **scrcpy（推荐）**：本机弹出 **桌面窗口** 显示云机画面；依赖 ADB，与 Layer B 完全独立。  
- **浏览器里看画面**：可选 **noVNC**（需 **KVM** + `docker-compose.emulator.yml`，与 Redroid 路线不同）或 **自行评估** 的 Web 封装 / minicap 系项目（安全与维护需自负）。  

**验收**：不经过 mediasoup，也能稳定看到 Redroid 桌面/应用。**详细命令见下文 §5。** C0 完成只表示 **采集链路在工程上可行**，不等于 Layer C 全部完成。

---

### C1 — 把「编码后的媒体」送进 **mediasoup Router**

**目标**：浏览器侧 **仍用现有 `consume` 流程**，但视频源来自 **安卓侧或宿主机转码管道**，而不是 `getUserMedia`。

**技术实质**：在 SFU 上新增一路 **Producer**，其 RTP 来自：

| 路线 | 思路 | 复杂度 |
|------|------|--------|
| **PlainTransport 收 RTP** | 宿主机或侧车用 FFmpeg/GStreamer 产出 **H264 RTP**，送入 mediasoup **PlainTransport**，再 `produce`；浏览器端只增加「订阅该 producer」的信令 | 中高（对齐 SSRC/Payload/时钟） |
| **独立 WebRTC 端（Node wrtc / 侧车）** | 侧车与安卓或采集端建 PeerConnection，收轨后再 **PipeTransport** 或二次转发进 Router | 高 |
| **安卓内原生 WebRTC** | App 内 `PeerConnection` 发屏，服务端当 SFU 客户端再接 Router | 高（开发/签名/ROM） |

**建议工程顺序**：先在 **C1** 用 **固定分辨率的 H264 测试流**（如 FFmpeg 彩条）打通 **PlainTransport → Producer → 浏览器 consume**，再换 **真实屏幕采集** 源，避免同时调试采集与 RTP 细节。

**验收**：浏览器 **不开摄像头**，仍能通过 SFU 看到 **来自管道/采集端** 的一路视频（与 Layer B 的 Tab2 体验一致，只是源变了）。

---

### C2 — 触控 / 按键回注（与 WebRTC 解耦）

**目标**：从 H5 或调试工具下发 **点击/滑动/按键** 到 Redroid。

**常见做法**：`adb shell input tap/swipe/keyevent`，或 **App 内 Socket** 接收指令。  
**注意**：与 **RTP/SFU** 无关，单独做可降低耦合。

**验收**：延迟可接受、坐标与分辨率映射正确（含横竖屏/DPI）。

---

### C3 — 产品化项（Layer C 之后）

多房间、鉴权、录屏合规、TURN、弱网、分辨率自适应、与掌厅 App 的风控关系等——与 **C1 媒体链** 分开排期。

---

## 2. 与本仓库代码的关系

- **`experiments/webrtc-sfu-pilot/server.cjs`**：当前仅 **浏览器 WebRtcTransport + produce/consume**。Layer C 要 **扩展信令**（例如：`externalVideo` 开关、`producerId` 广播、或独立 `layer-c` 进程通过 **PipeTransport** 连同一 Worker ——具体选型在实现阶段定）。  
- **根目录 `docker-compose.yml`**：Redroid 与 SFU **默认未编排在一起**；同机部署时注意 **端口、CPU、privileged 与 host 网络** 是否共存（SFU 常用 `network_mode: host`，Redroid 常用 bridge ——可行，但要避免端口冲突）。  

---

## 3. 风险与诚实边界

- **`screenrecord` 一键进 SFU** 不成立；需 **持续编码 + RTP/WebRTC 栈**（见 **`docs/webrtc-sfu-pilot.md` §1**）。  
- Redroid 与真机在 **MediaCodec、SurfaceFlinger** 行为上可能有差异，采集方案要 **在目标环境** 上验证。  
- 掌厅等 **加固 App** 可能对录屏/虚拟显示有限制，与 SFU 是否通 **无关**，需单独排障。

---

## 4. 下一步你可选的动作

1. 跑 **`scripts/check-layer-c-prereqs.sh`**（仓库内），确认 ADB + Redroid + SFU 端口。  
2. 选定 **C0 方案**（先看到画面），再开 **C1** 的 **PlainTransport + 测试 H264** 分支。  
3. 若团队更熟 **GStreamer**，优先以 **GStreamer → RTP → PlainTransport** 写设计评审，再写代码。

更细的 mediasoup API 请以 [mediasoup 文档](https://mediasoup.org/documentation/v3/mediasoup/api/) 与 **PlainTransport** 章节为准（版本升级时注意 API 差异）。

---

## 5. C0 实操：scrcpy + Redroid（推荐路径）

以下假设：**ECS 上 Redroid 已起**（`docker ps` 可见 `cloudphone-redroid`），且 compose 里 **5555 绑在 `127.0.0.1`**（本仓库默认），**不对公网开放 ADB**。

### 5.1 在 ECS 上确认 ADB 端口（可选）

```bash
ss -tlnp | grep 5555
# 期望类似 127.0.0.1:5555
```

### 5.2 在你自己的电脑（Mac 示例）安装工具

```bash
brew install android-platform-tools scrcpy
```

（Linux 桌面：用发行版包管理器安装 `adb`、`scrcpy`，或从 [scrcpy 发布页](https://github.com/Genymobile/scrcpy/releases) 安装。）

### 5.3 SSH 把远端 5555 转到本机

**终端 A**（保持运行，把 `EIP` 与密钥路径换成你的）：

```bash
ssh -N -L 5555:127.0.0.1:5555 -i /path/to/miyao.pem root@EIP
```

### 5.4 连接 ADB 并起 scrcpy

**终端 B**：

```bash
adb connect 127.0.0.1:5555
adb devices
# 应看到 127.0.0.1:5555 为 device

scrcpy -s 127.0.0.1:5555
```

若有多台设备，**必须**带 **`-s 127.0.0.1:5555`**。

### 5.5 Redroid 上常用降级参数（卡顿 / 花屏时试）

```bash
scrcpy -s 127.0.0.1:5555 --max-size=720 --video-bit-rate=4M
```

个别环境可试 **`--video-codec=h264`** 或 **`--render-driver=software`**（以当前 scrcpy 版本 `--help` 为准）。

### 5.6 验收清单（C0 = 通过）

- [ ] `adb devices` 为 **device** 而非 offline  
- [ ] scrcpy 窗口能 **连续** 看到 Launcher / 已装 App，操作可接受  
- [ ] 断开后重连 **可重复**（再执行 `adb connect` + `scrcpy`）

### 5.7 常见问题

| 现象 | 处理 |
|------|------|
| `adb` 只有 `no devices` | 检查 **终端 A** SSH 是否仍在线；ECS 上 Redroid 是否运行；端口是否为 **5555**。 |
| `unauthorized` / `offline` | `adb kill-server` 后重新 `adb connect`；必要时重启 Redroid 容器。 |
| scrcpy 立即退出 | 在 ECS 上 `docker logs cloudphone-redroid`；对照 **`docs/redroid-notes.md`**（binder、镜像标签）。 |
| 只想在 **浏览器** 里看 | 走 **noVNC / docker-android**（需 KVM），或另选 Web 方案；**不在此文档承诺**具体镜像。 |

### 5.8 C0 结束后

进入 **C1**：把 **H264 RTP** 以 **PlainTransport** 等形式送入 **mediasoup**（见上文 **§1 C1**）；不要在未稳定 **编码与分辨率** 前过早改 SFU 信令。
