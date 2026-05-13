'use strict';

/**
 * mediasoup worker 子进程的 C++ 日志走 stdout → Node 用 `debug` 包以 mediasoup:Worker 输出。
 * 未设置 DEBUG 时这些行不会出现在 docker logs，grep「suitable|ReceiveRtp」会空。
 * MEDIASOUP_WORKER_DEBUG=1 时自动打开 Worker 命名空间；或手动 DEBUG=mediasoup:Worker,mediasoup:WARN:Worker
 */
if (process.env.MEDIASOUP_WORKER_DEBUG === '1') {
  const need = 'mediasoup:Worker,mediasoup:WARN:Worker';
  const d = process.env.DEBUG || '';
  if (!d.includes('mediasoup')) {
    process.env.DEBUG = d ? `${d},${need}` : need;
  }
}

const http = require('http');
const path = require('path');
const express = require('express');
const WebSocket = require('ws');
const mediasoup = require('mediasoup');
const pilotPkg = require('./package.json');
const { registerC2Routes, c2Enabled } = require('./c2-adb-api.cjs');

const PORT = Number(process.env.PORT || 3000);
/** 0.0.0.0 = all IPv4 interfaces (explicit; avoids confusion with logs / some host setups). */
const HTTP_LISTEN_HOST = process.env.HTTP_LISTEN_HOST || '0.0.0.0';
const RTC_MIN_PORT = Number(process.env.MEDIASOUP_RTC_MIN_PORT || 40000);
const RTC_MAX_PORT = Number(process.env.MEDIASOUP_RTC_MAX_PORT || 49999);
/** 与前端一致：唯一来源 package.json「pilotVersion」；`PILOT_VERSION` 环境变量可临时覆盖。`npm run build:client` 会同步 public 内文案。 */
const PILOT_VERSION = process.env.PILOT_VERSION || pilotPkg.pilotVersion || 'pilot-unknown';

/**
 * MEDIASOUP_ROUTER_VIDEO_H264_ONLY=1：Router 只注册 H264，不注册 VP8（排查 PT/codec 映射时减少变量）。
 * 设为 1 后请勿再用 MEDIASOUP_INGEST_CODEC=vp8（router 将无 VP8）。
 */
const ROUTER_VIDEO_H264_ONLY = process.env.MEDIASOUP_ROUTER_VIDEO_H264_ONLY === '1';

/** MEDIASOUP_INGEST_TRACE=1 且 Layer C1 启用时：为 ingest Producer 打开 trace（rtp/keyframe/pli 等），日志量较大 */
const INGEST_TRACE = process.env.MEDIASOUP_INGEST_TRACE === '1';

/** MEDIASOUP_WORKER_DEBUG=1 → logLevel=debug；LOG_TAGS 会与默认合并（避免 .env 里只写 rtp,rtcp 盖掉 info/rtx） */
function workerLogSettings() {
  let logLevel = process.env.MEDIASOUP_WORKER_LOG_LEVEL || 'warn';
  let logTags;
  const raw = process.env.MEDIASOUP_WORKER_LOG_TAGS;
  if (raw && String(raw).trim()) {
    logTags = String(raw)
      .split(',')
      .map((t) => t.trim())
      .filter(Boolean);
  }
  if (process.env.MEDIASOUP_WORKER_DEBUG === '1') {
    logLevel = 'debug';
    const defaults = ['info', 'rtp', 'rtcp', 'rtx'];
    const merged = new Set(logTags && logTags.length ? logTags : []);
    for (const t of defaults) merged.add(t);
    logTags = Array.from(merged);
  }
  const settings = { logLevel, rtcMinPort: RTC_MIN_PORT, rtcMaxPort: RTC_MAX_PORT };
  if (logTags && logTags.length) settings.logTags = logTags;
  return settings;
}

function listenIpConfig() {
  const announcedIp = process.env.MEDIASOUP_ANNOUNCED_IP;
  if (announcedIp && announcedIp.length > 0) {
    return [{ ip: '0.0.0.0', announcedIp }];
  }
  return [{ ip: '127.0.0.1' }];
}

