#!/usr/bin/env bash
# install.sh — set up Claude Code + Opus 4.8 via a local LiteLLM→GitHub Copilot proxy.
#
# Auth modes:
#   • SEED  : put your Copilot access-token in .env (COPILOT_ACCESS_TOKEN=ghu_...) → it's
#             written to the proxy's token file, NO GitHub OAuth/2FA. Your token, your device.
#   • OAUTH : no token in .env → normal GitHub Copilot device login.
#
# Runtime: native Python (pipx) by default — most reliable on a fresh Mac. Docker (via
# Colima) only if you pass --docker or a working docker engine is already present.
# Flags: --docker | --python (force) · --remote (also install ssh/tailscale/tmux helpers)
set -uo pipefail

# --- make brew + user-local bins reachable in THIS shell (agents run each step fresh) ---
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LL_DIR="$HOME/.config/litellm"
KEYFILE="$LL_DIR/.master_key"
GC_DIR="$LL_DIR/github_copilot"

log(){ printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok(){  printf "\033[1;32m  ok\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m  ! \033[0m %s\n" "$*"; }
die(){ printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# --- load .env FIRST (COPILOT_ACCESS_TOKEN, optional RUNTIME/LITELLM_MASTER_KEY) --------
if [[ -f "$REPO/.env" ]]; then set -a; . "$REPO/.env"; set +a; ok "loaded .env"; fi
# sanitize a pasted token: strip CR (CRLF files), surrounding quotes, and whitespace
if [[ -n "${COPILOT_ACCESS_TOKEN:-}" ]]; then
  COPILOT_ACCESS_TOKEN="${COPILOT_ACCESS_TOKEN//$'\r'/}"
  COPILOT_ACCESS_TOKEN="${COPILOT_ACCESS_TOKEN//\"/}"; COPILOT_ACCESS_TOKEN="${COPILOT_ACCESS_TOKEN//\'/}"
  COPILOT_ACCESS_TOKEN="${COPILOT_ACCESS_TOKEN// /}"
fi

# --- args OVERRIDE .env (flags win) ---------------------------------------
RUNTIME="${RUNTIME:-auto}"; WITH_REMOTE=0
for a in "$@"; do case "$a" in
  --docker) RUNTIME=docker;; --python) RUNTIME=python;;
  --remote) WITH_REMOTE=1;; *) warn "unknown arg: $a";; esac; done

# --- 1. deps ---------------------------------------------------------------
log "Checking dependencies"
[[ "$(uname)" == "Darwin" ]] || die "this installer targets macOS"
command -v brew >/dev/null || die "Homebrew not found on PATH. Run: eval \"\$(/opt/homebrew/bin/brew shellenv)\" (or install from https://brew.sh) then re-run"
python3 -c 'import sys' >/dev/null 2>&1 || brew install python   # real test: /usr/bin/python3 may be a CLT stub
command -v jq >/dev/null 2>&1 || brew install jq                 # for the statusline
command -v curl >/dev/null || die "curl required"
mkdir -p "$LL_DIR"
ok "base deps present"

# --- 2. litellm config + gateway control script ----------------------------
log "Writing $LL_DIR/config.yaml"
[[ -f "$LL_DIR/config.yaml" ]] && cp "$LL_DIR/config.yaml" "$LL_DIR/config.yaml.bak.$(date +%s)"
cp "$REPO/litellm/config.yaml" "$LL_DIR/config.yaml"
cp "$REPO/litellm/gateway.sh" "$LL_DIR/gateway.sh"; chmod +x "$LL_DIR/gateway.sh"
ok "config + gateway control script written"

