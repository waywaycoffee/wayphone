import { Device } from './mediasoup-client.esm.js';

/** 与 index.html 中 app.mjs 查询参数同步 bump，便于确认已加载新前端 */
const FRONTEND_BUILD = 'pilot-20260206c';

const logEl = document.getElementById('log');
const localVideo = document.getElementById('localVideo');
const remoteVideo = document.getElementById('remoteVideo');

function log(line) {
  logEl.textContent += `${line}\n`;
  logEl.scrollTop = logEl.scrollHeight;
}

const wsUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}`;
const pending = new Map();
const producerQueue = [];
const consumedProducerIds = new Set();
let ws;
let device;
let sendTransport;
let recvTransport;

/** 连续多次 play() 会互相 Abort，必须串行 */
let remotePlayChain = Promise.resolve();

async function flushProducerQueue() {
  if (!recvTransport) return;
  while (producerQueue.length) {
    const producerId = producerQueue.shift();
    try {
      await consumeIfViewer(producerId);
    } catch (e) {
      log(`队列 consume 失败: ${e.message}`);
    }
  }
}

function rpc(type, data = {}) {
  const requestId = `${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
  return new Promise((resolve, reject) => {
    pending.set(requestId, { resolve, reject });
    ws.send(JSON.stringify({ type, requestId, ...data }));
  });
}

function attachWsHandlers() {
  ws.addEventListener('message', async (ev) => {
    let msg;
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    if (msg.requestId != null && pending.has(msg.requestId)) {
      const { resolve, reject } = pending.get(msg.requestId);
      pending.delete(msg.requestId);
      if (msg.ok === false) reject(new Error(msg.error || 'rpc error'));
      else resolve(msg);
      return;
    }
    if (msg.type === 'newProducer' && msg.kind === 'video') {
      log(`事件: newProducer ${msg.producerId}`);
      producerQueue.push(msg.producerId);
      try {
        await flushProducerQueue();
      } catch (e) {
        log(`consume 失败: ${e.message}`);
      }
    }
    if (msg.type === 'producerClosed') {
      log(`事件: producerClosed ${msg.producerId}`);
      consumedProducerIds.delete(msg.producerId);
      if (remoteVideo.srcObject) {
        remoteVideo.srcObject.getTracks().forEach((t) => t.stop());
        remoteVideo.srcObject = null;
      }
    }
  });
}

async function ensureDeviceLoaded() {
  if (device && device.loaded) return;
  const caps = await rpc('getRouterRtpCapabilities');
  device = new Device();
  await device.load({ routerRtpCapabilities: caps.routerRtpCapabilities });
  log('Device.load OK');
}

async function createRecvPipeline() {
  if (recvTransport) {
    log('RecvTransport 已存在，跳过重复创建');
    return;
  }
  await ensureDeviceLoaded();
  const created = await rpc('createWebRtcTransport', {});
  const tInfo = created.transport;
  recvTransport = device.createRecvTransport({
    id: tInfo.id,
    iceParameters: tInfo.iceParameters,
    iceCandidates: tInfo.iceCandidates,
    dtlsParameters: tInfo.dtlsParameters,
  });
  recvTransport.on('connect', ({ dtlsParameters }, callback, errback) => {
    rpc('connectTransport', {
      transportId: recvTransport.id,
      dtlsParameters,
    })
      .then(() => callback())
      .catch((e) => errback(e));
  });
  recvTransport.on('connectionstatechange', () => {
    log(`RecvTransport 连接状态: ${recvTransport.connectionState}`);
  });
  log('RecvTransport 已创建');
}

