# Claude Code statusline -- self-contained PowerShell (no jq dependency)
# Reads Claude Code's statusline JSON from stdin and prints a compact colored line.
#
# Context tracking note:
#   This setup routes Claude Code -> LiteLLM -> GitHub Copilot. Copilot does NOT
#   implement Anthropic's /v1/messages/count_tokens endpoint, so the proxy returns
#   a bogus constant for it. That makes Claude Code's built-in context_window
#   percentage empty/wrong. Instead we read the REAL token usage from the session
#   transcript (the usage block the model actually returned) and divide by the
#   model's true context window. This is accurate regardless of the proxy.

$inputJson = [Console]::In.ReadToEnd()
$esc = [char]27

$reset    = "${esc}[0m"
$cVer     = "${esc}[38;5;39m"
$cCtx     = "${esc}[38;5;208m"
$cCtxOk   = "${esc}[38;5;78m"    # green  (< 50%)
$cCtxWarn = "${esc}[38;5;220m"   # yellow (50-80%)
$cCtxHot  = "${esc}[38;5;203m"   # red    (> 80%)
$cModel   = "${esc}[38;5;141m"
$cDir     = "${esc}[38;5;78m"
$cBranch  = "${esc}[38;5;220m"
$sep      = "${esc}[38;5;240m | ${esc}[0m"

function Get-Prop {
    param([object]$Object, [string[]]$Path)
    $current = $Object
    foreach ($part in $Path) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function First-Value {
    param([object[]]$Values)
    foreach ($value in $Values) {
        if ($null -ne $value -and "$value" -ne "") { return $value }
    }
    return $null
}

function Short-Path {
    param([string]$Path, [int]$MaxSegments = 2)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $parts = $Path -split "[\\/]+" | Where-Object { $_ -ne "" }
    if ($parts.Count -le $MaxSegments) { return $Path }
    $tail = $parts[-$MaxSegments..-1]
    return "...\" + ($tail -join "\")
}

# real context-window sizes (input tokens) for the models reachable via Copilot.
# pulled from the Copilot /models API; key match is case-insensitive substring.
function Get-ContextWindow {
    param([string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return 200000 }
    $m = $Model.ToLowerInvariant()
    # order matters: most specific first
    $map = [ordered]@{
        "opus-4.8"            = 1000000
        "opus-4.7-high"       = 200000
        "opus-4.7-xhigh"      = 200000
        "opus-4.7-1m"         = 1000000
        "opus-4.7"            = 1000000
        "opus-4.6"            = 1000000
        "opus-4.5"            = 200000
        "sonnet-4.6"          = 1000000
        "sonnet-4.5"          = 200000
        "haiku-4.5"           = 200000
    }
    foreach ($k in $map.Keys) { if ($m -like "*$k*") { return $map[$k] } }
    if ($m -like "*1m*") { return 1000000 }
    return 200000
}

function Format-Tokens {
    param([double]$N)
    if ($N -ge 1000000) { return ("{0:0.##}M" -f ($N / 1000000)) }
    if ($N -ge 1000)    { return ("{0:0.#}k"  -f ($N / 1000)) }
    return ("{0:0}" -f $N)
}

# Walk the session transcript and return the high-water mark of main-chain
# (non-sidechain) assistant context size + model. Returns $null on miss.
#
# Why MAX instead of the latest value: through the Copilot proxy, a request's
# reported input_tokens is the FULL context on some turns (e.g. 252k) but only
# the small incremental message on others (e.g. 2k) -- so reading just the latest
# turn makes the statusline yo-yo 252k -> 2k -> 254k and look like context
# vanished. The real conversation footprint only grows (no prompt caching, and
# auto-compact is disabled), so the peak over the recent tail is the honest
# "how full am I" number.
function Get-ContextFromTranscript {
    param([string]$TranscriptPath)
    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $null }
    try {
        # tail covers the recent turns; -Tail reads from the end so it stays fast.
        $lines = Get-Content -LiteralPath $TranscriptPath -Tail 400 -ErrorAction Stop
    } catch { return $null }
    $maxTokens   = 0
    $maxModel    = $null
    $latestModel = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ($line -notlike '*"usage"*' -or $line -notlike '*"input_tokens"*') { continue }
        if ($line -notlike '*"assistant"*') { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $obj) { continue }
        if ((Get-Prop $obj @("isSidechain")) -eq $true) { continue }
        if ((Get-Prop $obj @("type")) -ne "assistant") { continue }
        $usage = Get-Prop $obj @("message", "usage")
        if ($null -eq $usage) { continue }
        $inTok  = [double](First-Value @((Get-Prop $usage @("input_tokens")), 0))
        $cacheR = [double](First-Value @((Get-Prop $usage @("cache_read_input_tokens")), 0))
        $cacheC = [double](First-Value @((Get-Prop $usage @("cache_creation_input_tokens")), 0))
        $total  = $inTok + $cacheR + $cacheC
        $model  = Get-Prop $obj @("message", "model")
        # latestModel = model on the most recent qualifying line (we scan newest-first)
        if ($null -eq $latestModel -and $model) { $latestModel = "$model" }
        if ($total -gt $maxTokens) { $maxTokens = $total; $maxModel = "$model" }
    }
    if ($maxTokens -le 0) { return $null }
    return [pscustomobject]@{
        Tokens = $maxTokens
        Model  = (First-Value @($maxModel, $latestModel))
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($inputJson)) { $data = $null }
    else { $data = $inputJson | ConvertFrom-Json }
} catch {
    Write-Output "${cVer}Claude${reset}${sep}${cCtx}status input unavailable${reset}"
    exit 0
}