# --- 3. local gateway master key (per machine; guards only 127.0.0.1:4000) --
if [[ -s "$KEYFILE" ]]; then MASTER_KEY="$(cat "$KEYFILE")"; ok "reusing local gateway key"
elif [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then MASTER_KEY="$LITELLM_MASTER_KEY"; umask 077; printf '%s' "$MASTER_KEY" > "$KEYFILE"; ok "using LITELLM_MASTER_KEY from .env"
else MASTER_KEY="sk-$(openssl rand -hex 24)"; umask 077; printf '%s' "$MASTER_KEY" > "$KEYFILE"; ok "generated local gateway key"; fi

# --- 4. SEED the Copilot token if provided (skips OAuth) --------------------
SEEDED=0
if [[ -n "${COPILOT_ACCESS_TOKEN:-}" ]]; then
  mkdir -p "$GC_DIR"; umask 077
  printf '%s' "$COPILOT_ACCESS_TOKEN" > "$GC_DIR/access-token"; chmod 600 "$GC_DIR/access-token"
  SEEDED=1; ok "seeded Copilot access-token from .env — device login will be skipped"
  case "$COPILOT_ACCESS_TOKEN" in ghu_*|gho_*) : ;; *) warn "token doesn't start with ghu_/gho_ — double-check you pasted it raw (no quotes)";; esac
fi

# --- 5. pick + prepare the runtime ----------------------------------------
setup_python(){
  command -v pipx >/dev/null || brew install pipx
  pipx ensurepath >/dev/null 2>&1 || true
  [[ -x "$HOME/.local/bin/litellm" ]] || pipx install "litellm[proxy]" || return 1
}
setup_docker(){
  if ! docker info >/dev/null 2>&1; then
    command -v colima >/dev/null || brew install colima docker || return 1
    colima status >/dev/null 2>&1 || colima start || return 1
  fi
  docker info >/dev/null 2>&1
}
log "Preparing proxy runtime (requested: $RUNTIME)"
case "$RUNTIME" in
  docker) setup_docker || die "docker runtime failed; retry with --python";;
  python) setup_python || die "python runtime failed";;
  auto)   if docker info >/dev/null 2>&1; then RUNTIME=docker; ok "existing docker engine detected"
          else setup_python && RUNTIME=python || die "python runtime failed"; fi;;
esac
printf '%s' "$RUNTIME" > "$LL_DIR/.runtime"
ok "runtime = $RUNTIME"

# --- 6. start the gateway --------------------------------------------------
log "Starting the LiteLLM gateway on 127.0.0.1:4000"
"$LL_DIR/gateway.sh" start || warn "gateway start reported an issue; will verify below"

# --- 7. OAUTH device login (only if we didn't seed a token) ----------------
if [[ $SEEDED -eq 0 && ! -s "$GC_DIR/access-token" ]]; then
  log "No token seeded — starting GitHub Copilot device login"
  warn "Authenticate with your GitHub account (the one holding your Copilot seat)."
  ( curl -s -m 300 http://127.0.0.1:4000/v1/chat/completions \
      -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
      -d '{"model":"claude-opus-4-8[1m]","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' >/dev/null 2>&1 & )
  echo "  Watch for: https://github.com/login/device  and a code to enter."
  waited=0
  while [[ ! -s "$GC_DIR/access-token" && $waited -lt 300 ]]; do
    { [[ "$RUNTIME" == docker ]] && docker logs litellm 2>&1 || cat "$LL_DIR/proxy.log" 2>/dev/null; } \
      | grep -iE "github.com/login/device|enter .*code|user.?code" | tail -1
    sleep 5; waited=$((waited+5))
  done
  [[ -s "$GC_DIR/access-token" ]] && ok "device login complete" || die "device login timed out — see '$LL_DIR/gateway.sh status' and logs"
fi

# --- 8. Claude Code + settings --------------------------------------------
if ! command -v claude >/dev/null; then
  log "Installing Claude Code"
  command -v node >/dev/null || brew install node
  npm i -g @anthropic-ai/claude-code || warn "Claude Code install failed — install from https://code.claude.com/docs"
