---
name: setup
description: Use when the user asks to set up, install, enable or configure codegraph and graphify in a repository, to choose the LLM backend (LiteLLM, Ollama, OpenAI-compatible, Claude, Gemini, or the current agent CLI) that builds the graphify graph, or to remove the old global graphify/codegraph hooks this plugin replaces.
---

# repo-intel setup

The CLI is `repo-intel` (on PATH while the plugin is enabled; otherwise
`${CLAUDE_PLUGIN_ROOT}/bin/repo-intel`). Run every step from the repository root.

1. `repo-intel doctor`. Read the report, then act only on what it lists.
2. Missing `graphify` or `codegraph`: ask the user before installing, then run
   `repo-intel install`. It uses uv or pipx for graphify and pnpm or npm for
   codegraph. It also imports this plugin's routing note into the global
   `CLAUDE.md`; `repo-intel install claude-md` does only that step. Missing `jq`:
   tell the user, since the build guard hook stays off without it.
3. Backend unset: ask which backend builds the graph. Offer the providers from
   `graphify provider list`, `ollama` for a local model, `agent` to build with
   the current agent CLI (its subagents run `/graphify`; `repo-intel build` then
   indexes code only), and `code-only` for no LLM at all. Then run `repo-intel config --backend <name> [--model <model>] [--base-url <url>]`.
   Add `--global` for a machine-wide default. API keys stay in environment variables
   and never go in the config file.
4. `repo-intel setup`. It indexes codegraph, adds `.codegraph/` and
   `graphify-out/cache/` to `.gitignore`, installs graphify's git hooks, runs
   the first build, then writes a short "Code graphs" block into `CLAUDE.md`
   and `AGENTS.md` so an agent without this plugin still uses the graphs. The
   user can remove that block later with `repo-intel instructions --remove`;
   it never deletes either file.
5. `doctor` reported the claude-md import or claude-md-link as anything but
   healthy: run `repo-intel install claude-md`. If it reports a regular file at
   the link path, ask the user before moving that file away.
6. `doctor` reported duplicate global hooks: show `repo-intel migrate-hooks`
   (a dry run), ask, then run `repo-intel migrate-hooks --apply`. It backs up
   `settings.json` first and prints the undo command.

Report what changed, the backend in use, and anything that failed, with its output.
