# Redroid / 云安卓备忘

本仓库主线为 **Linux（含阿里云 ECS）+ Docker Redroid**；不再内置 **ws-scrcpy** 实验目录。

## 本机 Mac 与 `docker: command not found`

- **Redroid 与根目录 `docker compose`** 应在 **已安装 Docker 的 Linux（如 ECS）** 上操作；Mac 上若未装 **Docker Desktop**，会出现 **`zsh: command not found: docker`**。安装并 **启动 Docker Desktop** 后再执行 `docker compose`（见 [Docker Mac 安装文档](https://docs.docker.com/desktop/setup/install/mac-install/)）。  
- **Apple Silicon（M 系列）**：Redroid 镜像多为 **linux/amd64**，在 Mac 上常走 **模拟/转译**，**只适合轻量联调**；**生产、性能与掌厅兼容性** 仍以 **x86 Linux 云机** 为准。  
- **更常见工作方式**：Mac 只跑 **`adb` + SSH 隧道**（见下文），**`docker compose ps` / Redroid** 在 **SSH 登录后的 ECS** 上执行。

## ECS 本机安装 `adb`（Ubuntu / Debian）

在 **SSH 登录的 ECS** 上若提示 **`adb: command not found`**：

```bash
sudo apt update
sudo apt install -y adb
adb version
```

部分旧系统包名为 **`android-tools-adb`**。装好后可在 **ECS 本机** 直接 **`adb connect 127.0.0.1:5555`**（与根目录 `docker-compose.yml` 中 **127.0.0.1:5555** 映射一致）。

## ADB 经 SSH（5555 只在 ECS 本机时）

在**你自己的电脑**上（二选一）：

```bash
# 仓库脚本
bash scripts/remote-adb-tunnel.sh 你的用户@ECS公网IP

# 或等价
ssh -N -L 5555:127.0.0.1:5555 你的用户@ECS公网IP
```

另开终端：

```bash
adb connect 127.0.0.1:5555
adb devices
```

根目录 `docker-compose.yml` 默认将 **5555 绑在 `127.0.0.1`**，请勿随意改为对公网 `0.0.0.0` 开放。

## Android 版本与镜像（默认 Android 9）

根目录 **`docker-compose.yml`** 默认镜像为 **`redroid/redroid:9.0.0-latest`**（**Android 9 / API 28**），用于降低部分业务 APK 在容器上的兼容风险；若需更新可试 **`11.0.0-latest`**、**`13.0.0_*`** 等（以 [redroid-doc](https://github.com/remote-android/redroid-doc) 为准）。若仓库根 **`.env`** 里设置了 **`REDROID_IMAGE`**，则以 `.env` 为准。

**从其它 Android 版本切换过来时**：执行 **`docker compose pull`** 后 **`docker compose up -d --force-recreate`**。容器内 **用户数据默认不持久** 时，切换后需 **重新安装 APK**（如 **`10086_10.2.1.apk`**）。标签与能力以 [redroid-doc](https://github.com/remote-android/redroid-doc) 为准。

## 容器状态 `Restarting`、且 `docker port` 无 5555

**现象**：`docker compose ps` 里 **STATUS** 为 **`Restarting (…)`**，`docker port cloudphone-redroid 5555/tcp` 提示 **no public port**。根因多是 **Redroid 没跑稳就反复退出**，端口映射不会正常生效。

**处理顺序**：

1. 看日志：`docker logs cloudphone-redroid --tail=120`（搜 `binder`、`memfd`、`FATAL`）。  
2. **Binder**：若见 **`/dev/binder` No such file**，按下文 **Binder** 一节执行 **`scripts/setup-binder-devices.sh`**。  
3. **memfd（5.15+ 云内核常见）**：根目录 **`docker-compose.yml`** 的 **`command`** 里已默认带 **`androidboot.use_memfd=0`**；改完后 **`docker compose up -d --force-recreate`**。  
4. 确认 **`STATUS` 为 `Up` 若干分钟** 后，再执行 **`docker port cloudphone-redroid 5555/tcp`** 与 **`scripts/layer-c0-redroid-on-ecs.sh`**。

---

## Binder 与容器反复重启（`/dev/binder` No such file）

若 `docker logs` / logcat 出现 **`Binder driver '/dev/binder' could not be opened`**，说明 **容器内（或宿主）没有可用的 classic binder 节点**。

### 先读内核配置（Ubuntu 24.04 云机常见）

```bash
grep CONFIG_ANDROID_BINDER /boot/config-"$(uname -r)" 2>/dev/null | grep -v '^#'
```

若出现 **`CONFIG_ANDROID_BINDER_DEVICES=""`**（空字符串），表示 **内核不会自动创建 `/dev/binder` / `hwbinder` / `vndbinder`**，即使 **`modprobe binder_linux devices=...`** 也可能 **没有** `/dev/binder`。此时应使用 **binderfs**（`CONFIG_ANDROID_BINDERFS=m` 时）：挂载后在 **`binder-control`** 上 **`BINDER_CTL_ADD`** 创建实例，再 **`/dev/binder` → `/dev/binderfs/binder`** 等符号链接。

本仓库提供一次性脚本（在 ECS **root** 下、仓库已 `git clone` 到例如 `/root/wayphone`）：

```bash
cd /root/wayphone
sudo bash scripts/setup-binder-devices.sh
ls -la /dev/binder /dev/hwbinder /dev/vndbinder
```

成功后再 **`docker compose up -d`**；根目录 `docker-compose.yml` 中 **`devices:`** 会把上述节点传入 Redroid。

若 **`/boot/config-*` 里根本没有 `CONFIG_ANDROID_BINDER_IPC`**，则当前内核 **不支持** Android binder，只能换镜像/内核或机型。

### 经典节点已预置的内核（少数环境）

若 **`CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`**（或等价），通常只需：

```bash
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
ls -la /dev/binder /dev/hwbinder /dev/vndbinder
```

三者在且 compose 里已映射 **`devices:`** 后，再 **`docker compose up -d`**。仅 `privileged: true` 在部分 Docker/内核组合下仍不会自动注入上述节点。

## 中国移动掌厅（仅备忘，不构成兼容性承诺）

- **包名**：`com.greenpoint.android.mc10086.activity`（若 `pm list packages` 显示为 `com.greenpoint.android.mc10086`，以实际包名为准）  
- **启动 Activity（Redroid 上 `dumpsys` 实测，随版本可能变）**：`com.mc10086.cmcc.base.StartPageActivity`（`MAIN` + `LAUNCHER`）。启动示例：  
  `adb -s 127.0.0.1:5555 shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.base.StartPageActivity`  
- **安装**：请使用 **官方渠道 APK**；勿使用来源不明的安装包。  
- **授权弹窗与串流（如何定位、能否模拟点击）**  
  - **是否「必须授权才能继续」**：冷启掌厅时看画面是否停在系统/应用对话框；或在 ECS 上 **`adb -s 127.0.0.1:5555 shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml /tmp/`**，在 **`/tmp/ui.xml`** 里搜 **`alert`**、**`permission`**、**`button`**、应用包名相关 **`node`**。也可 **`adb exec-out screencap -p > /tmp/screen.png`** 肉眼确认。  
  - **本仓库已实现的自动「同意」**：仅针对系统 **「允许访问设备日志」** 一类弹窗（界面文案常为 **Allow … access all device logs?**），通过 **`uiautomator dump`** 查找资源 **`log_access_dialog_allow_button`**，计算 **`bounds` 中心点后 `adb shell input tap`**；解析失败时用环境变量 **`LOG_DIALOG_FALLBACK_X` / `LOG_DIALOG_FALLBACK_Y`**（默认 **`360`/`1042`**，对应 Redroid 常见 **720×1280**）。  
    - 试点目录：**`npm run adb:dismiss-log-dialog`**（你已 **`am start` 掌厅** 后执行）；或 **`npm run adb:start-zhangting-dismiss-log-dialog`**（先起掌厅再等弹窗并点 **Allow one-time access**）。脚本见 **`experiments/webrtc-sfu-pilot/scripts/adb-dismiss-log-access-dialog.sh`**。  
    - **说明**：**「one-time」** 可能在一段时间后再次弹出；脚本只处理**这一类**系统控件 id，**不**覆盖存储/电话/悬浮窗等其它运行时权限框，也**不**处理应用内 H5/营销弹窗。  
    - **Android 版本**：该类 **日志访问限制弹窗** 多见于较新系统；**Android 9** 上若掌厅**根本不弹**此框，脚本在超时后会正常退出（日志里写「未发现日志访问授权框」），**不代表**没有其它授权问题。  
  - **与「串流停止」的关系**：若弹窗挡在最上层，**`screenrecord` 可能仍出画面（录到弹窗）**，但业务路径会卡住；若应用因**未授权**在后台逻辑里**自停/断流**，需对症授权。**native 崩溃（SIGSEGV）**、**`screenrecord` 时长/策略限制**、**ADB 断连** 等都会导致 ingest 停，**不能**靠点日志授权框解决。  
  - **要自动点其它按钮时**：从同一份 **`uiautomator dump`** 里复制目标 **`resource-id`** 或 **`text`** 所在行的 **`bounds`**，按现有脚本写法另加一段 grep + **`input tap`** 即可（注意分辨率变化时要重算坐标）。  
- **本仓库约定路径**（SFU 试点目录下，含空格目录名，shell 需加引号）：**`experiments/webrtc-sfu-pilot/source app/10086_10.2.1.apk`**（推荐 **10.2.1** 以降低与 Redroid 的兼容风险）；安装命令与 **`adb`** 说明见 **`experiments/webrtc-sfu-pilot/README.md`** 中「掌厅 APK 路径」一节。  
- **APK 不会进 Git**（`.gitignore`），需在 **ECS** 上自备文件。Mac 上传到 ECS 示例（密钥、IP、本地路径请替换）：

```bash
# 1）在 ECS 上建目录（一次即可）
ssh -i ~/.ssh/miyao.pem root@你的ECS_IP 'mkdir -p "/opt/wayphone/experiments/webrtc-sfu-pilot/source app"'

# 2）上传（注意整行引号）
scp -i ~/.ssh/miyao.pem \
  "/Users/mac/程序/cloudPhone/experiments/webrtc-sfu-pilot/source app/10086_10.2.1.apk" \
  root@你的ECS_IP:"/opt/wayphone/experiments/webrtc-sfu-pilot/source app/10086_10.2.1.apk"

# 3）ECS 上安装（Redroid 为 127.0.0.1:5555 时）
# adb -s 127.0.0.1:5555 install -r -g "/opt/wayphone/experiments/webrtc-sfu-pilot/source app/10086_10.2.1.apk"
```  
- **云化 / H5 深链形态（示意）**：掌厅侧常见为 **`com.greenpoint://android.mc10086.activity?url=<HTTPS 或活动页完整 URL>`**，例如：  
  `com.greenpoint://android.mc10086.activity?url=https://wx.10086.cn/qwhdhub/diy-client/…?A_C_CODE=…&channelId=…`  
  **注意**：`url=` 后面的内容若自带 **`?` `&`**，在作为 **单一 Intent data** 传递时，**应对整段 `url` 做 URL 编码**（`?`→`%3F`，`&`→`%26`，`:`→`%3A` 等），否则部分环境会截断参数。可在本机用 Python 生成编码串：  
  `python3 -c "import urllib.parse; print(urllib.parse.quote('https://wx.10086.cn/...', safe=''))"`  
  得到 **`url=` 的值** 后再拼进 `com.greenpoint://android.mc10086.activity?url=编码后字符串`。
- **ADB 唤起（App 已安装、Redroid 已 `adb connect`）**：  

```bash
# 整段 data 建议单引号包裹；以下为「url 已编码」后的示例结构
adb -s 127.0.0.1:5555 shell am start -a android.intent.action.VIEW \
  -d 'com.greenpoint://android.mc10086.activity?url=https%3A%2F%2Fwx.10086.cn%2Fqwhdhub%2Fdiy-client%2F…%3FA_C_CODE%3D…%26channelId%3D…'
```

若 **`VIEW` 解析失败**，可显式指定 **`SchemeDispatchActivity`**（与 `dumpsys` 中 `com.greenpoint` scheme 一致）：  

```bash
adb -s 127.0.0.1:5555 shell am start -n com.greenpoint.android.mc10086.activity/com.mc10086.cmcc.view.mine.html5.SchemeDispatchActivity \
  -a android.intent.action.VIEW -d 'com.greenpoint://android.mc10086.activity?url=…同上编码…'
```

在部分 **模拟器 / 非标准环境** 上曾出现 **16KB 页** 与 native 库加载问题；云 Redroid 以 **实测** 为准。
