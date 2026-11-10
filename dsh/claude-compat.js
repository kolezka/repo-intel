// src/plugin.ts
import { randomUUID as randomUUID2 } from "node:crypto";
import { existsSync as existsSync2 } from "node:fs";
import { dirname as dirname3, join as join3, resolve as resolve2 } from "node:path";
import { fileURLToPath } from "node:url";

// src/hooks.ts
import { spawn } from "node:child_process";

// src/plugin-files.ts
import { readdirSync, readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
var DEFAULT_HOOK_TIMEOUT_S = 60;
function parseFrontMatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!match) return { meta: {}, body: text };
  const meta = {};
  for (const line of (match[1] ?? "").split(/\r?\n/)) {
    const kv = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line);
    if (!kv || kv[1] === void 0 || kv[2] === void 0) continue;
    const raw = kv[2].trim();
    let value = raw;
    if (value.startsWith('"') && value.endsWith('"') || value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1);
      if (raw.startsWith('"')) value = value.replace(/\\"/g, '"').replace(/\\\\/g, "\\");
    }
    meta[kv[1]] = value;
  }
  return { meta, body: text.slice(match[0].length) };
}
var CLAUDE_ONLY_OPEN = /^\s*(?:#+\s*)?<!--\s*harness:claude-only\s*-->\s*$/;
var CLAUDE_ONLY_CLOSE = /^\s*(?:#+\s*)?<!--\s*\/harness\s*-->\s*$/;
function stripClaudeOnlyBlocks(text) {
  const out = [];
  let inside = false;
  for (const line of text.split(/(?<=\n)/)) {
    const bare = line.replace(/\r?\n$/, "");
    if (!inside && CLAUDE_ONLY_OPEN.test(bare)) inside = true;
    else if (inside && CLAUDE_ONLY_CLOSE.test(bare)) inside = false;
    else if (!inside) out.push(line);
  }
  return { text: out.join(""), unterminated: inside };
}
var stripClaudeOnly = (text) => stripClaudeOnlyBlocks(text).text;
var escapeClosingTag = (text, tag) => String(text).replaceAll(`</${tag}`, `<\\/${tag}`);
function expandPluginRoot(text, root) {
  return text.replaceAll("${CLAUDE_PLUGIN_ROOT}", root).replaceAll("$CLAUDE_PLUGIN_ROOT", root);
}
var kebab = (value) => String(value).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return void 0;
  }
}
function listDir(path) {
  try {
    return readdirSync(path, { withFileTypes: true });
  } catch {
    return [];
  }
}
function readManifest(root) {
  const raw = readText(join(root, ".claude-plugin", "plugin.json"));
  const manifest = raw ? JSON.parse(raw) : {};
  return { ...manifest, name: manifest.name || basename(root) };
}
function discoverSkills(root, options = {}) {
  const dir = join(root, "skills");
  const skip = new Set(options.exclude ?? []);
  const out = [];
  for (const entry of listDir(dir)) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    if (skip.has(entry.name)) continue;
    const path = join(dir, entry.name, "SKILL.md");
    const text = readText(path);
    if (text === void 0) continue;
    const { meta } = parseFrontMatter(text);
    const bare = kebab(meta.name || entry.name);
    if (!bare || !meta.description) continue;
    const name = options.prefix ? `${options.prefix}-${bare}` : bare;
    out.push({ name, description: meta.description, path, base: dirname(path), meta });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}
