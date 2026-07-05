# UserPromptSubmit hook (Windows): nudge the main agent to call docs-scout when the
# current project has an ENABLED docs wiki (a docs-wiki/ directory) AND the prompt is a
# substantial task prompt. Fast, fails silent, never blocks. Opt-in gate = docs-wiki/ present.
$ErrorActionPreference = "SilentlyContinue"
$raw = [Console]::In.ReadToEnd()
function Emit-Silent { Write-Output '{}'; exit 0 }

try { $p = $raw | ConvertFrom-Json } catch { Emit-Silent }
$prompt = "$($p.prompt)"
$cwd    = "$($p.cwd)"
$proj   = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { $cwd }

if (-not $proj) { Emit-Silent }
if (-not (Test-Path (Join-Path $proj "docs-wiki"))) { Emit-Silent }   # opt-in gate
if (-not $prompt) { Emit-Silent }
if ($prompt.StartsWith("/")) { Emit-Silent }                          # skip slash-commands
if ($prompt.Length -lt 60) { Emit-Silent }                           # skip trivial asks

$nudge = "[docs-scout reminder] This project has an enabled docs wiki (./docs-wiki/). Before answering from memory or reading the wiki yourself, STRONGLY prefer dispatching the read-only 'docs-scout' subagent with a detailed 3-4 paragraph request to gather cited prior context from docs-wiki/. Skip only if you already hold the needed cited context this session or the ask is trivial. After good work, run /docs-sync to fork docs-writer subagent(s) and file the session's durable knowledge back into the wiki."

@{ hookSpecificOutput = @{ hookEventName = "UserPromptSubmit"; additionalContext = $nudge } } | ConvertTo-Json -Compress
