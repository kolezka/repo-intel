// claude-compat: run an unmodified Claude Code plugin inside DeepSeek Harness (DSH).
//
// One file, no dependencies. Every kolezka plugin vendors a byte-identical copy as
// dsh/claude-compat.js; the canonical copy lives in kolezka/marketplace under
// dsh-compat/. The plugin tree (.claude-plugin/, skills/, commands/, agents/,
// hooks/hooks.json, CLAUDE.md files) is read as is, so Claude Code keeps working
// and DSH sees the same content:
//
//   skills/<name>/SKILL.md     -> skill provider (rank 450, between ~/.dsh/skills and ~/.agents/skills)
//   commands/<name>.md         -> /<plugin>-<name> slash command (prompt template sent as a follow-up turn)
//   agents/<name>.md           -> virtual skill "<plugin>-agent-<name>": a brief to pass to subagent/spawn_teammate
//   instruction files          -> system prompt section, <!--harness:claude-only--> blocks removed
//   hooks/hooks.json commands  -> agent and tool events, Claude Code hook JSON on stdin
//   .mcp.json                  -> not handled here: dsh-mcp-client rows in the bundle patch do that
//
// Hook event mapping:
//   SessionStart      first step of each agent (once per agent instance)
//   UserPromptSubmit  a step that carries a user message
//   PreToolUse        tools/pre-execute, can deny or ask
//   PostToolUse       tools/result, fire and forget
//   Stop              agent/turn-stopping, {"decision":"block"} steers one more step
//   SubagentStop      agent/turn-stopping of a subagent session
//   SessionEnd        agent/disposed
// Hook stdout additionalContext is queued with agent.inject() and reaches the model at
// the next step. transcript_path points at a Claude-shaped JSONL export of the DSH session.

import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const COMPAT_VERSION = '0.1.0'
export const SKILL_RANK = 450
const HOOK_STDOUT_LIMIT = 256 * 1024
const DEFAULT_HOOK_TIMEOUT_S = 60
// Events whose hooks read the transcript. Other events get the path of the last export,
// so a per-tool-call hook does not rewrite the whole session on every call.
const TRANSCRIPT_EVENTS = new Set(['Stop', 'SubagentStop', 'SessionEnd', 'PreCompact'])

// DSH tool name -> Claude Code tool name, for matchers and tool_name in hook input.
export const TOOL_NAME_MAP = {
  bash: 'Bash',
  read: 'Read',
  read_image: 'Read',
  write: 'Write',
  edit: 'Edit',
  str_replace_based_edit_tool: 'Edit',
  glob: 'Glob',
  grep: 'Grep',
  web_fetch: 'WebFetch',
  web_search: 'WebSearch',
  skill: 'Skill',
  subagent: 'Agent',
  subagent_fork: 'Agent',
  spawn_teammate: 'Agent',
  todo_write: 'TodoWrite',
  ask_user_question: 'AskUserQuestion',
}

// ---------------------------------------------------------------- plugin files

/** Split YAML-ish front matter from a markdown file. Only flat `key: value` lines are read. */
export function parseFrontMatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text)
  if (!match) return { meta: {}, body: text }
  const meta = {}
  for (const line of match[1].split(/\r?\n/)) {
    const kv = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line)
    if (!kv) continue
    let value = kv[2].trim()
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
      if (kv[2].trim().startsWith('"')) value = value.replace(/\\"/g, '"').replace(/\\\\/g, '\\')
    }
    meta[kv[1]] = value
  }
  return { meta, body: text.slice(match[0].length) }
}

/** Remove `<!--harness:claude-only--> ... <!--/harness-->` blocks. */
export function stripClaudeOnly(text) {
  return text.replace(/^[^\n]*<!--\s*harness:claude-only\s*-->[\s\S]*?<!--\s*\/harness\s*-->[^\n]*\n?/gm, '')
}

/** Replace the Claude plugin root variables with the real plugin directory. */
export function expandPluginRoot(text, root) {
  return text.replaceAll('${CLAUDE_PLUGIN_ROOT}', root).replaceAll('$CLAUDE_PLUGIN_ROOT', root)
}

const kebab = (value) => String(value).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')

function readText(path) {
  try {
    return readFileSync(path, 'utf8')
  } catch {
    return undefined
  }
}

function listDir(path) {
  try {
    return readdirSync(path, { withFileTypes: true })
  } catch {
    return []
  }
}

