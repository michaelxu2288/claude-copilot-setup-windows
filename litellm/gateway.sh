#!/usr/bin/env bash
# gateway.sh — start/stop/status the LiteLLM proxy, runtime-agnostic.
# Reads ~/.config/litellm/.runtime (docker|python) and ~/.config/litellm/.master_key.
# Installed to ~/.config/litellm/gateway.sh; run by a LaunchAgent at login.
set -uo pipefail
# a login LaunchAgent inherits a minimal PATH — make brew/colima/docker/litellm reachable
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

LL="$HOME/.config/litellm"
KEY="$(cat "$LL/.master_key" 2>/dev/null || true)"
RT="$(cat "$LL/.runtime" 2>/dev/null || echo python)"
IMG="ghcr.io/berriai/litellm:main-latest"
export LITELLM_MASTER_KEY="$KEY"

health(){ curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:4000/health/liveliness 2>/dev/null; }
wait_health(){ for _ in $(seq 1 45); do [ "$(health)" = 200 ] && return 0; sleep 2; done; return 1; }  # up to 90s (cold docker pull)

start_docker(){
  command -v colima >/dev/null 2>&1 && { colima status >/dev/null 2>&1 || colima start; }
  docker start litellm >/dev/null 2>&1 || \
  docker run -d --name litellm --restart unless-stopped \
    -p 127.0.0.1:4000:4000 -e LITELLM_MASTER_KEY="$KEY" \
    -v "$LL:/root/.config/litellm" "$IMG" \
    --config /root/.config/litellm/config.yaml >/dev/null
}
start_python(){
  pgrep -f 'litellm --config' >/dev/null && return 0
  nohup "$HOME/.local/bin/litellm" --config "$LL/config.yaml" --host 127.0.0.1 --port 4000 >>"$LL/proxy.log" 2>&1 &
}

case "${1:-start}" in
  start)
    if [ "$RT" = docker ]; then start_docker; else start_python; fi
    if wait_health; then echo "gateway up (runtime=$RT, HTTP 200)"; else echo "gateway not healthy yet (runtime=$RT) — if first docker run, the image may still be pulling"; fi;;
  stop)    docker stop litellm >/dev/null 2>&1 || true; pkill -f 'litellm --config' 2>/dev/null || true; echo "stopped";;
  restart) "$0" stop; "$0" start;;
  status)  echo "runtime=$RT  health=$(health)";;
  *) echo "usage: gateway.sh {start|stop|restart|status}"; exit 1;;
esac