/** mediasoup v3：PlainTransport 使用 listenInfo（listenIps 已不可用） */
function plainTransportListenInfo() {
  const announcedIp = process.env.MEDIASOUP_ANNOUNCED_IP;
  if (announcedIp && announcedIp.length > 0) {
    return {
      protocol: 'udp',
      ip: '0.0.0.0',
      announcedAddress: announcedIp,
    };
  }
  return { protocol: 'udp', ip: '127.0.0.1' };
}

function makeFindProducer(ingestCtx) {
  return function findProducer(peers, producerId) {
    if (
      ingestCtx.producer &&
      !ingestCtx.producer.closed &&
      ingestCtx.producer.id === producerId
    ) {
      return ingestCtx.producer;
    }
    for (const peer of peers.values()) {
      const p = peer.producers.get(producerId);
      if (p) return p;
    }
    return null;
  };
}

function listProducerSummaries(peers, ingestCtx) {
  const producers = [];
  if (ingestCtx.producer && !ingestCtx.producer.closed) {
    producers.push({
      id: ingestCtx.producer.id,
      kind: ingestCtx.producer.kind,
      appData: ingestCtx.producer.appData || {},
    });
  }
  for (const peer of peers.values()) {
    for (const prod of peer.producers.values()) {
      producers.push({ id: prod.id, kind: prod.kind, appData: prod.appData || {} });
    }
  }
  return producers;
}

