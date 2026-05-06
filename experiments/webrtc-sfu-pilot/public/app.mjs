import { Device } from './mediasoup-client.esm.js';

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
  remoteVideo.srcObject = new MediaStream([consumer.track]);
  consumedProducerIds.add(producerId);
  log(`正在播放远端轨 consumer=${consumer.id}`);
  try {
    await remoteVideo.play();
  } catch (e) {
    log(`远端 video.play 失败: ${e.message}（可试点击页面后再点「仅观看」）`);
  }
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
      await flushProducerQueue();
      log('已订阅已有发布者');
    } else {
      log('当前还没有发布者，等待 newProducer…');
    }
    await flushProducerQueue();
  } catch (e) {
    log(`观看失败: ${e.message}`);
    console.error(e);
  }
});

function connectWs() {
  ws = new WebSocket(wsUrl);
  ws.addEventListener('open', () => {
    log(`WebSocket 已连接 ${wsUrl}`);
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
