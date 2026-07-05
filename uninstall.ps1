<#
uninstall.ps1 — stop the gateway + Scheduled Task, restore the settings backup.
  -Purge  also remove %USERPROFILE%\.config\litellm and the /artifact skill
#>
param([switch]$Purge)
$LL = Join-Path $env:USERPROFILE ".config\litellm"
$Claude = Join-Path $env:USERPROFILE ".claude"

Write-Host "==> removing logon Scheduled Task"
Unregister-ScheduledTask -TaskName "litellm-gateway" -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "==> stopping the gateway (docker + python)"
docker rm -f litellm 2>$null | Out-Null
Get-CimInstance Win32_Process -Filter "Name='litellm.exe'" 2>$null | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name like '%python%'" 2>$null | Where-Object { $_.CommandLine -like "*litellm*--config*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$bak = Get-ChildItem "$Claude\settings.json.bak.*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($bak) { Copy-Item $bak.FullName "$Claude\settings.json" -Force; Write-Host "  restored settings.json from $($bak.Name)" }
else { Write-Host "  no settings backup found — leaving settings.json as-is" }

if ($Purge) {
  Write-Host "==> -Purge: removing gateway config, token, statusline, and /artifact skill"
  Remove-Item -Recurse -Force $LL -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force "$Claude\skills\artifact" -ErrorAction SilentlyContinue
  Remove-Item -Force "$Claude\statusline-command.ps1" -ErrorAction SilentlyContinue
  Write-Host "  purged"
}
Write-Host "==> done"
