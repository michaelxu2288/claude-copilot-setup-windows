#!/usr/bin/env bash
# uninstall.sh — stop the gateway and restore Claude Code settings.
# Conservative by default: keeps your litellm config + Copilot login.
#   --purge  also remove ~/.config/litellm (config + token) and the /artifact skill
set -uo pipefail
PURGE=0; [[ "${1:-}" == "--purge" ]] && PURGE=1
PLIST="$HOME/Library/LaunchAgents/com.local.litellm-gateway.plist"

echo "==> unloading + removing the login LaunchAgent"
launchctl unload "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST" && echo "  removed $PLIST" || echo "  (no LaunchAgent)"

echo "==> stopping the gateway (docker + python)"
docker rm -f litellm >/dev/null 2>&1 && echo "  removed docker container" || true
pkill -f 'litellm --config' 2>/dev/null && echo "  stopped python proxy" || true

# restore the most recent settings backup install.sh made
latest=$(ls -t "$HOME/.claude/settings.json.bak."* 2>/dev/null | head -1 || true)
if [[ -n "${latest:-}" ]]; then
  cp "$latest" "$HOME/.claude/settings.json"; echo "  restored ~/.claude/settings.json from $(basename "$latest")"
else
  echo "  no settings backup found — leaving ~/.claude/settings.json as-is"
fi

if [[ $PURGE == 1 ]]; then
  echo "==> --purge: removing gateway config, Copilot login, statusline, and /artifact skill"
  rm -rf "$HOME/.config/litellm" "$HOME/.claude/skills/artifact" "$HOME/.claude/statusline-command.sh"
  echo "  purged"
fi
echo "==> done"
