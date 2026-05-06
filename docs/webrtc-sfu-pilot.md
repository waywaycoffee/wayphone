# WebRTC + SFU（MediaSoup）实验路线说明

本文档对应「从 ws-scrcpy 换为 WebRTC + SFU」的**可落地**版本：纠正常见误导、说明 Mac / Linux 差异，并指向仓库内**最小可运行验证**。

## 1. 你看到的教程里哪些是错的或不可直接照抄

| 说法 / 命令 | 实际情况 |
|-------------|-----------|
| `adb shell screenrecord --rtc …` | **不存在**。Android `screenrecord` 用于录屏到文件等，**没有**「一条命令推到 SFU」的官方用法。云机画面进 WebRTC 需要：**容器/设备内编码 + RTP/WebRTC 栈**（如 GStreamer webrtcbin、自研采集、或把已有 H.264 流桥进 SFU），不是 `screenrecord` 的一个参数。 |
| MacBook + Docker 跑 Redroid「和手机一样」 | Redroid 依赖 **Linux 内核 + 特权容器** 等条件。在 **Docker Desktop（Mac）** 里常**不稳定或根本跑不起来**；本仓库的 Redroid 编排面向 **Linux 云主机 / ECS**（见根目录 `docker-compose.yml`）。Mac 上更现实的是：**本机 AVD / 物理机** 做业务验证，**SFU 与信令**可在 Mac 上跑。 |
| 仅 `npm install mediasoup ws express` + 空壳 `ws.on('message')` | 只能起 HTTP/WebSocket，**不能**自动完成 SDP/ICE、Router、Transport、Producer/Consumer。完整链路需要按 [mediasoup](https://mediasoup.org/) 的信令与 API 逐步实现（或参考官方 demo）。 |

### 1.1 对照：你粘贴的「三步跑通」教程缺了什么

下面针对「SFU server.js + Redroid + public/index.html = ✅ 跑通整套架构」这一类说法，按技术事实拆开说明（与是否能在本机把进程拉起来无关）。

| 教程片段 | 问题 |
|----------|------|
| `worker/router` 放在 **未 await 的** `(async () => { ... })();`，同时 `httpServer.listen` 立刻执行 | **竞态**：首个 WebSocket 连上时 `router` 可能仍是 `undefined`，`router.createWebRtcTransport` 会直接异常。正确做法是 **先** `await` 建好 Worker/Router，**再** `listen`。 |
| 所有浏览器共用一个 `transport` | mediasoup 里每个参与者通常需要自己的 **WebRtcTransport**（发送/接收还常拆成 **sendTransport / recvTransport**）。单例 `transport` 既不是官方用法，也无法支撑多观众或多路流。 |
| `ws.on('message')` 只 `console.log`，没有 `connect` / `produce` / `consume` 等信令 | **没有任何 SDP/ICE/DTLS** 在浏览器与 mediasoup 之间走通，SFU **不会**凭空出现画面。 |
| `index.html` 里只有 `new WebSocket(...)`，没有 `RTCPeerConnection` / `mediasoup-client` | `<video>` **永远不会**被赋 `srcObject`；黑屏是正常结果，不是「低延迟已达成」。 |
| Redroid `docker-compose` 里把 `androidboot.redroid_width=...` 写在 `command:` | 是否与镜像预期一致需对照 **Redroid 官方文档**；很多示例用 **环境变量或完整启动参数**，照抄 `command:` 容易容器起不来或分辨率不生效。 |
| Mac + Docker Desktop 跑 Redroid | 仍见上文 **§1 表格**：实验可尝试，但不要默认与 Linux 云机等价。 |

**结论**：教程里「能访问 http://localhost:3000」最多说明 **静态页 + WS 端口通了**；把其称为「H5 低延迟操控 + SFU 转发已跑通」属于**过度承诺**。本仓库的 `experiments/webrtc-sfu-pilot` 刻意在页面与 WS 首包中写明：**当前仅为壳 + Router 就绪**，避免自我误导。

### 1.2 对照：「一整套可商用成品」类话术

网上偶见把 **Redroid + 一段 H5 + WebRTC 字样** 包装成「云手机可上线、10086 绝不卡启动页」的文案，与工程事实常见偏差如下：

| 话术 | 实际情况 |
|------|-----------|
| `curl … \| bash` 一键部署 | **高风险习惯**：脚本来源若不可审计，等价于远程任意执行。示例里的 `gh/yourtools/redroid` 常为**占位仓库名**，未必存在、更未经你方安全评审。生产环境应使用**固定版本**镜像与**自己维护**的 IaC（compose / k8s），而非盲信外链。 |
| Redroid「不是模拟器、无 SELinux、10086 当真实手机」 | Redroid 仍是 **AOSP 容器化运行环境**，有正常的 Android 安全与权限模型；**并非**对任意 App 自动「过风控 / 过加固」。能否启动、是否卡启动页取决于 **App 自身**、网络、ROM/容器差异；**无法**在工程上承诺「绝不卡启动页」。本仓库内若出现解压/Native/崩溃类日志，应**按日志排查**，而非假定换容器即消失。 |
| H5 里 `new RTCPeerConnection()` + `ontrack` | 若没有 **信令交换（SDP）**、**ICE 候选**、对端 **addTrack / transceiver** 或 SFU 的 **consume** 流程，`ontrack` **不会**被调用，画面**不会**出现；菜单、悬浮球、进度条只是 **UI 壳**，不等于流媒体已通。 |
| 应用商店 / 微信跳转链接 | 可做 **深链与渠道包引导**，与「云端实时画面 + 操控」是**不同子系统**；且各厂商商店协议、微信内 WebView 策略会随时间变化，需**单独维护与合规评估**。 |

**结论**：真正可商用的云手机/WebRTC 方案需要 **可验证的发布物**（镜像 digest、版本锁、监控指标、安全与合规），而不是口号式「全套成品」。本仓库提供的是 **可渐进验证** 的实验分层（见 §2），与上述营销话术不是同一回事。

## 2. 诚实的最简「能成功」分层

1. **Layer A（本仓库已提供）**  
   - `experiments/webrtc-sfu-pilot`：**mediasoup Worker + Router** + HTTP 静态页（与 Layer B 共用同一进程）。  
2. **Layer B（本仓库已提供：最小 SFU 媒体面）**  
   - **WebSocket 信令** + 浏览器 **`mediasoup-client`**：`sendTransport` / `recvTransport`、`produce` / `consume`。  
   - **验证方式**：同一台机开 **两个浏览器 Tab**（或两台设备同一局域网）：Tab1 点「发布摄像头」，Tab2 点「仅观看」，应能看到经 SFU 转发的画面（**不含** Redroid / 安卓采集）。  
3. **Layer C（安卓画面 → WebRTC）**  
   - 这是工作量最大的一层：在 **Linux + Redroid** 或 **AVD/真机** 上，用 **GStreamer / 定制 native / 或商业方案** 把编码后的轨送进 SFU；**触控回注**还要走 `adb`/minicap 同类通道或应用内协议，与纯 WebRTC 不是同一行命令能搞定。  

当前仓库的 **ws-scrcpy 实验** 仍适合「先看到画面、调 10086」；**WebRTC 路线**适合作为中长期架构验证，与 Layer C 并行规划。

## 3. 在本仓库里怎么跑 Layer A + B

```bash
cd experiments/webrtc-sfu-pilot
npm install
npm run build:client   # 生成 public/mediasoup-client.esm.js（esbuild 打包）
node server.cjs
```

- 本机浏览器打开日志里的 `http://127.0.0.1:3000/`（若端口被占用可 `PORT=3010 node server.cjs`）。  
- **跨机 / 局域网**：在运行 `server.cjs` 的机器上设置 **`MEDIASOUP_ANNOUNCED_IP`** 为「对端浏览器能路由到的 IP」（例如服务器内网 IP），否则 ICE 可能失败。  
- **非 localhost 的 HTTPS 站点**：浏览器对 `getUserMedia` 有安全上下文要求，需自行配 TLS / 反向代理（本试点未内置）。

一键 smoke（仓库根目录，**自动选空闲端口**；会按需 `npm install` / `build:client`）：

```bash
bash scripts/smoke-webrtc-sfu-pilot.sh
# 或固定端口: PORT=3010 bash scripts/smoke-webrtc-sfu-pilot.sh
```

预期：日志中有 `mediasoup Worker + Router OK`；smoke 校验 **HTTP**、`getRouterRtpCapabilities` **WebSocket RPC**。

若 mediasoup worker 启动失败，请对照 [mediasoup 安装文档](https://mediasoup.org/documentation/v3/mediasoup/installation/) 检查 Node 版本、防火墙与 `rtcMinPort`–`rtcMaxPort`。

### 3.1 Linux 上 Docker 部署（可选）

在 **`experiments/webrtc-sfu-pilot`** 目录：

```bash
export MEDIASOUP_ANNOUNCED_IP=192.168.x.x   # 填实际可达 IP，远程观看必设
docker compose up --build
```

Compose 使用 **`network_mode: host`**（Linux 常见做法，便于 mediasoup UDP）。仅适用于支持 host 网络的 Docker 环境；**与 Mac Docker Desktop 行为不同**，请以 Linux 云主机为准。

**云机安全组、防火墙、`MEDIASOUP_ANNOUNCED_IP` 填法、与 Redroid 并行实验、采购/「并发」话术澄清**：见 **[docs/linux-cloud-lab.md](linux-cloud-lab.md)**（其中 **§7**）。

## 4. 与现有云机文档的关系

- **Redroid / 云机部署**：仍以根目录 `README.md`、`docker-compose.yml` 与 `docs/cloud-app-runbook.md` 为准（**Linux**）。  
- **掌厅 / adb / 深链**：`scripts/cloud-10086.sh`、`docs/ws-scrcpy-10086-integration.md`。  
- **WebRTC SFU**：以本文档 + `experiments/webrtc-sfu-pilot` 为起点；**Layer B** 信令与浏览器示例已在试点目录内，**Layer C**（安卓画面进 SFU）仍待单独设计。

## 5. 推荐阅读顺序

1. [mediasoup 架构](https://mediasoup.org/documentation/v3/mediasoup/scalability/)  
2. [mediasoup-demo](https://github.com/versatica/mediasoup-demo)（完整但重，适合对照）  
3. 本仓库 `experiments/webrtc-sfu-pilot/README.md`（本目录说明）
