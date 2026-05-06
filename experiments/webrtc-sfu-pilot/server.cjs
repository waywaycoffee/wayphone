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

function listenIpConfig() {
  const announcedIp = process.env.MEDIASOUP_ANNOUNCED_IP;
  if (announcedIp && announcedIp.length > 0) {
    return [{ ip: '0.0.0.0', announcedIp }];
  }
  return [{ ip: '127.0.0.1' }];
}

function findProducer(peers, producerId) {
  for (const peer of peers.values()) {
    const p = peer.producers.get(producerId);
    if (p) return p;
  }
  return null;
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

  const app = express();
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
            const producers = [];
            for (const [, p] of peers) {
              for (const prod of p.producers.values()) {
                producers.push({ id: prod.id, kind: prod.kind });
              }
            }
            reply(ws, requestId, { ok: true, producers });
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
    console.log('  listen IPs:', JSON.stringify(listenIpConfig()));
    console.log('HTTP + WebSocket bind:', `${HTTP_LISTEN_HOST}:${PORT}`);
    const ann = process.env.MEDIASOUP_ANNOUNCED_IP;
    if (ann) console.log('  Remote browser URL:', `http://${ann}:${PORT}/`);
    else console.log('  Remote browser URL: set MEDIASOUP_ANNOUNCED_IP (e.g. EIP) for WebRTC + bookmark');
    console.log('Layer B: open two tabs — Tab1「发布摄像头」, Tab2「仅观看」.');
    console.log('Press Ctrl+C to exit.');
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
