# 基于 ws-scrcpy 实现中国移动掌厅「浏览器云访问」

本方案对齐开源项目 **[NetrisTV/ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy)**：在 **Android 模拟器（或未来远端实例）** 内运行官方掌厅 APK，通过 **浏览器** 接收 **H.264 流 + 触控回传**，实现「免本地安装 App、通过网络操控云端 Android 里的掌厅」——即你说的 **应用云化（流化）**。

> **说明**：浏览器里运行的是 **ws-scrcpy 前端 + 视频解码**，不是把 APK 编译成纯 WebAssembly；业务仍在 Android 内执行。

---

## 1. 上游 ws-scrcpy 要点（来自 GitHub README）

| 上游要求 | 在本仓库中的落地 |
|----------|------------------|
| **adb** 在 PATH | `brew install android-platform-tools` |
| **Node.js** 构建并启动服务端 | `experiments/ws-scrcpy`，`npm run dist` + `dist` 内 `node index.js` |
| 浏览器支持 WebSocket、MSE/WASM 解码 | 前端选用 Broadway / TinyH264 等 |
| 设备 Android 5+ + USB 调试 | 模拟器等效 |

克隆地址：`https://github.com/NetrisTV/ws-scrcpy.git`

---

## 2. 本仓库相对上游的补丁（必须保留）

在 Apple Silicon + **Node 24** 环境下，上游默认 **`node-pty@0.10.x`** 编译失败；并已适配 **`node-pty` 1.x** 的 `onData` / `onExit` API：

- `experiments/ws-scrcpy/package.json`：`node-pty` → **^1.1.0**
- `experiments/ws-scrcpy/src/server/goog-device/mw/RemoteShell.ts`：**RemoteShell** 监听方式更新

依赖安装推荐：**`npm install --omit=optional`**（由 `scripts/run-cloud-app-lab.sh` 自动执行）。

若你清空 `experiments/ws-scrcpy` 并重新 `git clone` **纯净上游**，需自行恢复上述修改或改用 **Node 20 LTS** 按上游文档安装。

---

## 3. 数据流（与上游一致）

```text
浏览器 ──HTTP/WebSocket──► ws-scrcpy（Node，:8000）
                              │
                              ├── adb（proxy-adb / scrcpy-server.jar）
                              ▼
                         Android 模拟器 ──► 掌厅 APK（官方安装）
```

直连投屏页使用 hash 路由：`#!action=stream&udid=…&player=…&ws=…`（与上游 `src/app/index.ts` 逻辑一致）。  
本仓库提供 **`scripts/ws-scrcpy-stream-url.sh`** 生成该 URL，避免手工编码错误。

---

## 4. 一键命令映射（掌厅云化）

在项目根目录 `cloudPhone`：

| 目的 | 命令 |
|------|------|
| 环境自检（adb、PAGE_SIZE、依赖、8000 端口） | `bash scripts/cloud-10086.sh check` |
| 打印推荐的多终端步骤 | `bash scripts/cloud-10086.sh lab` |
| 启动 ws-scrcpy（首次拉 npm、编译 webpack） | `bash scripts/run-cloud-app-lab.sh` |
| 停止 ws-scrcpy（仅释放 8000） | `bash scripts/stop-ws-scrcpy.sh` |
| 仅 adb 拉起掌厅 | `bash scripts/cloud-10086.sh launch-app` |
| 打印直连投屏链接（需 ws-scrcpy 已运行） | `bash scripts/cloud-10086.sh stream-url` |
| 拉起掌厅 + 本机浏览器打开直连页 | `bash scripts/cloud-10086.sh open` |
| 外网 HTTPS 穿透（可选） | `bash scripts/step1-public-tunnel.sh` |

局域网示例：`WS_SCRCPY_BASE=http://192.168.x.x:8000 bash scripts/cloud-10086.sh stream-url`

---

## 5. 掌厅稳定性（模拟器）

- **PAGE_SIZE=16384**（16k 页镜像）易导致 **`libmmkv.so` 加载失败**，表现为闪退；请换 **API 34 / PAGE_SIZE=4096** 的 ARM 镜像（详见 `docs/cloud-app-runbook.md`）。
- **仅使用官方渠道 APK**，勿使用来源不明的「改版」安装包。

---

## 6. 官方深度链接（App 内 H5，非流化）

掌厅注册的 **`com.greenpoint://android.mc10086.activity?url=https://...`** 用于 **已安装的 App** 打开指定 H5；与 ws-scrcpy **并列**，不改变「浏览器云访问」架构。

---

## 7. 延伸阅读

- 上游 README：<https://github.com/NetrisTV/ws-scrcpy/blob/master/README.md>  
- 本仓库实操手册：`docs/cloud-app-runbook.md`
