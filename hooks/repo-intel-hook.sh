#!/bin/sh
# repo-intel hook entry point: one short-lived sh process per event.
# Silent (zero tokens, no node/python start) unless the repo has a graph or a backend.
# Usage: repo-intel-hook.sh session-start|prompt|pre-search|pre-llm  (hook JSON on stdin)

event=$1
input=$(cat)

# jq is the only hard dependency on the hot path; without it, stay out of the way.
command -v jq >/dev/null 2>&1 || exit 0

# One jq call for every field any event needs. Fields are joined with the ASCII unit
# separator (a non-whitespace IFS keeps empty fields); newlines become ";" so a
# multi-line command still reads as separate statements.
fields=$(printf '%s' "$input" | jq -r '[
  .session_id, .cwd, .tool_name,
  .tool_input.command, .tool_input.skill, .tool_input.args, .tool_input.prompt
] | map((. // "") | tostring | gsub("[\r\n]"; ";") | gsub("\u001f"; " ")) | join("\u001f")' 2>/dev/null) || exit 0

us=$(printf '\037')
IFS=$us read -r session_id cwd tool_name tool_command skill_name skill_args agent_prompt <<EOF
$fields
EOF
[ -n "$cwd" ] || cwd=$PWD

# Nearest dir holding a graph, and the git root; both stop at $HOME.
graph_root=""
git_root=""
d=$cwd
while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
  if [ -z "$graph_root" ] && { [ -d "$d/.codegraph" ] || [ -f "$d/graphify-out/graph.json" ]; }; then
    graph_root=$d
  fi
  if [ -e "$d/.git" ]; then git_root=$d; break; fi
  d=$(dirname "$d")
done

# Backend and model come from one source: env, else the first config file that
# names a backend (repo root, then user). An unreadable file is reported, not trusted.
backend=""; model=""; config_error=""
if [ -n "${REPO_INTEL_BACKEND:-}" ]; then
  backend=$REPO_INTEL_BACKEND; model=${REPO_INTEL_MODEL:-}
else
  for f in ${git_root:+"$git_root/.repo-intel.json"} "${XDG_CONFIG_HOME:-$HOME/.config}/repo-intel/config.json"; do
    [ -f "$f" ] || continue
    if ! pair=$(jq -r '"\(.llm.backend // "")\u001f\(.llm.model // "")"' "$f" 2>/dev/null); then
      config_error=$f; continue
    fi
    IFS=$us read -r b m <<EOF
$pair
EOF
    if [ -n "$b" ]; then backend=$b; model=${REPO_INTEL_MODEL:-$m}; break; fi
  done
fi
enforce=0; [ -n "$backend" ] && [ "$backend" != agent ] && enforce=1

emit_context() {
  jq -cn --arg e "$1" --arg c "$2" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

# The build guard must also cover the first build, before any graph exists.
if [ "$event" = pre-llm ]; then
  [ $enforce = 1 ] || exit 0
  reason="repo-intel: graphify semantic extraction here runs on the ${backend}${model:+/$model} backend, not on agent subagents. Run \`repo-intel build\` (Bash) instead. Graph reads stay allowed: \`graphify query|path|explain\`. To build with subagents on purpose, the user can run \`repo-intel config --backend agent\`."
  case $tool_name in
  Skill)
    case $skill_name in
    graphify|*:graphify) ;;
    *) exit 0 ;;
    esac
    first=$(printf '%s' "$skill_args" | awk '{print $1}')
    case $first in
    query|path|explain) exit 0 ;;
    esac
    deny "$reason"
    ;;
  Agent|Task)
    # Match the extraction spec's opening line only, so prompts that merely quote it pass.
    printf '%s' "$agent_prompt" | grep -Eq '^[[:space:]]*You are a graphify extraction subagent' && deny "$reason"
    ;;
  esac
  exit 0
fi

root=$graph_root
if [ -z "$root" ]; then
  [ "$event" = session-start ] && [ -n "$config_error" ] && \
    emit_context SessionStart "repo-intel: $config_error is not valid JSON; its backend setting is ignored."
  exit 0
fi
has_codegraph=0; [ -d "$root/.codegraph" ] && has_codegraph=1
has_graphify=0; [ -f "$root/graphify-out/graph.json" ] && has_graphify=1

