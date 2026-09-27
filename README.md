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
repo-intel install                       # install or upgrade to latest: graphify via uv/pipx, codegraph via pnpm/npm
repo-intel config --backend litellm --model deepseek/deepseek-v4-flash
repo-intel setup                         # index, .gitignore, graphify git hooks, first build
repo-intel migrate-hooks                 # dry run: old global hooks this plugin replaces
```

Requirements: `git`, `jq`, and `uv`/`pipx` plus `pnpm`/`npm` for the installs.

## What the agent gets

| Event | Behaviour | Cost when the repo has no graph |
|---|---|---|
| SessionStart | One short routing note: codegraph for structure, graphify for concepts, rg for literal text. Flags docs changed since the last `repo-intel build` (graphify's own git hook keeps code current). Warns about an unreadable `.repo-intel.json`. | one `sh` + `jq`, no output |
| UserPromptSubmit | Runs `codegraph prompt-hook` only for prompts that look structural ("who calls", "what breaks", a camelCase or snake_case symbol, a file path; English and Polish). Other prompts never start node. | same |
| PreToolUse Bash, Grep, Glob | The first search in a session gets a one-line pointer to the graphs. Never repeated, never blocks. | same |
| PreToolUse Skill, Agent, Task | With a backend configured, denies `/graphify` builds and graphify extraction subagents (also in a repo with no graph yet) and points to `repo-intel build`. `/graphify query`, `path` and `explain` stay allowed. `repo-intel config --backend agent` turns the guard off. | same |

Skills: `/repo-intel:setup`, `/repo-intel:build`, `/repo-intel:route` (which tool answers which question).

## LLM backend

`repo-intel build` calls `graphify extract --backend <backend> [--model <model>]`.

| Backend | Notes |
|---|---|
| a graphify provider, e.g. `litellm` | Defined with `graphify provider add`; its API key comes from the variable the provider names |
| `ollama` | Local; the build runs one chunk at a time. `--base-url` sets `OLLAMA_HOST` |
| `openai` | With `--base-url` it reaches llama.cpp, vLLM, LM Studio or a LiteLLM proxy |
| `claude` | With `--base-url` it reaches an Anthropic-compatible gateway |
| `gemini`, `deepseek`, `kimi` | graphify's built-in clients |
| `code-only` | No LLM; code structure only. Also what `build` does when nothing is configured |
| `agent` | Opt back into Claude Code subagents via `/graphify` |

Config lives in `.repo-intel.json` at the repo root (commit it to share the choice) or in
`~/.config/repo-intel/config.json` with `--global`. `REPO_INTEL_BACKEND` and
`REPO_INTEL_MODEL` override both. Backend, model and URL always come from the same
source, so a repo backend never picks up the user config's model. The file holds names
and URLs only; keys stay in the environment. `--base-url` applies to `openai`, `claude`
and `ollama`; a graphify provider keeps its URL in `~/.graphify/providers.json`.

codegraph has no LLM step: it indexes with tree-sitter, so there is nothing to route.

## Replacing the old global hooks

If `~/.claude/settings.json` already runs `graphify hook-guard` (PreToolUse on every Bash,
Grep, Read and Glob) or `codegraph prompt-hook` (every prompt), both fire next to this
plugin. `repo-intel migrate-hooks --apply` removes exactly those entries (bare, `npx`,
`uvx` or absolute-path forms), keeps a timestamped backup and prints the undo command.
A symlinked `settings.json` is edited through the link, so a dotfiles setup stays intact.
`hook-guard read` is dropped rather than replaced: repo-intel nudges on searches only.

## Tests

```bash
bash tests/run.sh
```

The tests use fake `graphify` and `codegraph` binaries and a temporary `HOME`; they never
touch your real settings or call an LLM.
