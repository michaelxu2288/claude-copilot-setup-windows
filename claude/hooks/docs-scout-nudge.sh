#!/usr/bin/env bash
# UserPromptSubmit hook: nudge the main agent to call docs-scout when the current
# project has an ENABLED docs wiki (a docs-wiki/ directory) AND the prompt is a
# substantial task prompt. Fast, dependency-light, fails silent. Emits
# hookSpecificOutput.additionalContext (the sanctioned UserPromptSubmit injection
# point) only when it should nudge; otherwise prints {} and exits 0. Never blocks
# a prompt. The opt-in gate is purely the presence of docs-wiki/ — so this stays
# 100% silent in any project that has not opted in.

payload="$(cat)"

emit_silent() { printf '{}\n'; exit 0; }

# jq is the only dependency; if it's missing, stay silent rather than risk noise
command -v jq >/dev/null 2>&1 || emit_silent

# parse prompt + cwd from the hook payload; on any parse error, stay silent
prompt="$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null)" || emit_silent
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"

# resolve the project root: CLAUDE_PROJECT_DIR wins, else the payload cwd
proj="${CLAUDE_PROJECT_DIR:-$cwd}"
[ -n "$proj" ] || emit_silent

# opt-in gate: no docs-wiki/ in this project -> stay completely silent
[ -d "$proj/docs-wiki" ] || emit_silent

# substantial-prompt gate: skip empty prompts, slash-commands, and very short asks
[ -n "$prompt" ] || emit_silent
case "$prompt" in /*) emit_silent ;; esac
[ "${#prompt}" -ge 60 ] || emit_silent

nudge="[docs-scout reminder] This project has an enabled docs wiki (./docs-wiki/). Before answering from memory or reading the wiki yourself, STRONGLY prefer dispatching the read-only 'docs-scout' subagent with a detailed 3-4 paragraph request to gather cited prior context from docs-wiki/. Skip only if you already hold the needed cited context this session or the ask is trivial. After good work, run /docs-sync to fork docs-writer subagent(s) and file the session's durable knowledge back into the wiki."

jq -cn --arg ctx "$nudge" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
