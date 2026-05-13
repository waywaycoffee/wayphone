'use strict';

/**
 * Layer C2 PoC：HTTP → adb shell input（与 WebRTC 解耦）。
 * 由 server.cjs 挂载；生产前宜拆独立服务（见 docs/layer-c-roadmap.md C2）。
 */
const { execFile } = require('child_process');
const express = require('express');

function numEnv(name, def) {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : def;
}

function c2Enabled() {
  return process.env.PILOT_C2_ENABLED === '1' || process.env.PILOT_C2_ENABLED === 'true';
}

function adbSerial() {
  return (
    process.env.C2_ADB_SERIAL ||
    process.env.ANDROID_SERIAL ||
    '127.0.0.1:5555'
  ).trim();
}

function deviceSize() {
  return {
    w: numEnv('C2_DEVICE_WIDTH', 720),
    h: numEnv('C2_DEVICE_HEIGHT', 1280),
  };
}

function maxPerMin() {
  return Math.min(600, Math.max(10, numEnv('PILOT_C2_MAX_PER_MIN', 120)));
}

/** @type {Map<string, { n: number, t0: number }>} */
const rate = new Map();

function rateKey(req) {
  const xf = req.headers['x-forwarded-for'];
  if (typeof xf === 'string' && xf.length) return xf.split(',')[0].trim();
  return req.socket.remoteAddress || 'local';
}

function allowRate(key) {
  const now = Date.now();
  const winMs = 60_000;
  const max = maxPerMin();
  let b = rate.get(key);
  if (!b || now - b.t0 > winMs) {
    b = { n: 0, t0: now };
    rate.set(key, b);
  }
  if (b.n >= max) return false;
  b.n += 1;
  return true;
}

function execAdb(args) {
  return new Promise((resolve, reject) => {
    execFile(
      'adb',
      args,
      { timeout: 12_000, maxBuffer: 512 * 1024, windowsHide: true },
      (err, stdout, stderr) => {
        if (err) {
          err.stderr = stderr;
          err.stdout = stdout;
          reject(err);
        } else resolve({ stdout: stdout || '', stderr: stderr || '' });
      },
    );
  });
}

let adbConnectAttempted = false;

async function ensureAdbTcp() {
  if (adbConnectAttempted) return;
  adbConnectAttempted = true;
  const s = adbSerial();
  if (!/^\d+\.\d+\.\d+\.\d+:\d+$/.test(s)) return;
  try {
    await execAdb(['connect', s]);
  } catch (e) {
    console.warn('Layer C2: adb connect', s, 'failed:', e.message || e);
  }
}

function checkToken(req, res) {
  const tok = process.env.PILOT_C2_TOKEN;
  if (!tok || !String(tok).trim()) return true;
  const h = req.headers.authorization || '';
  const want = `Bearer ${String(tok).trim()}`;
  if (h !== want) {
    res.status(401).json({ ok: false, error: 'unauthorized' });
    return false;
  }
  return true;
}

/**
 * @param {import('express').Express} app
 */
function registerC2Routes(app) {
  const router = express.Router();
  router.use(express.json({ limit: '4kb' }));

  router.get('/status', (_req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    const enabled = c2Enabled();
    const { w, h } = deviceSize();
    res.json({
      ok: true,
      enabled,
      adbSerial: adbSerial(),
      deviceWidth: w,
      deviceHeight: h,
      maxPerMinute: maxPerMin(),
      authRequired: Boolean(process.env.PILOT_C2_TOKEN && String(process.env.PILOT_C2_TOKEN).trim()),
    });
  });

  router.get('/config', (_req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    if (!c2Enabled()) {
      res.status(403).json({ ok: false, error: 'c2_disabled' });
      return;
    }
    const { w, h } = deviceSize();
    res.json({ ok: true, deviceWidth: w, deviceHeight: h });
  });

  router.post('/tap', async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    if (!c2Enabled()) {
      res.status(403).json({ ok: false, error: 'c2_disabled' });
      return;
    }
    if (!checkToken(req, res)) return;
    const key = rateKey(req);
    if (!allowRate(key)) {
      res.status(429).json({ ok: false, error: 'rate_limit' });
      return;
    }

    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const vx = Number(body.vx);
    const vy = Number(body.vy);
    const vw = Number(body.vw);
    const vh = Number(body.vh);
    const { w: dw, h: dh } = deviceSize();

    if (
      !Number.isFinite(vx) ||
      !Number.isFinite(vy) ||
      !Number.isFinite(vw) ||
      !Number.isFinite(vh) ||
      vw < 16 ||
      vh < 16
    ) {
      res.status(400).json({
        ok: false,
        error: 'bad_body',
        hint: '需要 JSON: { vx, vy, vw, vh } 为视频帧内像素坐标与视频宽高（见前端映射）',
      });
      return;
    }

    let x = Math.round((vx * dw) / vw);
    let y = Math.round((vy * dh) / vh);
    x = Math.max(0, Math.min(dw - 1, x));
    y = Math.max(0, Math.min(dh - 1, y));

    const serial = adbSerial();
    const args = ['-s', serial, 'shell', 'input', 'tap', String(x), String(y)];

    try {
      await ensureAdbTcp();
      const out = await execAdb(args);
      res.json({
        ok: true,
        x,
        y,
        deviceWidth: dw,
        deviceHeight: dh,
        adbSerial: serial,
        stderr: out.stderr ? String(out.stderr).slice(0, 200) : '',
      });
    } catch (e) {
      console.warn('Layer C2 tap failed:', e.message || e, e.stderr || '');
      res.status(502).json({
        ok: false,
        error: 'adb_failed',
        message: (e.message || String(e)).slice(0, 300),
      });
    }
  });

  app.use('/api/c2', router);
}

module.exports = { registerC2Routes, c2Enabled };
