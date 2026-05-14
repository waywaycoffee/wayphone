#!/usr/bin/env bash
# ECS 宿主机：检查 C2 API 与 pilot 容器内 adb（experiments/webrtc-sfu-pilot 目录）。
# pilot 使用 network_mode:host 时，HTTP 监听在「宿主机」上，须本机 curl 127.0.0.1:$PORT。
#   bash scripts/c2-smoke.sh
#   PORT=3010 bash scripts/c2-smoke.sh
set -uo pipefail
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_DIR}"

echo "=== docker compose ps (webrtc-sfu-pilot) ==="
set +e
_PS=$(docker compose ps webrtc-sfu-pilot 2>&1)
echo "${_PS}"
set -e

PORT="${PORT:-3000}"
if echo "${_PS}" | grep -qE 'Up|running'; then
  _pe=$(docker compose exec -T webrtc-sfu-pilot printenv PORT 2>/dev/null | tr -d '\r')
  if [[ -n "${_pe}" ]]; then
    PORT="${_pe}"
  fi
fi

echo ""
echo "=== 本机 TCP 监听（期望含 :${PORT}）==="
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -E ":${PORT}\\b" || echo "(ss 未看到 :${PORT} — Node 可能未 bind 或已崩；见下)"
else
  echo "(未安装 ss，跳过)"
fi

if command -v ss >/dev/null 2>&1 && ! ss -tlnp 2>/dev/null | grep -qE ":${PORT}\\b"; then
  echo "" >&2
  echo "WARN: 本机未见 TCP :${PORT} 监听 — 常见原因:" >&2
  echo "  ① pilot 未起: docker compose up -d" >&2
  echo "  ② 实际端口不是 3000: docker compose exec webrtc-sfu-pilot printenv PORT" >&2
  echo "  ③ 容器反复重启: docker compose logs --tail=40 webrtc-sfu-pilot" >&2
  echo "" >&2
fi

echo ""
echo "=== GET http://127.0.0.1:${PORT}/api/c2/status ==="
set +e
_curl_st=$(curl -sS -o /tmp/c2-smoke-status.json -w "%{http_code}" "http://127.0.0.1:${PORT}/api/c2/status" 2>/tmp/c2-smoke-curl.err)
_curl_rc=$?
set -e
if [[ "${_curl_rc}" -ne 0 ]]; then
  echo "curl 失败 (exit ${_curl_rc}): $(cat /tmp/c2-smoke-curl.err 2>/dev/null || true)"
else
  echo "HTTP ${_curl_st}"
  cat /tmp/c2-smoke-status.json 2>/dev/null || true
fi
echo ""

echo "=== pilot 容器内 adb（须镜像已装 android-tools-adb）==="
set +e
docker compose exec -T webrtc-sfu-pilot sh -lc '
  command -v adb >/dev/null 2>&1 || { echo "no adb in container — docker compose build --no-cache"; exit 1; }
  adb version | head -1
  adb devices
  S="${C2_ADB_SERIAL:-127.0.0.1:5555}"
  echo "C2_ADB_SERIAL=$S"
  adb connect "$S" 2>/dev/null || true
  adb -s "$S" shell echo c2-smoke-ok
' 2>&1
set -e

echo ""
echo "=== POST /api/c2/tap（中心点探针；须 PILOT_C2_ENABLED=1）==="
set +e
_curl2=$(curl -sS -o /tmp/c2-smoke-tap.json -w "%{http_code}" -X POST "http://127.0.0.1:${PORT}/api/c2/tap" \
  -H 'Content-Type: application/json' \
  -d '{"vx":360,"vy":640,"vw":720,"vh":1280}' 2>/tmp/c2-smoke-curl2.err)
_rc2=$?
set -e
if [[ "${_rc2}" -ne 0 ]]; then
  echo "curl 失败 (exit ${_rc2}): $(cat /tmp/c2-smoke-curl2.err 2>/dev/null || true)"
else
  echo "HTTP ${_curl2}"
  cat /tmp/c2-smoke-tap.json 2>/dev/null || true
fi
echo ""
