# webrtc-sfu-pilot

**Layer A + B**：mediasoup **Worker / Router** + **WebSocket 信令** + 浏览器 **`mediasoup-client`**，实现 **摄像头 → SFU → 另一 Tab / 另一台浏览器** 的最小闭环。

**不是**：Redroid / 安卓画面采集、触控回注、商用房间与鉴权（见 `docs/webrtc-sfu-pilot.md` 的 Layer C）。

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

## Docker（Linux，可选）

```bash
export MEDIASOUP_ANNOUNCED_IP=192.168.x.x
docker compose up --build
```

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
