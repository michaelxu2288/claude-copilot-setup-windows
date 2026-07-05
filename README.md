# claude-copilot-setup (Windows) — hand-off runbook

Turn a **fresh Windows PC** into **Claude Code running Opus 4.8**, via a local
**LiteLLM proxy → GitHub Copilot**. Assumes the machine has **nothing** — no Python,
Node, Docker, LiteLLM, or Claude Code (only `winget`, which ships with Windows 10/11).

> This is the **Windows** port of [`claude-copilot-setup`](https://github.com/michaelxu2288/claude-copilot-setup)
> (macOS). Same product, PowerShell instead of bash. Model auth is done by **seeding one
> token** — no GitHub OAuth/2FA login on this machine.

Two parts, easiest-first:
- **PART 1 — get Opus 4.8 working in the CLI (do this first).** Native-Python proxy, fastest to a green test.
- **PART 2 — make it permanent + extras (after Part 1 works).** Auto-start Scheduled Task (or Docker), the context-bar status line, the `/artifact` skill, remote access, and the docs-wiki harness.

> **The only manual human step:** paste one token into `.env`.

Run everything in **PowerShell** (not cmd). If a script is blocked, prefix with
`powershell -ExecutionPolicy Bypass -File <script>`.

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

## Fast path
`powershell -ExecutionPolicy Bypass -File .\install.ps1` runs all of Part 1 automatically
(add `-Remote` for SSH/Tailscale, `-Docker` for Docker Desktop). The manual steps below
are the same thing, one command at a time, for debugging.

---

# PART 1 — get Opus 4.8 running in the CLI (easiest)

**Goal:** `claude` answers on Opus 4.8. Run these in one PowerShell window.

### 1. Python (via winget)
```powershell
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { winget install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements }
```
**Verify:** `python --version` prints 3.x. (If "not found", close and reopen PowerShell so PATH refreshes.)

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
npm install -g @anthropic-ai/claude-code
```
**Verify:** `claude --version` (reopen PowerShell if not found).

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
**Verify:** `powershell -File "$LL\gateway.ps1" status` shows `health=200`.
**If it fails:** `Get-Content "$LL\proxy.err.log" -Tail 20` — a 401/403 means the seeded token is stale (redo Step 5).

### 7. Minimal Claude Code settings (Opus 4.8 recognition + 1M context)
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude" | Out-Null
python claude\apply-settings.py claude\settings.template.json "$env:USERPROFILE\.claude\settings.json" $KEY --env-only
```
(Top-level settings — status line, theme — come in Part 2B.)

### 8. ✅ END-TO-END TEST
```powershell
$r = Invoke-RestMethod -Method Post http://127.0.0.1:4000/v1/chat/completions -Headers @{Authorization="Bearer $KEY"} -ContentType application/json -TimeoutSec 90 -Body '{"model":"claude-opus-4-8[1m]","messages":[{"role":"user","content":"reply with the single word: ready"}],"max_tokens":16}'
if (($r | ConvertTo-Json -Depth 8) -match "ready") { "PROXY OK" } else { "PROXY FAILED" }
if ((claude -p "reply with the single word: ready") -match "ready") { "CLAUDE OK" } else { "CLAUDE FAILED" }
```
**Success = `PROXY OK` and `CLAUDE OK`.** Optional: run `claude`, then `/status` → base URL
`http://localhost:4000`, model **Opus 4.8 1M**.

**🎉 Opus 4.8 works in the CLI. If that's all you wanted, you're done.**

---

# PART 2 — make it permanent + add the extras (after Part 1 works)

## A. Auto-start the proxy on sign-in (Scheduled Task)
Part 1's proxy stops when you log off. Register a logon task so it comes back:
```powershell
$LL = "$env:USERPROFILE\.config\litellm"
$act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LL\gateway.ps1`" start"
Register-ScheduledTask -TaskName "litellm-gateway" -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Force
```
**(Alternative) Docker Desktop**, mirroring the mac machine's always-on container:
`Set-Content "$LL\.runtime" "docker"`, install Docker Desktop (`winget install Docker.DockerDesktop`, needs WSL2 + reboot), enable "start at login", then `powershell -File "$LL\gateway.ps1" restart` — it runs the `litellm` container with `--restart unless-stopped`.

## B. The context-bar status line + full settings
The built-in context bar can't show a % through the proxy (`max_input_tokens=null`); the
PowerShell status line reads real usage from the transcript ÷ the true 1M window.
```powershell
Copy-Item claude\statusline-command.ps1 "$env:USERPROFILE\.claude\statusline-command.ps1" -Force
python claude\apply-settings.py claude\settings.template.json "$env:USERPROFILE\.claude\settings.json" (Get-Content "$env:USERPROFILE\.config\litellm\.master_key" -Raw).Trim()
```
(The `statusLine` entry runs `powershell -File ...statusline-command.ps1`.)

## C. The `/artifact` skill
Local HTML viewer (rendered diffs/code/docs) served to a phone over Tailscale.
```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
Copy-Item skills\artifact "$env:USERPROFILE\.claude\skills\artifact" -Recurse -Force
```
Usage in `skills\artifact\SKILL.md`. `artifact.py` is OS-aware (Tailscale/LAN detection + browser-open work on Windows).

## D. Remote / phone access (OpenSSH + Tailscale) — optional
```powershell
powershell -ExecutionPolicy Bypass -File remote\setup-remote.ps1   # elevated: enables sshd + Tailscale + always-on power
Copy-Item remote\claude-remote.ps1 "$HOME\.claude-remote.ps1" -Force
```
Helpers (dot-sourced from your profile): `llm` (restart gateway), `ccnew <name>` (new agent
window — Windows has no tmux, so it's separate windows, not panes), `wake` (keep awake).
From the phone: SSH into PowerShell over Tailscale and read code via the `/artifact` URLs.

## E. Docs-wiki harness (per-project LLM knowledge base) — optional
Opt-in per project (switch = a `docs-wiki/` folder). Two agents + a nudge hook + three commands.
```powershell
$C = "$env:USERPROFILE\.claude"
New-Item -ItemType Directory -Force "$C\agents","$C\commands","$C\hooks" | Out-Null
Copy-Item claude\agents\*.md "$C\agents\" -Force
Copy-Item claude\commands\docs-*.md "$C\commands\" -Force
Copy-Item claude\hooks\docs-scout-nudge.ps1 "$C\hooks\" -Force
```
Then register the nudge hook by adding this to the `hooks` block of `~/.claude/settings.json`:
```json
"UserPromptSubmit": [
  { "hooks": [ { "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/hooks/docs-scout-nudge.ps1",
    "timeout": 15 } ] }
]
```
Use: `docs-scout` (read-only librarian), `docs-writer` (scribe), `/docs-init` (scaffold in a
project), `/docs-sync` (compile session knowledge), `/docs-ask` (query). Folder is an Obsidian vault.

## F. Optional extra hooks
```powershell
Copy-Item claude\hooks\format-python.ps1 "$env:USERPROFILE\.claude\hooks\" -Force   # auto-format on edit (needs: pip install ruff)
Copy-Item claude\hooks\artifact-on-stop.py "$env:USERPROFILE\.claude\hooks\" -Force # auto-publish artifact on Stop (best-effort)
```
Register in `settings.json` `hooks`: `PostToolUse` → `powershell -File ~/.claude/hooks/format-python.ps1`,
`Stop` → `python ~/.claude/hooks/artifact-on-stop.py`.

---

## Reference

**What each file is**
```
litellm\config.yaml            Claude via github_copilot; the critical disable_copilot_system_to_assistant flag
litellm\gateway.ps1            start/stop/status the proxy (python or docker)
claude\settings.template.json  Opus 4.8 1M recognition (env) + top-level settings (statusLine points at .ps1)
claude\apply-settings.py       merges the template into ~/.claude/settings.json
claude\statusline-command.ps1  proxy-aware context bar (Part 2B)
claude\agents\, commands\      docs-wiki subagents + /docs-* commands (Part 2E)
claude\hooks\*.ps1, *.py       docs-scout-nudge (2E) + optional format-python / artifact-on-stop (2F)
skills\artifact\               the /artifact phone-viewer skill (OS-aware)
install.ps1 / uninstall.ps1    one-shot install / teardown
remote\                        OpenSSH/Tailscale helpers (Part 2D)
```

**Troubleshooting**
| Symptom | Fix |
| --- | --- |
| `python`/`litellm`/`claude` not found | close + reopen PowerShell (PATH refresh); or `$env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"` |
| script "cannot be loaded / not digitally signed" | run via `powershell -ExecutionPolicy Bypass -File <script>` |
| proxy health `0`/not up | `Get-Content "$env:USERPROFILE\.config\litellm\proxy.err.log" -Tail 20`; `powershell -File gateway.ps1 restart` |
| auth/401 in the log | seeded token stale/revoked → redo Part 1 Step 5 with a fresh token |
| model denied (not 401) | your Copilot org must have Claude models enabled for your seat |
| token alone won't auth | copy the whole `%USERPROFILE%\.config\litellm\github_copilot\` folder from a working machine, then `gateway.ps1 restart` |
| Claude weakly follows instructions | confirm `disable_copilot_system_to_assistant: true` in the config, `gateway.ps1 restart` |

**Notes**
- `.env` is git-ignored — your token never gets committed and never leaves the machine.
- The proxy binds `127.0.0.1` only. Your own token, your own PC.
