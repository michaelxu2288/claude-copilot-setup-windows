# claude-remote helpers (Windows) — dot-source from your PowerShell profile:
#   . "$HOME\.claude-remote.ps1"
$LLDIR = Join-Path $env:USERPROFILE ".config\litellm"

# (re)start the litellm gateway + confirm it's live
function llm { powershell -NoProfile -ExecutionPolicy Bypass -File "$LLDIR\gateway.ps1" restart }

# start a new Claude Code agent. Prefers zellij (persistent, attach from the phone) if
# installed, else opens a new PowerShell window.
#   ccnew a1   ->  zellij session 'a1' running claude (attach: zellij attach a1 ; detach: Ctrl-o d)
function ccnew([string]$name = "a1") {
  if (Get-Command zellij -ErrorAction SilentlyContinue) {
    Start-Process zellij -ArgumentList @("--session","$name","--layout","claude")
    Write-Host "zellij session '$name' started  (attach: zellij attach $name  |  detach: Ctrl-o d)"
  } else {
    Start-Process powershell -ArgumentList @("-NoExit","-Command","`$host.UI.RawUI.WindowTitle='claude:$name'; claude --dangerously-skip-permissions")
    Write-Host "claude window 'claude:$name' started  (install zellij for attachable sessions)"
  }
}
function cclist { if (Get-Command zellij -ErrorAction SilentlyContinue) { zellij list-sessions } else { Write-Host "(install zellij to list sessions)" } }
function cckill([string]$name) { if (Get-Command zellij -ErrorAction SilentlyContinue) { zellij kill-session $name } }

# keep the machine awake until this shell exits (Ctrl-C to release)
function wake {
  Add-Type -Namespace Win32 -Name P -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint e);' -ErrorAction SilentlyContinue
  [Win32.P]::SetThreadExecutionState(0x80000001) | Out-Null   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
  Write-Host "awake until this shell exits (Ctrl-C to release)"
  try { while ($true) { Start-Sleep 60 } } finally { [Win32.P]::SetThreadExecutionState(0x80000000) | Out-Null }
}
