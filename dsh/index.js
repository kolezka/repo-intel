import { createPlugin, rootFrom } from 'claude-plugin-dsh'

const plugin = createPlugin({
  root: rootFrom(import.meta.url),
  skills: { prefix: 'repo-intel' },
  instructions: ['claude/CLAUDE.md'],
  // SessionStart only repoints the Claude import link, which DSH does not use.
  hooks: { events: ['PreToolUse'] },
})
export const { name, apply } = plugin
export default plugin
