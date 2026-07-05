<#
setup-remote.ps1 — one-shot: OpenSSH server + Tailscale + always-on power on Windows.
Run in an ELEVATED PowerShell:  powershell -ExecutionPolicy Bypass -File .\setup-remote.ps1
#>
Write-Host "== SSH (OpenSSH Server) ==" -ForegroundColor Blue
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null

Write-Host "== Tailscale ==" -ForegroundColor Blue
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
  winget install --id tailscale.tailscale -e --accept-package-agreements --accept-source-agreements | Out-Null
}
$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (Test-Path $ts) { & $ts up --ssh }

Write-Host "== always-on power (plugged in) ==" -ForegroundColor Blue
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Write-Host "== helpers -> PowerShell profile ==" -ForegroundColor Blue
Copy-Item (Join-Path $PSScriptRoot 'claude-remote.ps1') "$HOME\.claude-remote.ps1" -Force
$prof = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path $prof)) { New-Item -ItemType File -Force -Path $prof | Out-Null }
if (-not (Select-String -Path $prof -Pattern 'claude-remote.ps1' -Quiet -ErrorAction SilentlyContinue)) {
  Add-Content $prof ". `"$HOME\.claude-remote.ps1`""
}
if (Test-Path $ts) { Write-Host "tailnet IP: $(& $ts ip -4)" }
Write-Host "note: Windows has no tmux — drive agents in separate PowerShell windows (ccnew), and read code via the /artifact URLs."
