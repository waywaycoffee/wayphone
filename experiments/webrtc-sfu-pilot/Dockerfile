# Linux: mediasoup 需编译 native；部署时建议 host 网络并设置 MEDIASOUP_ANNOUNCED_IP
FROM node:20-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund

COPY server.cjs ./
COPY client ./client
COPY public ./public

RUN npm run build:client

ENV NODE_ENV=production
EXPOSE 3000

CMD ["node", "server.cjs"]
