#!/bin/sh
# repo-intel build guard: with a non-agent backend configured, deny graphify builds
# that would run on agent subagents. Routing advice lives in claude/CLAUDE.md, not here.
# Usage: repo-intel-hook.sh pre-llm  (PreToolUse hook JSON on stdin)

[ "$1" = pre-llm ] || exit 0
input=$(cat)

# jq is the only hard dependency; without it, stay out of the way.
command -v jq >/dev/null 2>&1 || exit 0

# One jq call for every field. Fields are joined with the ASCII unit separator (a
# non-whitespace IFS keeps empty fields); newlines become ";" so the prompt stays on one line.
fields=$(printf '%s' "$input" | jq -r '[
  .cwd, .tool_name, .tool_input.skill, .tool_input.args, .tool_input.prompt
] | map((. // "") | tostring | gsub("[\r\n]"; ";") | gsub("\u001f"; " ")) | join("\u001f")' 2>/dev/null) || exit 0

us=$(printf '\037')
IFS=$us read -r cwd tool_name skill_name skill_args agent_prompt <<EOF
$fields
EOF

# Cheap exits first: most Skill and Agent calls have nothing to do with graphify.
case $tool_name in
Skill)
  case $skill_name in
  graphify|*:graphify) ;;
  *) exit 0 ;;
  esac
  case $(printf '%s' "$skill_args" | awk '{print $1}') in
  query|path|explain) exit 0 ;;
  esac
  ;;
Agent|Task)
  # Match the extraction spec's opening line only, so prompts that merely quote it pass.
  printf '%s' "$agent_prompt" | grep -Eq '^[[:space:]]*You are a graphify extraction subagent' || exit 0
  ;;
*) exit 0 ;;
esac

[ -n "$cwd" ] || cwd=$PWD
# Git root, stopping at $HOME.
git_root=""
d=$cwd
while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
  if [ -e "$d/.git" ]; then git_root=$d; break; fi
  d=$(dirname "$d")
done

# Backend and model come from one source: env, else the first config file that
# names a backend (repo root, then user). An unreadable file is skipped.
backend=""; model=""
if [ -n "${REPO_INTEL_BACKEND:-}" ]; then
  backend=$REPO_INTEL_BACKEND; model=${REPO_INTEL_MODEL:-}
else
  for f in ${git_root:+"$git_root/.repo-intel.json"} "${XDG_CONFIG_HOME:-$HOME/.config}/repo-intel/config.json"; do
    [ -f "$f" ] || continue
    pair=$(jq -r '"\(.llm.backend // "")\u001f\(.llm.model // "")"' "$f" 2>/dev/null) || continue
    IFS=$us read -r b m <<EOF
$pair
EOF
    if [ -n "$b" ]; then backend=$b; model=${REPO_INTEL_MODEL:-$m}; break; fi
  done
fi
[ -n "$backend" ] && [ "$backend" != agent ] || exit 0

reason="repo-intel: graphify semantic extraction here runs on the ${backend}${model:+/$model} backend, not on agent subagents. Run \`repo-intel build\` (Bash) instead. Graph reads stay allowed: \`graphify query|path|explain\`. To build with subagents on purpose, the user can run \`repo-intel config --backend agent\`."
jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