/** Read the plugin manifest; the plugin name falls back to the directory name. */
export function readManifest(root) {
  const raw = readText(join(root, '.claude-plugin', 'plugin.json'))
  const manifest = raw ? JSON.parse(raw) : {}
  return { ...manifest, name: manifest.name || basename(root) }
}

/** Skill directories: `skills/<name>/SKILL.md`. */
export function discoverSkills(root, options = {}) {
  const dir = join(root, 'skills')
  const skip = new Set(options.exclude ?? [])
  const out = []
  for (const entry of listDir(dir)) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
    if (skip.has(entry.name)) continue
    const path = join(dir, entry.name, 'SKILL.md')
    const text = readText(path)
    if (text === undefined) continue
    const { meta } = parseFrontMatter(text)
    const bare = kebab(meta.name || entry.name)
    if (!bare || !meta.description) continue
    const name = options.prefix ? `${options.prefix}-${bare}` : bare
    out.push({ name, description: meta.description, path, base: dirname(path), meta })
  }
  return out.sort((a, b) => a.name.localeCompare(b.name))
}

/** Command files: `commands/<name>.md`. */
export function discoverCommands(root, options = {}) {
  const dir = join(root, 'commands')
  const skip = new Set(options.exclude ?? [])
  const out = []
  for (const entry of listDir(dir)) {
    if (!entry.name.endsWith('.md')) continue
    const stem = entry.name.slice(0, -3)
    if (skip.has(stem)) continue
    const path = join(dir, entry.name)
    const text = readText(path)
    if (text === undefined) continue
    const { meta, body } = parseFrontMatter(text)
    out.push({ stem, name: kebab(meta.name || stem), description: meta.description || stem, hint: meta['argument-hint'] || '', body, path })
  }
  return out.sort((a, b) => a.name.localeCompare(b.name))
}

/** Agent definitions: `agents/<name>.md` plus any extra directories the bundle lists. */
export function discoverAgents(root, options = {}) {
  const dirs = [join(root, 'agents'), ...(options.extraDirs ?? []).map((d) => resolve(root, d))]
  const skip = new Set(options.exclude ?? [])
  const out = []
  const seen = new Set()
  for (const dir of dirs) {
    for (const entry of listDir(dir)) {
      if (!entry.name.endsWith('.md')) continue
      const path = join(dir, entry.name)
      const text = readText(path)
      if (text === undefined) continue
      const { meta, body } = parseFrontMatter(text)
      const name = kebab(meta.name || entry.name.slice(0, -3))
      if (skip.has(name) || seen.has(name) || !meta.description) continue
      seen.add(name)
      out.push({ name, description: meta.description, tools: meta.tools || '', model: meta.model || '', body, path })
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name))
}

/** hooks/hooks.json command hooks, flattened. Function-hook `modules` are Claude-only and skipped. */
export function readHooks(root) {
  const raw = readText(join(root, 'hooks', 'hooks.json'))
  if (!raw) return []
  const hooks = JSON.parse(raw).hooks ?? {}
  const out = []
  for (const [event, groups] of Object.entries(hooks)) {
    for (const group of groups ?? []) {
      for (const hook of group.hooks ?? []) {
        if (hook.type !== 'command' || !hook.command) continue
        out.push({ event, matcher: group.matcher ?? '', command: hook.command, timeout: hook.timeout ?? DEFAULT_HOOK_TIMEOUT_S })
      }
    }
  }
  return out
}

/** A Claude Code matcher: empty or `*` matches all, otherwise an anchored regex (`Bash`, `Skill|Agent|Task`). */
export function matcherMatches(matcher, toolName) {
  if (!matcher || matcher === '*') return true
  try {
    return new RegExp(`^(?:${matcher})$`).test(toolName)
  } catch {
    return matcher === toolName
  }
}

/** Expand `$ARGUMENTS`, `$1..$9` and `${CLAUDE_PLUGIN_ROOT}` in a command body. */
export function renderCommand(body, rawInput, root) {
  const args = rawInput.trim()
  const positional = args ? args.split(/\s+/) : []
  let text = expandPluginRoot(body, root)
  const usesArgs = /\$ARGUMENTS|\$[1-9]/.test(text)
  text = text.replaceAll('$ARGUMENTS', args).replace(/\$([1-9])/g, (_, n) => positional[Number(n) - 1] ?? '')
  if (!usesArgs && args) text += `\n\nArguments: ${args}`
  return text
}

