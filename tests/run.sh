#!/usr/bin/env bash
# Behaviour tests for the hook script and the repo-intel CLI.
# Real graphify/codegraph are replaced by fakes that log their arguments.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
hook="$here/hooks/repo-intel-hook.sh"
cli="$here/bin/repo-intel"
pass=0 fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" CLAUDE_CONFIG_DIR="$work/home/.claude" TMPDIR="$work/tmp"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$TMPDIR" "$work/fakebin"
unset REPO_INTEL_BACKEND REPO_INTEL_MODEL

for tool in graphify codegraph; do
  cat > "$work/fakebin/$tool" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$work/$tool.log"
[ "\$1" = prompt-hook ] && printf '<codegraph_context>fake</codegraph_context>\n'
exit 0
EOF
  chmod +x "$work/fakebin/$tool"
done
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
