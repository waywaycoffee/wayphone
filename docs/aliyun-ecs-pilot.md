# 阿里云 ECS：先跑通测试（与本仓库一致）

目标：**在阿里云 Linux 上把本仓库里「能客观验证」的两块先跑通**——① WebRTC SFU 试点（Layer B）；②（可选）Redroid 容器。不承诺掌厅业务结果，以实测为准。

更通用的防火墙与「并发」话术澄清：见 **[linux-cloud-lab.md](linux-cloud-lab.md)**（含 **§7**）。

---

## 0. 开什么机器（最小可验证）

- **镜像**：**Ubuntu 22.04 LTS** 64 位（与仓库文档一致，少踩坑）。  
- **规格**：**2 核 4 GB** 起可试跑 **mediasoup 试点**（`npm install` 编 native 会吃 CPU/内存）；若要同机再跑 **Redroid**，建议 **4 核 8 GB** 起，并以 [redroid-doc](https://github.com/remote-android/redroid-doc) 与实测为准。  
- **架构**：**x86 或 ARM** 均以厂商说明 + **Redroid / Docker 特权容器** 是否可行为准，**不要**把「某架构必过掌厅」当购买依据。  
- **网络**：分配 **弹性公网 IP（EIP）**（或明确你从办公网/VPN 访问的 **内网 IP**）；后面 `MEDIASOUP_ANNOUNCED_IP` 填 **浏览器访问 ECS 时实际连到的那个 IP**。

> **规格族 / 轻量应用服务器**：是否支持 Redroid 所需的内核与容器能力，以阿里云文档 + 你开一台 PoC **跑 `docker compose` 能否稳定起容器** 为准；不在此写死「必买某款」。

---

## 1. 安全组（必配）

在 ECS 绑定的**安全组**入方向放行（可按需收紧来源 IP）：

| 协议 | 端口 | 用途 |
|------|------|------|
| TCP | 22 | SSH |
| TCP | 3000 | SFU 试点 HTTP/WebSocket（若改 `PORT` 则同步改） |
| UDP | 40000–49999 | mediasoup RTP（若改 `MEDIASOUP_RTC_*` 则与安全组一致） |

**系统防火墙**（若开启了 `ufw`/`firewalld`）需与安全组**同时**放行，见 [linux-cloud-lab.md §2](linux-cloud-lab.md)。

---

## 2. 登录 ECS 并装 Docker

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
# Docker 官方安装指引见 https://docs.docker.com/engine/install/ubuntu/
# 安装完成后确认：
docker --version
docker compose version
```

---

## 3. 拉代码（替换为你的仓库地址）

```bash
sudo mkdir -p /opt/cloudPhone
sudo chown "$USER":"$USER" /opt/cloudPhone
cd /opt/cloudPhone
git clone <你的 cloudPhone 仓库 URL> .
# 若私有库，用 SSH key 或 token，按你团队规范来
```

---

## 4. 先跑通 A：WebRTC SFU 试点（建议第一步）

在 ECS 上（有 EIP 时把下面 `EIP` 换成公网 IP；仅内网访问则换成内网 IP）：

```bash
cd /opt/cloudPhone/experiments/webrtc-sfu-pilot
export MEDIASOUP_ANNOUNCED_IP=EIP
export PORT=3000
docker compose up --build
```

浏览器（你本机或手机 4G）：`http://EIP:3000/`  

- **Tab 1**：「发布摄像头」  
- **Tab 2**：「仅观看」  

若只有信令没有画面：多半是 **`MEDIASOUP_ANNOUNCED_IP` 与 EIP 不一致** 或 **UDP 段未放行**，见 `docs/webrtc-sfu-pilot.md` 与 `linux-cloud-lab.md` §5。

**无 Docker 时用 Node**（需 `python3`、`build-essential` 以便编 mediasoup）：

```bash
sudo apt-get install -y python3 build-essential
cd /opt/cloudPhone/experiments/webrtc-sfu-pilot
npm install
npm run build:client
export MEDIASOUP_ANNOUNCED_IP=EIP
export PORT=3000
node server.cjs
```

---

## 5. 再试 B：Redroid（可选，与 SFU 独立）

```bash
cd /opt/cloudPhone
docker compose up -d
```

根目录 `docker-compose.yml` 默认 **ADB 5555 只绑 `127.0.0.1`**，不直接暴露公网。从本机连上云安卓用 **SSH 端口转发**：见 **`scripts/remote-adb-tunnel.sh`** 与 **`docs/redroid-notes.md`**。

**说明**：当前仓库 **未** 把 Redroid 画面自动接入 mediasoup（Layer C 另做）；你在阿里云上「跑通」到 **ADB 能装 App / 能起容器** 即可算环境就绪。

---

## 6. 费用与后续

- 控制台关注 **ECS + EIP + 流量/带宽** 计费；PoC 结束及时 **关机或释放** 实例，避免空跑。  
- 掌厅与合规：仅用 **官方渠道 APK**，勿使用不明来源安装包。

---

## 7. 自检命令（可选）

在**你本机**（有 `bash`）对 ECS 做最小自动化检查（需已 `git clone` 同一代码；ECS 上 3000 已监听、`MEDIASOUP_ANNOUNCED_IP` 已正确）：

```bash
# 在仓库根目录，指向云上已开的端口（若 SSH 隧道则换成本地端口）
PORT=3000 bash scripts/smoke-webrtc-sfu-pilot.sh
```

若 smoke 跑在你本机而服务在云上，应把脚本里的 `127.0.0.1` 改成 **EIP** 或把 smoke 放到 ECS 上执行；当前脚本默认测 **本机** `127.0.0.1`，**在 ECS 内执行**最贴切。
