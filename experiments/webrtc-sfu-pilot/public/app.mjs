import { Device } from './mediasoup-client.esm.js';

/** 与 index.html `<meta name="pilot-frontend-version">` 一致；由 npm run build:client 从 package.json 写入 */
function readPilotFrontendVersion() {
  const m = document.querySelector('meta[name="pilot-frontend-version"]');
  const c = m?.getAttribute('content')?.trim();
  return c && c.length > 0 ? c : 'unknown';
}

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

/** 短时间多次 play() 会触发 AbortError；合并为一次延迟 play */
let remotePlayTimer;
let remotePlayLastReason = '';

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

/** 区分「SFU→浏览器没收 RTP」与「收到了但解不出」；negotiatedMime 如 video/VP8 用于纠正提示文案 */
async function logRecvDiagnostics(
  label,
  consumer,
  recvTransport,
  sawRemoteUnmuteRef,
  negotiatedMime = '',
) {
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
    if (parts.length) {
      log(`${label} consumer.getStats: ${parts.join(' | ')}`);
    } else {
      const types = [];
      for (const s of rs.values()) {
        types.push(s.type + (s.kind ? `/${s.kind}` : ''));
      }
      log(
        `${label} consumer.getStats: 无 inbound-rtp（本浏览器统计类型: ${types.slice(0, 12).join(', ') || '空'}）`,
      );
    }
  } catch (e) {
    log(`${label} consumer.getStats 失败: ${e.message}`);
  }
  try {
    const ts = await recvTransport.getStats();
    let videoBytes = 0;
    let otherRtpBytes = 0;
    let decoded;
    for (const s of ts.values()) {
      if (s.type === 'inbound-rtp') {
        const b = Number(s.bytesReceived || 0);
        if (s.kind === 'video') {
          videoBytes += b;
          if (s.framesDecoded != null) decoded = s.framesDecoded;
        } else {
          otherRtpBytes += b;
        }
      }
    }
    let line =
      `${label} transport.getStats: video-bytes≈${videoBytes}` +
      (otherRtpBytes > 0 ? ` 其它inbound-rtp≈${otherRtpBytes}` : '') +
      (decoded != null ? ` framesDecoded=${decoded}` : ' framesDecoded=(无统计)');
    // ~1e4 且 1s/3s 不变：多为 DTLS/握手，不是「已有视频流」；勿与解码问题混淆
    if (videoBytes < 80000 && (decoded === 0 || decoded === undefined)) {
      line +=
        ' → 字节偏少：更像未收到持续视频 RTP。查 ① 宿主机是否在跑 c1:ingest / c1:ingest:adb（容器重启后须重跑）② MEDIASOUP_ANNOUNCED_IP=公网EIP ③ 安全组入站 UDP 40000–49999 ④ docker logs「PlainTransport|FFmpeg→SFU」是否在涨。';
    } else if (videoBytes >= 80000 && (decoded === 0 || decoded === undefined)) {
      if (String(negotiatedMime).includes('VP8')) {
        line +=
          ' → VP8 已较多字节仍无帧：run-c1+vp8、核对服务端 ingest 与 PT；仍异常再查网络。';
      } else {
        line +=
          ' → 已收到较多字节仍无解码帧：可试 MEDIASOUP_INGEST_CODEC=vp8 + 宿主机 vp8 彩条，见 README。';
      }
    } else if (videoBytes < 500 && otherRtpBytes > 2000) {
      line +=
        ' → video-bytes 很低但其它 RTP 有量：可能统计未标 kind=video，或 SFU 未转发到本路 video consumer。';
    }
    log(line);
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

  function schedulePlayRemoteVideo(reason) {
    remoteVideo.muted = true;
    remotePlayLastReason = reason;
    clearTimeout(remotePlayTimer);
    remotePlayTimer = setTimeout(async () => {
      const r = remotePlayLastReason;
      try {
        await remoteVideo.play();
        log(`远端 video.play OK（${r}）`);
      } catch (e) {
        if (e.name === 'AbortError') {
          log(
            `远端 video.play（${r}）: AbortError（多为上一路 play 未结束；已合并调度，若仍无画面请看 framesDecoded 与 SFU ingest 日志）`,
          );
        } else {
          log(`远端 video.play（${r}）: ${e.name} — ${e.message}`);
        }
      }
    }, 160);
  }

  track.addEventListener('unmute', () => {
    sawRemoteUnmuteRef.v = true;
    log('远端 video 轨 unmute（开始收到媒体）');
    void schedulePlayRemoteVideo('unmute 后重试');
  });
  track.addEventListener('mute', () => log('远端 video 轨 mute（暂无媒体帧，多为网络/NAT）'));
  track.addEventListener('ended', () => log('远端 video 轨 ended'));
  remoteVideo.srcObject = new MediaStream([track]);
  consumedProducerIds.add(producerId);
  const vcodec = consumer.rtpParameters?.codecs?.[0];
  log(
    `正在播放远端轨 consumer=${consumer.id} readyState=${track.readyState} track.muted=${track.muted}`,
  );
  log(
    `远端协商编码: ${vcodec?.mimeType || '?'} PT=${vcodec?.payloadType ?? '?'}` +
      (String(vcodec?.mimeType || '').includes('H264')
        ? '（若一直 framesDecoded=0，请改用 VP8 ingest）'
        : String(vcodec?.mimeType || '').includes('VP8')
          ? '（framesDecoded=0：① 若跑的是 h264 FFmpeg，请把容器 MEDIASOUP_INGEST_CODEC=h264 后重启 SFU；② 若 ingest 为 vp8，宿主机须跑 ffmpeg-ingest-vp8.sh）'
          : ''),
  );
  log('提示：[1s]/[3s] 诊断；video 尺寸仅在 2s / 6s 各打一行，减少刷屏。');
  // unmute 可能在绑定监听器之前就触发，必须在同一轮后补一次 play
  queueMicrotask(() => {
    if (!track.muted) {
      sawRemoteUnmuteRef.v = true;
      log('远端轨已是 unmuted（补绑：立即 play）');
      void schedulePlayRemoteVideo('microtask 已 unmuted');
    }
  });
  remoteVideo.addEventListener(
    'loadeddata',
    () => {
      void schedulePlayRemoteVideo('loadeddata');
    },
    { once: true },
  );
  // controls 下「一直转圈」多为：有 SRTP 字节但解码不出帧（framesDecoded=0）→ readyState 上不去
  remoteVideo.addEventListener('waiting', () => {
    log(
      '远端 video: waiting（缓冲/等可解码帧；若长时间如此请看日志 framesDecoded 与 [1s]/[3s] video-bytes）',
    );
  });
  remoteVideo.addEventListener('stalled', () => log('远端 video: stalled（网络/解码停滞）'));
  remoteVideo.addEventListener('canplay', () => {
    log(`远端 video: canplay ${remoteVideo.videoWidth}x${remoteVideo.videoHeight}`);
  });
  remoteVideo.addEventListener(
    'playing',
    () => {
      log(
        `远端 video playing 事件: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight} paused=${remoteVideo.paused}`,
      );
    },
    { once: true },
  );
  void schedulePlayRemoteVideo('srcObject 后');
  setTimeout(() => void schedulePlayRemoteVideo('1.5s 兜底'), 1500);
  if (typeof remoteVideo.requestVideoFrameCallback === 'function') {
    remoteVideo.requestVideoFrameCallback(() => {
      log(
        `远端 requestVideoFrameCallback: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight}`,
      );
    });
  }
  setTimeout(() => {
    log(
      `[2s] 远端 video: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight} readyState=${remoteVideo.readyState}`,
    );
  }, 2000);
  setTimeout(() => {
    log(
      `[6s] 远端 video: ${remoteVideo.videoWidth}x${remoteVideo.videoHeight} readyState=${remoteVideo.readyState}`,
    );
  }, 6000);
  const negotiatedMime = vcodec?.mimeType || '';
  setTimeout(
    () => logRecvDiagnostics('[1s]', consumer, recvTransport, sawRemoteUnmuteRef, negotiatedMime),
    1000,
  );
  setTimeout(
    () => logRecvDiagnostics('[3s]', consumer, recvTransport, sawRemoteUnmuteRef, negotiatedMime),
    3000,
  );
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
    const plist = list.producers || [];
    /** 多条 video 时勿用首个：优先 Layer C1 PlainTransport ingest（与 FFmpeg 编码一致） */
    const videoP =
      plist.find((p) => p.kind === 'video' && p.appData && p.appData.source === 'plain-ingest-test') ||
      plist.find((p) => p.kind === 'video');
    if (plist.filter((p) => p.kind === 'video').length > 1) {
      log(
        `提示: 当前有 ${plist.filter((p) => p.kind === 'video').length} 路 video，已优先 consume ingest（appData.source=plain-ingest-test）。`,
      );
    }
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
    log(`前端构建 ${readPilotFrontendVersion()} | WebSocket 已连接 ${wsUrl}`);
    void fetch(`/__pilot_version?t=${Date.now()}`, { cache: 'no-store' })
      .then((r) => r.text())
      .then((t) =>
        log(
          `服务端 __pilot_version: ${t.trim()}（与上项不一致 = 镜像内未跑 build:client 或仅重启未重建；ECS: docker compose build --no-cache）`,
        ),
      )
      .catch((e) => log(`__pilot_version 拉取失败: ${e.message}`));
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
