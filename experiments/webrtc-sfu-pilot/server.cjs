'use strict';

const http = require('http');
const path = require('path');
const express = require('express');
const WebSocket = require('ws');
const mediasoup = require('mediasoup');

const PORT = Number(process.env.PORT || 3000);
/** 0.0.0.0 = all IPv4 interfaces (explicit; avoids confusion with logs / some host setups). */
const HTTP_LISTEN_HOST = process.env.HTTP_LISTEN_HOST || '0.0.0.0';
const RTC_MIN_PORT = Number(process.env.MEDIASOUP_RTC_MIN_PORT || 40000);
const RTC_MAX_PORT = Number(process.env.MEDIASOUP_RTC_MAX_PORT || 49999);
/** 与前端/镜像一致；`curl http://<EIP>:3000/__pilot_version` 可验证是否已部署新镜像（与浏览器缓存无关） */
const PILOT_VERSION = process.env.PILOT_VERSION || 'pilot-20260207';

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
    producers.push({ id: ingestCtx.producer.id, kind: ingestCtx.producer.kind });
  }
  for (const peer of peers.values()) {
    for (const prod of peer.producers.values()) {
      producers.push({ id: prod.id, kind: prod.kind });
    }
  }
  return producers;
}

/** MEDIASOUP_INGEST_TEST=1：FFmpeg RTP → PlainTransport → Producer（Layer C1 PoC） */
async function setupPlainIngest({ router, peers, ingestCtx, broadcastFn }) {
  if (process.env.MEDIASOUP_INGEST_TEST !== '1') return;

  const RTP_PAYLOAD_TYPE = Number(process.env.MEDIASOUP_INGEST_PT || 96);
  const RTP_SSRC = Number(process.env.MEDIASOUP_INGEST_SSRC || 111222333);
  const ingestCodec = (process.env.MEDIASOUP_INGEST_CODEC || 'h264').toLowerCase();
  const useVp8 = ingestCodec === 'vp8';

  const li = plainTransportListenInfo();
  const plainTransport = await router.createPlainTransport({
    listenInfo: li,
    rtcpMux: true,
    comedia: false,
  });

  ingestCtx.plainTransport = plainTransport;
  console.log('Layer C1 PlainTransport listenInfo:', JSON.stringify(li));

  const videoCodec = useVp8
    ? {
        mimeType: 'video/VP8',
        payloadType: RTP_PAYLOAD_TYPE,
        clockRate: 90000,
        parameters: {},
        rtcpFeedback: [],
      }
    : {
        mimeType: 'video/H264',
        payloadType: RTP_PAYLOAD_TYPE,
        clockRate: 90000,
        parameters: {
          'packetization-mode': 1,
          'profile-level-id': '42e01f',
          'level-asymmetry-allowed': 1,
        },
        rtcpFeedback: [],
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

  producer.on('transportclose', () => {
    console.warn('Layer C1 ingest producer: transport closed');
    ingestCtx.producer = null;
  });

  const tuple = plainTransport.tuple;
  const lip = tuple.localIp || '127.0.0.1';
  const ffmpegHost = lip === '0.0.0.0' || lip === '::' ? '127.0.0.1' : lip;
  const ffmpegPort = tuple.localPort;
  const ffmpegScript = useVp8 ? 'ffmpeg-ingest-vp8.sh' : 'ffmpeg-ingest-h264.sh';

  console.log('');
  console.log(
    `=== Layer C1 ingest (PlainTransport ${useVp8 ? 'VP8' : 'H264'}, FFmpeg test pattern) ===`,
  );
  console.log(
    'MEDIASOUP_INGEST_CODEC:',
    useVp8 ? 'vp8（若 H264 黑屏/framesDecoded=0 可改用此项）' : 'h264（默认）',
  );
  console.log(
    '推荐: bash scripts/run-c1-ffmpeg-ingest.sh  # 从 docker compose logs 解析 host/port 并启动 FFmpeg',
  );
  console.log('mediasoup RTP tuple:', `${lip}:${ffmpegPort}`);
  console.log(`手动（或排错）: bash scripts/${ffmpegScript} ${ffmpegHost} ${ffmpegPort}`);
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
  const worker = await mediasoup.createWorker({
    logLevel: 'warn',
    rtcMinPort: RTC_MIN_PORT,
    rtcMaxPort: RTC_MAX_PORT,
  });

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
    {
      kind: 'video',
      mimeType: 'video/VP8',
      clockRate: 90000,
    },
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
  // 避免浏览器/CDN 强缓存旧 app.mjs（用户曾看到与仓库不一致的日志文案）
  app.use((req, res, next) => {
    if (/\.(mjs|js|html)$/i.test(req.path)) {
      res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
    }
    next();
  });
  app.use(express.static(path.join(__dirname, 'public')));

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
              setTimeout(() => {
                ingestCtx.producer
                  .getStats()
                  .then((stats) => {
                    const v = Array.isArray(stats)
                      ? stats.find((s) => s.type === 'inbound-rtp' && s.kind === 'video')
                      : null;
                    if (v) {
                      console.log(
                        'Layer C1 FFmpeg→SFU (ingest producer):',
                        `packetCount=${v.packetCount} byteCount=${v.byteCount} bitrate=${v.bitrate}`,
                      );
                      if (Number(v.packetCount) === 0) {
                        console.warn(
                          'Layer C1: ingest 收包为 0 — 确认 FFmpeg 在跑；RTP 目标端口正确；脚本已使用 rtcpport=与 RTP 同端口（rtcpMux）。',
                        );
                      }
                    } else {
                      console.log('Layer C1 ingest producer getStats:', JSON.stringify(stats));
                    }
                  })
                  .catch((e) => console.warn('Layer C1 producer getStats failed:', e));
              }, 1500);
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
    console.log('Press Ctrl+C to exit.');
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
