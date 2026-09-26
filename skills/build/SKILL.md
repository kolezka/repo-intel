---
name: build
description: Use when the user asks to build, rebuild, refresh or update the codegraph index or the graphify knowledge graph, or when a repo-intel hook says the graph is older than the last commit.
---

# repo-intel build

Run `repo-intel build` from the repository root. Add `--full` only when the user
asks for a full rebuild or the incremental build produced a broken graph.

- The build refreshes codegraph (`codegraph sync`), then runs `graphify extract`
  on the configured backend. Without a backend it indexes code only and calls no LLM.
- Never build the graph with the `/graphify` skill or with extraction subagents
  when a backend is configured. The repo-intel hook denies those calls.
- `repo-intel config --show` prints the backend. A failed extract usually means
  the backend's API key variable is unset or the endpoint is down: report the
  error output as is and do not retry on another backend without asking.
