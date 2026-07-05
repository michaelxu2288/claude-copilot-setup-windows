# claude-remote helpers — sourced from ~/.zshrc
# the gateway config (base url + token + models) lives in the normal ~/.claude profile.

CC_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"

# --- litellm gateway ---
# one command: (re)start the gateway and confirm it's live
llm() {
  open -ga Docker
  docker restart litellm 2>/dev/null || docker start litellm
  sleep 2
  local code
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:4000/health/liveliness 2>/dev/null)
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    echo "litellm up on http://127.0.0.1:4000 (HTTP $code)"
  else
    echo "litellm not answering yet — give Docker a few more seconds, then run: llm"
  fi
}

# --- claude agents in tmux ---
# ccnew a1        start a new detached agent session named a1
# cclist          list running agent sessions
# cckill a1       stop agent a1
# attach locally: tmux attach -t a1   |  from phone: mosh mac -- tmux attach -t a1
ccnew() {
  local name="${1:?usage: ccnew <name> [extra claude args]}"; shift 2>/dev/null || true
  tmux new -d -s "$name" "caffeinate -i -s '$CC_BIN' --dangerously-skip-permissions $*"
  echo "agent '$name' started -> tmux attach -t $name   (phone: mosh mac -- tmux attach -t $name)"
}
cclist() { tmux ls 2>/dev/null || echo "no tmux sessions"; }
cckill() { tmux kill-session -t "${1:?usage: cckill <name>}" && echo "killed $1"; }

# --- keep-awake tied to Ghostty ---
# keeps the MACHINE awake (display + disk still sleep) only while Ghostty is open.
# hangs in the foreground; Ctrl-C to release, or it releases when Ghostty quits.
wake() {
  local pid; pid=$(pgrep -i ghostty | head -1)
  if [ -n "$pid" ]; then
    echo "awake while Ghostty (pid $pid) is open — Ctrl-C to stop"
    caffeinate -is -w "$pid"
  else
    echo "Ghostty not detected; holding awake until Ctrl-C"
    caffeinate -is
  fi
}
