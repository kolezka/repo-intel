#!/bin/sh
# SessionStart: keep ${CLAUDE_CONFIG_DIR:-~/.claude}/repo-intel/CLAUDE.md pointed at this
# plugin version after an update. Only repoints a link `repo-intel install claude-md`
# already made; never creates one, never touches a regular file. Silent, always exits 0.

[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0
link="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/repo-intel/CLAUDE.md"
[ -L "$link" ] || exit 0
# Physical path, the same form the CLI writes, so the two never flip the link back and forth.
root=$(cd "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P) || exit 0
target="$root/claude/CLAUDE.md"
[ -f "$target" ] || exit 0
[ "$(readlink "$link" 2>/dev/null)" = "$target" ] && exit 0
ln -sfn "$target" "$link" >/dev/null 2>&1
exit 0
