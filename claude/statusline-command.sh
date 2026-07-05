#!/usr/bin/env bash
# Claude Code statusline — native bash/jq port of statusline-command.ps1.
# Use this on macOS/Linux to avoid a PowerShell dependency just for the statusline.
#
# Why this exists (the proxy problem):
#   Claude Code -> LiteLLM -> GitHub Copilot. Claude Code's BUILT-IN context bar is
#   unusable through the proxy: even though LiteLLM now returns real /count_tokens
#   numbers, the proxy's model registry exposes only the wildcard "*" with
#   max_input_tokens=null — so Claude Code has a numerator but NO denominator and
#   can't compute a percentage. This script sidesteps that entirely: it reads the
#   REAL token usage from the session transcript (the usage block the model actually
#   returned) and divides by the model's true context window (hardcoded map below).
#   Accurate regardless of the proxy.
#
# Dependency: jq  (brew install jq). Degrades gracefully to version/model/dir if absent.

input="$(cat)"
esc=$'\033'
reset="${esc}[0m"
c_ver="${esc}[38;5;39m"
c_model="${esc}[38;5;141m"
c_dir="${esc}[38;5;78m"
c_branch="${esc}[38;5;220m"
c_ok="${esc}[38;5;78m"     # green  <50%
c_warn="${esc}[38;5;220m"  # yellow 50-80%
c_hot="${esc}[38;5;203m"   # red    >=80%
sep="${esc}[38;5;240m | ${esc}[0m"

have_jq=1; command -v jq >/dev/null 2>&1 || have_jq=0

jqget() { [ "$have_jq" = 1 ] && printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

ccver="$(jqget '.version')"; [ -z "$ccver" ] && ccver="$(jqget '.cli_version')"
model="$(jqget '.model.display_name')"; [ -z "$model" ] && model="$(jqget '.model')"
model_short="$(printf '%s' "$model" | sed 's/^Claude //')"
effort="$(jqget '.effortLevel')"
cwd="$(jqget '.workspace.current_dir')"; [ -z "$cwd" ] && cwd="$PWD"
transcript="$(jqget '.transcript_path')"
session="$(jqget '.session_id')"

# derive transcript path from cwd+session if not provided (Claude Code maps each of
# : \ / . to its own dash, e.g. /Users/me/proj -> -Users-me-proj)
if [ -z "$transcript" ] && [ -n "$cwd" ]; then
  mangled="$(printf '%s' "$cwd" | sed 's#[/:.\\]#-#g')"
  projdir="$HOME/.claude/projects/$mangled"
  if [ -n "$session" ] && [ -f "$projdir/$session.jsonl" ]; then
    transcript="$projdir/$session.jsonl"
  elif [ -d "$projdir" ]; then
    transcript="$(ls -t "$projdir"/*.jsonl 2>/dev/null | head -1)"
  fi
fi

# true context windows (input tokens) for models reachable via Copilot; substring match.
context_window() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    *opus-4.8*|*opus-4-8*|*opus-4.7-1m*|*opus-4.7|*opus-4.6*|*sonnet-4.6*|*1m*) echo 1000000 ;;
    *opus-4.5*|*sonnet-4.5*|*haiku-4.5*|*opus-4.7-high*|*opus-4.7-xhigh*) echo 200000 ;;
    *) echo 200000 ;;
  esac
}
fmt() { awk -v n="$1" 'BEGIN{ if(n>=1e6)printf "%.2fM",n/1e6; else if(n>=1e3)printf "%.1fk",n/1e3; else printf "%d",n }'; }

# high-water-mark of main-chain (non-sidechain) assistant context. MAX not latest:
# through the proxy a turn's input_tokens is the FULL context on some turns and just
# the incremental message on others, so latest-turn yo-yos 252k->2k->254k. The real
# footprint only grows (no caching, auto-compact disabled), so peak is the honest number.
ctx_text=""
if [ "$have_jq" = 1 ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  read -r max_tokens max_model < <(
    tail -n 400 "$transcript" 2>/dev/null | jq -rc '
      select(.type=="assistant" and (.isSidechain|not) and .message.usage.input_tokens != null)
      | [ (.message.usage.input_tokens
           + (.message.usage.cache_read_input_tokens // 0)
           + (.message.usage.cache_creation_input_tokens // 0)),
          (.message.model // "") ] | @tsv' 2>/dev/null \
    | awk -F'\t' '$1>m{m=$1;mm=$2} END{if(m>0)print m"\t"mm}' | tr '\t' ' '
  )
  if [ -n "$max_tokens" ] && [ "$max_tokens" -gt 0 ] 2>/dev/null; then
    win_model="$max_model"; [ -z "$win_model" ] && win_model="$model"
    window="$(context_window "$win_model")"
    pct=$(awk -v t="$max_tokens" -v w="$window" 'BEGIN{printf "%d", (t/w)*100}')
    col="$c_ok"; [ "$pct" -ge 50 ] && col="$c_warn"; [ "$pct" -ge 80 ] && col="$c_hot"
    ctx_text="${col}Ctx $(fmt "$max_tokens")/$(fmt "$window") (${pct}%)${reset}"
  fi
fi

branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git --no-optional-locks -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)"
  [ -z "$branch" ] && branch="$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
fi

# short dir: last 2 segments
short_dir="$cwd"
seg_count="$(printf '%s' "$cwd" | tr '/' '\n' | grep -c .)"
[ "${seg_count:-0}" -gt 2 ] && short_dir=".../$(printf '%s' "$cwd" | rev | cut -d/ -f1-2 | rev)"

verlabel="Claude"; [ -n "$ccver" ] && verlabel="V$ccver"
modeltext="$model_short"; [ -n "$effort" ] && [ -n "$model_short" ] && modeltext="$model_short/$effort"

line="${c_ver}${verlabel}${reset}${sep}"
[ -n "$ctx_text" ]  && line+="${ctx_text}${sep}"
[ -n "$modeltext" ] && line+="${c_model}(${modeltext})${reset}${sep}"
[ -n "$cwd" ]       && line+="${c_dir}DIR: ${short_dir}${reset}"
[ -n "$branch" ]    && line+="${sep}${c_branch}Branch: ${branch}${reset}"

printf "%b\n" "$line"
