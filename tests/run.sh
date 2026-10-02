#!/usr/bin/env bash
# Behaviour tests for the hook script and the repo-intel CLI.
# Real graphify/codegraph are replaced by fakes that log their arguments.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/hooks/repo-intel-hook.sh"
cli="$here/bin/repo-intel"
bump="$here/scripts/bump-version.sh"
pass=0 fail=0
orig_path=$PATH

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" CLAUDE_CONFIG_DIR="$work/home/.claude" TMPDIR="$work/tmp"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$TMPDIR" "$work/fakebin"
unset REPO_INTEL_BACKEND REPO_INTEL_MODEL

cat > "$work/fakebin/codegraph" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/codegraph.log"
[ "\$1" = prompt-hook ] && printf '<codegraph_context>fake</codegraph_context>\n'
exit 0
EOF
chmod +x "$work/fakebin/codegraph"

# Fake graphify. `extract` is configurable per test via sentinel files under
# $work (absent means the default: writes a valid empty graph, exits 0, no
# warning), so build's exit-status contract can be exercised without the real
# tool:
#   graphify.exit       exit code `extract` returns (default 0)
#   graphify.no-graph   present: `extract` does not write graphify-out/graph.json
#   graphify.bad-json   present: `extract` writes invalid JSON to graph.json
#   graphify.warn       present: its contents are printed to stderr as-is
#                        (used to simulate graphify's partial-parse warning)
cat > "$work/fakebin/graphify" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/graphify.log"
if [ "\$1" = prompt-hook ]; then
  printf '<codegraph_context>fake</codegraph_context>\n'
  exit 0
fi
if [ "\$1" = extract ]; then
  [ -f "$work/graphify.warn" ] && /bin/cat "$work/graphify.warn" >&2
  if [ ! -f "$work/graphify.no-graph" ]; then
    mkdir -p graphify-out
    if [ -f "$work/graphify.bad-json" ]; then
      printf '{not json' > graphify-out/graph.json
    else
      printf '{}\n' > graphify-out/graph.json
    fi
  fi
  ec=0
  [ -f "$work/graphify.exit" ] && ec=\$(/bin/cat "$work/graphify.exit")
  exit "\$ec"
fi
exit 0
EOF
chmod +x "$work/fakebin/graphify"
export PATH="$work/fakebin:$PATH"

# Fake installers, one per own directory so a test can compose an install-time
# PATH from exactly the tools it wants "present", never falling through to the
# real uv/pipx/pnpm/npm on this machine. Each logs its argv and honours a
# "<name>.fail" sentinel to simulate a failing install.
for tool in uv pipx pnpm npm; do
  mkdir -p "$work/bin-$tool"
  /bin/cat > "$work/bin-$tool/$tool" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/$tool.log"
[ -f "$work/$tool.fail" ] && exit 1
exit 0
EOF
  chmod +x "$work/bin-$tool/$tool"
done
# pipx also answers `list --short`, driven by "$work/pipx.list" (absent or no
# matching line means pipx does not manage that package).
/bin/cat > "$work/bin-pipx/pipx" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/pipx.log"
[ -f "$work/pipx.fail" ] && exit 1
if [ "\$1" = list ] && [ "\$2" = --short ]; then
  [ -f "$work/pipx.list" ] && /bin/cat "$work/pipx.list"
fi
exit 0
EOF
chmod +x "$work/bin-pipx/pipx"
install_path() { # space-separated dirs under $work to expose, e.g. "bin-uv fakebin"
  local p="/usr/bin:/bin" d
  for d in "$@"; do p="$work/$d:$p"; done
  printf '%s' "$p"
}

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { # name, status (0 = pass), detail shown on failure
  if [ "$2" = 0 ]; then ok "$1"; else ko "$1" "$3"; fi
}

new_repo() {
  local d="$work/repos/$1"
  mkdir -p "$d" && git -C "$d" init -q && git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$d"
}

hook_json() { # cwd, extra fields as JSON
  jq -cn --arg cwd "$1" --argjson extra "${2:-{\}}" '{session_id: "s1", cwd: $cwd} + $extra'
}

run_hook() { # event, json
  printf '%s' "$2" | sh "$hook" "$1"
}

echo "hook"

plain=$(new_repo plain)
out=$(run_hook session-start "$(hook_json "$plain")")
check "silent in a repo without graphs" "$([ -z "$out" ]; echo $?)" "got: $out"

cg=$(new_repo cg); mkdir -p "$cg/.codegraph" "$cg/src"
out=$(run_hook session-start "$(hook_json "$cg/src")")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("codegraph")' >/dev/null
check "session-start routes to codegraph from a subdirectory" $? "got: $out"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("graphify query") | not' >/dev/null
check "session-start omits graphify when it has no graph" $? "got: $out"

both=$(new_repo both); mkdir -p "$both/.codegraph" "$both/graphify-out"; echo '{}' > "$both/graphify-out/graph.json"
out=$(run_hook session-start "$(hook_json "$both")")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("older than") | not' >/dev/null
check "no stale warning without a build marker" $? "got: $out"

search=$(hook_json "$both" '{"tool_name":"Bash","tool_input":{"command":"cd src && rg -n foo"}}')
out=$(run_hook pre-search "$search")
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
check "pre-search nudges on the first rg" $? "got: $out"
out=$(run_hook pre-search "$search")
check "pre-search stays silent after the first nudge" "$([ -z "$out" ]; echo $?)" "got: $out"

out=$(run_hook pre-search "$(jq -cn --arg cwd "$both" '{session_id:"s2",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls -la"}}')")
check "pre-search ignores non-search commands" "$([ -z "$out" ]; echo $?)" "got: $out"

out=$(run_hook pre-search "$(jq -cn --arg cwd "$both" '{session_id:"s3",cwd:$cwd,tool_name:"Bash",tool_input:{command:"echo hi\nfind . -name x"}}')")
check "pre-search sees a search on a later line" "$([ -n "$out" ]; echo $?)" "got nothing"

skill_full=$(hook_json "$both" '{"tool_name":"Skill","tool_input":{"skill":"graphify","args":"."}}')
out=$(run_hook pre-llm "$skill_full")
check "pre-llm allows everything when no backend is set" "$([ -z "$out" ]; echo $?)" "got: $out"

printf '{"llm":{"backend":"litellm","model":"deepseek-v4-flash"}}' > "$both/.repo-intel.json"
out=$(run_hook pre-llm "$skill_full")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | test("litellm/deepseek-v4-flash"))' >/dev/null
check "pre-llm denies a /graphify build when a backend is set" $? "got: $out"

out=$(run_hook pre-llm "$(hook_json "$both" '{"tool_name":"Skill","tool_input":{"skill":"graphify","args":"query \"who owns auth\""}}')")
check "pre-llm allows /graphify query" "$([ -z "$out" ]; echo $?)" "got: $out"

out=$(run_hook pre-llm "$(hook_json "$both" '{"tool_name":"Agent","tool_input":{"prompt":"You are a graphify extraction subagent. Read the files"}}')")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
check "pre-llm denies extraction subagents" $? "got: $out"

out=$(run_hook pre-llm "$(hook_json "$both" '{"tool_name":"Agent","tool_input":{"prompt":"review this diff"}}')")
check "pre-llm leaves other subagents alone" "$([ -z "$out" ]; echo $?)" "got: $out"

out=$(REPO_INTEL_BACKEND=agent run_hook pre-llm "$skill_full")
check "REPO_INTEL_BACKEND=agent overrides the repo config" "$([ -z "$out" ]; echo $?)" "got: $out"

