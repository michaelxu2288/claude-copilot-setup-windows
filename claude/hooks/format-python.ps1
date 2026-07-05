# PostToolUse hook (Windows): auto-format Python files with ruff after Edit/Write/MultiEdit.
# Never blocks: always exits 0, prints {} when nothing to do; notes only if ruff fails.
# Dormant until `pip install ruff` (or `winget install astral-sh.ruff`).
$ErrorActionPreference = "SilentlyContinue"
$raw = [Console]::In.ReadToEnd()
function Emit-Empty { Write-Output '{}'; exit 0 }

try { $p = $raw | ConvertFrom-Json } catch { Emit-Empty }
$tool = if ($p.tool_name) { $p.tool_name } elseif ($p.toolName) { $p.toolName } else { "" }
if ($tool -and ($tool -notin @("edit","create","Edit","Write","MultiEdit"))) { Emit-Empty }

$ti = $p.tool_input; $ta = $p.toolArgs
$file = ""
foreach ($c in @($ti.file_path, $ti.path, $ta.file_path, $ta.path)) { if ($c) { $file = "$c"; break } }
if (-not $file) { Emit-Empty }
if ($file -notlike "*.py") { Emit-Empty }
if (-not [System.IO.Path]::IsPathRooted($file)) { $cwd = "$($p.cwd)"; if ($cwd) { $file = Join-Path $cwd $file } }
if (-not (Test-Path $file)) { Emit-Empty }
if (-not (Get-Command ruff -ErrorAction SilentlyContinue)) { Emit-Empty }

$checkOut  = & ruff check --fix $file 2>&1; $checkExit  = $LASTEXITCODE
$formatOut = & ruff format $file 2>&1;      $formatExit = $LASTEXITCODE
if ($checkExit -ne 0 -or $formatExit -ne 0) {
    $detail = ((@($checkOut) + @($formatOut)) -join "`n")
    $msg = "Python formatting hook reported issues for $file`n$detail"
    @{ hookSpecificOutput = @{ hookEventName = "PostToolUse"; additionalContext = $msg } } | ConvertTo-Json -Compress
    exit 0
}
Emit-Empty