async function createSendPipeline() {
  if (sendTransport) {
    log('SendTransport 已存在，跳过重复创建');
    return;
  }
  await ensureDeviceLoaded();
  if (!device.canProduce('video')) {
    throw new Error('此浏览器/设备不支持发送 video（canProduce=false）');
  }
  const created = await rpc('createWebRtcTransport', {});
  const tInfo = created.transport;
  sendTransport = device.createSendTransport({
    id: tInfo.id,
    iceParameters: tInfo.iceParameters,
    iceCandidates: tInfo.iceCandidates,
    dtlsParameters: tInfo.dtlsParameters,
  });
  sendTransport.on('connect', ({ dtlsParameters }, callback, errback) => {
    rpc('connectTransport', {
      transportId: sendTransport.id,
      dtlsParameters,
    })
      .then(() => callback())
      .catch((e) => errback(e));
  });
  sendTransport.on('produce', ({ kind, rtpParameters, appData }, callback, errback) => {
    rpc('produce', {
      transportId: sendTransport.id,
      kind,
      rtpParameters,
      appData,
    })
      .then((r) => callback({ id: r.producerId }))
      .catch((e) => errback(e));
  });
  sendTransport.on('connectionstatechange', () => {
    log(`SendTransport 连接状态: ${sendTransport.connectionState}`);
  });
  log('SendTransport 已创建');
}

/** 区分「SFU→浏览器没收 RTP」与「收到了但解不出」；请向下滚动日志区看完整输出 */
async function logRecvDiagnostics(label, consumer, recvTransport, sawRemoteUnmuteRef) {
  try {
    const rs = await consumer.getStats();
    const parts = [];
    for (const s of rs.values()) {
      if (s.type === 'inbound-rtp') {
        parts.push(
          `inbound-rtp kind=${s.kind || '?'} bytes=${s.bytesReceived ?? 0} pkts=${s.packetsReceived ?? 0} decoded=${s.framesDecoded ?? 'n/a'}`,
        );
      }
    }
    log(`${label} consumer.getStats: ${parts.length ? parts.join(' | ') : '无 inbound-rtp'}`);
  } catch (e) {
    log(`${label} consumer.getStats 失败: ${e.message}`);
  }
  try {
    const ts = await recvTransport.getStats();
    let bytes = 0;
    let decoded;
    for (const s of ts.values()) {
      if (s.type === 'inbound-rtp') {
        bytes += Number(s.bytesReceived || 0);
        if (s.kind === 'video' && s.framesDecoded != null) decoded = s.framesDecoded;
      }
    }
    log(
      `${label} transport.getStats: inbound-rtp 合计 bytes≈${bytes}` +
        (decoded != null ? ` framesDecoded=${decoded}` : ''),
    );
  } catch (e) {
    log(`${label} transport.getStats 失败: ${e.message}`);
  }
  if (!sawRemoteUnmuteRef.v) {
    log(
      `${label} 仍未触发「远端 unmute」— 若 bytes≈0：查 ECS 安全组 UDP 40000–49999；若 bytes>0 仍黑屏：换 Chrome 试或看服务端 ingest 收包统计`,
    );
  }
}

