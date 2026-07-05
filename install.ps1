<#
install.ps1 — set up Claude Code + Opus 4.8 via a local LiteLLM->GitHub Copilot proxy on Windows.

Auth: paste your Copilot access-token into .env (COPILOT_ACCESS_TOKEN=ghu_...) and it's
seeded into the proxy's token file — no GitHub OAuth/2FA login. Your token, your machine.

Runtime: native Python (pipx) by default. Docker Desktop only with -Docker.

Run from an elevated-optional PowerShell, inside the repo:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
  (add -Remote to also install OpenSSH/Tailscale helpers, -Docker to use Docker Desktop)
#>
param([switch]$Docker, [switch]$Python, [switch]$Remote)

$ErrorActionPreference = "Stop"
function Log($m){ Write-Host "==> $m" -ForegroundColor Blue }
function Ok($m){  Write-Host "  ok $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  ! $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

$Repo   = $PSScriptRoot
$LL     = Join-Path $env:USERPROFILE ".config\litellm"
$GC     = Join-Path $LL "github_copilot"
$Claude = Join-Path $env:USERPROFILE ".claude"
$KeyFile= Join-Path $LL ".master_key"

# --- load .env FIRST (COPILOT_ACCESS_TOKEN, optional RUNTIME / LITELLM_MASTER_KEY) ---
if (Test-Path "$Repo\.env") {
  Get-Content "$Repo\.env" | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k,$v = $_ -split '=',2
    Set-Item "Env:$($k.Trim())" $v.Trim()
  }
  Ok "loaded .env"
}
$Token = $env:COPILOT_ACCESS_TOKEN
if ($Token) { $Token = $Token.Trim().Trim('"').Trim("'").Replace("`r","").Replace(" ","") }

# --- runtime: flags override .env ---
$Runtime = if ($env:RUNTIME) { $env:RUNTIME } else { "python" }
if ($Docker) { $Runtime = "docker" }
if ($Python) { $Runtime = "python" }

# --- 1. deps ---
Log "Checking dependencies"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Die "winget not found — install 'App Installer' from the Microsoft Store, then re-run" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { winget install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements | Out-Null }
python -c "import sys" 2>$null; if ($LASTEXITCODE -ne 0) { Die "python not runnable on PATH — open a new PowerShell after install and re-run" }
python -m pip install --user -q pipx 2>$null | Out-Null
python -m pipx ensurepath 2>$null | Out-Null
$env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
if (-not (Get-Command litellm -ErrorAction SilentlyContinue)) { Log "Installing LiteLLM"; python -m pipx install "litellm[proxy]" 2>$null | Out-Null }
Ok "base deps present"

# --- 2. gateway config ---
Log "Writing $LL\config.yaml"
New-Item -ItemType Directory -Force -Path $LL | Out-Null
if (Test-Path "$LL\config.yaml") { Copy-Item "$LL\config.yaml" "$LL\config.yaml.bak.$([int](Get-Date -UFormat %s))" }
Copy-Item "$Repo\litellm\config.yaml" "$LL\config.yaml" -Force
Copy-Item "$Repo\litellm\gateway.ps1" "$LL\gateway.ps1" -Force
Ok "config + gateway.ps1 written"

# --- 3. local gateway master key ---
if (Test-Path $KeyFile) { $MasterKey = (Get-Content $KeyFile -Raw).Trim(); Ok "reusing local gateway key" }
elseif ($env:LITELLM_MASTER_KEY) { $MasterKey = $env:LITELLM_MASTER_KEY; Set-Content -NoNewline $KeyFile $MasterKey; Ok "using LITELLM_MASTER_KEY from .env" }
else { $MasterKey = "sk-" + (-join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })); Set-Content -NoNewline $KeyFile $MasterKey; Ok "generated local gateway key" }

# --- 4. seed the Copilot token (skips OAuth) ---
$Seeded = $false
if ($Token) {
  New-Item -ItemType Directory -Force -Path $GC | Out-Null
  Set-Content -NoNewline -Path "$GC\access-token" -Value $Token
  $Seeded = $true; Ok "seeded Copilot access-token from .env — device login skipped"
  if ($Token -notmatch '^(ghu_|gho_)') { Warn "token doesn't start with ghu_/gho_ — double-check you pasted it raw (no quotes)" }
}

