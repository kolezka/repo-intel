# repo-intel

Claude Code plugin that installs [codegraph](https://www.npmjs.com/package/@colbymchenry/codegraph)
and [graphify](https://github.com/safishamsi/graphify) in a repository, keeps both graphs
fresh, and routes the agent to the right one. graphify's semantic extraction runs on an
LLM backend you choose (LiteLLM, Ollama, any OpenAI- or Anthropic-compatible endpoint)
instead of Claude Code subagents.

## Install

```text
/plugin marketplace add kolezka/marketplace
/plugin install repo-intel@kolezka
/reload-plugins
```

Then, in the repository: `/repo-intel:setup`, or by hand:

```bash
repo-intel doctor
repo-intel install                       # install or upgrade to latest: graphify via uv/pipx, codegraph via pnpm/npm,
                                         # and import this plugin's CLAUDE.md from the global one
repo-intel config --backend litellm --model deepseek/deepseek-v4-flash
repo-intel setup                         # index, .gitignore, graphify git hooks, first build
repo-intel instructions                  # CLAUDE.md/AGENTS.md note so agents without this plugin use the graphs too
repo-intel migrate-hooks                 # dry run: old global hooks this plugin replaces
```

Requirements: `git`, `jq`, and `uv`/`pipx` plus `pnpm`/`npm` for the installs.

## What the agent gets

Routing lives in [`claude/CLAUDE.md`](claude/CLAUDE.md): codegraph for structure, graphify
for concepts, rg for literal text and complete call-site lists. `repo-intel install` (or
`repo-intel install claude-md` alone) links `${CLAUDE_CONFIG_DIR:-~/.claude}/repo-intel/CLAUDE.md`
to the installed plugin's copy and adds a managed block to
`${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md` that imports that link with `@<path>`. Re-running
replaces the block in place, backs up the file first, and edits through a symlink. A block
written by an older version, importing a versioned cache path, is rewritten to the link. If
a regular file sits where the link goes, `install` stops and changes nothing.

The link path has no version in it, so the import survives plugin updates. A SessionStart
hook repoints an existing link at the new version; it never creates one. Claude Code loads
memory before SessionStart hooks run, so the first session after an update may still read
the previous version's file (or nothing, if that directory is gone), and the next one reads
the new one. `repo-intel doctor` reports the link (ok, dangling, points elsewhere, or a
regular file) and whether the block imports it.

`repo-intel doctor` also reports a graphify graph as stale when docs changed since the
last `repo-intel build` (graphify's own git hook keeps code current).

Besides that link hook, there is a guard on PreToolUse Skill, Agent and Task. With a backend configured
it denies `/graphify` builds and graphify extraction subagents (also in a repo with no
graph yet) and points to `repo-intel build`. `/graphify query`, `path` and `explain` stay
allowed. `repo-intel config --backend agent` turns the guard off. It costs one `sh` and
one `jq` call for unrelated tools. There are no per-prompt or per-search hooks.

The global import covers your own sessions in every repo. The per-repo block below covers
everyone else. Where both exist, the agent sees the same advice twice, which is harmless.

`repo-intel instructions` writes a short "Code graphs" block into `AGENTS.md`
at the repo root, so an agent without this plugin (Codex, Cursor, a teammate's
Claude Code) still knows to use codegraph and graphify instead of grepping blind.
`CLAUDE.md` gets only an `@AGENTS.md` import, so the note is not repeated; if
`CLAUDE.md` already imports `AGENTS.md` itself, it gets no block at all. Each block
sits between `<!-- repo-intel:begin -->` and `<!-- repo-intel:end -->` markers;
everything else in both files is left alone, and running it again only rewrites a
block if it changed. A `CLAUDE.md` still holding the full note from an older
version gets the import in its place. If the two files are symlinked to each
other, it writes the full note into the shared file once and keeps the symlink.
`repo-intel setup` runs this step automatically after the first build.
`repo-intel instructions --remove` deletes the block (never the file).

Add puts exactly one blank line before the block and `--remove` takes exactly one
out, so the two undo each other. Two cases do not round-trip: a file with no final
newline gets one, and a hand-written blank line right before a hand-written block
is removed with it.

`instructions` writes nothing and exits nonzero on a file it cannot edit safely:
unreadable or unwritable, hardlinked, a dangling symlink, a symlink leaving the
repo, an unterminated code fence, or missing or duplicate markers. Markers inside
code fences are ignored. Writes are atomic and keep the file's mode.

Skills: `/repo-intel:setup`, `/repo-intel:build`, `/repo-intel:route` (which tool answers which question).

## LLM backend

`repo-intel build` calls `graphify extract --backend <backend> [--model <model>]`.
If the repo tracks any `.svelte` files, `build` first adds `*.svelte` to `.graphifyignore`
(graphify cannot parse Svelte; codegraph already covers it).

| Backend | Notes |
|---|---|
| a graphify provider, e.g. `litellm` | Defined with `graphify provider add`; its API key comes from the variable the provider names |
| `ollama` | Local; the build runs one chunk at a time. `--base-url` sets `OLLAMA_HOST` |
| `openai` | With `--base-url` it reaches llama.cpp, vLLM, LM Studio or a LiteLLM proxy |
| `claude` | With `--base-url` it reaches an Anthropic-compatible gateway |
| `gemini`, `deepseek`, `kimi` | graphify's built-in clients |
| `code-only` | No LLM; code structure only. Also what `build` does when nothing is configured |
| `agent` | Build with the current agent CLI: its subagents run `/graphify`, `build` indexes code only |

Config lives in `.repo-intel.json` at the repo root (commit it to share the choice) or in
`~/.config/repo-intel/config.json` with `--global`. `REPO_INTEL_BACKEND` and
`REPO_INTEL_MODEL` override both. Backend, model and URL always come from the same
source, so a repo backend never picks up the user config's model. The file holds names
and URLs only; keys stay in the environment. `--base-url` applies to `openai`, `claude`
and `ollama`; a graphify provider keeps its URL in `~/.graphify/providers.json`.

codegraph has no LLM step: it indexes with tree-sitter, so there is nothing to route.

`repo-intel build` fails (nonzero) if graphify exits nonzero, or exits 0 but leaves no
valid `graphify-out/graph.json`. It still exits 0 when some files failed to parse,
printing a count; pass `--strict` to fail the build in that case instead.

## Replacing the old global hooks

If `~/.claude/settings.json` already runs `graphify hook-guard` (PreToolUse on every Bash,
Grep, Read and Glob) or `codegraph prompt-hook` (every prompt), both fire next to this
plugin. `repo-intel migrate-hooks --apply` removes exactly those entries (bare, `npx`,
`uvx` or absolute-path forms), keeps a timestamped backup and prints the undo command.
A symlinked `settings.json` is edited through the link, so a dotfiles setup stays intact.
`hook-guard read` is dropped rather than replaced; the routing note in `claude/CLAUDE.md` covers searches.

## Tests

```bash
bash tests/run.sh
```

The tests use fake `graphify` and `codegraph` binaries and a temporary `HOME`; they never
touch your real settings or call an LLM.

## Releasing

Version bumps are manual, via GitHub Actions: open the **Actions** tab, pick the
**Release** workflow, click **Run workflow**, and choose `patch`, `minor` or `major`.
The workflow runs the tests, bumps `.claude-plugin/plugin.json`, commits, tags and
pushes, then creates a GitHub release. It only runs on `main`.

If `main` requires pull requests (branch protection), the workflow's push as
`github-actions[bot]` will be rejected. Either add a bypass rule for that actor on
the branch protection ruleset, or swap `GITHUB_TOKEN` for a PAT or GitHub App token
with permission to push directly.