fresh=$(new_repo fresh)
printf '{"llm":{"backend":"litellm"}}' > "$fresh/.repo-intel.json"
out=$(run_hook pre-llm "$(hook_json "$fresh" '{"tool_name":"Skill","tool_input":{"skill":"graphify","args":"."}}')")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
check "pre-llm denies the first build in a repo with no graph yet" $? "got: $out"

mono=$(new_repo mono); mkdir -p "$mono/pkg/.codegraph"
printf '{"llm":{"backend":"litellm"}}' > "$mono/.repo-intel.json"
out=$(run_hook pre-llm "$(hook_json "$mono/pkg" '{"tool_name":"Skill","tool_input":{"skill":"graphify","args":"."}}')")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
check "hook reads .repo-intel.json at the git root, not at the graph dir" $? "got: $out"

mkdir -p "$XDG_CONFIG_HOME/repo-intel"
printf '{"llm":{"backend":"ollama","model":"qwen3"}}' > "$XDG_CONFIG_HOME/repo-intel/config.json"
out=$(run_hook pre-llm "$(hook_json "$fresh" '{"tool_name":"Skill","tool_input":{"skill":"graphify","args":"."}}')")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("litellm") and (test("qwen3") | not)' >/dev/null 2>&1
check "hook never mixes a repo backend with the user config's model" $? "got: $out"
rm -f "$XDG_CONFIG_HOME/repo-intel/config.json"

out=$(run_hook pre-llm "$(hook_json "$both" '{"tool_name":"Agent","tool_input":{"prompt":"Debug why the hook denies prompts saying: You are a graphify extraction subagent."}}')")
check "pre-llm only denies prompts that start as the extraction spec" "$([ -z "$out" ]; echo $?)" "got: $out"
out=$(run_hook pre-llm "$(hook_json "$both" '{"tool_name":"Task","tool_input":{"prompt":"You are a graphify extraction subagent. Read"}}')")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("backend agent")' >/dev/null 2>&1
check "pre-llm covers the older Task tool name and names the opt-out" $? "got: $out"

stale=$(new_repo stale); mkdir -p "$stale/graphify-out"; echo '{}' > "$stale/graphify-out/graph.json"
git -C "$stale" rev-parse HEAD > "$stale/graphify-out/.repo-intel-built"
sleep 1
git -C "$stale" add -A && git -C "$stale" -c user.email=t@t -c user.name=t commit -qm "commit the graph"
out=$(run_hook session-start "$(hook_json "$stale")")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("older than") | not' >/dev/null
check "committing only the graph does not mark it stale" $? "got: $out"
echo 'x = 1' > "$stale/app.py"
git -C "$stale" add -A && git -C "$stale" -c user.email=t@t -c user.name=t commit -qm "code change"
out=$(run_hook session-start "$(hook_json "$stale")")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("older than") | not' >/dev/null
check "a code-only commit does not mark the graph stale (graphify's git hook covers code)" $? "got: $out"
echo '# decision' > "$stale/DECISIONS.md"
git -C "$stale" add -A && git -C "$stale" -c user.email=t@t -c user.name=t commit -qm "doc change"
out=$(run_hook session-start "$(hook_json "$stale")")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("older than the docs")' >/dev/null
check "a doc commit after the build marks the graph stale" $? "got: $out"

bad=$(new_repo bad); mkdir -p "$bad/.codegraph"; printf '{not json' > "$bad/.repo-intel.json"
out=$(run_hook session-start "$(hook_json "$bad")")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("not valid JSON")' >/dev/null
check "session-start warns about an unreadable .repo-intel.json" $? "got: $out"

rm -f "$work/codegraph.log"
out=$(run_hook prompt "$(hook_json "$both" '{"prompt":"write a haiku about autumn"}')")
check "prompt skips codegraph for non-structural prompts" "$([ -z "$out" ] && [ ! -e "$work/codegraph.log" ]; echo $?)" "got: $out"
out=$(run_hook prompt "$(hook_json "$both" '{"prompt":"who calls parseConfig?"}')")
check "prompt delegates structural prompts to codegraph prompt-hook" "$([ "$out" = "<codegraph_context>fake</codegraph_context>" ]; echo $?)" "got: $out"
out=$(run_hook prompt "$(hook_json "$both" '{"prompt":"gdzie jest zdefiniowany limit?"}')")
check "prompt recognises Polish structural prompts" "$([ -n "$out" ]; echo $?)" "got nothing"