async function consumeIfViewer(producerId) {
  if (!recvTransport) return;
  if (consumedProducerIds.has(producerId)) return;
  const r = await rpc('consume', {
    transportId: recvTransport.id,
    producerId,
    rtpCapabilities: device.rtpCapabilities,
  });
  const c = r.consumer;
  const consumer = await recvTransport.consume({
    id: c.id,
    producerId: c.producerId,
    kind: c.kind,
    rtpParameters: c.rtpParameters,
    producerPaused: c.producerPaused,
  });
  await rpc('resumeConsumer', { consumerId: c.id });
  if (consumer.paused) {
    consumer.resume();
  }
  const track = consumer.track;
  const sawRemoteUnmuteRef = { v: false };

  function tryPlayRemoteVideo(reason) {
    remoteVideo.muted = true;
    remotePlayChain = remotePlayChain.then(async () => {
      try {
        await remoteVideo.play();
        log(`远端 video.play OK（${reason}）`);
      } catch (e) {
        log(`远端 video.play（${reason}）: ${e.name} — ${e.message}`);
      }
    });
    return remotePlayChain;
  }

  track.addEventListener('unmute', () => {
    sawRemoteUnmuteRef.v = true;
    log('远端 video 轨 unmute（开始收到媒体）');
    void tryPlayRemoteVideo('unmute 后重试');
  });
  track.addEventListener('mute', () => log('远端 video 轨 mute（暂无媒体帧，多为网络/NAT）'));
  track.addEventListener('ended', () => log('远端 video 轨 ended'));
  remoteVideo.srcObject = new MediaStream([track]);
  consumedProducerIds.add(producerId);
  log(
    `正在播放远端轨 consumer=${consumer.id} readyState=${track.readyState} track.muted=${track.muted}`,
  );
  log('提示：向下滚动看 [1s]/[3s] 诊断；video 尺寸多次采样在下方。');
  // unmute 可能在绑定监听器之前就触发，必须在同一轮后补一次 play
  queueMicrotask(() => {
    if (!track.muted) {
      sawRemoteUnmuteRef.v = true;
      log('远端轨已是 unmuted（补绑：立即 play）');
      void tryPlayRemoteVideo('microtask 已 unmuted');
    }
  });
  remoteVideo.addEventListener(
    'loadeddata',
    () => {
      void tryPlayRemoteVideo('loadeddata');
    },
    { once: true },
  );
  remoteVideo.addEventListener(
    'playing',
    () => {
      log(
        `远端 video playing 事件: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight} paused=${remoteVideo.paused}`,
      );
    },
    { once: true },
  );
  void tryPlayRemoteVideo('srcObject 后首次');
  setTimeout(() => void tryPlayRemoteVideo('400ms 后'), 400);
  setTimeout(() => void tryPlayRemoteVideo('1.2s 后'), 1200);
  if (typeof remoteVideo.requestVideoFrameCallback === 'function') {
    remoteVideo.requestVideoFrameCallback(() => {
      log(
        `远端 requestVideoFrameCallback: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight}`,
      );
    });
  }
  let polls = 0;
  const dimTimer = setInterval(() => {
    polls += 1;
    log(
      `[${polls * 500}ms] 远端 video: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight} paused=${remoteVideo.paused} readyState=${remoteVideo.readyState}`,
    );
    if (polls >= 12) clearInterval(dimTimer);
  }, 500);
  setTimeout(() => logRecvDiagnostics('[1s]', consumer, recvTransport, sawRemoteUnmuteRef), 1000);
  setTimeout(() => logRecvDiagnostics('[3s]', consumer, recvTransport, sawRemoteUnmuteRef), 3000);
}

document.getElementById('btnPublish').addEventListener('click', async () => {
  try {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      log('请先等待 WebSocket 连接');
      return;
    }
    if (!navigator.mediaDevices || typeof navigator.mediaDevices.getUserMedia !== 'function') {
      log(
        '发布失败: 当前页面不是「安全上下文」，浏览器禁用了摄像头 API（常见于用 http://公网IP 打开）。' +
          ' 解决: ① 在本机执行 SSH 端口转发后只用 http://127.0.0.1:3000 打开页面；② 或为站点配置 HTTPS（域名+证书）。见 docs/webrtc-sfu-pilot.md §3.2。',
      );
      return;
    }
    await createSendPipeline();
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 640 }, height: { ideal: 360 } },
      audio: false,
    });
    localVideo.srcObject = stream;
    const track = stream.getVideoTracks()[0];
    await sendTransport.produce({ track });
    log('已 produce 摄像头（另一 Tab 点「仅观看」应能看到）');
  } catch (e) {
    log(`发布失败: ${e.message}`);
    console.error(e);
  }
});

document.getElementById('btnWatch').addEventListener('click', async () => {
  try {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      log('请先等待 WebSocket 连接');
      return;
    }
    await createRecvPipeline();
    const list = await rpc('listProducers');
    const videoP = (list.producers || []).find((p) => p.kind === 'video');
    if (videoP) {
      producerQueue.push(videoP.id);
    } else {
      log('当前还没有发布者，等待 newProducer…');
    }
    await flushProducerQueue();
    if (videoP) {
      log('已订阅已有发布者');
    }
  } catch (e) {
    log(`观看失败: ${e.message}`);
    console.error(e);
  }
});

function connectWs() {
  ws = new WebSocket(wsUrl);
  ws.addEventListener('open', () => {
    log(`前端构建 ${FRONTEND_BUILD} | WebSocket 已连接 ${wsUrl}`);
    attachWsHandlers();
  });
  ws.addEventListener('close', () => {
    log('WebSocket 断开');
  });
  ws.addEventListener('error', () => {
    log('WebSocket 错误');
  });
}

connectWs();
