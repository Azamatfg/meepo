import { test, expect, mock } from 'claude-code/testing'
import { askReason, checkFailure, guidedReason, importantProject, projectCheck } from './guard'

const HOME = '/Users/me'
// As AppStore.writeGuard writes it from serverAndDatabaseAsks.
const COMMANDS = ['ssh', 'scp', 'rsync', 'sftp', 'docker exec', 'docker compose exec', 'kubectl', 'psql', 'pg_dump', 'mysql']
// As AppStore.writeGuard writes it from ClaudeLauncher.guidedAsks while guided mode is on.
const GUIDED = { commands: ['git push', 'git reset --hard', 'rm -rf', 'sudo', 'npm publish'], files: ['.env'] }

test('ssh asks wherever it sits in the command, bash -c included', () => {
  for (const command of [`ssh prod`, `bash -c 'echo hi && ssh -V'`, `cd x; psql -c 'select 1'`, `echo $(kubectl get pods)`,
                         `docker  compose exec db psql`, `sudo rsync -a . host:/srv`]) {
    expect(askReason('Bash', { command }, [], COMMANDS)).toContain('reaches a server or a database')
  }
})

test('commands that only mention a tool in a word run without asking', () => {
  for (const command of [`git status`, `ls ~/.ssh-keys`, `npm run mysqldump-docs`, `cat sshd_config`, `docker ps`]) {
    expect(askReason('Bash', { command }, [], COMMANDS)).toBeUndefined()
  }
})

test('a project Postgres MCP server asks, another MCP server does not', () => {
  expect(askReason('mcp__prod_db__query', {}, ['prod_db'], COMMANDS)).toContain('queries its database')
  expect(askReason('mcp__github__search', {}, ['prod_db'], COMMANDS)).toBeUndefined()
})

test('a worktree inside an important project is important; a sibling folder is not', () => {
  const projects = { '/work/app': ['prod_db'] }
  expect(importantProject(projects, '/work/app')).toEqual(['prod_db'])
  expect(importantProject(projects, '/work/app/.claude/worktrees/feat')).toEqual(['prod_db'])
  expect(importantProject(projects, '/work/app-old')).toBeUndefined()
})

test('guided mode asks before what is hard to take back, wherever it sits in the command', () => {
  for (const command of [`git push`, `bash -c 'npm test && git push origin main'`, `cd build; rm -rf dist`, `echo $(sudo ls)`]) {
    expect(guidedReason('Bash', { command }, GUIDED)).toContain('hard to take back')
  }
  for (const command of [`git status`, `git pushx`, `npm run rm-rf-docs`, `rm -r dist`]) {
    expect(guidedReason('Bash', { command }, GUIDED)).toBeUndefined()
  }
})

test('guided mode asks before changing a secrets file, not a file that only mentions env', () => {
  for (const tool of ['Edit', 'Write', 'MultiEdit']) {
    expect(guidedReason(tool, { file_path: '/work/app/.env.local' }, GUIDED)).toContain('.env.local holds secrets')
  }
  expect(guidedReason('Edit', { file_path: '/work/app/src/env.ts' }, GUIDED)).toBeUndefined()
  expect(guidedReason('Read', { file_path: '/work/app/.env' }, GUIDED)).toBeUndefined()
})

/** The world beneath the mod: Meepo's files, the session's root and Meepo's EventServer. `posts`: what reached
 *  Meepo; `reached`: the tool calls that got past the mod to the permission flow. */
function world(on: any, root: string, reply = '', guided?: typeof GUIDED) {
  const posts: any[] = [], reached: string[] = []
  mock.env(on, { HOME, MEEPO_SESSION_ID: '7', MEEPO_PORT: '47800' })
  on('session.root', () => ({ value: root }))
  on('session.cwd', () => ({ value: root }))
  on('session.id', () => ({ value: 'claude-id' }))
  on('fs.read', ($: any, e: any) => {
    if (e.path === `${HOME}/.meepo/guard.json`) return { value: JSON.stringify({ commands: COMMANDS, projects: { '/work/app': ['prod_db'] }, guided }) }
    if (e.path === `${HOME}/.meepo/token`) return { value: 'secret\n' }
    return { deny: `no such file: ${e.path}` }
  })
  on('http.fetch', ($: any, e: any) => {
    posts.push({ url: e.url, headers: e.init.headers, body: e.init.body && JSON.parse(e.init.body) })
    return { value: { status: 200, ok: true, headers: {}, text: reply } }
  })
  on('classic.PreToolUse', ($: any, e: any) => { reached.push(e.command); return {} })
  on('tool.call', () => ({ result: 'ran' }))
  return { posts, reached }
}