ms() { perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'; }
payload=$(hook_json "$plain")
start=$(ms)
for _ in 1 2 3 4 5 6 7 8 9 10; do printf '%s' "$payload" | sh "$hook" session-start >/dev/null; done
avg=$(( ($(ms) - start) / 10 ))
printf '       (no-graph session-start: %s ms avg)\n' "$avg"
check "hook is fast when the repo has no graph (<100 ms)" "$([ "$avg" -lt 100 ]; echo $?)" "avg ${avg} ms"

echo "cli"

out=$("$cli" help 2>&1)
check "help prints usage" "$(echo "$out" | grep -q '^Usage: repo-intel'; echo $?)" "got: $out"

r=$(new_repo cfg)
(cd "$r" && "$cli" config --backend litellm --model deepseek-v4-flash >/dev/null 2>&1)
jq -e '.llm == {"backend":"litellm","model":"deepseek-v4-flash"}' "$r/.repo-intel.json" >/dev/null 2>&1
check "config writes the repo backend" $? "got: $(cat "$r/.repo-intel.json" 2>/dev/null)"
(cd "$r" && "$cli" config --global --backend ollama --model qwen3 >/dev/null 2>&1)
jq -e '.llm.backend == "ollama"' "$XDG_CONFIG_HOME/repo-intel/config.json" >/dev/null 2>&1
check "config --global writes the user backend" $? "missing user config"
out=$(cd "$r" && "$cli" config --show 2>&1)
check "repo config wins over user config" "$(echo "$out" | grep -q 'backend=litellm'; echo $?)" "got: $out"

rm -f "$work/graphify.log"
(cd "$r" && "$cli" build >/dev/null 2>&1)
grep -qx 'extract . --backend litellm --model deepseek-v4-flash' "$work/graphify.log" 2>/dev/null
check "build passes the configured backend to graphify extract" $? "got: $(cat "$work/graphify.log" 2>/dev/null)"

rm -f "$work/graphify.log" "$XDG_CONFIG_HOME/repo-intel/config.json"
r2=$(new_repo nocfg)
(cd "$r2" && "$cli" build >/dev/null 2>&1)
grep -qx 'extract . --code-only' "$work/graphify.log" 2>/dev/null
check "build without a backend never calls an LLM" $? "got: $(cat "$work/graphify.log" 2>/dev/null)"

check "code-only build writes no build marker" "$([ ! -e "$r2/graphify-out/.repo-intel-built" ]; echo $?)" "marker written for a code-only build"

r3=$(new_repo mixed)
printf '{"llm":{"backend":"litellm"}}' > "$r3/.repo-intel.json"
printf '{"llm":{"backend":"ollama","model":"qwen3","base_url":"http://x"}}' > "$XDG_CONFIG_HOME/repo-intel/config.json"
rm -f "$work/graphify.log"
(cd "$r3" && "$cli" build >/dev/null 2>&1)
grep -qx 'extract . --backend litellm' "$work/graphify.log" 2>/dev/null
check "build takes model from the same config as the backend" $? "got: $(cat "$work/graphify.log" 2>/dev/null)"
rm -f "$work/graphify.log"
printf '{"llm":{"backend":"litellm","model":"deepseek-v4-flash"}}' > "$r3/.repo-intel.json"
(cd "$r3" && REPO_INTEL_BACKEND=ollama "$cli" build >/dev/null 2>&1)
grep -qx 'extract . --max-concurrency 1 --backend ollama' "$work/graphify.log" 2>/dev/null
check "an env backend ignores the file's model" $? "got: $(cat "$work/graphify.log" 2>/dev/null)"
rm -f "$XDG_CONFIG_HOME/repo-intel/config.json"

rm -f "$work/graphify.log"
printf '{"llm":{"backend":"ollama","model":"qwen3"}}' > "$r2/.repo-intel.json"
(cd "$r2" && "$cli" build --full >/dev/null 2>&1)
grep -qx 'extract . --force --max-concurrency 1 --backend ollama --model qwen3' "$work/graphify.log" 2>/dev/null
check "build throttles ollama and --full forces a rescan" $? "got: $(cat "$work/graphify.log" 2>/dev/null)"
git -C "$r2" rev-parse HEAD > "$work/head"
cmp -s "$work/head" "$r2/graphify-out/.repo-intel-built"
check "build records the commit it was built from" $? "missing or wrong $r2/graphify-out/.repo-intel-built"

svelte1=$(new_repo svelte1); mkdir -p "$svelte1/src"
printf '<script>let x = 1;</script>\n' > "$svelte1/src/App.svelte"
git -C "$svelte1" add -A && git -C "$svelte1" -c user.email=t@t -c user.name=t commit -qm "add svelte"
(cd "$svelte1" && "$cli" build >/dev/null 2>&1)
grep -qxF '*.svelte' "$svelte1/.graphifyignore" 2>/dev/null
check "repo with a tracked .svelte file gets *.svelte in .graphifyignore after build" $? "got: $(cat "$svelte1/.graphifyignore" 2>/dev/null)"

(cd "$svelte1" && "$cli" build >/dev/null 2>&1)
lines=$(grep -cxF '*.svelte' "$svelte1/.graphifyignore" 2>/dev/null || true)
check "running build twice leaves exactly one line" "$([ "$lines" = 1 ]; echo $?)" "got $lines line(s): $(cat "$svelte1/.graphifyignore" 2>/dev/null)"

nosvelte=$(new_repo nosvelte)
(cd "$nosvelte" && "$cli" build >/dev/null 2>&1)
check "repo without .svelte gets no .graphifyignore" "$([ ! -e "$nosvelte/.graphifyignore" ]; echo $?)" "file exists: $(cat "$nosvelte/.graphifyignore" 2>/dev/null)"

svelte2=$(new_repo svelte-existing-ignore); mkdir -p "$svelte2/src"
printf '<script>let x = 1;</script>\n' > "$svelte2/src/App.svelte"
printf 'node_modules/\n' > "$svelte2/.graphifyignore"
git -C "$svelte2" add -A && git -C "$svelte2" -c user.email=t@t -c user.name=t commit -qm "add svelte"
(cd "$svelte2" && "$cli" build >/dev/null 2>&1)
ignore_out=$(cat "$svelte2/.graphifyignore" 2>/dev/null)
check "an existing .graphifyignore with other lines is preserved" \
  "$(printf '%s\n' "$ignore_out" | grep -qxF 'node_modules/' && printf '%s\n' "$ignore_out" | grep -qxF '*.svelte'; echo $?)" \
  "got: $ignore_out"

# Enough tracked .svelte paths to push `git ls-files` past the ~64KB pipe buffer:
# a `producer | grep -q` pipeline under pipefail turns the resulting SIGPIPE into
# a false "no matches" and silently skips the ignore entry.
svelte3=$(new_repo svelte-bigrepo)
long=$(printf 'x%.0s' $(seq 1 180))
for i in $(seq 1 400); do
  d="$svelte3/dir-$long-$i"
  mkdir -p "$d"
  printf '<script>let x=1;</script>\n' > "$d/App.svelte"
done
git -C "$svelte3" add -A && git -C "$svelte3" -c user.email=t@t -c user.name=t commit -qm "add many svelte files"
bytes=$(git -C "$svelte3" ls-files -- '*.svelte' | wc -c | tr -d ' ')
check "test setup: git ls-files output for the big repo exceeds the 64KB pipe buffer" \
  "$([ "$bytes" -gt 65536 ]; echo $?)" "got $bytes bytes"
start=$(ms)
(cd "$svelte3" && "$cli" build >/dev/null 2>&1)
elapsed=$(( $(ms) - start ))
grep -qxF '*.svelte' "$svelte3/.graphifyignore" 2>/dev/null
check "a repo whose git ls-files output exceeds 64KB still gets *.svelte added" $? \
  "got: $(cat "$svelte3/.graphifyignore" 2>/dev/null); build took ${elapsed} ms"

cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{"model":"x","hooks":{
 "PreToolUse":[{"matcher":"Bash|Grep","hooks":[{"type":"command","command":"graphify hook-guard search"}]},
               {"matcher":"Edit","hooks":[{"type":"command","command":"keep-me"}]}],
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"codegraph prompt-hook"},{"type":"command","command":"other"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"stop-hook"}]}]}}
EOF
before=$(cat "$CLAUDE_CONFIG_DIR/settings.json")
"$cli" migrate-hooks >/dev/null 2>&1
check "migrate-hooks is a dry run by default" "$([ "$before" = "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" ]; echo $?)" "settings changed"
"$cli" migrate-hooks --apply >/dev/null 2>&1
jq -e '.model == "x"
  and ([.hooks[][] .hooks[].command] | sort == ["keep-me","other","stop-hook"])
  and (.hooks.PreToolUse | length == 1)' "$CLAUDE_CONFIG_DIR/settings.json" >/dev/null 2>&1
check "migrate-hooks --apply removes only the replaced hooks" $? "got: $(cat "$CLAUDE_CONFIG_DIR/settings.json")"
ls "$CLAUDE_CONFIG_DIR"/settings.json.bak-repo-intel-* >/dev/null 2>&1
check "migrate-hooks keeps a backup" $? "no backup file"

rm -f "$CLAUDE_CONFIG_DIR"/settings.json*
mkdir -p "$work/dotfiles"
printf '{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/Users/x/.local/bin/graphify hook-guard read"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"npx codegraph prompt-hook"}]}]}}' > "$work/dotfiles/settings.json"
ln -s "$work/dotfiles/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
out=$("$cli" migrate-hooks 2>&1)
check "migrate-hooks finds path-qualified and npx commands" "$(echo "$out" | grep -q 'hook-guard read' && echo "$out" | grep -q 'npx codegraph prompt-hook'; echo $?)" "got: $out"
"$cli" migrate-hooks --apply >/dev/null 2>&1
check "migrate-hooks keeps a symlinked settings.json a symlink" "$([ -L "$CLAUDE_CONFIG_DIR/settings.json" ]; echo $?)" "symlink replaced"
jq -e '.hooks == {}' "$work/dotfiles/settings.json" >/dev/null 2>&1
check "migrate-hooks edits the symlink target" $? "got: $(cat "$work/dotfiles/settings.json")"

echo "install"

rm -f "$work/uv.log"
out=$(PATH=$(install_path bin-uv fakebin) "$cli" install graphify 2>&1)
check "uv present: installs the latest, upgrading over an existing fake graphify" \
  "$(grep -qx 'tool install graphifyy@latest' "$work/uv.log" 2>/dev/null; echo $?)" "got: $(cat "$work/uv.log" 2>/dev/null); output: $out"