// ---------------------------------------------------------------- DSH session helpers

function sessionEvents(session) {
  try {
    return session.ownEvents?.() ?? session.snapshotEvents?.() ?? session.events ?? []
  } catch {
    return []
  }
}

const textOf = (message) =>
  (message?.content ?? []).filter((b) => b?.type === 'text' && b.text).map((b) => b.text).join('\n')

function parseArguments(raw) {
  if (raw === undefined || raw === null) return {}
  if (typeof raw !== 'string') return raw
  try {
    return JSON.parse(raw)
  } catch {
    return { raw }
  }
}

/** DSH tool arguments -> Claude Code `tool_input` shape. */
export function toClaudeToolInput(dshName, args) {
  const input = { ...(args ?? {}) }
  if (dshName === 'glob' || dshName === 'grep') {
    if (input.include && !input.glob) input.glob = input.include
  }
  if (dshName === 'subagent' || dshName === 'subagent_fork' || dshName === 'spawn_teammate') {
    if (input.description === undefined && input.name) input.description = input.name
    if (input.subagent_type === undefined) input.subagent_type = input.name ?? 'general-purpose'
  }
  if (dshName === 'skill' && input.name && input.skill === undefined) input.skill = input.name
  return input
}

export const claudeToolName = (dshName) => TOOL_NAME_MAP[dshName] ?? dshName

/**
 * Export DSH session events as Claude Code transcript JSONL records:
 * `{type:"user"|"assistant", message:{role, content:[...]}, sessionId, timestamp, cwd}`.
 * Tool calls become `tool_use` blocks with Claude tool names; results become `tool_result`.
 */
export function toClaudeTranscript(events, sessionId, cwd) {
  const lines = []
  const stamp = (event) => new Date(event.time ?? Date.now()).toISOString()
  for (const event of events) {
    if (!event || typeof event !== 'object') continue
    if (event.type === 'user/message') {
      const message = event.data
      if (message?.source?.kind !== 'user') continue
      const text = textOf(message)
      if (!text) continue
      lines.push({ type: 'user', uuid: randomUUID(), sessionId, cwd, timestamp: stamp(event), message: { role: 'user', content: text } })
    } else if (event.type === 'assistant/message') {
      const message = event.data?.message
      if (!message) continue
      const content = []
      for (const block of message.content ?? []) {
        if (block?.type === 'text' && block.text) content.push({ type: 'text', text: block.text })
        else if (block?.type === 'tool-call') {
          content.push({ type: 'tool_use', id: block.id, name: claudeToolName(block.name), input: toClaudeToolInput(block.name, parseArguments(block.arguments)) })
        }
      }
      if (content.length) lines.push({ type: 'assistant', uuid: randomUUID(), sessionId, cwd, timestamp: stamp(event), message: { role: 'assistant', content } })
    } else if (event.type === 'tool/result') {
      const message = event.data?.message
      if (!message?.toolCallId) continue
      lines.push({
        type: 'user',
        uuid: randomUUID(),
        sessionId,
        cwd,
        timestamp: stamp(event),
        message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: message.toolCallId, content: textOf(message), is_error: message.isError === true }] },
      })
    }
  }
  return lines.map((line) => JSON.stringify(line)).join('\n') + (lines.length ? '\n' : '')
}

function stateHome() {
  const base = process.env.DSH_HOME || join(homedir(), '.dsh')
  return join(base, 'state', 'claude-compat')
}

function transcriptPath(agent) {
  return join(stateHome(), 'transcripts', `${String(agent.session.header.id).replace(/[^A-Za-z0-9_-]/g, '')}.jsonl`)
}

function writeTranscript(agent, cwd) {
  const path = transcriptPath(agent)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, toClaudeTranscript(sessionEvents(agent.session), agent.session.header.id, cwd))
  return path
}

function lastAssistantText(session) {
  const events = sessionEvents(session)
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i]?.type === 'assistant/message') return textOf(events[i].data?.message)
  }
  return ''
}

// ---------------------------------------------------------------- hook execution

