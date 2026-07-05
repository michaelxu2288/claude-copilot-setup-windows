#!/bin/zsh
# one-shot: enable SSH + tmux + Tailscale + always-on power on this Mac.
# run once:   zsh ~/bin/setup-remote.sh      (prompts for your sudo password)
set -uo pipefail

echo "== 1/5  SSH (Remote Login) =="
sudo systemsetup -setremotelogin on \
  || echo "  -> if that failed, enable via System Settings > General > Sharing > Remote Login"

echo "== 2/5  tmux + mosh =="
command -v tmux >/dev/null 2>&1 || brew install tmux
command -v mosh >/dev/null 2>&1 || brew install mosh
grep -qs 'mouse on' "$HOME/.tmux.conf" 2>/dev/null || echo 'set -g mouse on' >> "$HOME/.tmux.conf"

echo "== 3/5  Tailscale (system daemon, survives logout) =="
command -v tailscale >/dev/null 2>&1 || brew install tailscale
sudo tailscaled install-system-daemon 2>/dev/null || true
sudo tailscale up --ssh    # opens a browser to sign in (one-time)

echo "== 4/5  always-on power (charger scope only; battery behavior untouched) =="
sudo pmset -c sleep 0 disksleep 0
sudo pmset -a autorestart 1

echo "== 5/5  done =="
echo "  tailnet IP:  $(tailscale ip -4 2>/dev/null || echo '(run: tailscale ip -4)')"
echo "  GUI reminder: System Settings > Battery > Charging > set Charge Limit to 80%."