rm -f "$work/pipx.log" "$work/pipx.list"
out=$(PATH=$(install_path bin-pipx) "$cli" install graphify 2>&1)
check "pipx present, graphify unmanaged and absent: pipx install" \
  "$(grep -qx 'install graphifyy' "$work/pipx.log" 2>/dev/null; echo $?)" "got: $(cat "$work/pipx.log" 2>/dev/null); output: $out"

rm -f "$work/pipx.log"
printf 'graphifyy 0.9.0\n' > "$work/pipx.list"
out=$(PATH=$(install_path bin-pipx fakebin) "$cli" install graphify 2>&1)
check "pipx present, pipx list shows graphifyy: pipx upgrade" \
  "$(grep -qx 'upgrade graphifyy' "$work/pipx.log" 2>/dev/null; echo $?)" "got: $(cat "$work/pipx.log" 2>/dev/null); output: $out"
rm -f "$work/pipx.list"

rm -f "$work/pipx.log"
printf 'otherpkg 1.0.0\n' > "$work/pipx.list"
out=$(PATH=$(install_path bin-pipx fakebin) "$cli" install graphify 2>&1)
check "pipx present, graphify on PATH but not pipx-managed (e.g. brew): pipx install, not upgrade" \
  "$(grep -qx 'install graphifyy' "$work/pipx.log" 2>/dev/null; echo $?)" "got: $(cat "$work/pipx.log" 2>/dev/null); output: $out"
rm -f "$work/pipx.list"

rm -f "$work/pnpm.log"
out=$(PATH=$(install_path bin-pnpm fakebin) "$cli" install codegraph 2>&1)
check "pnpm present: add -g codegraph@latest" \
  "$(grep -qx 'add -g @colbymchenry/codegraph@latest' "$work/pnpm.log" 2>/dev/null; echo $?)" "got: $(cat "$work/pnpm.log" 2>/dev/null); output: $out"

rm -f "$work/npm.log"
out=$(PATH=$(install_path bin-npm fakebin) "$cli" install codegraph 2>&1)
check "pnpm absent, npm present: install -g codegraph@latest" \
  "$(grep -qx 'install -g @colbymchenry/codegraph@latest' "$work/npm.log" 2>/dev/null; echo $?)" "got: $(cat "$work/npm.log" 2>/dev/null); output: $out"

touch "$work/uv.fail"
PATH=$(install_path bin-uv fakebin) "$cli" install graphify >/dev/null 2>&1
rc=$?
check "a failing installer makes repo-intel install exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc"
rm -f "$work/uv.fail"
echo "bump-version"

bv_plugin() { # extra fields as JSON, defaults to {} -> writes $work/bump/plugin.json
  mkdir -p "$work/bump"
  jq -cn --arg v "$1" --argjson extra "${2:-{\}}" '{name: "repo-intel", version: $v} + $extra' > "$work/bump/plugin.json"
  printf '%s' "$work/bump/plugin.json"
}

pf=$(bv_plugin "0.1.0" '{"description":"d","keywords":["a","b"]}')
out=$("$bump" patch "$pf" 2>&1)
check "patch bump prints the new version" "$([ "$out" = 0.1.1 ]; echo $?)" "got: $out"
jq -e '.version == "0.1.1"' "$pf" >/dev/null 2>&1
check "patch bump writes the new version" $? "got: $(cat "$pf")"
jq -e '.description == "d" and .keywords == ["a","b"] and .name == "repo-intel"' "$pf" >/dev/null 2>&1
check "patch bump leaves other fields untouched" $? "got: $(cat "$pf")"

pf=$(bv_plugin "1.2.3")
"$bump" minor "$pf" >/dev/null 2>&1
jq -e '.version == "1.3.0"' "$pf" >/dev/null 2>&1
check "minor bump resets patch to 0" $? "got: $(cat "$pf")"

pf=$(bv_plugin "1.2.3")
"$bump" major "$pf" >/dev/null 2>&1
jq -e '.version == "2.0.0"' "$pf" >/dev/null 2>&1
check "major bump resets minor and patch to 0" $? "got: $(cat "$pf")"

pf=$(bv_plugin "1.0.0")
"$bump" bogus "$pf" >/dev/null 2>&1
check "invalid bump type fails nonzero" "$([ "$?" != 0 ]; echo $?)" "exit 0"
jq -e '.version == "1.0.0"' "$pf" >/dev/null 2>&1
check "invalid bump type leaves the file untouched" $? "got: $(cat "$pf")"

pf=$(bv_plugin "1.2")
"$bump" patch "$pf" >/dev/null 2>&1
check "non-semver version fails nonzero" "$([ "$?" != 0 ]; echo $?)" "exit 0"
jq -e '.version == "1.2"' "$pf" >/dev/null 2>&1
check "non-semver version leaves the file untouched" $? "got: $(cat "$pf")"

# ---------------------------------------------------------------------------
# build's exit-status contract (fix/build-exit-status). Kept as its own
# section: graph.json presence/validity, the partial-parse count and --strict.
# ---------------------------------------------------------------------------
echo "build exit status"

repo=$(new_repo build-ok)
(cd "$repo" && "$cli" build >/dev/null 2>&1); rc=$?
check "build exits 0 on a normal graphify run" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"

repo=$(new_repo build-fail)
echo 1 > "$work/graphify.exit"
(cd "$repo" && "$cli" build >/dev/null 2>&1); rc=$?
check "graphify exiting nonzero makes build exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc"
rm -f "$work/graphify.exit"

repo=$(new_repo build-nograph)
touch "$work/graphify.no-graph"
(cd "$repo" && "$cli" build >/dev/null 2>&1); rc=$?
check "graphify exits 0 but writes no graph.json: build exits nonzero" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc"
rm -f "$work/graphify.no-graph"

repo=$(new_repo build-badjson)
touch "$work/graphify.bad-json"
(cd "$repo" && "$cli" build >/dev/null 2>&1); rc=$?
check "invalid graph.json makes build exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc"
check "invalid graph.json: no build marker written" "$([ ! -e "$repo/graphify-out/.repo-intel-built" ]; echo $?)" "marker written despite invalid graph.json"
rm -f "$work/graphify.bad-json"

printf 'warning: 3 file(s) had syntax errors and may be partially extracted: A.svelte (first error at line 1, no symbols extracted), B.svelte (first error at line 1, no symbols extracted), C.svelte (first error at line 1, 1 symbol(s) extracted)\n' > "$work/graphify.warn"

repo=$(new_repo build-warn)
res=$(cd "$repo" && "$cli" build 2>&1); rc=$?
check "a partial-parse warning still exits 0 by default" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"
echo "$res" | grep -q 'graphify: 3 file(s) could not be fully parsed'
check "default build prints the partial-parse count" $? "got: $res"

repo=$(new_repo build-warn-strict)
(cd "$repo" && "$cli" build --strict >/dev/null 2>&1); rc=$?
check "--strict fails the build on a partial-parse warning" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc"

rm -f "$work/graphify.warn"

repo=$(new_repo build-flags-a)
(cd "$repo" && "$cli" build --strict --full >/dev/null 2>&1); rc=$?
check "--strict --full is accepted" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"

repo=$(new_repo build-flags-b)
(cd "$repo" && "$cli" build --full --strict >/dev/null 2>&1); rc=$?
check "--full --strict is accepted" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"

repo=$(new_repo build-badflag)
res=$(cd "$repo" && "$cli" build --bogus 2>&1); rc=$?
check "an unknown build flag fails" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc"
echo "$res" | grep -q 'Usage: repo-intel'
check "an unknown build flag prints usage" $? "got: $res"

