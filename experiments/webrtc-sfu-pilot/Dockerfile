# Linux: mediasoup 需编译 native；部署时建议 host 网络并设置 MEDIASOUP_ANNOUNCED_IP
# mediasoup-client 3.18.8+ 在 package.json 中要求 Node>=22；本镜像用 Node 20 故依赖锁定在 3.18.7。若需更新 client 到 3.20，可改为：ARG NODE_IMAGE=node:22-bookworm
# 国内部分镜像源对 library/node 403/404 时：docker compose build --build-arg NODE_IMAGE=docker.m.daocloud.io/library/node:20-bookworm
ARG NODE_IMAGE=node:20-bookworm
FROM ${NODE_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ android-tools-adb \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund

COPY c2-adb-api.cjs ./
COPY server.cjs ./
COPY client ./client
COPY public ./public
COPY scripts ./scripts

RUN npm run build:client

ENV NODE_ENV=production
EXPOSE 3000

CMD ["node", "server.cjs"]
