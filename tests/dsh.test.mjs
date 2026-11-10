import test from 'node:test'
import assert from 'node:assert/strict'
import { apply, name } from '../dsh/index.js'

async function registrations() {
  const seen = { providers: [], sections: [], events: [], warnings: [] }
  const ctx = {
    logger: { warn: (message) => seen.warnings.push(message) },
    skills: { registerProvider: (factory) => seen.providers.push(factory({ signal: new AbortController().signal, invalidate() {} })) },
    commands: { register() {} },
    systemPrompt: { section: (section) => seen.sections.push(section) },
    workingDirectory: { get: () => process.cwd() },
    inject: (_services, callback) => callback(ctx),
    effect() {},
    on: (event) => seen.events.push(event),
  }
  await apply(ctx, {})
  return seen
}

test('registers prefixed skills with readable content', async () => {
  const seen = await registrations()
  assert.equal(name, 'claude-compat-repo-intel')
  assert.deepEqual(seen.warnings, [])
  assert.equal(seen.providers.length, 1)
  const provider = seen.providers[0]
  const skills = await provider.list({})
  assert.deepEqual(skills.map((skill) => skill.name).sort(), [
    'repo-intel-build', 'repo-intel-route', 'repo-intel-setup',
  ])
  for (const skill of skills) assert.ok((await provider.get(skill, {})).content.trim())
})

test('registers the routing guidance and build guard without SessionStart', async () => {
  const seen = await registrations()
  assert.equal(seen.sections.length, 1)
  assert.match(seen.sections[0].text({}), /codegraph/i)
  assert.match(seen.sections[0].text({}), /graphify/i)
  assert.ok(seen.events.includes('tools/pre-execute'))
  assert.ok(!seen.events.includes('agent/created'))
})