/** Run one hook command with Claude Code's hook contract: JSON on stdin, exit 2 blocks. */
export function runHook(hook, input, env) {
  return new Promise((resolvePromise) => {
    let stdout = ''
    let stderr = ''
    let settled = false
    const child = spawn('/bin/sh', ['-c', hook.command], { cwd: input.cwd || process.cwd(), env, stdio: ['pipe', 'pipe', 'pipe'] })
    const timer = setTimeout(() => {
      child.kill('SIGKILL')
      finish({ code: null, stdout, stderr: stderr + `\nhook timed out after ${hook.timeout}s`, timedOut: true })
    }, (hook.timeout || DEFAULT_HOOK_TIMEOUT_S) * 1000)
    function finish(result) {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolvePromise(result)
    }
    child.stdout.on('data', (chunk) => {
      if (stdout.length < HOOK_STDOUT_LIMIT) stdout += chunk
    })
    child.stderr.on('data', (chunk) => {
      if (stderr.length < HOOK_STDOUT_LIMIT) stderr += chunk
    })
    child.on('error', (error) => finish({ code: null, stdout, stderr: String(error), timedOut: false }))
    child.on('close', (code) => finish({ code, stdout, stderr, timedOut: false }))
    child.stdin.on('error', () => {})
    child.stdin.end(JSON.stringify(input))
  })
}

/** Normalize a hook result to one decision shape across events. */
export function interpretHookResult(result) {
  const out = { context: [], decision: undefined, reason: undefined }
  if (result.code === 2) {
    out.decision = 'block'
    out.reason = result.stderr.trim() || 'blocked by hook'
    return out
  }
  if (result.code !== 0) return out
  const text = result.stdout.trim()
  if (!text) return out
  let json
  try {
    json = JSON.parse(text)
  } catch {
    out.context.push(text)
    return out
  }
  const specific = json.hookSpecificOutput ?? {}
  if (specific.additionalContext) out.context.push(String(specific.additionalContext))
  if (json.systemMessage) out.context.push(String(json.systemMessage))
  if (specific.permissionDecision) {
    out.decision = specific.permissionDecision
    out.reason = specific.permissionDecisionReason
  } else if (json.decision) {
    out.decision = json.decision === 'approve' ? 'allow' : json.decision
    out.reason = json.reason
  }
  if (json.continue === false) {
    out.decision = 'block'
    out.reason = json.stopReason || out.reason
  }
  return out
}

// ---------------------------------------------------------------- the DSH plugin

/**
 * Build a Cordis plugin for one Claude Code plugin directory.
 * @param {object} spec
 * @param {string} spec.root - plugin root, the directory holding `.claude-plugin/`.
 * @param {string[]} [spec.instructions] - root-relative files injected into the system prompt.
 * @param {object} [spec.skills] - `{ exclude: [], prefix }`; prefix renames `x` to `<prefix>-x` to avoid clashes.
 * @param {object} [spec.commands] - `{ exclude: [], prefix }`; prefix defaults to the plugin name.
 * @param {object} [spec.agents] - `{ exclude: [], extraDirs: [] }`.
 * @param {object} [spec.hooks] - `{ events: [] }` to limit which hook events run; default all.
 * @param {object} [spec.env] - extra environment for hooks, values may use `${CLAUDE_PLUGIN_ROOT}`.
 * @param {string[]} [spec.disableByDefault] - parts off unless the row config sets `disable`.
 */
