#!/usr/bin/env bash
# PostToolUse hook: auto-format Python files with ruff after Edit/Write/MultiEdit.
# Ported from format-python.ps1 (pwsh) to bash for macOS. Never blocks a tool:
# always exits 0, prints {} when there's nothing to do, and only injects an
# additionalContext note when ruff actually reports a problem.

payload="$(cat)"

emit_empty() { printf '{}\n'; exit 0; }

# jq is the only hard dependency; without it, stay quiet
command -v jq >/dev/null 2>&1 || emit_empty

# on unparseable payload, stay quiet (PostToolUse payloads are always valid JSON)
tool="$(printf '%s' "$payload" | jq -r '.tool_name // .toolName // ""' 2>/dev/null)" || emit_empty

# secondary tool gate (the settings.json matcher already scopes Edit|Write|MultiEdit).
# accept the legacy Copilot verbs too, and an empty tool (don't over-filter).
case "$tool" in
  ""|edit|create|Edit|Write|MultiEdit) : ;;
  *) emit_empty ;;
esac

# file path across Claude Code (tool_input.*) and legacy Copilot (toolArgs.*) shapes
file="$(printf '%s' "$payload" | jq -r '(.tool_input.file_path // .tool_input.path // .toolArgs.file_path // .toolArgs.path) // ""' 2>/dev/null)"
[ -n "$file" ] || emit_empty

# only python files
case "$file" in
  *.py) : ;;
  *) emit_empty ;;
esac

# resolve a relative path against the payload cwd
case "$file" in
  /*) : ;;
  *)
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
    [ -n "$cwd" ] && file="$cwd/$file"
    ;;
esac

[ -f "$file" ] || emit_empty
command -v ruff >/dev/null 2>&1 || emit_empty

# ruff check --fix returns non-zero when unfixable lint remains; ruff format
# returns non-zero on error. Capture both, report only on failure.
check_out="$(ruff check --fix "$file" 2>&1)"; check_exit=$?
format_out="$(ruff format "$file" 2>&1)"; format_exit=$?

if [ "$check_exit" -ne 0 ] || [ "$format_exit" -ne 0 ]; then
  detail="$(printf '%s\n%s\n' "$check_out" "$format_out" | head -20)"
  msg="Python formatting hook reported issues for $file
$detail"
  jq -cn --arg d "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$d}}'
  exit 0
fi

emit_empty
