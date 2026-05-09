#!/usr/bin/env node
'use strict';
/**
 * 唯一真相：package.json 的 "pilotVersion"。
 * 将 public/index.html（及含 token 的其它列名文件）中所有 pilot-… 占位替换为该值。
 * public/app.mjs 从 meta 读取版本，通常无 token；Dockerfile 在 COPY public 后执行 npm run build:client 即可对齐。
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const pkgPath = path.join(root, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
const v = pkg.pilotVersion;
if (!v || typeof v !== 'string') {
  console.error('package.json 缺少字符串字段 "pilotVersion"（须匹配 pilot-[8位日期][后缀]，如 pilot-20260506a）');
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