test('in an important project the asking call never reaches the rest of the flow; a harmless one does', async ($, on) => {
  const { reached } = world(on, '/work/app')
  await $.tool.call({ tool: 'Bash', command: `bash -c 'ssh prod'` })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(reached).toEqual(['ls'])
})

test('outside an important project ssh goes on as usual', async ($, on) => {
  const { reached } = world(on, '/work/other')
  await $.tool.call({ tool: 'Bash', command: 'ssh prod' })
  expect(reached).toEqual(['ssh prod'])
})

test('guided mode asks in any project, and only while it is on', async ($, on) => {
  const { reached } = world(on, '/work/other', '', GUIDED)
  await $.tool.call({ tool: 'Bash', command: `bash -c 'git push'` })
  await $.tool.call({ tool: 'Bash', command: 'git status' })
  expect(reached).toEqual(['git status'])
})

test('with guided mode off git push goes on as usual', async ($, on) => {
  const { reached } = world(on, '/work/other')
  await $.tool.call({ tool: 'Bash', command: 'git push' })
  expect(reached).toEqual(['git push'])
})

test('PreToolUse reaches Meepo in the shape meepo-bridge.sh sent', async ($, on) => {
  const { posts } = world(on, '/work/other')
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(posts[0].url).toBe('http://127.0.0.1:47800/event')
  expect(posts[0].headers).toEqual({ 'Content-Type': 'application/json', 'X-Meepo-Token': 'secret', 'X-Meepo-Session': '7' })
  expect(posts[0].body).toEqual(expect.objectContaining({
    hook_event_name: 'PreToolUse', session_id: 'claude-id', cwd: '/work/other', tool_name: 'Bash', tool_input: { command: 'ls' } }))
})

// The append into the conversation is checked live: the kit's test hooks don't answer a `$.session.append`
// made from a timer (2.1.291).
test("Meepo's news is picked up every 10 s and shown to the person", async ($, on) => {
  const { posts } = world(on, '/work/app', JSON.stringify({ notes: ['[Meepo] CI passed on main · “feat: x”: Build'], waiting: [] }))
  const toasts: string[] = []
  on('ui.toast', ($: any, e: any) => { toasts.push(e.text); return { value: undefined } })
  on('session.start', ($: any, e: any) => ({ cwd: e.cwd }))
  const clock = mock.clock(on)
  await ($ as any).session.start({ cwd: '/work/app', surface: 'terminal', isInteractive: true })
  expect(posts).toEqual([])
  await clock.advance(10_000)
  expect(posts[0].url).toBe('http://127.0.0.1:47800/inbox')
  expect(toasts).toEqual(['[Meepo] CI passed on main · “feat: x”: Build'])
})

test("Meepo's reply to a prompt becomes context for Claude", async ($, on) => {
  const { posts } = world(on, '/work/app', '[Meepo] Teammates pushed 1 new commit')
  on('classic.UserPromptSubmit', () => ({}))
  const result: any = await ($ as any).classic.UserPromptSubmit({ prompt: 'hi' })
  expect(result.additionalContext).toEqual(['[Meepo] Teammates pushed 1 new commit'])
  expect(posts[0].body.hook_event_name).toBe('UserPromptSubmit')
})

test('a worktree runs its project check; a project without one checks nothing', () => {
  const checks = { '/work/app': 'npm test' }
  expect(projectCheck(checks, '/work/app')).toBe('npm test')
  expect(projectCheck(checks, '/work/app/.claude/worktrees/feat')).toBe('npm test')
  expect(projectCheck(checks, '/work/app-old')).toBeUndefined()
})

test('a failed check tells Claude the command and the end of its output, where the error is', () => {
  const output = Array.from({ length: 100 }, (_, i) => `line ${i}`).join('\n') + '\nerror: x is undefined\n'
  const reason = checkFailure('npm test', output)
  expect(reason).toContain('npm test')
  expect(reason).toContain('error: x is undefined')
  expect(reason).not.toContain('line 50')
})