case $event in
session-start)
  msg="repo-intel ($root):"
  if [ $has_codegraph = 1 ]; then
    msg="$msg Code structure (where X is defined, who calls it, what breaks if it changes): codegraph first, via the codegraph_explore MCP tool or \`codegraph explore \"<symbols or question>\"\`."
  fi
  if [ $has_graphify = 1 ]; then
    msg="$msg Concepts, docs, architecture and why: \`graphify query \"<question>\"\` (also \`graphify path A B\`, \`graphify explain X\`)."
    # graphify's own git hook keeps code fresh; only docs changed since the last build need an LLM pass.
    built=$(cat "$root/graphify-out/.repo-intel-built" 2>/dev/null)
    if [ -n "$built" ] && git -C "$root" diff --name-only "$built" HEAD -- . 2>/dev/null \
        | grep -v '^graphify-out/' | grep -Eiq '\.(md|mdx|markdown|txt|rst|pdf|docx|xlsx|png|jpe?g|webp|gif)$'; then
      msg="$msg The graphify graph is older than the docs changed since its last build; run \`repo-intel build\` before trusting it on those."
    fi
  fi
  msg="$msg Literal text, and any complete list of call sites before calling a change safe: rg."
  if [ $enforce = 1 ]; then
    msg="$msg Graph builds run on the ${backend}${model:+/$model} backend via \`repo-intel build\`; never dispatch graphify extraction subagents."
  fi
  [ -n "$config_error" ] && msg="$msg Warning: $config_error is not valid JSON; its backend setting is ignored."
  emit_context SessionStart "$msg"
  ;;

prompt)
  [ $has_codegraph = 1 ] || exit 0
  command -v codegraph >/dev/null 2>&1 || exit 0
  prompt=$(printf '%s' "$input" | jq -r '.prompt // ""')
  # Start node only for prompts that look structural or name a code symbol.
  if printf '%s' "$prompt" | grep -Eiq '(call(s|ers|ees|ed)?|who uses|used by|defin(ed|ition)|implement|impact|blast radius|break|refactor|rename|depend|import|trace|flow|entry ?point|architecture|how does|where is|wywo[lł]|u[zż]ywa|zdefiniow|implementac|zale[zż]|zepsuje|refaktor|przep[lł]yw|architektur|jak dzia[lł]a|gdzie jest)' \
    || printf '%s' "$prompt" | grep -Eq '([a-z0-9]+[A-Z][A-Za-z0-9]+|[a-z0-9]+_[a-z0-9_]+|[A-Za-z0-9_]+\(\)|[A-Za-z0-9_/-]+\.(ts|tsx|js|jsx|mjs|py|go|rs|java|kt|rb|php|swift|cs|c|cc|cpp|h))'; then
    printf '%s' "$input" | codegraph prompt-hook
  fi
  ;;

pre-search)
  is_search=0
  case $tool_name in
  Grep|Glob) is_search=1 ;;
  Bash)
    printf '%s' "$tool_command" | grep -Eq '(^|[;&|(])[[:space:]]*(rg|grep|egrep|fgrep|ag|ack|fd|find|git[[:space:]]+grep)([[:space:]]|$)' && is_search=1
    ;;
  esac
  [ $is_search = 1 ] || exit 0
  # Nudge once per session and root; repeating it only burns context.
  state_dir="${TMPDIR:-/tmp}/repo-intel"
  root_key=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
  marker="$state_dir/${session_id:-nosession}.$root_key"
  [ -e "$marker" ] && exit 0
  mkdir -p "$state_dir" 2>/dev/null && : > "$marker"
  hint="repo-intel: this repo has"
  [ $has_codegraph = 1 ] && hint="$hint a codegraph index (\`codegraph explore \"<symbols>\"\` answers where/who-calls/impact in one call)"
  [ $has_codegraph = 1 ] && [ $has_graphify = 1 ] && hint="$hint and"
  [ $has_graphify = 1 ] && hint="$hint a graphify graph (\`graphify query \"<question>\"\` for concepts and architecture)"
  hint="$hint. Orient there first for broad questions; rg stays right for literal text and exhaustive call-site lists. (Shown once per session.)"
  emit_context PreToolUse "$hint"
  ;;
esac
exit 0