/** MEDIASOUP_INGEST_TEST=1：FFmpeg RTP → PlainTransport → Producer（Layer C1 PoC） */
async function setupPlainIngest({ router, peers, ingestCtx, broadcastFn }) {
  if (process.env.MEDIASOUP_INGEST_TEST !== '1') return;

  const RTP_SSRC = Number(process.env.MEDIASOUP_INGEST_SSRC || 111222333);
  const ingestCodec = (process.env.MEDIASOUP_INGEST_CODEC || 'h264').toLowerCase();
  const useVp8 = ingestCodec === 'vp8';
  /** Router 同时注册 VP8+H264 时，VP8 的 preferredPayloadType 常为 101 而非 96；与 FFmpeg -payload_type 不一致会出现 bytesReceived 很大但 rtpBytesReceived=0 */
  const ingestVideoCap = (router.rtpCapabilities.codecs || []).find((c) => {
    if (c.kind !== 'video') return false;
    const m = c.mimeType.toLowerCase();
    if (useVp8) return m === 'video/vp8';
    return m === 'video/h264';
  });
  const RTP_PAYLOAD_TYPE = Number(
    process.env.MEDIASOUP_INGEST_PT ||
      (ingestVideoCap ? ingestVideoCap.preferredPayloadType : 96),
  );
  if (!ingestVideoCap) {
    console.error(
      'Layer C1: router.rtpCapabilities 中找不到与 MEDIASOUP_INGEST_CODEC 匹配的视频 codec，无法创建 ingest',
    );
    return;
  }
  /** 仅当 MEDIASOUP_INGEST_PLAIN_CONNECT=1：comedia:false + connect(FFmpeg 固定源端口)。默认 comedia:true：FFmpeg 常无法真正绑定 -localport（tcpdump 仍见随机源口），须首包学习源端口 */
  const ffmpegSrcPort = Number(process.env.MEDIASOUP_INGEST_FFMPEG_LOCAL_PORT || 35500);
  const ffmpegSrcIp = process.env.MEDIASOUP_INGEST_FFMPEG_IP || '127.0.0.1';
  const strictPlainConnect = process.env.MEDIASOUP_INGEST_PLAIN_CONNECT === '1';
  /** 与 versatica/mediasoup-demo broadcasters/ffmpeg.sh 一致：rtcpMux=false 时 FFmpeg 使用 ?rtcpport=<独立端口>，部分环境 VP8/FFmpeg 在 rtcpMux=true 下 rtpBytesReceived 不涨 */
  const ingestRtcpMux = process.env.MEDIASOUP_INGEST_RTCP_MUX !== '0';

  const li = plainTransportListenInfo();
  const plainTransport = await router.createPlainTransport({
    listenInfo: li,
    rtcpMux: ingestRtcpMux,
    comedia: !strictPlainConnect,
  });

  ingestCtx.plainTransport = plainTransport;
  console.log('Layer C1 PlainTransport listenInfo:', JSON.stringify(li));

  const videoCodec = {
    mimeType: ingestVideoCap.mimeType,
    payloadType: RTP_PAYLOAD_TYPE,
    clockRate: ingestVideoCap.clockRate,
    parameters: ingestVideoCap.parameters || {},
    rtcpFeedback: ingestVideoCap.rtcpFeedback || [],
  };

  const producer = await plainTransport.produce({
    kind: 'video',
    rtpParameters: {
      codecs: [videoCodec],
      encodings: [{ ssrc: RTP_SSRC }],
      rtcp: {
        cname: 'layer-c1-ingest',
        reducedSize: true,
      },
    },
    appData: { source: 'plain-ingest-test', codec: useVp8 ? 'vp8' : 'h264' },
  });

  ingestCtx.producer = producer;

  if (INGEST_TRACE) {
    try {
      await producer.enableTraceEvent(['rtp', 'keyframe', 'pli', 'nack']);
      producer.on('trace', (trace) => {
        console.log('Layer C1 ingest producer trace:', JSON.stringify(trace));
      });
      console.log(
        'Layer C1: MEDIASOUP_INGEST_TRACE=1 — producer trace enabled (rtp/keyframe/pli/nack)；若 worker 未识别 RTP，此处通常无 rtp 事件)',
      );
    } catch (e) {
      console.warn('Layer C1: enableTraceEvent failed:', e.message || e);
    }
  }

  producer.on('transportclose', () => {
    console.warn('Layer C1 ingest producer: transport closed');
    ingestCtx.producer = null;
  });

  if (strictPlainConnect) {
    await plainTransport.connect({
      ip: ffmpegSrcIp,
      port: ffmpegSrcPort,
    });
    console.log(
      `Layer C1 PlainTransport connect: 远端 RTP 源=${ffmpegSrcIp}:${ffmpegSrcPort}（MEDIASOUP_INGEST_PLAIN_CONNECT=1；FFmpeg 必须真从该端口发出，见 tcpdump src port）`,
    );
  } else {
    console.log(
      'Layer C1 PlainTransport comedia=true（默认）：首包到达后自动绑定 FFmpeg 源端口；勿设 MEDIASOUP_INGEST_PLAIN_CONNECT 除非已确认 -localport 生效',
    );
  }

  console.log(
    `Layer C1 PlainTransport rtcpMux=${ingestRtcpMux}（MEDIASOUP_INGEST_RTCP_MUX=0 可对齐 mediasoup-demo，FFmpeg 用独立 rtcpport）`,
  );

  const tuple = plainTransport.tuple;
  const lip = tuple.localIp || '127.0.0.1';
  const ffmpegHost = lip === '0.0.0.0' || lip === '::' ? '127.0.0.1' : lip;
  const ffmpegPort = tuple.localPort;
  const rtcpT = plainTransport.rtcpTuple;
  const ffmpegRtcpPort =
    ingestRtcpMux || !rtcpT ? ffmpegPort : rtcpT.localPort ?? ffmpegPort;
  if (!ingestRtcpMux && rtcpT) {
    console.log(
      `Layer C1 ingest_rtcp_port=${ffmpegRtcpPort}（FFmpeg URL 须 rtcpport=${ffmpegRtcpPort}，勿与 RTP 端口 ${ffmpegPort} 混用）`,
    );
  }
  const ffmpegScript = useVp8 ? 'ffmpeg-ingest-vp8.sh' : 'ffmpeg-ingest-h264.sh';

  console.log('');
  console.log(
    `=== Layer C1 ingest (PlainTransport ${useVp8 ? 'VP8' : 'H264'}, FFmpeg test pattern 或 ADB 真屏) ===`,
  );
  console.log(
    'MEDIASOUP_INGEST_CODEC:',
    useVp8 ? 'vp8（若 H264 黑屏/framesDecoded=0 可改用此项）' : 'h264（默认）',
  );
  console.log(
    `Layer C1: ingest PT=${RTP_PAYLOAD_TYPE}（须与 FFmpeg -payload_type 一致；由 Router preferredPayloadType 推导，勿再固定写 96）`,
  );
  if (!useVp8) {
    console.log(
      'Redroid/真机掌厅画面: 宿主机 adb devices 为 device 后 → npm run c1:ingest:adb -- --local（C1_INGEST_SOURCE=adb，见 scripts/ffmpeg-ingest-h264-adb-screenrecord.sh）',
    );
  }
  console.log(
    '推荐: bash scripts/run-c1-ffmpeg-ingest.sh  # 从 docker compose logs 解析 host/port 并启动 FFmpeg',
  );
  console.log('mediasoup RTP tuple:', `${lip}:${ffmpegPort}`);
  console.log(`同机 ingest: bash scripts/run-c1-ffmpeg-ingest.sh --local`);
  if (strictPlainConnect) {
    console.log(
      `  严格 connect 模式: FFmpeg 须从 ${ffmpegSrcIp}:${ffmpegSrcPort} 发 RTP（rtp URL 带 &localport=${ffmpegSrcPort} 或验证 tcpdump）`,
    );
  }
  console.log(
    ingestRtcpMux
      ? `  手动: bash scripts/${ffmpegScript} 127.0.0.1 ${ffmpegPort}  # rtcpMux=true，rtcp 与 RTP 同端口`
      : `  手动: bash scripts/${ffmpegScript} 127.0.0.1 ${ffmpegPort} ${ffmpegRtcpPort}  # 第三参为 RTCP 端口`,
  );
  if (useVp8) {
    console.warn(
      'Layer C1: 已为 VP8 ingest — 宿主机必须运行 ffmpeg-ingest-vp8.sh（或 run-c1 解析到 vp8）。若仍跑 h264 脚本，浏览器会协商 VP8 但解不出帧（framesDecoded=0）。',
    );
  }
  console.log(
    `  PT=${RTP_PAYLOAD_TYPE} SSRC=${RTP_SSRC} (env MEDIASOUP_INGEST_PT / MEDIASOUP_INGEST_SSRC)`,
  );
  console.log('Browser: 「仅观看」即可（无需「发布摄像头」）.');
  console.log('=================================================================');
  console.log('');

  broadcastFn(peers, null, {
    type: 'newProducer',
    producerId: producer.id,
    kind: producer.kind,
  });
}

