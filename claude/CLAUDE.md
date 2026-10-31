# repo-intel

Applies in a repository with a `.codegraph/` directory or a `graphify-out/graph.json`
graph (at the git root or in a sub-project). Elsewhere, ignore this section.

- Code structure (where X is defined, who calls it, what breaks if it changes):
  codegraph first, via the `codegraph_explore` MCP tool or
  `codegraph explore "<symbols or question>"`.
- Concepts, docs, architecture and why: `graphify query "<question>"`, also
  `graphify path A B` and `graphify explain X`.
- Literal text, config values, and any complete list of call sites before calling a
  change safe: `rg`. The graphs miss dynamic dispatch, generated code and bodies
  wrapped in higher-order calls.
- Before relying on graphify for docs, run `repo-intel doctor`. If it reports the
  graph as stale, run `repo-intel build` first.
- Build or refresh graphs with `repo-intel build`. Do not dispatch graphify
  extraction subagents unless `repo-intel config --show` reports `backend=agent`.
- `repo-intel config --show` also reports `tools=` (codegraph, graphify or both). Use
  only the tools it names, even if the other one's files are still on disk.
- Full routing table: the `/repo-intel:route` skill.
