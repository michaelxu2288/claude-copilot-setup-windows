<#
gateway.ps1 — start/stop/status the LiteLLM proxy on Windows, runtime-agnostic.
Reads %USERPROFILE%\.config\litellm\.runtime (python|docker) and .master_key.
Installed to %USERPROFILE%\.config\litellm\gateway.ps1; run by a logon Scheduled Task.

  powershell -NoProfile -ExecutionPolicy Bypass -File gateway.ps1 start|stop|restart|status
#>
param([Parameter(Position=0)][string]$Action = "start")

$LL  = Join-Path $env:USERPROFILE ".config\litellm"
$Key = if (Test-Path "$LL\.master_key") { (Get-Content "$LL\.master_key" -Raw).Trim() } else { "" }
$RT  = if (Test-Path "$LL\.runtime")    { (Get-Content "$LL\.runtime" -Raw).Trim() }    else { "python" }
$Img = "ghcr.io/berriai/litellm:main-latest"
$env:LITELLM_MASTER_KEY = $Key
# make pipx/python/docker reachable in a Scheduled-Task context
$env:PATH = "$env:USERPROFILE\.local\bin;$env:LOCALAPPDATA\Programs\Python\Python312;$env:LOCALAPPDATA\Programs\Python\Python312\Scripts;$env:PATH"

function Get-Health {
  try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:4000/health/liveliness").StatusCode }
  catch { 0 }
}
function Wait-Health { for ($i=0; $i -lt 45; $i++) { if ((Get-Health) -eq 200) { return $true }; Start-Sleep 2 }; return $false }

function Start-Python {
  # already up?
  if ((Get-Health) -eq 200) { return }
  $litellm = (Get-Command litellm -ErrorAction SilentlyContinue).Source
  if (-not $litellm) { $litellm = "$env:USERPROFILE\.local\bin\litellm.exe" }
  Start-Process -FilePath $litellm `
    -ArgumentList @("--config", "$LL\config.yaml", "--host", "127.0.0.1", "--port", "4000") `
    -WindowStyle Hidden `
    -RedirectStandardOutput "$LL\proxy.log" -RedirectStandardError "$LL\proxy.err.log"
}
function Start-Docker {
  docker start litellm 2>$null
  if ($LASTEXITCODE -ne 0) {
    docker run -d --name litellm --restart unless-stopped `
      -p 127.0.0.1:4000:4000 -e "LITELLM_MASTER_KEY=$Key" `
      -v "${LL}:/root/.config/litellm" $Img `
      --config /root/.config/litellm/config.yaml | Out-Null
  }
}

switch ($Action) {
  "start" {
    if ($RT -eq "docker") { Start-Docker } else { Start-Python }
    if (Wait-Health) { Write-Host "gateway up (runtime=$RT, HTTP 200)" }
    else { Write-Host "gateway not healthy yet (runtime=$RT) — if first docker run, image may still be pulling" }
  }
  "stop" {
    docker stop litellm 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='litellm.exe'" 2>$null | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name like '%python%'" 2>$null | Where-Object { $_.CommandLine -like "*litellm*--config*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "stopped"
  }
  "restart" { & $PSCommandPath stop; & $PSCommandPath start }
  "status"  { Write-Host "runtime=$RT  health=$(Get-Health)" }
  default   { Write-Host "usage: gateway.ps1 {start|stop|restart|status}" }
}
