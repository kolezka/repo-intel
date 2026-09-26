---
name: route
description: Use when deciding how to answer a question about a repository that has a .codegraph/ index or a graphify-out/graph.json graph, such as where something is defined, who calls it, what breaks if it changes, how a feature works, or why a design was chosen.
---

# Choosing codegraph, graphify or rg

| Question | Tool |
|---|---|
| Where is X defined, who calls X, what does X call | codegraph: `codegraph_explore` MCP tool, or `codegraph explore "<symbols>"` |
| What breaks if X changes, which tests cover it | `codegraph impact X`, `codegraph affected <files>` |
| How does a feature work end to end | codegraph first; graphify for the docs and decisions around it |
| Concepts, architecture, why something was decided | `graphify query "<question>"`, `graphify explain X` |
| How two things connect | `graphify path "A" "B"` |
| Literal text, config values, error strings | `rg` |
| Every call site before calling a change safe | `rg`, after the graph pointed you to the area |

Rules:

- One graph call replaces a round of grep and file reads. Start there for broad
  questions, then read only the files it names.
- The graphs miss things: dynamic dispatch, generated code, bodies wrapped in
  higher-order calls. A claim that something is unused or safe to change needs `rg`.
- Stale graph (the session-start note says so): run `repo-intel build` before
  relying on it.