echo "instructions"

r=$(new_repo instr-cg); mkdir -p "$r/.codegraph"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "info line reports CLAUDE.md added" "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: added'; echo $?)" "got: $out"
check "info line reports AGENTS.md added" "$(echo "$out" | grep -qx 'repo-intel: AGENTS.md: added'; echo $?)" "got: $out"
grep -qF '<!-- repo-intel:begin -->' "$r/CLAUDE.md" && grep -qF '<!-- repo-intel:end -->' "$r/CLAUDE.md"
check "codegraph-only: CLAUDE.md gets the managed block" $? "got: $(cat "$r/CLAUDE.md" 2>/dev/null)"
grep -qF '<!-- repo-intel:begin -->' "$r/AGENTS.md"
check "codegraph-only: AGENTS.md gets the managed block too" $? "got: $(cat "$r/AGENTS.md" 2>/dev/null)"
grep -q 'codegraph_explore' "$r/CLAUDE.md"
check "codegraph-only: codegraph section is present" $? "got: $(cat "$r/CLAUDE.md")"
grep -q 'graphify query' "$r/CLAUDE.md"
check "codegraph-only: graphify section is absent" "$([ $? != 0 ]; echo $?)" "graphify section should not be there"

r=$(new_repo instr-both); mkdir -p "$r/.codegraph" "$r/graphify-out"; echo '{}' > "$r/graphify-out/graph.json"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
grep -q 'codegraph_explore' "$r/CLAUDE.md"
check "both graphs: codegraph section is present" $? "got: $(cat "$r/CLAUDE.md")"
grep -q 'graphify query' "$r/CLAUDE.md"
check "both graphs: graphify section is present" $? "got: $(cat "$r/CLAUDE.md")"

cp "$r/CLAUDE.md" "$work/instr-both-claude-before"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "rerun with no change in graph presence reports unchanged" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: unchanged' && echo "$out" | grep -qx 'repo-intel: AGENTS.md: unchanged'; echo $?)" "got: $out"
cmp -s "$r/CLAUDE.md" "$work/instr-both-claude-before"
check "rerun with no change leaves file content identical" $? "content changed"

r=$(new_repo instr-update); mkdir -p "$r/.codegraph"
printf 'BEFORE line\n' > "$r/CLAUDE.md"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
printf '%s\nAFTER line\n' "$(cat "$r/CLAUDE.md")" > "$r/CLAUDE.md"
mkdir -p "$r/graphify-out"; echo '{}' > "$r/graphify-out/graph.json"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "adding a second graph updates the block" "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: updated'; echo $?)" "got: $out"
grep -qxF 'BEFORE line' "$r/CLAUDE.md"
check "update preserves content before the block" $? "got: $(cat "$r/CLAUDE.md")"
grep -qxF 'AFTER line' "$r/CLAUDE.md"
check "update preserves content after the block" $? "got: $(cat "$r/CLAUDE.md")"
grep -q 'graphify query' "$r/CLAUDE.md"
check "update adds the newly available graphify section" $? "got: $(cat "$r/CLAUDE.md")"

r=$(new_repo instr-nograph)
out=$(cd "$r" && "$cli" instructions 2>&1)
check "no graph: nothing created, info says no graph found" \
  "$([ ! -e "$r/CLAUDE.md" ] && [ ! -e "$r/AGENTS.md" ] && echo "$out" | grep -qx 'repo-intel: CLAUDE.md: no graph found'; echo $?)" "got: $out; CLAUDE.md exists: $([ -e "$r/CLAUDE.md" ] && echo yes || echo no)"

r=$(new_repo instr-symlink); mkdir -p "$r/.codegraph"
printf 'shared notes\n' > "$r/AGENTS.md"
ln -s AGENTS.md "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "symlinked CLAUDE.md -> AGENTS.md: one shared info line" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md, AGENTS.md (same file): added'; echo $?)" "got: $out"
check "symlinked CLAUDE.md -> AGENTS.md: CLAUDE.md stays a symlink" "$([ -L "$r/CLAUDE.md" ]; echo $?)" "symlink replaced by a regular file"
grep -qF 'shared notes' "$r/AGENTS.md" && grep -qF '<!-- repo-intel:begin -->' "$r/AGENTS.md"
check "symlinked CLAUDE.md -> AGENTS.md: the shared file has both the old content and the block" $? "got: $(cat "$r/AGENTS.md")"

r=$(new_repo instr-remove); mkdir -p "$r/.codegraph"
printf 'My own CLAUDE.md notes.\n\nSecond paragraph.\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$work/instr-remove-orig"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
out=$(cd "$r" && "$cli" instructions --remove 2>&1)
check "--remove reports removed" "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: removed'; echo $?)" "got: $out"
cmp -s "$r/CLAUDE.md" "$work/instr-remove-orig"
check "--remove restores the original content exactly" $? "got: $(cat "$r/CLAUDE.md")"
check "--remove never deletes AGENTS.md itself" "$([ -e "$r/AGENTS.md" ]; echo $?)" "AGENTS.md is gone"

r=$(new_repo instr-remove-untouched)
printf 'nothing to remove here\n' > "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions --remove 2>&1)
check "--remove on a file with no block leaves it untouched" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: unchanged' && grep -qxF 'nothing to remove here' "$r/CLAUDE.md"; echo $?)" "got: $out"

r=$(new_repo instr-setup)
out=$(cd "$r" && "$cli" setup 2>&1); rc=$?
check "setup runs install, build and instructions in order without failing" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qF '<!-- repo-intel:begin -->' "$r/CLAUDE.md" 2>/dev/null
check "setup writes the managed block into CLAUDE.md" $? "got: $(cat "$r/CLAUDE.md" 2>/dev/null)"
grep -qF '<!-- repo-intel:begin -->' "$r/AGENTS.md" 2>/dev/null
check "setup writes the managed block into AGENTS.md" $? "got: $(cat "$r/AGENTS.md" 2>/dev/null)"

rsetup=$(new_repo instr-doctor)
out=$(cd "$rsetup" && "$cli" doctor 2>&1)
echo "$out" | grep -qE '^  instructions +n/a \(no graph yet\)$'
check "doctor reports instructions n/a when there is no graph at all" $? "got: $out"
mkdir -p "$rsetup/.codegraph"
out=$(cd "$rsetup" && "$cli" doctor 2>&1)
echo "$out" | grep -qE '^  instructions +missing \(run: repo-intel instructions\)$'
check "doctor reports instructions missing once a graph exists but the block does not" $? "got: $out"
(cd "$rsetup" && "$cli" instructions >/dev/null 2>&1)
out=$(cd "$rsetup" && "$cli" doctor 2>&1)
echo "$out" | grep -qE '^  instructions +present$'
check "doctor reports instructions present after they are written" $? "got: $out"
check "doctor's exit status is unaffected by the instructions line" "$(cd "$rsetup" && "$cli" doctor >/dev/null 2>&1; echo $?)" ""

echo "instructions: CRLF files"

r=$(new_repo instr-crlf); mkdir -p "$r/.codegraph"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
awk '{printf "%s\r\n", $0}' "$r/CLAUDE.md" > "$r/CLAUDE.md.crlf" && mv "$r/CLAUDE.md.crlf" "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "a CRLF-converted file: rerun recognises the existing block instead of duplicating it" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: unchanged'; echo $?)" "got: $out"
begins=$(grep -cF '<!-- repo-intel:begin -->' "$r/CLAUDE.md")
check "a CRLF-converted file: still has exactly one begin marker" "$([ "$begins" = 1 ]; echo $?)" "got $begins begin markers"

