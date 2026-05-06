# 自建 ws-scrcpy「应用云化」实验 — 可执行方案（修正版）

本仓库已集成 **ws-scrcpy**（`experiments/ws-scrcpy`，对齐 [NetrisTV/ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy)），并对 **Node 24 + node-pty** 做过兼容修改。**不要使用来历不明的第三方掌厅 APK**（安全风险）；掌厅请用**官方渠道**安装的包。

**集成说明与命令总表**：见 **`docs/ws-scrcpy-10086-integration.md`**；日常可用 **`bash scripts/cloud-10086.sh check`** / **`lab`**。

---

## A. 环境前置（做一次）

1. **Mac**：已安装 **adb**（如 `brew install android-platform-tools`）、**Node.js**（建议能用即可；当前用法依赖 npm）。
2. **Android Studio**：新建或使用一台模拟器：
   - **API 34**（Android 14）优先，`ABI` 选 **ARM 64**（Apple Silicon Mac 必须用 ARM 镜像）。
   - **Services** 选 **Google APIs** 可以。
   - **不要**选用名称或说明里带 **16 KB / 16k page** 的实验镜像（易触发掌厅 native 库 `libmmkv` 加载失败）。
3. **自检页大小**（模拟器启动后）：

   ```bash
   adb shell getconf PAGE_SIZE
   ```

   期望 **`4096`**；若为 **`16384`**，换镜像再试。

---

## B. 依赖安装（ws-scrcpy，做一次）

在项目根目录 `cloudPhone`：

```bash
cd /Users/mac/程序/cloudPhone   # 按你的实际路径
bash scripts/run-cloud-app-lab.sh
```

- **首次**会自动执行：`cd experiments/ws-scrcpy && npm install --omit=optional …`
- 若你删掉了 `experiments/ws-scrcpy` 并重新 `git clone` **原版**，需恢复本仓库已改的 **`package.json` 里 node-pty 版本** 与 **`RemoteShell.ts`**，或改用 Node 20 LTS 再按上游文档安装。

---

## C. 掌厅安装（官方 APK）

1. 在模拟器内通过浏览器从 **中国移动官方下载页 / 可信分发** 安装掌厅（或 `adb install` 你已校验过的官方包）。
2. 仅排查问题时卸载重装：

   ```bash
   adb uninstall com.greenpoint.android.mc10086.activity
   ```

---

## D. 启动「云服务」（ws-scrcpy）

```bash
cd /Users/mac/程序/cloudPhone
bash scripts/run-cloud-app-lab.sh
```

- 成功时终端会出现 **`Listening on:`**，其中有 **`http://127.0.0.1:8000/`**（具体以终端为准）。
- 若提示端口占用：**多半已在运行**。可先 **`bash scripts/stop-ws-scrcpy.sh`** 再重跑；或直接使用浏览器打开脚本打印的同网地址。

**不要使用 `pkill -f node`** ——会杀掉其它 Node 进程；应用 **`scripts/stop-ws-scrcpy.sh`** 仅清理 **8000** 监听。

---

## E. 浏览器访问（局域网「云控制台」）

- 本机：`http://127.0.0.1:8000/`
- 同 WiFi 手机：`http://<Mac 局域网 IP>:8000/`  
  （终端可查：`ipconfig getifaddr en0`）

在页面中选设备 → **Configure stream** → 选解码（如 **Broadway.js**）进入画面。

---

## F. 外网 HTTPS（可选）

前提：**ws-scrcpy 已在跑**。

```bash
cd /Users/mac/程序/cloudPhone
bash scripts/step1-public-tunnel.sh          # 默认 cloudflared，边缘协议 http2
# 或（需先 ngrok config add-authtoken）
bash scripts/step1-public-tunnel.sh ngrok
```

临时隧道域名会变；窗口需保持打开。

---

## G. 一键：拉起掌厅 + 打开直连投屏页（仅本机）

```bash
cd /Users/mac/程序/cloudPhone
WS_SCRCPY_BASE=http://127.0.0.1:8000 bash scripts/open-cloud-10086.sh
```

同网访问时请把 `WS_SCRCPY_BASE` 改成 `http://你的局域网IP:8000`。

---

## H. 架构对照（你要的「应用云化」）

```text
浏览器  ←→  ws-scrcpy（本机 :8000）  ←→  adb  ←→  模拟器里的 Android App（掌厅等）
```

---

## I. 常见问题

| 现象 | 处理 |
|------|------|
| 掌厅一点就闪退 | 先看 `PAGE_SIZE`；多为 **16k 镜像**，换 **API 34** 非 16k 镜像；再看 logcat。 |
| `EADDRINUSE :8000` | `bash scripts/stop-ws-scrcpy.sh` 或脚本已提示「已在运行」则直接用浏览器打开。 |
| `npm install` 失败 | 使用本仓库脚本默认的 `--omit=optional`；或换 Node 20 + 上游原版依赖流程。 |

---

## J. 终止模拟器（按需）

在 Android Studio Device Manager 里关闭即可；**不必** `pkill -f emulator`（除非你确认没有其它重要会话）。