function broadcast(peers, exceptWs, obj) {
  const s = JSON.stringify(obj);
  for (const client of peers.keys()) {
    if (client !== exceptWs && client.readyState === WebSocket.OPEN) client.send(s);
  }
}

function createPeerState() {
  return {
    transports: new Map(),
    producers: new Map(),
    consumers: new Map(),
  };
}

async function main() {
  const wLog = workerLogSettings();
  const worker = await mediasoup.createWorker(wLog);
  if (wLog.logTags && wLog.logTags.length) {
    console.log(
      'mediasoup Worker log:',
      `level=${wLog.logLevel}`,
      `tags=${wLog.logTags.join(',')}`,
    );
  }
  if (process.env.MEDIASOUP_WORKER_DEBUG === '1') {
    console.log(
      'mediasoup Node DEBUG (worker C++ stdout 经 debug 包输出，须含 mediasoup:Worker):',
      process.env.DEBUG || '(unset — 旧镜像或未注入)',
    );
  }

  worker.on('died', (error) => {
    console.error('mediasoup Worker died:', error);
    process.exit(1);
  });

  const mediaCodecs = [
    {
      kind: 'audio',
      mimeType: 'audio/opus',
      clockRate: 48000,
      channels: 2,
    },
    ...(ROUTER_VIDEO_H264_ONLY
      ? []
      : [
          {
            kind: 'video',
            mimeType: 'video/VP8',
            clockRate: 90000,
          },
        ]),
    {
      kind: 'video',
      mimeType: 'video/H264',
      clockRate: 90000,
      parameters: {
        'packetization-mode': 1,
        'profile-level-id': '42e01f',
        'level-asymmetry-allowed': 1,
      },
    },
  ];

  if (ROUTER_VIDEO_H264_ONLY) {
    console.log(
      'Router mediaCodecs: Opus + H264 only (MEDIASOUP_ROUTER_VIDEO_H264_ONLY=1)。浏览器与 ingest 均只能走 H264。',
    );
  }

  const router = await worker.createRouter({ mediaCodecs });
  const peers = new Map();
  const ingestCtx = { producer: null, plainTransport: null, ingestReady: false };
  const findProducer = makeFindProducer(ingestCtx);

  try {
    await setupPlainIngest({ router, peers, ingestCtx, broadcastFn: broadcast });
    if (ingestCtx.producer && !ingestCtx.producer.closed) {
      ingestCtx.ingestReady = true;
    }
  } catch (e) {
    console.error('MEDIASOUP_INGEST_TEST PlainTransport setup failed:', e);
  }

  const app = express();
  app.get('/__pilot_version', (_req, res) => {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
    res.type('text/plain').send(`${PILOT_VERSION}\n`);
  });
  app.get('/__pilot_health', (_req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.json({ ok: true, pilotVersion: PILOT_VERSION });
  });
  registerC2Routes(app);
  app.use(
    express.static(path.join(__dirname, 'public'), {
      etag: false,
      lastModified: false,
      setHeaders(res, filePath) {
        if (/\.(html|js|mjs|css)$/i.test(filePath)) {
          res.setHeader(
            'Cache-Control',
            'no-store, no-cache, must-revalidate, pragma: no-cache, max-age=0',
          );
        }
      },
    }),
  );

  const httpServer = http.createServer(app);
  const wss = new WebSocket.Server({ server: httpServer });

  function reply(ws, requestId, payload) {
    if (requestId) ws.send(JSON.stringify({ requestId, ...payload }));
    else ws.send(JSON.stringify(payload));
  }

  function replyErr(ws, requestId, message) {
    reply(ws, requestId, { ok: false, error: message });
  }

  wss.on('connection', (ws) => {
    const peer = createPeerState();
    peers.set(ws, peer);
    console.log('WebSocket client connected; peers=', peers.size);

    ws.on('message', async (buf) => {
      let msg;
      try {
        msg = JSON.parse(buf.toString());
      } catch {
        return;
      }
      const { requestId } = msg;

      try {
        switch (msg.type) {
          case 'getRouterRtpCapabilities': {
            reply(ws, requestId, {
              ok: true,
              routerRtpCapabilities: router.rtpCapabilities,
            });
            break;
          }
          case 'listProducers': {
            reply(ws, requestId, {
              ok: true,
              producers: listProducerSummaries(peers, ingestCtx),
            });
            break;
          }
          case 'createWebRtcTransport': {
            const transport = await router.createWebRtcTransport({
              listenIps: listenIpConfig(),
              enableUdp: true,
              enableTcp: true,
            });
            peer.transports.set(transport.id, transport);
            transport.on('dtlsstatechange', (dtlsState) => {
              if (dtlsState === 'closed') transport.close();
            });
            reply(ws, requestId, {
              ok: true,
              transport: {
                id: transport.id,
                iceParameters: transport.iceParameters,
                iceCandidates: transport.iceCandidates,
                dtlsParameters: transport.dtlsParameters,
              },
            });
            break;
          }
          case 'connectTransport': {
            const transport = peer.transports.get(msg.transportId);
            if (!transport) {
              replyErr(ws, requestId, 'transport not found');
              break;
            }
            await transport.connect({ dtlsParameters: msg.dtlsParameters });
            reply(ws, requestId, { ok: true });
            break;
          }
          case 'produce': {
            const transport = peer.transports.get(msg.transportId);
            if (!transport) {
              replyErr(ws, requestId, 'transport not found');
              break;
            }
            const producer = await transport.produce({
              kind: msg.kind,
              rtpParameters: msg.rtpParameters,
              appData: msg.appData || {},
            });
            peer.producers.set(producer.id, producer);
            producer.on('transportclose', () => {
              peer.producers.delete(producer.id);
            });
            reply(ws, requestId, { ok: true, producerId: producer.id });
            broadcast(peers, ws, {
              type: 'newProducer',
              producerId: producer.id,
              kind: producer.kind,
            });
            break;
          }
          case 'consume': {
            const transport = peer.transports.get(msg.transportId);
            if (!transport) {
              replyErr(ws, requestId, 'transport not found');
              break;
            }
            const producer = findProducer(peers, msg.producerId);
            if (!producer) {
              replyErr(ws, requestId, 'producer not found');
              break;
            }
            if (
              !router.canConsume({
                producerId: msg.producerId,
                rtpCapabilities: msg.rtpCapabilities,
              })
            ) {
              replyErr(ws, requestId, 'cannot consume');
              break;
            }
            // paused: true 再按信令 resume，避免 RTP 早于浏览器 Consumer 就绪（见 mediasoup 文档推荐顺序）
            const consumer = await transport.consume({
              producerId: msg.producerId,
              rtpCapabilities: msg.rtpCapabilities,
              paused: true,
            });
            const c0 = consumer.rtpParameters?.codecs?.[0];
            console.log(
              `consume: producerId=${msg.producerId} appData=${JSON.stringify(producer.appData || {})} → consumer codec=${c0?.mimeType} PT=${c0?.payloadType}`,
            );
            peer.consumers.set(consumer.id, consumer);
            consumer.on('transportclose', () => {
              peer.consumers.delete(consumer.id);
            });
            reply(ws, requestId, {
              ok: true,
              consumer: {
                id: consumer.id,
                producerId: consumer.producerId,
                kind: consumer.kind,
                rtpParameters: consumer.rtpParameters,
                producerPaused: consumer.producerPaused,
              },
            });
            break;
          }
          case 'resumeConsumer': {
            const consumer = peer.consumers.get(msg.consumerId);
            if (!consumer) {
              replyErr(ws, requestId, 'consumer not found');
              break;
            }
            if (consumer.paused) {
              await consumer.resume();
            }
            reply(ws, requestId, { ok: true });
            if (
              process.env.MEDIASOUP_INGEST_TEST === '1' &&
              ingestCtx.producer &&
              !ingestCtx.producer.closed &&
              consumer.producerId === ingestCtx.producer.id
            ) {
              const logIngestStats = async (phase) => {
                let rtpRx = 0;
                try {
                  const pt = ingestCtx.plainTransport;
                  if (pt && !pt.closed) {
                    const ts = await pt.getStats();
                    const t = ts[0];
                    if (t) {
                      rtpRx = Number(t.rtpBytesReceived) || 0;
                      console.log(
                        `Layer C1 PlainTransport stats (${phase}): rtpBytesReceived=${t.rtpBytesReceived} bytesReceived=${t.bytesReceived} remote=${t.tuple?.remoteIp}:${t.tuple?.remotePort}`,
                      );
                    }
                  }
                } catch (e) {
                  console.warn(`Layer C1 PlainTransport getStats (${phase}) failed:`, e.message || e);
                }
                try {
                  const stats = await ingestCtx.producer.getStats();
                  if (!Array.isArray(stats) || stats.length === 0) {
                    const hint =
                      rtpRx > 0
                        ? 'PlainTransport 已计 RTP 字节但 producer 仍无 inbound-rtp：多为映射/统计延迟，或对端 PT 与 Producer 不一致'
                        : 'PlainTransport rtpBytesReceived=0：UDP(bytesReceived)可能为非 RTP 或载荷未被识别为当前 ingest（换 MEDIASOUP_INGEST_CODEC、核对 ingest PT、tcpdump RTP 头）';
                    console.warn(
                      `Layer C1 ingest producer getStats (${phase}): [] — ${hint}`,
                    );
                  } else {
                    const v = stats.find((s) => s.type === 'inbound-rtp' && s.kind === 'video');
                    if (v) {
                      console.log(
                        `Layer C1 FFmpeg→SFU (${phase}):`,
                        `packetCount=${v.packetCount} byteCount=${v.byteCount} bitrate=${v.bitrate}`,
                      );
                      if (Number(v.packetCount) === 0) {
                        console.warn(
                          'Layer C1: ingest 收包为 0 — 查 FFmpeg 与端口、rtcpMux(rtcpport=)。',
                        );
                      }
                    } else {
                      console.log(
                        `Layer C1 ingest producer getStats (${phase}) 无 video inbound-rtp，条目:`,
                        stats.map((s) => `${s.type}/${s.kind || '-'}`).join(', '),
                      );
                    }
                  }
                } catch (e) {
                  console.warn('Layer C1 producer getStats failed:', e);
                }
                // 下行：SFU→浏览器。勿在 producer getStats 空时提前 return，否则本段永不执行。
                try {
                  const cs = await consumer.getStats();
                  const arr = Array.isArray(cs) ? cs : [];
                  const out = arr.find((s) => s.type === 'outbound-rtp' && s.kind === 'video');
                  if (out) {
                    const ob = Number(out.byteCount ?? out.bytesSent ?? 0);
                    console.log(
                      `Layer C1 SFU-to-browser (${phase}): consumer outbound-rtp packetCount=${out.packetCount} byteCount=${ob} bitrate=${out.bitrate}`,
                    );
                    if (ob < 50000 && rtpRx > 1_000_000) {
                      console.warn(
                        'Layer C1: ingest 字节很大但 consumer outbound 很小 — 查 MEDIASOUP_ANNOUNCED_IP（须为浏览器可达的公网 IP）、安全组 UDP 40000–49999、客户端网络是否拦 UDP；可试本机浏览器或 HTTPS+443。',
                      );
                    }
                  } else {
                    console.warn(
                      `Layer C1 consumer getStats (${phase}) 无 outbound-rtp/video，条目: ${arr.map((s) => `${s.type}/${s.kind || '-'}`).join(', ') || '(空)'}`,
                    );
                  }
                } catch (e) {
                  console.warn('Layer C1 consumer getStats failed:', e.message || e);
                }
              };
              setTimeout(() => void logIngestStats('1.5s'), 1500);
              setTimeout(() => void logIngestStats('5s'), 5000);
            }
            break;
          }
          default:
            replyErr(ws, requestId, `unknown type: ${msg.type}`);
        }
      } catch (e) {
        console.error('ws handler error:', e);
        replyErr(ws, msg.requestId, e.message || String(e));
      }
    });

    ws.on('close', () => {
      const p = peers.get(ws);
      if (!p) return;
      for (const producer of p.producers.values()) {
        broadcast(peers, ws, { type: 'producerClosed', producerId: producer.id });
        producer.close();
      }
      for (const consumer of p.consumers.values()) {
        consumer.close();
      }
      for (const transport of p.transports.values()) {
        transport.close();
      }
      peers.delete(ws);
      console.log('WebSocket client left; peers=', peers.size);
    });
  });

  httpServer.listen(PORT, HTTP_LISTEN_HOST, () => {
    console.log('mediasoup Worker + Router OK');
    console.log('  worker.pid:', worker.pid);
    console.log('  router.id:', router.id);
    console.log('  rtc ports:', RTC_MIN_PORT, '-', RTC_MAX_PORT);
    console.log(
      '  WebRtcTransport listenIps (browser only):',
      JSON.stringify(listenIpConfig()),
    );
    console.log('HTTP + WebSocket bind:', `${HTTP_LISTEN_HOST}:${PORT}`);
    console.log(
      '  PILOT_VERSION:',
      PILOT_VERSION,
      `(验证: curl -sS http://127.0.0.1:${PORT}/__pilot_version)`,
    );
    const ann = process.env.MEDIASOUP_ANNOUNCED_IP;
    if (ann) console.log('  Remote browser URL:', `http://${ann}:${PORT}/`);
    else console.log('  Remote browser URL: set MEDIASOUP_ANNOUNCED_IP (e.g. EIP) for WebRTC + bookmark');
    console.log('Layer B: Tab1「发布摄像头」, Tab2「仅观看」.');
    if (process.env.MEDIASOUP_INGEST_TEST === '1') {
      if (ingestCtx.ingestReady) {
        console.log(
          'Layer C1: ingest OK — 推荐: bash scripts/run-c1-ffmpeg-ingest.sh（自动解析日志）；再浏览器「仅观看」.',
        );
      } else {
        console.warn(
          'Layer C1: MEDIASOUP_INGEST_TEST=1 but ingest did NOT start (see error above). FFmpeg will not work until fixed.',
        );
      }
    }
    if (c2Enabled()) {
      console.log(
        'Layer C2: PILOT_C2_ENABLED=1 — POST /api/c2/tap（adb）；C2_ADB_SERIAL=',
        process.env.C2_ADB_SERIAL || process.env.ANDROID_SERIAL || '127.0.0.1:5555',
        '；设备逻辑分辨率 C2_DEVICE_WIDTH x C2_DEVICE_HEIGHT =',
        process.env.C2_DEVICE_WIDTH || '720',
        'x',
        process.env.C2_DEVICE_HEIGHT || '1280',
        '。公网务必配 PILOT_C2_TOKEN。',
      );
    } else {
      console.log('Layer C2: 未启用（设 PILOT_C2_ENABLED=1 且镜像含 adb，见 README §C2）。');
    }
    console.log('Press Ctrl+C to exit.');
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