r=$(new_repo instr-crlf-update); mkdir -p "$r/.codegraph"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
awk '{printf "%s\r\n", $0}' "$r/CLAUDE.md" > "$r/CLAUDE.md.crlf" && mv "$r/CLAUDE.md.crlf" "$r/CLAUDE.md"
mkdir -p "$r/graphify-out"; echo '{}' > "$r/graphify-out/graph.json"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "a CRLF-converted file: adding a second graph updates, not duplicates, the block" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: updated'; echo $?)" "got: $out"
begins=$(grep -cF '<!-- repo-intel:begin -->' "$r/CLAUDE.md")
check "a CRLF-converted file: update still leaves exactly one begin marker" "$([ "$begins" = 1 ]; echo $?)" "got $begins begin markers"
line=$(grep -F 'Refresh when stale' "$r/CLAUDE.md")
check "a CRLF-converted file: the rewritten block keeps CRLF line endings" "$([[ $line == *$'\r' ]]; echo $?)" "got line without trailing CR: $(printf '%s' "$line" | od -c | head -3)"

echo "instructions: --remove symmetry"

r=$(new_repo instr-sep-blank); mkdir -p "$r/.codegraph"
printf 'a\n\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$work/instr-sep-blank.orig"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
(cd "$r" && "$cli" instructions --remove >/dev/null 2>&1)
cmp -s "$r/CLAUDE.md" "$work/instr-sep-blank.orig"
check "remove exactly restores a file that already ended in a blank line (a\\n\\n)" $? \
  "got: $(cat -A "$r/CLAUDE.md" 2>/dev/null); want: $(cat -A "$work/instr-sep-blank.orig" 2>/dev/null)"

r=$(new_repo instr-sep-single); mkdir -p "$r/.codegraph"
printf 'a\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$work/instr-sep-single.orig"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
(cd "$r" && "$cli" instructions --remove >/dev/null 2>&1)
cmp -s "$r/CLAUDE.md" "$work/instr-sep-single.orig"
check "remove exactly restores a file with a single trailing newline (a\\n)" $? \
  "got: $(cat -A "$r/CLAUDE.md" 2>/dev/null); want: $(cat -A "$work/instr-sep-single.orig" 2>/dev/null)"

r=$(new_repo instr-sep-none); mkdir -p "$r/.codegraph"
printf 'a' > "$r/CLAUDE.md"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
(cd "$r" && "$cli" instructions --remove >/dev/null 2>&1)
printf 'a\n' > "$work/instr-sep-none.want"
cmp -s "$r/CLAUDE.md" "$work/instr-sep-none.want"
check "remove on a file with no trailing newline restores it with one newline added (documented, accepted loss)" $? \
  "got: $(cat -A "$r/CLAUDE.md" 2>/dev/null)"

echo "instructions: validate before writing"

r=$(new_repo instr-unreadable); mkdir -p "$r/.codegraph"
printf 'keep me\n' > "$r/CLAUDE.md"
chmod 200 "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
chmod 644 "$r/CLAUDE.md" 2>/dev/null
check "unreadable CLAUDE.md: instructions dies instead of overwriting it" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qxF 'keep me' "$r/CLAUDE.md"
check "unreadable CLAUDE.md: original content is not lost" $? "got: $(cat "$r/CLAUDE.md" 2>/dev/null)"
check "unreadable CLAUDE.md: AGENTS.md is not written either (both validated before either is written)" \
  "$([ ! -e "$r/AGENTS.md" ]; echo $?)" "AGENTS.md exists: $(cat "$r/AGENTS.md" 2>/dev/null)"

r=$(new_repo instr-fenced); mkdir -p "$r/.codegraph"
cat > "$r/CLAUDE.md" <<'MARKDOWN'
# Notes

Example of the managed block:

```
<!-- repo-intel:begin -->
fake example, do not touch
<!-- repo-intel:end -->
```

End of notes.
MARKDOWN
out=$(cd "$r" && "$cli" instructions 2>&1)
check "a fenced example block: instructions adds a real block, not fooled by the fenced one" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: added'; echo $?)" "got: $out"
begins=$(grep -cF '<!-- repo-intel:begin -->' "$r/CLAUDE.md")
check "a fenced example block: now has two begin markers total (the example, and the real one)" \
  "$([ "$begins" = 2 ]; echo $?)" "got $begins"
grep -qxF 'fake example, do not touch' "$r/CLAUDE.md"
check "a fenced example block: the example inside the fence is preserved untouched" $? "got: $(cat "$r/CLAUDE.md")"

r=$(new_repo instr-nul); mkdir -p "$r/.codegraph"
printf 'before\x00after\n' > "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "a file with an embedded NUL byte: instructions still adds the block" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: added'; echo $?)" "got: $out"
head -n1 "$r/CLAUDE.md" > "$work/instr-nul-got.bin"
printf 'before\x00after\n' > "$work/instr-nul-want.bin"
cmp -s "$work/instr-nul-got.bin" "$work/instr-nul-want.bin"
check "a file with an embedded NUL byte: the NUL-containing line survives byte for byte" $? \
  "got: $(od -c "$work/instr-nul-got.bin" 2>/dev/null | head -2)"

r=$(new_repo instr-symlink-outside); mkdir -p "$r/.codegraph"
printf 'outside content\n' > "$work/instr-outside-target.md"
ln -s "$work/instr-outside-target.md" "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "CLAUDE.md symlinked outside the repo: instructions dies instead of writing through it" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qxF 'outside content' "$work/instr-outside-target.md"
check "CLAUDE.md symlinked outside the repo: the external target is untouched" $? \
  "got: $(cat "$work/instr-outside-target.md" 2>/dev/null)"

r=$(new_repo instr-symlink-dangling-outside); mkdir -p "$r/.codegraph"
ln -s ../outside-dangling.md "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "CLAUDE.md as a dangling symlink pointing outside the repo: instructions dies" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
check "CLAUDE.md as a dangling symlink pointing outside the repo: nothing gets created at the target" \
  "$([ ! -e "$work/repos/outside-dangling.md" ]; echo $?)" "target was created"

r=$(new_repo instr-dup-begin); mkdir -p "$r/.codegraph"
printf '<!-- repo-intel:begin -->\nA\n<!-- repo-intel:end -->\n<!-- repo-intel:begin -->\nB\n<!-- repo-intel:end -->\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$work/instr-dup-begin.orig"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "two begin/end pairs outside any fence: instructions dies naming the file" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
echo "$out" | grep -q 'CLAUDE.md'
check "the die message names the file" $? "got: $out"
cmp -s "$r/CLAUDE.md" "$work/instr-dup-begin.orig"
check "two begin/end pairs: the file is left untouched" $? "got: $(cat "$r/CLAUDE.md")"

r=$(new_repo instr-trailing-ws); mkdir -p "$r/.codegraph"
printf '<!-- repo-intel:begin -->   \n## x\n<!-- repo-intel:end -->\t\n' > "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1)
check "a marker with trailing spaces/tabs: still recognised, file updated in place not duplicated" \
  "$(echo "$out" | grep -qx 'repo-intel: CLAUDE.md: updated'; echo $?)" "got: $out"
begins=$(grep -cF '<!-- repo-intel:begin -->' "$r/CLAUDE.md")
check "a marker with trailing spaces/tabs: exactly one begin marker after the update" "$([ "$begins" = 1 ]; echo $?)" "got $begins"

