#!/usr/bin/env node
'use strict';
/**
 * 唯一真相：package.json 的 "pilotVersion"。
 * 将 public/app.mjs、public/index.html 中所有 pilot-YYYYMMDD… 占位替换为该值（供 npm run build:client / Docker 构建前一致）。
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const pkgPath = path.join(root, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
const v = pkg.pilotVersion;
if (!v || typeof v !== 'string') {
  console.error('package.json 缺少字符串字段 "pilotVersion"（例如 "pilot-20260207q"）');
  process.exit(1);
}

const tokenRe = /\bpilot-[0-9]{8}[a-z0-9]*\b/g;
const files = ['public/app.mjs', 'public/index.html'];

for (const rel of files) {
  const p = path.join(root, rel);
  let s = fs.readFileSync(p, 'utf8');
  const n = (s.match(tokenRe) || []).length;
  s = s.replace(tokenRe, v);
  fs.writeFileSync(p, s);
  console.log(`${rel}: pilotVersion → ${v}（替换 ${n} 处 token）`);
}
