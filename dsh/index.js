// DeepSeek Harness entry for this Claude Code plugin.
// Refresh the vendored runtime with claude-plugins-dsh sync.
import { createPlugin, rootFrom } from './claude-compat.js'

const plugin = createPlugin({
  root: rootFrom(import.meta.url),
  skills: { prefix: 'repo-intel' },
  instructions: ['claude/CLAUDE.md'],
  // SessionStart only repoints the ~/.claude import link; nothing to do in DSH.
  hooks: { events: ['PreToolUse'] },
})
export const { name, apply } = plugin
export default plugin