r=$(new_repo instr-doctor-invalid); mkdir -p "$r/.codegraph"
printf '<!-- repo-intel:begin -->\nA\n<!-- repo-intel:end -->\n<!-- repo-intel:begin -->\nB\n<!-- repo-intel:end -->\n' > "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" doctor 2>&1); rc=$?
echo "$out" | grep -qE '^  instructions +invalid \('
check "doctor reports invalid for a malformed block instead of present" $? "got: $out"
check "doctor's exit status is unaffected by a malformed block" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"

r=$(new_repo instr-remove-bogus); mkdir -p "$r/.codegraph"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
out=$(cd "$r" && "$cli" instructions --remove --bogus 2>&1); rc=$?
check "instructions --remove --bogus dies on the unknown option" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qF '<!-- repo-intel:begin -->' "$r/CLAUDE.md"
check "instructions --remove --bogus: the block is not removed" $? "got: $(cat "$r/CLAUDE.md" 2>/dev/null)"

echo "instructions: symlink escape (round 2)"

r=$(new_repo instr-escape-absdotdot); mkdir -p "$r/.codegraph"
ln -s "$(realpath "$r")/../instr-escape-absdotdot-outside.md" "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "an absolute dangling symlink target containing .. is refused" "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
check "an absolute dangling symlink target containing ..: nothing gets created at it" \
  "$([ ! -e "$work/repos/instr-escape-absdotdot-outside.md" ]; echo $?)" "target was created"

r=$(new_repo instr-escape-chain); mkdir -p "$r/.codegraph"
ln -s middle.md "$r/CLAUDE.md"
ln -s "$work/instr-escape-chain-missing-external.md" "$r/middle.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "a dangling symlink chain (CLAUDE.md -> middle.md -> missing external file) is refused" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
check "a dangling symlink chain: nothing gets created at the far end, and middle.md itself is untouched" \
  "$([ ! -e "$work/instr-escape-chain-missing-external.md" ] && [ -L "$r/middle.md" ]; echo $?)" \
  "far end exists: $([ -e "$work/instr-escape-chain-missing-external.md" ] && echo yes || echo no); middle.md is a symlink: $([ -L "$r/middle.md" ] && echo yes || echo no)"

r=$(new_repo instr-escape-symlinked-dir); mkdir -p "$r/.codegraph"
printf 'leaked\n' > "$work/instr-escape-symlinked-dir-target.md"
ln -s "$work" "$r/through"
ln -s through/../instr-escape-symlinked-dir-target.md "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "a relative dangling-looking link through a symlinked directory, resolving outside the repo, is refused" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qxF 'leaked' "$work/instr-escape-symlinked-dir-target.md"
check "symlinked-directory escape: the external target is untouched" $? \
  "got: $(cat "$work/instr-escape-symlinked-dir-target.md" 2>/dev/null)"

r=$(new_repo instr-escape-inrepo-still-works); mkdir -p "$r/.codegraph" "$r/sub"
printf 'hi\n' > "$r/sub/real.md"
ln -s sub "$r/through"
ln -s through/../sub/real.md "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "a symlink through a symlinked directory that stays inside the repo still works" \
  "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qF '<!-- repo-intel:begin -->' "$r/sub/real.md"
check "...and the real target actually received the block" $? "got: $(cat "$r/sub/real.md" 2>/dev/null)"

r=$(new_repo instr-escape-doctor-dangling); mkdir -p "$r/.codegraph"
ln -s nonexistent-target.md "$r/CLAUDE.md"
out=$(cd "$r" && "$cli" doctor 2>&1); rc=$?
echo "$out" | grep -qE '^  instructions +invalid \(dangling symlink\)$'
check "doctor reports invalid (dangling symlink) rather than present or missing" $? "got: $out"
check "doctor's exit status is unaffected by a dangling symlink" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"

echo "instructions: unterminated code fence"

r=$(new_repo instr-unterminated-fence); mkdir -p "$r/.codegraph"
printf 'Notes\n\n```\nunclosed fence, no closing backticks below\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$work/instr-unterminated-fence.orig"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "a file ending inside an open fence: instructions dies instead of appending inside it" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
echo "$out" | grep -q 'unterminated code fence'
check "the die message names the problem" $? "got: $out"
cmp -s "$r/CLAUDE.md" "$work/instr-unterminated-fence.orig"
check "an unterminated fence: the file is left untouched" $? "got: $(cat "$r/CLAUDE.md")"
out=$(cd "$r" && "$cli" doctor 2>&1)
echo "$out" | grep -qE '^  instructions +invalid \('
check "doctor reports invalid for an unterminated fence" $? "got: $out"

echo "instructions: atomic write"

# A fake `cat` that fails only when asked to read FROM a temp file (matched
# by basename, never by the full path: the test's own $work dir is itself
# under a mktemp'd directory, so a path-wide match would misfire on every
# real file too). This is exactly the shape of the old bug: `cat "$tmp" >
# "$file"` reads the temp to write the real file; a tool that behaves fine on
# every other read but fails on that one specific read is what "a failing
# copy" means here. Real reads (of CLAUDE.md, of the repo's other files)
# still go through to the real cat.
mkdir -p "$work/failcat"
cat > "$work/failcat/cat" <<'FAKECAT'
#!/bin/sh
for a in "$@"; do
  case "$(basename "$a" 2>/dev/null)" in
    tmp.*|.repo-intel-instructions.*) exit 1 ;;
  esac
done
exec /bin/cat "$@"
FAKECAT
chmod +x "$work/failcat/cat"

r=$(new_repo instr-atomic-failure); mkdir -p "$r/.codegraph"
printf 'ORIGINAL CONTENT, MUST SURVIVE A FAILED WRITE\n' > "$r/CLAUDE.md"
out=$(cd "$r" && PATH="$work/failcat:$PATH" "$cli" instructions 2>&1); rc=$?
check "a failing read of the temp file never leaves CLAUDE.md truncated to empty" \
  "$([ -s "$r/CLAUDE.md" ]; echo $?)" "exit code was $rc; output: $out; got $(wc -c < "$r/CLAUDE.md" 2>/dev/null) bytes"
leftover=$(find "$r" -maxdepth 1 -name '.repo-intel-instructions.*' 2>/dev/null)
check "a failing read of the temp file: no stray temp file is left behind" "$([ -z "$leftover" ]; echo $?)" "found: $leftover"

# This one uses an update (a block already present, a second graph appears),
# not an add: that is the path where sed actually copies real content ranges
# into the candidate, rather than just an optional CRLF probe that fails
# open and harmlessly falls back to "no CRLF" without aborting anything.
r=$(new_repo instr-atomic-build-failure); mkdir -p "$r/.codegraph"
printf 'ORIGINAL CONTENT, MUST SURVIVE A FAILED BUILD\n' > "$r/CLAUDE.md"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
cp "$r/CLAUDE.md" "$work/instr-atomic-build-failure.orig"
mkdir -p "$r/graphify-out"; echo '{}' > "$r/graphify-out/graph.json"
mkdir -p "$work/failsed"
cat > "$work/failsed/sed" <<'FAKESED'
#!/bin/sh
exit 1
FAKESED
chmod +x "$work/failsed/sed"
out=$(cd "$r" && PATH="$work/failsed:$PATH" "$cli" instructions 2>&1); rc=$?
check "a failing tool while building the candidate makes instructions exit nonzero" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
cmp -s "$r/CLAUDE.md" "$work/instr-atomic-build-failure.orig"
check "a failing tool while building the candidate: the original (pre-update) file is byte-for-byte untouched" $? \
  "got: $(cat "$r/CLAUDE.md" 2>/dev/null)"