function discoverCommands(root, options = {}) {
  const dir = join(root, "commands");
  const skip = new Set(options.exclude ?? []);
  const out = [];
  for (const entry of listDir(dir)) {
    if (!entry.name.endsWith(".md")) continue;
    const stem = entry.name.slice(0, -3);
    if (skip.has(stem)) continue;
    const path = join(dir, entry.name);
    const text = readText(path);
    if (text === void 0) continue;
    const { meta, body } = parseFrontMatter(text);
    out.push({ stem, name: kebab(meta.name || stem), description: meta.description || stem, hint: meta["argument-hint"] || "", body, path });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}
function discoverAgents(root, options = {}) {
  const dirs = [join(root, "agents"), ...(options.extraDirs ?? []).map((d) => resolve(root, d))];
  const skip = new Set(options.exclude ?? []);
  const out = [];
  const seen = /* @__PURE__ */ new Set();
  for (const dir of dirs) {
    for (const entry of listDir(dir)) {
      if (!entry.name.endsWith(".md")) continue;
      const path = join(dir, entry.name);
      const text = readText(path);
      if (text === void 0) continue;
      const { meta, body } = parseFrontMatter(text);
      const name = kebab(meta.name || entry.name.slice(0, -3));
      if (skip.has(name) || seen.has(name) || !meta.description) continue;
      seen.add(name);
      out.push({ name, description: meta.description, tools: meta.tools || "", model: meta.model || "", body, path });
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}
function readHooks(root) {
  const raw = readText(join(root, "hooks", "hooks.json"));
  if (!raw) return [];
  const hooks = JSON.parse(raw).hooks ?? {};
  const out = [];
  for (const [event, groups] of Object.entries(hooks)) {
    for (const group of groups ?? []) {
      for (const hook of group.hooks ?? []) {
        if (hook.type !== "command" || !hook.command) continue;
        const spec = { event, matcher: group.matcher ?? "", command: hook.command, timeout: hook.timeout ?? DEFAULT_HOOK_TIMEOUT_S };
        if (hook.args !== void 0) {
          if (!Array.isArray(hook.args) || !hook.args.every((arg) => typeof arg === "string")) throw new Error(`hooks.json: ${event} hook "${hook.command}" has args that are not a list of strings`);
          spec.args = hook.args;
        }
        if (hook.onFailure === "block" || hook.onFailure === "continue") spec.onFailure = hook.onFailure;
        out.push(spec);
      }
    }
  }
  return out;
}
function matcherMatches(matcher, toolName) {
  if (!matcher || matcher === "*") return true;
  try {
    return new RegExp(`^(?:${matcher})$`).test(toolName);
  } catch {
    return matcher === toolName;
  }
}
function renderCommand(body, rawInput, root) {
  const args = rawInput.trim();
  const positional = args ? args.split(/\s+/) : [];
  let text = expandPluginRoot(body, root);
  const usesArgs = /\$ARGUMENTS|\$[1-9]/.test(text);
  text = text.replace(/\$(ARGUMENTS|[1-9])/g, (_, key) => key === "ARGUMENTS" ? args : positional[Number(key) - 1] ?? "");
  if (!usesArgs && args) text += `

Arguments: ${args}`;
  return text;
}

// src/hooks.ts
var PLACEHOLDERS = ["CLAUDE_PLUGIN_ROOT", "CLAUDE_PROJECT_DIR"];
function expandPlaceholders(text, env) {
  let out = text;
  for (const name of PLACEHOLDERS) {
    const value = env[name];
    if (value !== void 0) out = out.replaceAll("${" + name + "}", value).replaceAll("$" + name, value);
  }
  return out;
}
var HOOK_STDOUT_LIMIT = 256 * 1024;
var HOOK_DRAIN_MS = 50;
var PLAIN_CONTEXT_EVENTS = /* @__PURE__ */ new Set(["SessionStart", "UserPromptSubmit"]);
function runHook(hook, input, env, signal) {
  return new Promise((resolvePromise) => {
    let stdout = "";
    let stderr = "";
    let truncated = false;
    let settled = false;
    let drain;
    const options = { cwd: input.cwd || process.cwd(), env, stdio: ["pipe", "pipe", "pipe"], detached: true };
    const child = hook.args ? spawn(expandPlaceholders(hook.command, env), hook.args.map((arg) => expandPlaceholders(arg, env)), options) : spawn("/bin/sh", ["-c", hook.command], options);
    const killGroup = () => {
      try {
        if (child.pid !== void 0) process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    };
    const timer = setTimeout(
      () => {
        killGroup();
        finish({ code: null, stdout, stderr: stderr + `
hook timed out after ${hook.timeout}s`, timedOut: true, truncated });
      },
      (hook.timeout || DEFAULT_HOOK_TIMEOUT_S) * 1e3
    );
    const onAbort = () => {
      killGroup();
      finish({ code: null, stdout: "", stderr: "hook cancelled", timedOut: false, truncated: false, aborted: true });
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    function finish(result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(drain);
      signal?.removeEventListener("abort", onAbort);
      child.stdout.destroy();
      child.stderr.destroy();
      resolvePromise(result);
    }
    child.stdout.on("data", (chunk) => {
      if (stdout.length + chunk.length > HOOK_STDOUT_LIMIT) truncated = true;
      else stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      if (stderr.length < HOOK_STDOUT_LIMIT) stderr += chunk;
    });
    child.on("error", (error) => finish({ code: null, stdout, stderr: String(error), timedOut: false, truncated }));
    child.on("exit", (code) => {
      drain = setTimeout(() => finish({ code, stdout, stderr, timedOut: false, truncated }), HOOK_DRAIN_MS);
    });
    child.on("close", (code) => finish({ code, stdout, stderr, timedOut: false, truncated }));
    child.stdin.on("error", () => {
    });
    child.stdin.end(JSON.stringify(input));
  });
}
function interpretHookResult(result, event) {
  const out = { context: [], decision: void 0, reason: void 0, updatedInput: void 0, notices: [] };
  if (result.code === 2) {
    out.decision = "block";
    out.reason = result.stderr.trim() || "blocked by hook";
    return out;
  }
  if (result.code !== 0) return out;
  if (result.truncated) {
    out.notices.push(`hook output over ${HOOK_STDOUT_LIMIT} bytes was dropped`);
    return out;
  }
  const text = result.stdout.trim();
  if (!text) return out;
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    if (event === void 0 || PLAIN_CONTEXT_EVENTS.has(event)) out.context.push(text);
    return out;
  }
  const specific = json.hookSpecificOutput ?? {};
  if (specific.additionalContext) out.context.push(String(specific.additionalContext));
  if (specific.updatedInput && typeof specific.updatedInput === "object" && !Array.isArray(specific.updatedInput)) out.updatedInput = specific.updatedInput;
  if (json.systemMessage) out.notices.push(String(json.systemMessage));
  if (specific.permissionDecision) {
    out.decision = specific.permissionDecision;
    out.reason = specific.permissionDecisionReason;
  } else if (json.decision) {
    out.decision = json.decision === "approve" ? "allow" : json.decision;
    out.reason = json.reason;
  }
  if (json.continue === false) {
    out.decision = "block";
    out.reason = json.stopReason || out.reason;
  }
  return out;
}

// src/transcript.ts
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname as dirname2, join as join2 } from "node:path";
var TOOL_NAME_MAP = {
  bash: "Bash",
  read: "Read",
  read_image: "Read",
  write: "Write",
  edit: "Edit",
  str_replace_editor: "Edit",
  glob: "Glob",
  grep: "Grep",
  web_fetch: "WebFetch",
  web_search: "WebSearch",
  skill: "Skill",
  subagent: "Agent",
  subagent_fork: "Agent",
  spawn_teammate: "Agent",
  todo_write: "TodoWrite",
  ask_user_question: "AskUserQuestion"
};
var claudeToolName = (dshName) => TOOL_NAME_MAP[dshName] ?? dshName;
function textOf(message) {
  return (message?.content ?? []).filter((b) => b?.type === "text" && typeof b.text === "string" && b.text !== "").map((b) => b.text).join("\n");
}
function parseArguments(raw) {
  if (raw === void 0 || raw === null) return {};
  if (typeof raw !== "string") return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return { raw };
  }
}
function toClaudeToolInput(dshName, args) {
  const input = { ...args ?? {} };
  if (dshName === "glob" || dshName === "grep") {
    if (input.include && !input.glob) input.glob = input.include;
  }
  if (dshName === "subagent" || dshName === "subagent_fork" || dshName === "spawn_teammate") {
    if (input.description === void 0 && input.name) input.description = input.name;
    if (input.subagent_type === void 0) input.subagent_type = input.name ?? "general-purpose";
  }
  if (dshName === "skill" && input.name && input.skill === void 0) input.skill = input.name;
  return input;
}
function toClaudeToolResponse(dshName, args, result) {
  const input = args ?? {};
  const output = textOf(result);
  const isError = result?.isError === true;
  switch (dshName) {
    case "bash":
      return { stdout: isError ? "" : output, stderr: isError ? output : "", interrupted: false, isImage: false };
    case "read":
    case "read_image":
      return { type: "text", file: { filePath: String(input.file_path ?? input.path ?? ""), content: output } };
    case "write":
      return { type: "update", filePath: String(input.file_path ?? ""), content: String(input.content ?? ""), originalFile: null };
    case "edit":
    case "str_replace_editor":
      return {
        filePath: String(input.file_path ?? input.path ?? ""),
        oldString: String(input.old_string ?? input.old_str ?? ""),
        newString: String(input.new_string ?? input.new_str ?? "")
      };
    case "glob": {
      const filenames = output.split("\n").map((line) => line.trim()).filter(Boolean);
      return { filenames, durationMs: 0, numFiles: filenames.length, truncated: false };
    }
    case "grep": {
      const lines = output.split("\n").filter(Boolean);
      return { content: output, numFiles: lines.length };
    }
    case "web_fetch":
      return { url: String(input.url ?? ""), result: output };
    case "web_search":
      return { query: String(input.query ?? (Array.isArray(input.queries) ? input.queries.join(" ") : "")), results: output };
    default:
      return { content: output, isError };
  }
}
var isUserMessageEvent = (e) => e.type === "user/message";
function toClaudeTranscript(events, sessionId, cwd) {
  const lines = [];
  const stamp = (event) => new Date(event.time ?? Date.now()).toISOString();
  for (const event of events) {
    if (!event || typeof event !== "object") continue;
    if (isUserMessageEvent(event)) {
      const message = event.data;
      if (message?.source?.kind !== "user") continue;
      const text = textOf(message);
      if (!text) continue;
      lines.push({ type: "user", uuid: randomUUID(), sessionId, cwd, timestamp: stamp(event), message: { role: "user", content: text } });
    } else if (event.type === "assistant/message") {
      const message = event.data?.message;
      if (!message) continue;
      const content = [];
      for (const block of message.content ?? []) {
        if (block?.type === "text" && "text" in block && typeof block.text === "string" && block.text) content.push({ type: "text", text: block.text });
        else if (block?.type === "tool-call") {
          const call = block;
          content.push({ type: "tool_use", id: call.id, name: claudeToolName(call.name), input: toClaudeToolInput(call.name, parseArguments(call.arguments)) });
        }
      }
      if (content.length) lines.push({ type: "assistant", uuid: randomUUID(), sessionId, cwd, timestamp: stamp(event), message: { role: "assistant", content } });
    } else if (event.type === "tool/result") {
      const message = event.data?.message;
      if (!message?.toolCallId) continue;
      lines.push({
        type: "user",
        uuid: randomUUID(),
        sessionId,
        cwd,
        timestamp: stamp(event),
        message: { role: "user", content: [{ type: "tool_result", tool_use_id: message.toolCallId, content: textOf(message), is_error: message.isError === true }] }
      });
    }
  }
  return lines.map((line) => JSON.stringify(line)).join("\n") + (lines.length ? "\n" : "");
}
function sessionEvents(session) {
  try {
    return session.snapshotEvents?.() ?? session.events ?? session.ownEvents?.() ?? [];
  } catch {
    return [];
  }
}
function lastAssistantText(session) {
  const events = sessionEvents(session);
  for (let i = events.length - 1; i >= 0; i--) {
    const event = events[i];
    if (event?.type === "assistant/message") return textOf(event.data?.message);
  }
  return "";
}
function stateHome() {
  const base = process.env.DSH_HOME || join2(homedir(), ".dsh");
  return join2(base, "state", "claude-compat");
}
function transcriptPath(agent) {
  return join2(stateHome(), "transcripts", `${String(agent.session.header.id).replace(/[^A-Za-z0-9_-]/g, "")}.jsonl`);
}
var exported = /* @__PURE__ */ new Map();
function syncTranscript(agent, cwd) {
  const path = transcriptPath(agent);
  const events = sessionEvents(agent.session);
  let done = exported.get(path);
  if (done === void 0 || done > events.length || !existsSync(path)) {
    mkdirSync(dirname2(path), { recursive: true, mode: 448 });
    writeFileSync(path, "", { mode: 384 });
    done = 0;
  }
  if (events.length > done) appendFileSync(path, toClaudeTranscript(events.slice(done), agent.session.header.id, cwd), { mode: 384 });
  exported.set(path, events.length);
  return path;
}
function dropTranscript(agent) {
  const path = transcriptPath(agent);
  exported.delete(path);
  rmSync(path, { force: true });
}

// src/plugin.ts
var COMPAT_VERSION = "0.1.0";
var SKILL_RANK = 450;
function createPlugin(spec) {
  const root = resolve2(spec.root);
  const manifest = readManifest(root);
  const pluginName = kebab(manifest.name);
  const id = `claude-compat-${pluginName}`;
  const commandPrefix = spec.commands?.prefix ?? pluginName;
  const hasAgents = () => !(spec.disableByDefault ?? []).includes("agents") && discoverAgents(root, spec.agents).length > 0;
  const harnessNote = () => [
    `> Loaded from the ${pluginName} Claude Code plugin into DeepSeek Harness. Plugin root: \`${root}\`.`,
    `> A Claude command \`/${pluginName}:<cmd>\` is the DSH command \`/${commandPrefix ? `${commandPrefix}-` : ""}<cmd>\`; when you cannot run it, do what its section here says.`,
    hasAgents() ? `> A Claude agent type \`${pluginName}:<agent>\` is the skill \`${pluginName}-agent-<agent>\`: load it and pass its role text to \`subagent\` or \`spawn_teammate\`.` : ""
  ].filter(Boolean).join("\n");
  function apply(host, config = {}) {
    if (!("inject" in host) || typeof host.inject !== "function" || !("on" in host) || typeof host.on !== "function") {
      throw new TypeError("claude-plugins-dsh: expected a Cordis context with inject() and on()");
    }
    const ctx = host;
    const disabled = new Set(config.disable ?? spec.disableByDefault ?? []);
    const enabled = (part) => !disabled.has(part);
    const warn = (msg) => (ctx.logger ?? console).warn(`[${id}] ${msg}`);
    if (enabled("skills") || enabled("agents")) ctx.inject(["skills"], (sub) => registerSkills(sub, enabled, warn));
    if (enabled("commands")) ctx.inject(["commands"], (sub) => registerCommands(sub, warn));
    if (enabled("instructions")) ctx.inject(["systemPrompt"], (sub) => registerInstructions(sub, warn));
    if (enabled("hooks")) registerHooks(ctx, warn);
  }
  function registerSkills(ctx, enabled, warn) {
    if (!ctx.skills?.registerProvider) return warn("skills service missing, skills not registered");
    const provider = {
      name: id,
      async list() {
        const candidates = [];
        if (enabled("skills")) {
          for (const skill of discoverSkills(root, spec.skills)) {
            candidates.push({
              name: skill.name,
              description: skill.description,
              ...skill.meta.whenToUse ? { whenToUse: skill.meta.whenToUse } : {},
              invocation: { modelInvocable: skill.meta["disable-model-invocation"] !== "true", userInvocable: skill.meta["user-invocable"] !== "false" },
              provider: id,
              source: "custom",
              path: skill.path,
              resourceBase: { kind: "directory", path: skill.base },
              rank: SKILL_RANK,
              locator: { kind: "skill", path: skill.path, base: skill.base }
            });
          }
        }
        if (enabled("agents")) {
          for (const agent of discoverAgents(root, spec.agents)) {
            candidates.push({
              name: `${pluginName}-agent-${agent.name}`,
              description: `Role brief for a delegated worker (${pluginName} agent "${agent.name}"). ${agent.description}`,
              invocation: { modelInvocable: true, userInvocable: true },
              provider: id,
              source: "custom",
              path: agent.path,
              resourceBase: { kind: "directory", path: dirname3(agent.path) },
              rank: SKILL_RANK,
              locator: { kind: "agent", path: agent.path }
            });
          }
        }
        return candidates;
      },
      async get(candidate) {
        const locator = candidate.locator;
        const text = readText(locator.path);
        if (text === void 0) return void 0;
        const { body } = parseFrontMatter(text);
        let content = expandPluginRoot(body, root);
        if (locator.kind === "skill") {
          content = `${harnessNote()}
> Relative paths in this skill resolve from \`${locator.base}\`.

${content}`;
        } else {
          const agent = discoverAgents(root, spec.agents).find((a) => a.path === locator.path);
          const tools = agent?.tools ? `
Original tool allowlist: ${agent.tools}. Respect it: do not use tools outside that list.` : "";
          content = [
            `# Delegated role: ${agent?.name ?? candidate.name}`,
            "",
            `This is a Claude Code agent definition from the ${pluginName} plugin. DSH has no agent types, so use it as a brief:`,
            "- To run this role, call `subagent` (or `spawn_teammate` for a durable teammate) with a prompt made of the role text below, then the concrete task, exact files, and the check that proves it done.",
            "- Pick the provider/model yourself; the original pin does not apply in DSH." + tools,
            "",
            "## Role text",
            "",
            content
          ].join("\n");
        }
        const definition = {
          name: candidate.name,
          description: candidate.description,
          invocation: candidate.invocation,
          provider: id,
          source: "custom",
          path: locator.path,
          content
        };
        if (candidate.resourceBase) definition.resourceBase = candidate.resourceBase;
        return definition;
      }
    };
    ctx.skills.registerProvider(() => provider);
  }
  function registerCommands(ctx, warn) {
    const commands = ctx.commands;
    if (!commands?.register) return;
    for (const command of discoverCommands(root, spec.commands)) {
      const name = commandPrefix ? `${commandPrefix}-${command.name}` : command.name;
      if (!/^[a-z][a-z0-9_-]*$/.test(name)) {
        warn(`command name ${name} is not valid, skipped`);
        continue;
      }
      try {
        commands.register({
          name,
          description: command.description,
          ...command.hint ? { input: { hint: command.hint } } : {},
          handler(invocation) {
            const text = readText(command.path);
            const body = text === void 0 ? command.body : parseFrontMatter(text).body;
            invocation.agent.followup({
              id: randomUUID2(),
              role: "user",
              content: [{ type: "text", text: `<command-name>/${pluginName}:${command.stem}</command-name>

${renderCommand(body, invocation.rawInput, root)}` }],
              source: { kind: "user" }
            });
            return { kind: "success", text: `/${name} queued` };
          }
        });
      } catch (error) {
        warn(`command /${name} not registered: ${error.message}`);
      }
    }
  }
  function registerInstructions(ctx, warn) {
    const files = spec.instructions ?? [];
    if (!files.length) return;
    if (!ctx.systemPrompt?.section) return warn("systemPrompt service missing, instructions not registered");
    ctx.systemPrompt.section({
      name: `${id}-instructions`,
      order: 450,
      interpolate: false,
      text: () => files.map((file) => {
        const raw = readText(resolve2(root, file));
        if (raw === void 0) return "";
        const stripped = stripClaudeOnlyBlocks(expandPluginRoot(raw, root));
        if (stripped.unterminated) warn(`${file}: <!--harness:claude-only--> has no closing <!--/harness-->, the rest of the file was dropped`);
        return stripped.text.trim();
      }).filter(Boolean).join("\n\n")
    });
  }
  function registerHooks(ctx, warn) {
    const only = spec.hooks?.events ? new Set(spec.hooks.events) : void 0;
    const hooks = readHooks(root).filter((hook) => !only || only.has(hook.event));
    if (!hooks.length) return;
    const byEvent = (event) => hooks.filter((hook) => hook.event === event);
    const stopBlocks = /* @__PURE__ */ new WeakMap();
    const tag = `${pluginName}-hook`;
    let workingDirectory;
    ctx.inject(["workingDirectory"], (sub) => {
      workingDirectory = sub.workingDirectory;
      sub.effect(() => () => {
        workingDirectory = void 0;
      });
    });
    const cwdOf = (agent) => {
      try {
        return workingDirectory?.get(agent.session) || agent.session.header.cwd || process.cwd();
      } catch {
        return agent.session.header.cwd || process.cwd();
      }
    };
    const envFor = (cwd) => {
      const env = { ...process.env, CLAUDE_PLUGIN_ROOT: root, CLAUDE_PROJECT_DIR: cwd, CLAUDE_HARNESS: "dsh", DSH_CLAUDE_COMPAT: COMPAT_VERSION };
      for (const [key, value] of Object.entries(spec.env ?? {})) env[key] = expandPluginRoot(String(value), root);
      return env;
    };
    const inputFor = (agent, event, cwd, extra = {}) => {
      let transcript = transcriptPath(agent);
      try {
        transcript = syncTranscript(agent, cwd);
      } catch (error) {
        warn(`transcript export failed: ${error.message}`);
      }
      return { session_id: String(agent.session.header.id), transcript_path: transcript, cwd, hook_event_name: event, permission_mode: "default", ...extra };
    };
    async function fire(event, agent, extra, options = {}) {
      const list = byEvent(event).filter(options.filter ?? (() => true));
      if (!list.length) return [];
      const cwd = cwdOf(agent);
      const input = inputFor(agent, event, cwd, extra);
      const env = envFor(cwd);
      const settled = await Promise.all(
        list.map(
          (hook) => runHook(hook, input, env, options.signal).catch((error) => ({ code: null, stdout: "", stderr: String(error?.message ?? error), timedOut: false }))
        )
      );
      return settled.map((result, index) => {
        const failed = !result.aborted && (result.timedOut || result.code !== 0 && result.code !== 2);
        if (failed) warn(`${event} hook exited ${result.code}: ${result.stderr.trim().slice(0, 300)}`);
        const interpreted = interpretHookResult(result, event);
        if (failed && list[index].onFailure === "block") {
          interpreted.decision = "block";
          interpreted.reason = `${pluginName} hook failed and its onFailure is "block": ${result.stderr.trim().slice(0, 300) || `exit ${result.code}`}`;
        }
        for (const notice of interpreted.notices) warn(`${event}: ${notice}`);
        return interpreted;
      });
    }
    const hookMessage = (event, text) => ({
      id: randomUUID2(),
      role: "user",
      content: [{ type: "text", text: `<${tag} event="${event}">
${escapeClosingTag(text, tag)}
</${tag}>` }],
      source: { kind: `plugin:${id}` }
    });
    const contextOf = (results) => results.flatMap((r) => r.context).filter(Boolean).join("\n\n");
    function injectContext(agent, event, results) {
      const text = contextOf(results);
      if (text) agent.inject(hookMessage(event, text));
    }
    const isSubagent = (agent) => agent.session.header.origin === "subagent";
    if (byEvent("SessionStart").length) {
      ctx.on("agent/created", async ({ agent, source, signal }) => {
        if (isSubagent(agent)) return;
        const results = await fire("SessionStart", agent, { source: source ?? "startup" }, { signal });
        injectContext(agent, "SessionStart", results);
      });
    }
    if (byEvent("UserPromptSubmit").length) {
      ctx.on("agent/pre-step", async (payload, next) => {
        const decision = await next();
        if (decision.kind !== "enter" || payload.signal?.aborted) return decision;
        const prompt = decision.messages.filter((m) => m?.source?.kind === "user").map(textOf).join("\n").trim();
        if (!prompt) return decision;
        const results = await fire("UserPromptSubmit", payload.agent, { prompt }, { signal: payload.signal });
        const blocked = results.find((r) => r.decision === "block");
        if (blocked) {
          const notice = `The ${pluginName} plugin blocked the user's last prompt: ${blocked.reason ?? "no reason given"}. Tell the user it was blocked and why. Do not act on it.`;
          return { ...decision, messages: [hookMessage("UserPromptSubmit", notice)] };
        }
        const text = contextOf(results);
        if (!text) return decision;
        return { ...decision, messages: [...decision.messages, hookMessage("UserPromptSubmit", text)] };
      });
    }
    if (byEvent("PreToolUse").length) {
      ctx.on("tools/pre-execute", async (exec, next) => {
        const agent = exec.agent;
        if (!agent) return next();
        const toolName = claudeToolName(exec.name);
        const matches = (hook) => matcherMatches(hook.matcher, toolName);
        if (!byEvent("PreToolUse").some(matches)) return next();
        const results = await fire(
          "PreToolUse",
          agent,
          { tool_name: toolName, tool_input: toClaudeToolInput(exec.name, parseArguments(exec.arguments)), tool_use_id: String(exec.callId) },
          { filter: matches, signal: exec.signal }
        );
        injectContext(agent, "PreToolUse", results);
        const deny = results.find((r) => r.decision === "deny" || r.decision === "block");
        if (deny) return { kind: "deny", reason: deny.reason || `denied by ${pluginName} hook` };
        const rewrote = results.find((r) => r.updatedInput !== void 0);
        if (rewrote) {
          return {
            kind: "deny",
            reason: `${pluginName} hook returned updatedInput, which DSH cannot apply; refusing to run the unmodified tool input`
          };
        }
        const ask = results.find((r) => r.decision === "ask");
        if (ask) {
          const reason = ask.reason || `${pluginName} hook asks for confirmation`;
          return { kind: "ask", reason, displayReason: { en: reason } };
        }
        const decision = await next();
        const allow = results.find((r) => r.decision === "allow");
        if (allow && decision.kind === "ask") return { kind: "allow" };
        return decision;
      });
    }
    if (byEvent("PostToolUse").length) {
      ctx.on("tools/post-execute", async (exec, result, next) => {
        const decision = await next();
        const agent = exec.agent;
        if (!agent) return decision;
        const toolName = claudeToolName(exec.name);
        const matches = (hook) => matcherMatches(hook.matcher, toolName);
        if (!byEvent("PostToolUse").some(matches)) return decision;
        const args = parseArguments(exec.arguments);
        const results = await fire(
          "PostToolUse",
          agent,
          {
            tool_name: toolName,
            tool_input: toClaudeToolInput(exec.name, args),
            tool_response: toClaudeToolResponse(exec.name, args, result),
            tool_use_id: String(exec.callId)
          },
          { filter: matches, signal: exec.signal }
        );
        const text = contextOf(results);
        const contexts = text ? [hookMessage("PostToolUse", text)] : [];
        const blocked = results.find((r) => r.decision === "block" || r.decision === "deny");
        if (blocked) {
          return {
            kind: "block",
            feedback: [{ type: "text", text: blocked.reason || `blocked by ${pluginName} hook` }],
            ...contexts.length ? { additionalContexts: contexts } : {}
          };
        }
        if (!contexts.length) return decision;
        if (decision.kind === "accept" || decision.kind === "block") {
          return { ...decision, additionalContexts: [...decision.additionalContexts ?? [], ...contexts] };
        }
        return decision;
      });
    }
    if (byEvent("Stop").length || byEvent("SubagentStop").length) {
      ctx.on("agent/turn-stopping", async ({ agent, signal }) => {
        if (signal?.aborted) return;
        const event = isSubagent(agent) ? "SubagentStop" : "Stop";
        if (!byEvent(event).length) return;
        const active = stopBlocks.get(agent) === true;
        const results = await fire(event, agent, { stop_hook_active: active, last_assistant_message: lastAssistantText(agent.session) }, { signal });
        const block = results.find((r) => r.decision === "block");
        if (block && !active) {
          stopBlocks.set(agent, true);
          agent.steer(hookMessage(event, block.reason ?? "A plugin hook asked for one more step."));
        } else {
          stopBlocks.set(agent, false);
        }
      });
    }
    ctx.on("agent/disposed", ({ agent }) => {
      const done = byEvent("SessionEnd").length ? fire("SessionEnd", agent, { reason: "other" }) : Promise.resolve([]);
      done.catch((error) => {
        warn(`SessionEnd: ${error.message}`);
        return [];
      }).finally(() => {
        try {
          dropTranscript(agent);
        } catch {
        }
      });
    });
  }
  return { name: id, apply };
}
function rootFrom(importMetaUrl) {
  const candidate = resolve2(dirname3(fileURLToPath(importMetaUrl)), "..");
  if (!existsSync2(join3(candidate, ".claude-plugin"))) throw new Error(`claude-plugins-dsh: no .claude-plugin under ${candidate}`);
  return candidate;
}
export {
  COMPAT_VERSION,
  DEFAULT_HOOK_TIMEOUT_S,
  SKILL_RANK,
  TOOL_NAME_MAP,
  claudeToolName,
  createPlugin,
  discoverAgents,
  discoverCommands,
  discoverSkills,
  escapeClosingTag,
  expandPluginRoot,
  interpretHookResult,
  kebab,
  matcherMatches,
  parseFrontMatter,
  readHooks,
  readManifest,
  readText,
  renderCommand,
  rootFrom,
  runHook,
  stripClaudeOnly,
  stripClaudeOnlyBlocks,
  toClaudeToolInput,
  toClaudeToolResponse,
  toClaudeTranscript
};