# claude code version (from payload if present, else nothing)
$ccVer = First-Value @(
    (Get-Prop $data @("version")),
    (Get-Prop $data @("cli_version"))
)
$verText = if ($ccVer) { "V$ccVer" } else { "Claude" }

$modelValue = First-Value @(
    (Get-Prop $data @("model", "display_name")),
    (Get-Prop $data @("model", "displayName")),
    (Get-Prop $data @("modelName")),
    (Get-Prop $data @("model"))
)
if ($null -ne $modelValue -and $modelValue.PSObject.Properties["display_name"]) {
    $modelValue = $modelValue.display_name
}
# strip "Claude " prefix to keep it short
$modelValue = "$modelValue" -replace "^Claude\s+", ""

$effort = First-Value @(
    (Get-Prop $data @("effortLevel")),
    (Get-Prop $data @("effort_level")),
    (Get-Prop $data @("model", "effortLevel")),
    (Get-Prop $data @("model", "effort_level"))
)

$cwd = First-Value @(
    (Get-Prop $data @("workspace", "current_dir")),
    (Get-Prop $data @("workspace", "currentDir")),
    (Get-Prop $data @("cwd")),
    (Get-Location).Path
)

# --- context tracking via transcript (accurate through the Copilot proxy) ---
$transcriptPath = First-Value @(
    (Get-Prop $data @("transcript_path")),
    (Get-Prop $data @("transcriptPath"))
)
# fallback: derive the project transcript dir from cwd + session_id
if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
    $sessionId = First-Value @((Get-Prop $data @("session_id")), (Get-Prop $data @("sessionId")))
    if ($cwd) {
        # claude code maps each of : \ / . to its own dash (no collapsing),
        # e.g. C:\Users\username -> C--Users-username
        $mangled = ($cwd -replace "[\\/:.]", "-")
        $projDir = Join-Path $env:USERPROFILE ".claude\projects\$mangled"
        if ($sessionId -and (Test-Path -LiteralPath (Join-Path $projDir "$sessionId.jsonl"))) {
            $transcriptPath = Join-Path $projDir "$sessionId.jsonl"
        } elseif (Test-Path -LiteralPath $projDir) {
            $newest = Get-ChildItem -LiteralPath $projDir -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { $transcriptPath = $newest.FullName }
        }
    }
}

$ctxText = $null
$ctx = Get-ContextFromTranscript -TranscriptPath $transcriptPath
if ($null -ne $ctx -and $ctx.Tokens -gt 0) {
    # prefer the model the transcript actually used; fall back to payload model
    $winModel = First-Value @($ctx.Model, $modelValue)
    $window = Get-ContextWindow -Model $winModel
    $pct = [math]::Round(($ctx.Tokens / $window) * 100)
    $ctxColor = if ($pct -ge 80) { $cCtxHot } elseif ($pct -ge 50) { $cCtxWarn } else { $cCtxOk }
    $ctxText = "${ctxColor}Ctx $(Format-Tokens $ctx.Tokens)/$(Format-Tokens $window) ($pct%)${reset}"
}

$branch = $null
if ($cwd -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $insideGit = & git --no-optional-locks -C "$cwd" rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and "$insideGit" -eq "true") {
        $branch = & git --no-optional-locks -C "$cwd" symbolic-ref --short HEAD 2>$null
        if ([string]::IsNullOrWhiteSpace($branch)) {
            $branch = & git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>$null
        }
    }
}

$modelText = $null
if ($modelValue) {
    if ($effort) { $modelText = "$modelValue/$effort" } else { $modelText = "$modelValue" }
}

$line = "${cVer}${verText}${reset}${sep}"
if ($ctxText)   { $line += "${ctxText}${sep}" }
if ($modelText) { $line += "${cModel}($modelText)${reset}${sep}" }
if ($cwd)       { $line += "${cDir}DIR: $(Short-Path $cwd)${reset}" }
if ($branch)    { $line += "${sep}${cBranch}Branch: $branch${reset}" }

Write-Output $line
