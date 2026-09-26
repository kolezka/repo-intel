---
name: setup
description: Use when the user asks to set up, install, enable or configure codegraph and graphify in a repository, to choose the LLM backend (LiteLLM, Ollama, OpenAI-compatible, Claude, Gemini) that builds the graphify graph, or to remove the old global graphify/codegraph hooks this plugin replaces.
---

# repo-intel setup

The CLI is `repo-intel` (on PATH while the plugin is enabled; otherwise
`${CLAUDE_PLUGIN_ROOT}/bin/repo-intel`). Run every step from the repository root.

1. `repo-intel doctor`. Read the report, then act only on what it lists.
2. Missing `graphify` or `codegraph`: ask the user before installing, then run
   `repo-intel install`. It uses uv or pipx for graphify and pnpm or npm for
   codegraph. Missing `jq`: tell the user, since the hooks stay silent without it.
3. Backend unset: ask which backend builds the graph. Offer the providers from
   `graphify provider list`, `ollama` for a local model, and `code-only` for no
   LLM at all. Then run `repo-intel config --backend <name> [--model <model>] [--base-url <url>]`.
   Add `--global` for a machine-wide default. API keys stay in environment variables
   and never go in the config file.
4. `repo-intel setup`. It indexes codegraph, adds `.codegraph/` and
   `graphify-out/cache/` to `.gitignore`, installs graphify's git hooks, and runs
   the first build.
5. `doctor` reported duplicate global hooks: show `repo-intel migrate-hooks`
   (a dry run), ask, then run `repo-intel migrate-hooks --apply`. It backs up
   `settings.json` first and prints the undo command.

Report what changed, the backend in use, and anything that failed, with its output.
