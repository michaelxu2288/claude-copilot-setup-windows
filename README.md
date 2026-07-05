# claude-copilot-setup (Windows) — hand-off runbook

Turn a **fresh Windows PC** into **Claude Code running Opus 4.8**, via a local
**LiteLLM proxy → GitHub Copilot**. Assumes the machine has **nothing** — no Python,
Node, Docker, LiteLLM, or Claude Code (only `winget`, which ships with Windows 10/11).

> Windows port of [`claude-copilot-setup`](https://github.com/michaelxu2288/claude-copilot-setup)
> (macOS). Same product, PowerShell instead of bash. Auth is done by **seeding one token** —
> no GitHub OAuth/2FA login on this machine.

Two parts, easiest-first:
- **PART 1 — get Opus 4.8 working in the CLI (do this first).** Native-Python proxy, fastest to green.
- **PART 2 — permanent + extras (after Part 1 works).** Scheduled-Task auto-start (or Docker), status line, `/artifact` skill, remote access, docs-wiki harness.

> **The only manual human step:** paste one token into `.env`.

**Run everything in PowerShell (not cmd).** Scripts are unsigned, so always launch them with
`powershell -ExecutionPolicy Bypass -File <script>` (a fresh PC defaults to `Restricted` and
will otherwise refuse to run `.ps1` files).

---

## The one manual step (do this first)

Get your Copilot access-token from a machine that already works:
```powershell
# macOS source:   cat ~/.config/litellm/github_copilot/access-token
# Windows source: Get-Content "$env:USERPROFILE\.config\litellm\github_copilot\access-token"
```
On this PC, in the repo, put it in `.env` (raw — no quotes, no trailing spaces):
```powershell
cd claude-copilot-setup-windows
Copy-Item .env.example .env
notepad .env      # set  COPILOT_ACCESS_TOKEN=ghu_xxxxxxxx...
```

---

## Fast path (recommended)
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
This does **Part 1 + the permanent bits (2A Scheduled Task, 2B statusline + full settings,
2C /artifact skill)** in one shot, and refreshes PATH itself between installs.
Switches: `-Python` (default runtime) · `-Docker` (Docker Desktop) · `-Remote` (SSH+Tailscale).
It does **not** set up the docs-wiki harness (2E) or optional hooks (2F) — those stay manual.
If it fails partway, fall back to the numbered manual steps below (same actions, debuggable).

---

# PART 1 — get Opus 4.8 running in the CLI (easiest, manual)

**Goal:** `claude` answers on Opus 4.8. First `cd` into the repo (steps use relative paths):
```powershell
cd path\to\claude-copilot-setup-windows
```
> **Shell-reopen rule (important):** `winget` updates the *persistent* PATH, not your current
> window. If a tool isn't found right after installing it, **close + reopen PowerShell, `cd`
> back to the repo, and re-run any `$LL` / `$KEY` / `$t` assignments** — variables don't survive
> a new shell. (`install.ps1` avoids this by refreshing PATH in-process.)

### 1. Python (via winget)
```powershell
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { winget install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements }
```
**Verify:** `python --version` prints 3.x. If "not found", reopen PowerShell.
**If `python` opens the Microsoft Store or prints nothing**, disable the App-execution aliases
for `python`/`python3` (Settings → Apps → Advanced app settings → App execution aliases), or use `py`.

### 2. The proxy (LiteLLM via pipx)
```powershell
python -m pip install --user pipx
python -m pipx ensurepath
$env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
python -m pipx install "litellm[proxy]"
```
**Verify:** `litellm --version`.

### 3. Claude Code (via Node)
```powershell
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements }
```
Node may raise a UAC prompt. **After it installs, close + reopen PowerShell and `cd` back**
(so `npm` is on PATH), then:
```powershell
npm install -g @anthropic-ai/claude-code
```
**Verify:** `claude --version` (reopen again if not found).

### 4. Gateway config + local key
```powershell
$LL = "$env:USERPROFILE\.config\litellm"
New-Item -ItemType Directory -Force $LL | Out-Null
Copy-Item litellm\config.yaml "$LL\config.yaml" -Force
Copy-Item litellm\gateway.ps1 "$LL\gateway.ps1" -Force
if (-not (Test-Path "$LL\.master_key")) { Set-Content -NoNewline "$LL\.master_key" ("sk-" + (-join ((1..48) | % { '{0:x}' -f (Get-Random -Max 16) }))) }
$KEY = (Get-Content "$LL\.master_key" -Raw).Trim()
```

### 5. Seed your Copilot token (skips the GitHub login)
```powershell
$t = ((Select-String '^COPILOT_ACCESS_TOKEN=' .env).Line -replace '^COPILOT_ACCESS_TOKEN=','').Trim().Trim('"').Replace("`r","").Replace(" ","")
New-Item -ItemType Directory -Force "$LL\github_copilot" | Out-Null
Set-Content -NoNewline "$LL\github_copilot\access-token" $t
```
**Verify:** `(Get-Content "$LL\github_copilot\access-token").Substring(0,4)` prints `ghu_` (or `gho_`).

### 6. Start the proxy (native Python)
```powershell
Set-Content -NoNewline "$LL\.runtime" "python"
powershell -NoProfile -ExecutionPolicy Bypass -File "$LL\gateway.ps1" start
```
**Verify:** `powershell -NoProfile -ExecutionPolicy Bypass -File "$LL\gateway.ps1" status` shows `health=200`.
**If it fails:** `Get-Content "$LL\proxy.err.log" -Tail 20` — a 401/403 means the seeded token is stale (redo Step 5).

### 7. Minimal Claude Code settings (Opus 4.8 recognition + 1M context)
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude" | Out-Null
python claude\apply-settings.py claude\settings.template.json "$env:USERPROFILE\.claude\settings.json" $KEY --env-only
```
(Top-level settings — status line, theme — come in Part 2B.)

### 8. ✅ END-TO-END TEST (self-contained — safe even in a fresh shell)
```powershell
$LL = "$env:USERPROFILE\.config\litellm"; $KEY = (Get-Content "$LL\.master_key" -Raw).Trim()
$r = Invoke-RestMethod -Method Post http://127.0.0.1:4000/v1/chat/completions -Headers @{Authorization="Bearer $KEY"} -ContentType application/json -TimeoutSec 90 -Body '{"model":"claude-opus-4-8[1m]","messages":[{"role":"user","content":"reply with the single word: ready"}],"max_tokens":16}'
if (($r | ConvertTo-Json -Depth 8) -match "ready") { "PROXY OK" } else { "PROXY FAILED" }
if ((claude -p "reply with the single word: ready") -match "ready") { "CLAUDE OK" } else { "CLAUDE FAILED" }
```
**Success = `PROXY OK` and `CLAUDE OK`.** Optional: run `claude`, then `/status` → base URL
`http://localhost:4000`, model **Opus 4.8 1M**. (First `claude` run may show a theme/trust prompt —
that can make the `claude -p` check flake once; the proxy is still fine.)

**🎉 Opus 4.8 works in the CLI. If that's all you wanted, you're done.**

---

# PART 2 — make it permanent + add the extras (after Part 1 works)

## A. Auto-start the proxy on sign-in (Scheduled Task)
Part 1's proxy stops when you log off. Register a logon task (**run this in an ELEVATED PowerShell**):
```powershell
$LL = "$env:USERPROFILE\.config\litellm"
$act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LL\gateway.ps1`" start"
Register-ScheduledTask -TaskName "litellm-gateway" -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Force
```
**(Alternative) Docker Desktop**, mirroring the mac machine's always-on container:
`Set-Content "$LL\.runtime" "docker"`, install Docker Desktop (`winget install Docker.DockerDesktop`,
needs WSL2 + reboot), enable "start at login", then
`powershell -NoProfile -ExecutionPolicy Bypass -File "$LL\gateway.ps1" restart` — it runs the
`litellm` container with `--restart unless-stopped`.

## B. The context-bar status line + full settings
The built-in context bar can't show a % through the proxy (`max_input_tokens=null`); the
PowerShell status line reads real usage from the transcript ÷ the true 1M window.
```powershell
Copy-Item claude\statusline-command.ps1 "$env:USERPROFILE\.claude\statusline-command.ps1" -Force
python claude\apply-settings.py claude\settings.template.json "$env:USERPROFILE\.claude\settings.json" (Get-Content "$env:USERPROFILE\.config\litellm\.master_key" -Raw).Trim()
```
(`apply-settings.py` expands `~` in the `statusLine` command to an absolute path — required, because
`powershell -File ~/...` does NOT resolve `~` on Windows.)

## C. The `/artifact` skill
Local HTML viewer (rendered diffs/code/docs) served to a phone over Tailscale.
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills\artifact" | Out-Null
Copy-Item skills\artifact\* "$env:USERPROFILE\.claude\skills\artifact\" -Recurse -Force
```
`artifact.py` is OS-aware (Tailscale/LAN detection + browser-open work on Windows; the server
liveness check uses `tasklist`, not the Windows-fatal `os.kill`).

## D. Remote / phone access (OpenSSH + Tailscale) — optional
```powershell
powershell -ExecutionPolicy Bypass -File remote\setup-remote.ps1   # ELEVATED: enables sshd + Tailscale + always-on power, and installs the helpers
```
Helpers (auto-dot-sourced from your profile): `llm` (restart gateway), `ccnew <name>` (new agent
window — Windows has no tmux, so separate windows not panes), `wake` (keep awake). From the phone:
SSH into PowerShell over Tailscale and read code via the `/artifact` URLs.

## E. Docs-wiki harness (per-project LLM knowledge base) — optional
Opt-in per project (switch = a `docs-wiki/` folder). Two agents + a nudge hook + three commands.
```powershell
$C = "$env:USERPROFILE\.claude"
New-Item -ItemType Directory -Force "$C\agents","$C\commands","$C\hooks" | Out-Null
Copy-Item claude\agents\*.md "$C\agents\" -Force
Copy-Item claude\commands\docs-*.md "$C\commands\" -Force
Copy-Item claude\hooks\docs-scout-nudge.ps1 "$C\hooks\" -Force
```
Then register the nudge hook. `settings.json` has **no `hooks` key yet**, so add the whole block
(replace `<you>` with your Windows username — use an absolute path, not `~`):
```json
"hooks": {
  "UserPromptSubmit": [
    { "hooks": [ { "type": "command",
      "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/<you>/.claude/hooks/docs-scout-nudge.ps1",
      "timeout": 15 } ] }
  ]
}
```
Use: `docs-scout` (read-only librarian), `docs-writer` (scribe), `/docs-init` (scaffold in a
project), `/docs-sync` (compile session knowledge), `/docs-ask` (query). Folder is an Obsidian vault.

## F. Optional extra hooks
```powershell
Copy-Item claude\hooks\format-python.ps1 "$env:USERPROFILE\.claude\hooks\" -Force   # auto-format on edit (needs: pip install ruff)
Copy-Item claude\hooks\artifact-on-stop.py "$env:USERPROFILE\.claude\hooks\" -Force # auto-publish artifact on Stop (best-effort)
```
Add to the same `hooks` block (absolute paths): `PostToolUse` (matcher `Edit|Write|MultiEdit`) →
`powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/<you>/.claude/hooks/format-python.ps1`;
`Stop` → `python C:/Users/<you>/.claude/hooks/artifact-on-stop.py`.

---

## Reference

**What each file is**
```
litellm\config.yaml            Claude via github_copilot; the critical disable_copilot_system_to_assistant flag
litellm\gateway.ps1            start/stop/status the proxy (python or docker)
claude\settings.template.json  Opus 4.8 1M recognition (env) + top-level settings
claude\apply-settings.py       merges the template into ~/.claude/settings.json (expands statusLine ~)
claude\statusline-command.ps1  proxy-aware context bar (Part 2B)
claude\agents\, commands\      docs-wiki subagents + /docs-* commands (Part 2E)
claude\hooks\*.ps1, *.py       docs-scout-nudge (2E) + optional format-python / artifact-on-stop (2F)
skills\artifact\               the /artifact phone-viewer skill (OS-aware)
install.ps1                    one-shot: Part 1 + 2A + 2B + 2C
uninstall.ps1                  stop proxy + Scheduled Task, restore settings backup (-Purge for full removal)
remote\                        OpenSSH/Tailscale helpers (Part 2D)
```

## Backups & recovery
- **Nothing is destroyed.** `install.ps1` / `apply-settings.py` back up any existing
  `~/.claude/settings.json` to `settings.json.bak.<timestamp>` before writing. The litellm
  `config.yaml` is likewise backed up to `config.yaml.bak.<timestamp>`.
- **Restore settings:** `.\uninstall.ps1` copies the most recent `settings.json.bak.*` back.
- **Start clean:** `.\uninstall.ps1 -Purge` removes `~/.config/litellm` (config + token), the
  statusline, and the `/artifact` skill — then re-run `install.ps1`.
- **The manual steps ARE the fallback** for the one-shot: if `install.ps1` fails partway, run
  Part 1's numbered steps to see exactly which one breaks.
- **Token backup / rotate:** the durable secret is only
  `%USERPROFILE%\.config\litellm\github_copilot\access-token`. Copy that one file to migrate;
  if it's stale/revoked, paste a fresh `ghu_` into `.env` and re-run Step 5 (or the whole
  `github_copilot\` folder from a working machine).

## Common causes of failure (read this if something breaks)
1. **`.ps1 cannot be loaded / not digitally signed`** → you ran a script without bypass. Use
   `powershell -ExecutionPolicy Bypass -File <script>`.
2. **`python` / `litellm` / `claude` "not recognized"** → PATH from a winget/npm install isn't
   in your current window. **Close + reopen PowerShell, `cd` back to the repo**, and re-set
   `$LL`/`$KEY`. (`install.ps1` refreshes PATH itself.)
3. **`python` opens the Microsoft Store / prints nothing** → the Windows App-execution alias is
   shadowing real Python. Disable it (Settings → App execution aliases) or use `py`.
4. **Proxy never reaches `health=200`** → check `Get-Content "$env:USERPROFILE\.config\litellm\proxy.err.log" -Tail 30`.
   `401/403` = seeded token stale/revoked (redo Step 5 with a fresh token). Anything about a
   missing `litellm` = pipx bin not on PATH (reopen shell).
5. **Model call denied but not 401** → your Copilot org hasn't enabled Claude models for your seat.
6. **`Register-ScheduledTask` / OpenSSH "Access is denied"** → run that step in an **elevated** PowerShell.
7. **Claude Code weakly follows instructions** → confirm `disable_copilot_system_to_assistant: true`
   in `%USERPROFILE%\.config\litellm\config.yaml`, then restart the gateway.
8. **Status line is blank** → the `statusLine.command` path must be absolute (not `~`);
   re-run Part 2B (`apply-settings.py` expands it), and confirm `~\.claude\statusline-command.ps1` exists.
9. **Token seeded but auth still fails** → CRLF/quotes in `.env`. Re-paste the token raw; or copy
   the whole `github_copilot\` folder from a working machine and restart the gateway.

**Notes:** `.env` is git-ignored (token never committed, never leaves the machine). The proxy
binds `127.0.0.1` only.
