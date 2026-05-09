# x86 本地 Linux 部署（保留方案）

与 **阿里云 ECS** 使用**同一套仓库**：Docker + Redroid、`experiments/webrtc-sfu-pilot`（mediasoup 试点）、根目录脚本。差别主要在 **网络形态**（无云安全组、多为局域网/家用路由）和 **是否暴露 `/dev/kvm`**（仅在你需要 **docker-android** 那条线时相关）。

通用防火墙与容量口径：见 **[linux-cloud-lab.md](linux-cloud-lab.md)**。

---

## 1. 适用场景

- **x86 台式机 / 小主机 / 机房服务器**，安装 **Ubuntu 22.04 LTS Server**（或你团队统一版本）。  
- 希望 **长期本地** 跑云安卓实验、与云上 **同一 compose** 对齐，便于以后迁移或双环境互备。

---

## 2. 与 ECS 相同的操作

1. 按根目录 **[README.md](../README.md)** 安装 Docker、`docker compose`。  
2. **Redroid**：`docker compose up -d`（见 README §2）。  
3. **WebRTC SFU 试点**：`docs/webrtc-sfu-pilot.md` + `docs/linux-cloud-lab.md`（`MEDIASOUP_ANNOUNCED_IP` 填 **局域网访问本机时使用的 IP**）。  
4. **ADB**：`docs/redroid-notes.md` + `scripts/remote-adb-tunnel.sh`；若 adb 与 Docker 同机，可直接 `adb connect 127.0.0.1:5555`（视 compose 绑定地址而定）。

本地 **没有弹性公网 IP**：浏览器从局域网访问时，`MEDIASOUP_ANNOUNCED_IP` 使用例如 **`192.168.x.x`**，不要用 `127.0.0.1` 给另一台设备当 ICE 地址。

---

## 3. x86 上「可选」的 KVM / docker-android 线

若你希望 **浏览器里 noVNC 看模拟器**（[docker-android](https://github.com/budtmo/docker-android)），宿主机需要 **`/dev/kvm`** 且容器能访问该设备。在 **裸金属 x86** 上通常可在 BIOS 开启 **Intel VT-x / AMD-V** 后满足；在 **虚拟机里的 Ubuntu** 则需嵌套虚拟化，未必可用。

自检命令与回退到 Redroid：见 **`scripts/check-env.sh`**、**`scripts/check-kvm-docker-android.sh`** 与 README **「先选哪套」**表格。

---

## 4. 外网访问（可选，安全自负）

本地默认 **无云厂商安全组**；若要从公网访问本机上的 HTTP/WebRTC：

- 在 **路由器** 做 **端口转发**（例如 TCP 3000、UDP RTP 段），并清楚暴露面；  
- 或使用 **Tailscale / WireGuard** 等 VPN，让客户端先进私网再访问 `http://内网IP:3000`，通常比裸映射端口更安全。

本仓库**不**内置 DDNS/证书自动化；需要时自行叠加。

---

## 5. 与阿里云文档的关系

| 主题 | 优先看 |
|------|--------|
| 云上安全组、EIP、`MEDIASOUP_ANNOUNCED_IP` 填公网 IP | **[aliyun-ecs-pilot.md](aliyun-ecs-pilot.md)** |
| UDP 段、防火墙、「并发」口径 | **[linux-cloud-lab.md](linux-cloud-lab.md)** |
| 本页 | **x86 本地 Linux** 与 ECS **同一套 compose**，差异在 **网络 / KVM 可得性** |