# --- 5. runtime + start ---
Set-Content -NoNewline "$LL\.runtime" $Runtime
if ($Runtime -eq "docker" -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Warn "Docker not found; installing Docker Desktop (needs WSL2 + a reboot). Consider -Python instead."
  winget install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements | Out-Null
}
Ok "runtime = $Runtime"
Log "Starting the LiteLLM gateway on 127.0.0.1:4000"
& powershell -NoProfile -ExecutionPolicy Bypass -File "$LL\gateway.ps1" start

# --- 6. OAUTH device login only if we didn't seed a token ---
if (-not $Seeded -and -not (Test-Path "$GC\access-token")) {
  Log "No token seeded — starting GitHub Copilot device login"
  Warn "Authenticate with your GitHub account (the one holding your Copilot seat)."
  Start-Job { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:4000/v1/chat/completions" -Headers @{ Authorization = "Bearer $using:MasterKey" } -ContentType "application/json" -Body '{"model":"claude-opus-4-8[1m]","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' } | Out-Null
  Write-Host "  Watch for https://github.com/login/device and a code in: $LL\proxy.log (and proxy.err.log)"
  $w = 0
  while (-not (Test-Path "$GC\access-token") -and $w -lt 300) {
    if (Test-Path "$LL\proxy.err.log") { Get-Content "$LL\proxy.err.log" -Tail 3 | Select-String -Pattern "device|user.?code|enter .*code" | Select-Object -Last 1 }
    Start-Sleep 5; $w += 5
  }
  if (-not (Test-Path "$GC\access-token")) { Die "device login timed out — see $LL\proxy.err.log" }
  Ok "device login complete"
}

# --- 7. Claude Code + settings ---
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Log "Installing Claude Code"
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements | Out-Null }
  npm install -g @anthropic-ai/claude-code 2>$null | Out-Null
}
Log "Installing statusline + settings"
New-Item -ItemType Directory -Force -Path $Claude | Out-Null
Copy-Item "$Repo\claude\statusline-command.ps1" "$Claude\statusline-command.ps1" -Force
python "$Repo\claude\apply-settings.py" "$Repo\claude\settings.template.json" "$Claude\settings.json" $MasterKey
if ($LASTEXITCODE -ne 0) { Die "settings merge failed" }
Ok "settings written"

# --- 8. /artifact skill ---
Log "Installing /artifact skill"
New-Item -ItemType Directory -Force -Path "$Claude\skills" | Out-Null
Copy-Item "$Repo\skills\artifact" "$Claude\skills\artifact" -Recurse -Force
Ok "skill installed"

# --- 9. persistence: logon Scheduled Task ---
Log "Registering logon Scheduled Task (gateway starts at sign-in)"
$act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LL\gateway.ps1`" start"
$trg = New-ScheduledTaskTrigger -AtLogOn
try {
  Register-ScheduledTask -TaskName "litellm-gateway" -Action $act -Trigger $trg -Force -RunLevel Limited | Out-Null
  Ok "scheduled task registered"
} catch { Warn "couldn't register task; after reboot run: powershell -File `"$LL\gateway.ps1`" start" }

if ($Remote) { Log "Remote helpers"; & powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\remote\setup-remote.ps1" }

# --- verify ---
Log "Verifying Opus 4.8 through the gateway"
$ok = $false
try {
  $r = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:4000/v1/chat/completions" -Headers @{ Authorization = "Bearer $MasterKey" } -ContentType "application/json" -TimeoutSec 90 -Body '{"model":"claude-opus-4-8[1m]","messages":[{"role":"user","content":"reply with the single word: ready"}],"max_tokens":16}'
  if (($r | ConvertTo-Json -Depth 8) -match "ready") { $ok = $true }
} catch { }
Write-Host ""
Log "Start Claude Code with:  claude   (verify with /status -> Opus 4.8 1M)"
Write-Host "     gateway control:  powershell -File `"$LL\gateway.ps1`" {start|stop|restart|status}"
if ($ok -and (Get-Command claude -ErrorAction SilentlyContinue)) { Ok "Opus 4.8 responded + Claude Code present — setup complete"; exit 0 }
else { Warn "setup NOT fully verified — check the seeded token (stale/revoked?) or that your org enabled Claude models; and that 'claude' is on PATH (open a new PowerShell)."; exit 1 }