r=$(new_repo instr-atomic-mode); mkdir -p "$r/.codegraph"
printf 'notes\n' > "$r/CLAUDE.md"
chmod 640 "$r/CLAUDE.md"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
mode1=$(/bin/ls -l "$r/CLAUDE.md" | awk '{print $1}')
mkdir -p "$r/graphify-out"; echo '{}' > "$r/graphify-out/graph.json"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
mode2=$(/bin/ls -l "$r/CLAUDE.md" | awk '{print $1}')
check "file mode (640) is preserved across add" "$([ "$mode1" = "-rw-r-----@" ] || [ "$mode1" = "-rw-r-----" ]; echo $?)" "got: $mode1"
check "file mode (640) is preserved across update" "$([ "$mode2" = "-rw-r-----@" ] || [ "$mode2" = "-rw-r-----" ]; echo $?)" "got: $mode2"

r=$(new_repo instr-atomic-symlink); mkdir -p "$r/.codegraph"
printf 'shared\n' > "$r/AGENTS.md"
ln -s AGENTS.md "$r/CLAUDE.md"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
mkdir -p "$r/graphify-out"; echo '{}' > "$r/graphify-out/graph.json"
(cd "$r" && "$cli" instructions >/dev/null 2>&1)
check "CLAUDE.md stays a symlink after an atomic update through it" "$([ -L "$r/CLAUDE.md" ]; echo $?)" "symlink replaced"
grep -q 'graphify query' "$r/AGENTS.md"
check "...and the update actually landed on the real file" $? "got: $(cat "$r/AGENTS.md" 2>/dev/null)"

echo "instructions: mode seeding, umask, hardlinks"

mkdir -p "$work/failcp"
cat > "$work/failcp/cp" <<'FAKECP'
#!/bin/sh
exit 1
FAKECP
chmod +x "$work/failcp/cp"

r=$(new_repo instr-failcp); mkdir -p "$r/.codegraph"
printf 'ORIGINAL CONTENT, MUST SURVIVE A FAILED MODE COPY\n' > "$r/CLAUDE.md"
chmod 644 "$r/CLAUDE.md"
out=$(cd "$r" && PATH="$work/failcp:$PATH" "$cli" instructions 2>&1); rc=$?
check "a failing cp while seeding the temp file's mode makes instructions exit nonzero" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
grep -qxF 'ORIGINAL CONTENT, MUST SURVIVE A FAILED MODE COPY' "$r/CLAUDE.md"
check "a failing cp while seeding the mode: the original content is untouched" $? \
  "got: $(cat "$r/CLAUDE.md" 2>/dev/null)"
find "$r/CLAUDE.md" -perm 644 | grep -q .
check "a failing cp while seeding the mode: the original mode (644) is untouched, not silently dropped to 600" \
  $? "got: $(/bin/ls -l "$r/CLAUDE.md" 2>/dev/null)"
leftover=$(find "$r" -maxdepth 1 -name '.repo-intel-instructions.*' 2>/dev/null)
check "a failing cp while seeding the mode: no stray temp file is left behind" "$([ -z "$leftover" ]; echo $?)" "found: $leftover"

r=$(new_repo instr-umask-restrictive); mkdir -p "$r/.codegraph"
(cd "$r" && umask 077 && "$cli" instructions >/dev/null 2>&1)
find "$r/CLAUDE.md" -perm 600 | grep -q .
check "a brand new CLAUDE.md respects a restrictive umask (077 -> 600)" $? "got: $(/bin/ls -l "$r/CLAUDE.md" 2>/dev/null)"

r=$(new_repo instr-umask-default); mkdir -p "$r/.codegraph"
(cd "$r" && umask 022 && "$cli" instructions >/dev/null 2>&1)
find "$r/CLAUDE.md" -perm 644 | grep -q .
check "a brand new CLAUDE.md respects the default umask (022 -> 644)" $? "got: $(/bin/ls -l "$r/CLAUDE.md" 2>/dev/null)"

r=$(new_repo instr-umask-group-writable); mkdir -p "$r/.codegraph"
(cd "$r" && umask 002 && "$cli" instructions >/dev/null 2>&1)
find "$r/CLAUDE.md" -perm 664 | grep -q .
check "a brand new CLAUDE.md respects a group-writable umask (002 -> 664)" $? "got: $(/bin/ls -l "$r/CLAUDE.md" 2>/dev/null)"

r=$(new_repo instr-hardlinked); mkdir -p "$r/.codegraph"
printf 'shared content\n' > "$r/CLAUDE.md"
ln "$r/CLAUDE.md" "$r/AGENTS.md"
# A third hardlink outside the repo, as a witness to the ORIGINAL inode: if
# CLAUDE.md got replaced by something that happens to match AGENTS.md (e.g.
# both un-shared the same way), comparing only CLAUDE.md to AGENTS.md
# afterwards would miss that; this witness would not match either.
ln "$r/CLAUDE.md" "$work/instr-hardlinked-witness"
out=$(cd "$r" && "$cli" instructions 2>&1); rc=$?
check "a hardlinked CLAUDE.md/AGENTS.md pair: instructions dies instead of un-sharing them" \
  "$([ "$rc" -ne 0 ]; echo $?)" "exit code was $rc; output: $out"
echo "$out" | grep -q 'CLAUDE.md'
check "the die message names the hardlinked file" $? "got: $out"
grep -qxF 'shared content' "$r/CLAUDE.md" && grep -qxF 'shared content' "$r/AGENTS.md"
check "a hardlinked pair: both files are left with their original content" $? \
  "CLAUDE.md: $(cat "$r/CLAUDE.md" 2>/dev/null); AGENTS.md: $(cat "$r/AGENTS.md" 2>/dev/null)"
find "$r/CLAUDE.md" -samefile "$r/AGENTS.md" | grep -q . && find "$r/CLAUDE.md" -samefile "$work/instr-hardlinked-witness" | grep -q .
check "a hardlinked pair: the inode is still shared (unchanged from before the attempt)" $? \
  "CLAUDE.md and AGENTS.md no longer share an inode, or neither matches the original"

r=$(new_repo instr-hardlinked-doctor); mkdir -p "$r/.codegraph"
printf 'shared\n' > "$r/CLAUDE.md"
ln "$r/CLAUDE.md" "$r/AGENTS.md"
out=$(cd "$r" && "$cli" doctor 2>&1); rc=$?
echo "$out" | grep -qE '^  instructions +invalid \(hardlinked file\)$'
check "doctor reports invalid (hardlinked file) for a hardlinked pair" $? "got: $out"
check "doctor's exit status is unaffected by a hardlinked pair" "$([ "$rc" = 0 ]; echo $?)" "exit code was $rc"

echo "graphify contract (real binary)"
real_graphify=$(PATH=$orig_path command -v graphify 2>/dev/null || true)
if [ -z "$real_graphify" ]; then
  echo "  skip  real graphify not on PATH; skipping stderr-wording contract test"
else
  sv=$(new_repo svelte-contract)
  /bin/cat > "$sv/Bad.svelte" <<'SVELTE'
<script>
  let x = {
</script>
SVELTE
  res=$(cd "$sv" && PATH=$orig_path "$real_graphify" extract . --code-only 2>&1 1>/dev/null)
  # Mirrors partial_parse_pattern in bin/repo-intel; catches upstream wording drift.
  echo "$res" | grep -Eq '[0-9]+ file\(s\) had syntax errors'
  check "real graphify's stderr still matches the partial-parse count wording" $? "got: $res"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
