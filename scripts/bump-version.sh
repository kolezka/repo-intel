#!/usr/bin/env bash
# bump-version: read the semver in plugin.json, bump it, write it back.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bump-version.sh <patch|minor|major> [plugin.json path]

  Reads "version" from plugin.json (default: .claude-plugin/plugin.json at
  the repo root), bumps it and writes the result back with the same
  formatting. Prints the new version on stdout.
EOF
}

die() { printf 'bump-version: %s\n' "$*" >&2; exit 1; }

[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || die "missing bump type (patch|minor|major)"

bump=$1
root=$(cd "$(dirname "$0")/.." && pwd)
file=${2:-$root/.claude-plugin/plugin.json}

case $bump in
  patch|minor|major) ;;
  *) die "bump type must be patch, minor or major (got: $bump)" ;;
esac

[[ -f $file ]] || die "no such file: $file"
command -v jq >/dev/null 2>&1 || die "jq is required"

current=$(jq -r '.version // empty' "$file") || die "$file is not valid JSON"
[[ -n $current ]] || die "$file has no .version"
[[ $current =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "$file version is not X.Y.Z: $current"
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

case $bump in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac
next="$major.$minor.$patch"

jq --indent 2 --arg v "$next" '.version = $v' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
printf '%s\n' "$next"
