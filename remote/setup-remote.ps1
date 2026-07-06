<#
setup-remote.ps1 — one-shot: OpenSSH server + Tailscale + always-on power on Windows.
Run in an ELEVATED PowerShell:  powershell -ExecutionPolicy Bypass -File .\setup-remote.ps1
#>
Write-Host "== SSH (OpenSSH Server) ==" -ForegroundColor Blue
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null

Write-Host "== Tailscale (join the SAME tailnet as your Mac/phone) ==" -ForegroundColor Blue
Write-Host "  When the browser opens, sign in with: michaelxu2288@gmail.com" -ForegroundColor Yellow
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
  winget install --id tailscale.tailscale -e --accept-package-agreements --accept-source-agreements | Out-Null
}
$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (Test-Path $ts) { & $ts up }   # plain up (SSH is via the OpenSSH server above); log into the same account

Write-Host "== always-on power (plugged in) ==" -ForegroundColor Blue
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Write-Host "== helpers -> PowerShell profile ==" -ForegroundColor Blue
Copy-Item (Join-Path $PSScriptRoot 'claude-remote.ps1') "$HOME\.claude-remote.ps1" -Force
# install the zellij 'claude' layout (used by ccnew) if zellij is present
if (Get-Command zellij -ErrorAction SilentlyContinue) {
  $zl = Join-Path $env:APPDATA 'zellij\layouts'
  New-Item -ItemType Directory -Force $zl | Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'claude.kdl') (Join-Path $zl 'claude.kdl') -Force
  Write-Host "  installed zellij 'claude' layout -> $zl\claude.kdl"
}
$prof = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path $prof)) { New-Item -ItemType File -Force -Path $prof | Out-Null }
if (-not (Select-String -Path $prof -Pattern 'claude-remote.ps1' -Quiet -ErrorAction SilentlyContinue)) {
  Add-Content $prof ". `"$HOME\.claude-remote.ps1`""
}
if (Test-Path $ts) {
  $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
  Write-Host ""
  Write-Host "==> DONE. Add ONE new host in iPhone Termius (plain SSH, NO mosh):" -ForegroundColor Green
  Write-Host "      Address : $ip     (stable; or use  $($env:COMPUTERNAME.ToLower()).tail18b6fd.ts.net )"
  Write-Host "      Port    : 22"
  Write-Host "      Username: $env:USERNAME"
  Write-Host "      Password: your Windows sign-in password  (or add an SSH key)"
  Write-Host "    Then in that Termius session run:  claude"
  Write-Host "    (Windows has no tmux — use separate Termius tabs / 'ccnew' windows; read code via the /artifact URLs.)"
}
