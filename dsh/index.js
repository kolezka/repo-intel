// DeepSeek Harness entry for this Claude Code plugin. The plugin tree is read as is;
// claude-compat.js is a vendored copy from kolezka/marketplace dsh-compat/, do not edit it here.
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