export function createPlugin(spec) {
  const root = resolve(spec.root)
  const manifest = readManifest(root)
  const pluginName = kebab(manifest.name)
  const id = `claude-compat-${pluginName}`
  const commandPrefix = spec.commands?.prefix ?? pluginName
  const hasAgents = () => !(spec.disableByDefault ?? []).includes('agents') && discoverAgents(root, spec.agents).length > 0
  const harnessNote = () =>
    [
      `> Loaded from the ${pluginName} Claude Code plugin into DeepSeek Harness. Plugin root: \`${root}\`.`,
      `> A Claude command \`/${pluginName}:<cmd>\` is the DSH command \`/${commandPrefix}-<cmd>\`; when you cannot run it, do what its section here says.`,
      hasAgents()
        ? `> A Claude agent type \`${pluginName}:<agent>\` is the skill \`${pluginName}-agent-<agent>\`: load it and pass its role text to \`subagent\` or \`spawn_teammate\`.`
        : '',
    ]
      .filter(Boolean)
      .join('\n')

  function apply(ctx, config = {}) {
    const disabled = new Set(config.disable ?? spec.disableByDefault ?? [])
    const enabled = (part) => !disabled.has(part)
    const log = ctx.logger ?? console
    const warn = (msg) => (log.warn ? log.warn(`[${id}] ${msg}`) : console.warn(`[${id}] ${msg}`))

    // Each part waits for its own service, so a profile without one keeps the rest.
    if (enabled('skills') || enabled('agents')) ctx.inject(['skills'], (sub) => registerSkills(sub, enabled, warn))
    if (enabled('commands')) ctx.inject(['commands'], (sub) => registerCommands(sub, warn))
    if (enabled('instructions')) ctx.inject(['systemPrompt'], (sub) => registerInstructions(sub, warn))
    if (enabled('hooks')) registerHooks(ctx, warn)
  }

  // ---- skills and agent briefs

  function registerSkills(ctx, enabled, warn) {
    if (!ctx.skills?.registerProvider) return warn('skills service missing, skills not registered')
    const provider = {
      name: id,
      async list() {
        const candidates = []
        if (enabled('skills')) {
          for (const skill of discoverSkills(root, spec.skills)) {
            candidates.push({
              name: skill.name,
              description: skill.description,
              ...(skill.meta.whenToUse ? { whenToUse: skill.meta.whenToUse } : {}),
              invocation: { modelInvocable: skill.meta['disable-model-invocation'] !== 'true', userInvocable: skill.meta['user-invocable'] !== 'false' },
              provider: id,
              source: 'custom',
              path: skill.path,
              resourceBase: { kind: 'directory', path: skill.base },
              rank: SKILL_RANK,
              locator: { kind: 'skill', path: skill.path, base: skill.base },
            })
          }
        }
        if (enabled('agents')) {
          for (const agent of discoverAgents(root, spec.agents)) {
            candidates.push({
              name: `${pluginName}-agent-${agent.name}`,
              description: `Role brief for a delegated worker (${pluginName} agent "${agent.name}"). ${agent.description}`,
              invocation: { modelInvocable: true, userInvocable: true },
              provider: id,
              source: 'custom',
              path: agent.path,
              resourceBase: { kind: 'directory', path: dirname(agent.path) },
              rank: SKILL_RANK,
              locator: { kind: 'agent', path: agent.path },
            })
          }
        }
        return candidates
      },
      async get(candidate) {
        const locator = candidate.locator
        const text = readText(locator.path)
        if (text === undefined) return undefined
        const { body } = parseFrontMatter(text)
        let content = expandPluginRoot(body, root)
        if (locator.kind === 'skill') {
          content = `${harnessNote()}\n> Relative paths in this skill resolve from \`${locator.base}\`.\n\n${content}`
        } else {
          const agent = discoverAgents(root, spec.agents).find((a) => a.path === locator.path)
          const tools = agent?.tools ? `\nOriginal tool allowlist: ${agent.tools}. Respect it: do not use tools outside that list.` : ''
          content = [
            `# Delegated role: ${agent?.name ?? candidate.name}`,
            '',
            `This is a Claude Code agent definition from the ${pluginName} plugin. DSH has no agent types, so use it as a brief:`,
            '- To run this role, call `subagent` (or `spawn_teammate` for a durable teammate) with a prompt made of the role text below, then the concrete task, exact files, and the check that proves it done.',
            '- Pick the provider/model yourself; the original pin does not apply in DSH.' + tools,
            '',
            '## Role text',
            '',
            content,
          ].join('\n')
        }
        return {
          name: candidate.name,
          description: candidate.description,
          invocation: candidate.invocation,
          provider: id,
          source: 'custom',
          path: locator.path,
          resourceBase: candidate.resourceBase,
          content,
        }
      },
    }
    ctx.skills.registerProvider(() => provider)
  }

  // ---- slash commands

  function registerCommands(ctx, warn) {
    if (!ctx.commands?.register) return
    const prefix = commandPrefix
    for (const command of discoverCommands(root, spec.commands)) {
      const name = `${prefix}-${command.name}`
      if (!/^[a-z][a-z0-9_-]*$/.test(name)) {
        warn(`command name ${name} is not valid, skipped`)
        continue
      }
      try {
        ctx.commands.register({
          name,
          description: command.description,
          ...(command.hint ? { input: { hint: command.hint } } : {}),
          handler(invocation) {
            const text = readText(command.path)
            const body = text === undefined ? command.body : parseFrontMatter(text).body
            invocation.agent.followup({
              id: randomUUID(),
              role: 'user',
              content: [{ type: 'text', text: `<command-name>/${prefix}:${command.stem}</command-name>\n\n${renderCommand(body, invocation.rawInput, root)}` }],
              source: { kind: 'user' },
            })
            return { kind: 'success', text: `/${name} queued` }
          },
        })
      } catch (error) {
        warn(`command /${name} not registered: ${error.message}`)
      }
    }
  }

  // ---- instruction files

  function registerInstructions(ctx, warn) {
    const files = spec.instructions ?? []
    if (!files.length) return
    if (!ctx.systemPrompt?.section) return warn('systemPrompt service missing, instructions not registered')
    ctx.systemPrompt.section({
      name: `${id}-instructions`,
      order: 450,
      interpolate: false,
      text: () =>
        files
          .map((file) => readText(resolve(root, file)))
          .filter(Boolean)
          .map((text) => stripClaudeOnly(expandPluginRoot(text, root)).trim())
          .join('\n\n'),
    })
  }

  // ---- hooks

  function registerHooks(ctx, warn) {
    const only = spec.hooks?.events ? new Set(spec.hooks.events) : undefined
    const hooks = readHooks(root).filter((hook) => !only || only.has(hook.event))
    if (!hooks.length) return
    const byEvent = (event) => hooks.filter((hook) => hook.event === event)
    const started = new WeakSet()
    const stopBlocks = new WeakMap()
    let workingDirectory
    ctx.inject(['workingDirectory'], (sub) => {
      workingDirectory = sub.workingDirectory
      sub.effect(() => () => {
        workingDirectory = undefined
      })
    })

    const baseEnv = () => {
      const env = { ...process.env, CLAUDE_PLUGIN_ROOT: root, CLAUDE_HARNESS: 'dsh', DSH_CLAUDE_COMPAT: COMPAT_VERSION }
      for (const [key, value] of Object.entries(spec.env ?? {})) env[key] = expandPluginRoot(String(value), root)
      return env
    }

    const cwdOf = (agent) => {
      try {
        return workingDirectory?.get(agent.session) || agent.session.header.cwd || process.cwd()
      } catch {
        return agent.session.header.cwd || process.cwd()
      }
    }

    const inputFor = (agent, event, extra = {}) => {
      const cwd = cwdOf(agent)
      let transcript = transcriptPath(agent)
      if (TRANSCRIPT_EVENTS.has(event) || !existsSync(transcript)) {
        try {
          transcript = writeTranscript(agent, cwd)
        } catch (error) {
          warn(`transcript export failed: ${error.message}`)
        }
      }
      return { session_id: String(agent.session.header.id), transcript_path: transcript, cwd, hook_event_name: event, permission_mode: 'default', ...extra }
    }

    async function fire(event, agent, extra, filter) {
      const list = byEvent(event).filter(filter ?? (() => true))
      if (!list.length) return []
      const input = inputFor(agent, event, extra)
      const env = baseEnv()
      const results = []
      for (const hook of list) {
        try {
          const result = await runHook(hook, input, env)
          if (result.timedOut || (result.code !== 0 && result.code !== 2)) warn(`${event} hook exited ${result.code}: ${result.stderr.trim().slice(0, 300)}`)
          results.push(interpretHookResult(result))
        } catch (error) {
          warn(`${event} hook failed: ${error.message}`)
        }
      }
      return results
    }

    function injectContext(agent, event, results) {
      const text = results.flatMap((r) => r.context).filter(Boolean).join('\n\n')
      if (!text) return
      agent.inject({
        id: randomUUID(),
        role: 'user',
        content: [{ type: 'text', text: `<${pluginName}-hook event="${event}">\n${text}\n</${pluginName}-hook>` }],
        source: { kind: `plugin:${id}` },
      })
    }

    const isSubagent = (agent) => agent.session.header.origin === 'subagent'

    if (byEvent('SessionStart').length || byEvent('UserPromptSubmit').length) {
      ctx.on(
        'agent/pre-step',
        async (payload, next) => {
          const decision = await next()
          if (decision.kind !== 'enter' || payload.signal?.aborted) return decision
          const { agent } = payload
          const added = []
          if (!started.has(agent)) {
            started.add(agent)
            const results = await fire('SessionStart', agent, { source: 'startup' })
            added.push(...results.flatMap((r) => r.context))
          }
          const prompt = decision.messages.filter((m) => m?.source?.kind === 'user').map(textOf).join('\n').trim()
          if (prompt && byEvent('UserPromptSubmit').length) {
            const results = await fire('UserPromptSubmit', agent, { prompt })
            const blocked = results.find((r) => r.decision === 'block')
            if (blocked) {
              added.push(`The ${pluginName} plugin blocked this prompt: ${blocked.reason ?? 'no reason given'}. Tell the user and do not act on it.`)
            }
            added.push(...results.flatMap((r) => r.context))
          }
          const text = added.filter(Boolean).join('\n\n')
          if (!text) return decision
          return {
            ...decision,
            messages: [...decision.messages, { id: randomUUID(), role: 'user', content: [{ type: 'text', text: `<${pluginName}-hook>\n${text}\n</${pluginName}-hook>` }], source: { kind: `plugin:${id}` } }],
          }
        },
      )
    }

    if (byEvent('PreToolUse').length) {
      ctx.on('tools/pre-execute', async (exec, next) => {
        const agent = exec.agent
        if (!agent) return next()
        const toolName = claudeToolName(exec.name)
        const list = byEvent('PreToolUse').filter((hook) => matcherMatches(hook.matcher, toolName))
        if (!list.length) return next()
        const results = await fire('PreToolUse', agent, { tool_name: toolName, tool_input: toClaudeToolInput(exec.name, parseArguments(exec.arguments)), tool_use_id: String(exec.callId) }, (hook) => matcherMatches(hook.matcher, toolName))
        injectContext(agent, 'PreToolUse', results)
        const deny = results.find((r) => r.decision === 'deny' || r.decision === 'block')
        if (deny) return { kind: 'deny', reason: deny.reason || `denied by ${pluginName} hook` }
        const ask = results.find((r) => r.decision === 'ask')
        if (ask) {
          const reason = ask.reason || `${pluginName} hook asks for confirmation`
          return { kind: 'ask', reason, displayReason: { en: reason } }
        }
        return next()
      })
    }

    if (byEvent('PostToolUse').length) {
      ctx.on('tools/result', (exec, result) => {
        const agent = exec.agent
        if (!agent) return
        const toolName = claudeToolName(exec.name)
        if (!byEvent('PostToolUse').some((hook) => matcherMatches(hook.matcher, toolName))) return
        const output = (result?.content ?? []).filter((b) => b?.type === 'text').map((b) => b.text).join('\n')
        const response = result?.isError ? { success: false, error: output } : { success: true, output }
        fire('PostToolUse', agent, { tool_name: toolName, tool_input: toClaudeToolInput(exec.name, parseArguments(exec.arguments)), tool_response: response, tool_use_id: String(exec.callId) }, (hook) => matcherMatches(hook.matcher, toolName))
          .then((results) => injectContext(agent, 'PostToolUse', results))
          .catch((error) => warn(`PostToolUse: ${error.message}`))
      })
    }

    if (byEvent('Stop').length || byEvent('SubagentStop').length) {
      ctx.on('agent/turn-stopping', async ({ agent, signal }) => {
        if (signal?.aborted) return
        const event = isSubagent(agent) ? 'SubagentStop' : 'Stop'
        if (!byEvent(event).length) return
        const active = stopBlocks.get(agent) === true
        const results = await fire(event, agent, { stop_hook_active: active, last_assistant_message: lastAssistantText(agent.session) })
        const block = results.find((r) => r.decision === 'block')
        if (block && !active) {
          stopBlocks.set(agent, true)
          agent.steer({ id: randomUUID(), role: 'user', content: [{ type: 'text', text: `<${pluginName}-hook event="${event}">\n${block.reason ?? 'A plugin hook asked for one more step.'}\n</${pluginName}-hook>` }], source: { kind: `plugin:${id}` } })
        } else {
          stopBlocks.set(agent, false)
        }
      })
    }

    if (byEvent('SessionEnd').length) {
      ctx.on('agent/disposed', ({ agent }) => {
        fire('SessionEnd', agent, { reason: 'other' }).catch((error) => warn(`SessionEnd: ${error.message}`))
      })
    }
  }

  return { name: id, apply }
}

/** The plugin root is the parent of the `dsh/` directory holding the caller. */
export function rootFrom(importMetaUrl) {
  const candidate = resolve(dirname(fileURLToPath(importMetaUrl)), '..')
  if (!existsSync(join(candidate, '.claude-plugin'))) throw new Error(`claude-compat: no .claude-plugin under ${candidate}`)
  return candidate
}