fi
log "Installing statusline script"
cp "$REPO/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh" 2>/dev/null || { mkdir -p "$HOME/.claude"; cp "$REPO/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"; }
chmod +x "$HOME/.claude/statusline-command.sh"
log "Writing ~/.claude/settings.json (Opus 4.8 1M + your settings)"
if python3 - "$REPO/claude/settings.template.json" "$HOME/.claude/settings.json" "$MASTER_KEY" <<'PY'
import json, os, sys, time
tmpl = json.load(open(sys.argv[1])); dst_path, key = sys.argv[2], sys.argv[3]
dst = {}
if os.path.exists(dst_path):
    raw = open(dst_path).read()
    open(dst_path + ".bak." + str(int(time.time())), "w").write(raw)   # back up RAW bytes
    try: dst = json.loads(raw)
    except Exception: dst = {}
if not isinstance(dst, dict): dst = {}                       # existing file could be a list/scalar
env = {k: (key if v == "__MASTER_KEY__" else v) for k, v in tmpl.get("env", {}).items()}
if not isinstance(dst.get("env"), dict): dst["env"] = {}
dst["env"].update(env)                                        # ours win, user's other env keys preserved
for k, v in tmpl.items():                                     # top-level keys (model, statusLine, ...)
    if k != "env": dst[k] = v
json.dump(dst, open(dst_path, "w"), indent=2)
print("  merged env + top-level settings into", dst_path)
PY
then ok "settings written"; else die "settings merge failed"; fi

# --- 9. /artifact skill (idempotent) --------------------------------------
log "Installing /artifact skill"
mkdir -p "$HOME/.claude/skills"; rm -rf "$HOME/.claude/skills/artifact"
cp -R "$REPO/skills/artifact" "$HOME/.claude/skills/artifact"
ok "skill installed"

# --- 10. persistence: start the gateway at login (with a real PATH) --------
log "Installing login LaunchAgent"
PLIST="$HOME/Library/LaunchAgents/com.local.litellm-gateway.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local.litellm-gateway</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$LL_DIR/gateway.sh</string><string>start</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LL_DIR/launchagent.log</string>
  <key>StandardErrorPath</key><string>$LL_DIR/launchagent.log</string>
</dict></plist>
PLISTEOF
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST" >/dev/null 2>&1 && ok "LaunchAgent loaded" || warn "couldn't load LaunchAgent; after reboot run: $LL_DIR/gateway.sh start"

# --- optional remote helpers ----------------------------------------------
if [[ $WITH_REMOTE -eq 1 ]]; then
  log "Installing remote-access helpers"
  cp "$REPO/remote/claude-remote.zsh" "$HOME/.claude-remote.zsh"
  mkdir -p "$HOME/bin"; cp "$REPO/remote/setup-remote.sh" "$HOME/bin/setup-remote.sh"; chmod +x "$HOME/bin/setup-remote.sh"
  grep -qs 'claude-remote.zsh' "$HOME/.zshrc" 2>/dev/null || echo '[ -f "$HOME/.claude-remote.zsh" ] && source "$HOME/.claude-remote.zsh"' >> "$HOME/.zshrc"
  ok "remote helpers installed (run ~/bin/setup-remote.sh to enable SSH+Tailscale)"
fi

# --- verify (exit non-zero if the model doesn't actually answer) -----------
log "Verifying Opus 4.8 through the gateway"
for i in {1..45}; do [[ "$(curl -s -o /dev/null -m3 -w '%{http_code}' http://127.0.0.1:4000/health/liveliness)" == 200 ]] && break; sleep 2; done
resp=$(curl -s -m 90 http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-8[1m]","messages":[{"role":"user","content":"reply with the single word: ready"}],"max_tokens":16}' 2>/dev/null)
echo; log "Start Claude Code with:  claude   (verify with /status → Opus 4.8 1M)"
echo "     gateway control:  $LL_DIR/gateway.sh {start|stop|restart|status}"
if echo "$resp" | grep -qi ready && command -v claude >/dev/null; then ok "Opus 4.8 responded + Claude Code present — setup complete"; exit 0
else warn "setup NOT fully verified:"
  echo "$resp" | grep -qi ready || { echo "$resp" | head -c 400; echo; warn "model test didn't return 'ready' — token stale/revoked, or org hasn't enabled Claude models."; }
  command -v claude >/dev/null || warn "Claude Code not on PATH — install it (README Phase C)."
  exit 1; fi
