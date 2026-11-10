import test from 'node:test'
import assert from 'node:assert/strict'
import { cpSync, existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = dirname(dirname(fileURLToPath(import.meta.url)))

function resolveDependency(adapterDir) {
  const script = `const { createRequire } = require('node:module');
const requireFromAdapter = createRequire(process.argv[1] + '/index.js');
try {
  const path = requireFromAdapter.resolve('claude-plugin-dsh');
  const pkg = requireFromAdapter('claude-plugin-dsh/package.json');
  console.log(JSON.stringify({ path, version: pkg.version }));
} catch (error) {
  console.error('dependency resolution failed:', error.code);
  process.exit(1);
}`
  const result = spawnSync(process.execPath, ['-e', script, adapterDir], { encoding: 'utf8' })
  assert.equal(result.status, 0, `dependency resolution failed: ${result.stderr.trim()}`)
  return JSON.parse(result.stdout)
}

test('standalone adapter loads the published runtime and registers useful content', async () => {
  assert.ok(existsSync(join(root, 'dsh/package.json')), 'adapter manifest must exist')
  const manifest = JSON.parse(readFileSync(join(root, 'dsh/package.json'), 'utf8'))
  assert.equal(manifest.dependencies['claude-plugin-dsh'], '0.1.0')
  assert.equal(manifest.version, JSON.parse(readFileSync(join(root, '.claude-plugin/plugin.json'), 'utf8')).version)
  assert.ok(!existsSync(join(root, 'dsh/claude-compat.js')))
  assert.match(readFileSync(join(root, 'dsh/index.js'), 'utf8'), /from ['"]claude-plugin-dsh['"]/)

  const temp = realpathSync(mkdtempSync(join(tmpdir(), 'repo-intel-dsh-')))
  try {
    const fixture = join(temp, 'plugin')
    cpSync(root, fixture, { recursive: true, filter: (source) => !['.git', 'node_modules'].includes(source.split('/').at(-1)) })
    const install = spawnSync('bun', ['install', '--frozen-lockfile'], { cwd: join(fixture, 'dsh'), encoding: 'utf8' })
    assert.equal(install.status, 0, `frozen install failed: ${install.stdout}\n${install.stderr}`)
    const dependency = resolveDependency(join(fixture, 'dsh'))
    assert.equal(dependency.version, '0.1.0')
    assert.ok(dependency.path.startsWith(join(fixture, 'dsh/node_modules/claude-plugin-dsh/')), dependency.path)
    console.log(`installed runtime ${dependency.version}: ${dependency.path}`)

    const { apply, name } = await import(`${new URL(`file://${fixture}/dsh/index.js`).href}`)
    const seen = { providers: [], sections: [], events: [], warnings: [] }
    const ctx = {
      logger: { warn: (message) => seen.warnings.push(message) },
      skills: { registerProvider: (factory) => seen.providers.push(factory({ signal: new AbortController().signal, invalidate() {} })) },
      commands: { register() {} },
      systemPrompt: { section: (section) => seen.sections.push(section) },
      workingDirectory: { get: () => fixture },
      inject: (_services, callback) => callback(ctx),
      effect() {},
      on: (event) => seen.events.push(event),
    }
    await apply(ctx, {})
    assert.equal(name, 'claude-compat-repo-intel')
    assert.deepEqual(seen.warnings, [])
    assert.equal(seen.providers.length, 1)
    const provider = seen.providers[0]
    const skills = await provider.list({})
    assert.deepEqual(skills.map((skill) => skill.name).sort(), ['repo-intel-build', 'repo-intel-route', 'repo-intel-setup'])
    for (const skill of skills) {
      const body = (await provider.get(skill, {})).content
      assert.match(body, /repo-intel/i)
      assert.ok(body.trim().length > 100, `${skill.name} has a substantive body`)
    }
    assert.equal(seen.sections.length, 1)
    assert.match(seen.sections[0].text({}), /codegraph/i)
    assert.match(seen.sections[0].text({}), /graphify/i)
    assert.ok(seen.events.includes('tools/pre-execute'))
    assert.ok(!seen.events.includes('agent/created'))
    console.log(`registered skills: ${skills.map((skill) => skill.name).sort().join(', ')}; instruction: codegraph, graphify; hook: tools/pre-execute`)
  } finally {
    rmSync(temp, { recursive: true, force: true })
  }
})

test('dependency resolution check rejects a missing runtime at its assertion', () => {
  const temp = mkdtempSync(join(tmpdir(), 'repo-intel-no-dsh-'))
  try {
    assert.throws(() => resolveDependency(temp), /dependency resolution failed:.*MODULE_NOT_FOUND/)
  } finally {
    rmSync(temp, { recursive: true, force: true })
  }
})
