import { test, expect, mock } from 'claude-code/testing'
import { askReason, importantProject } from './guard'

const HOME = '/Users/me'
// As AppStore.writeGuard writes it from serverAndDatabaseAsks.
const COMMANDS = ['ssh', 'scp', 'rsync', 'sftp', 'docker exec', 'docker compose exec', 'kubectl', 'psql', 'pg_dump', 'mysql']

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

/** The world beneath the mod: Meepo's files, the session's root and Meepo's EventServer. `posts`: what reached
 *  Meepo; `reached`: the tool calls that got past the mod to the permission flow. */
function world(on: any, root: string, reply = '') {
  const posts: any[] = [], reached: string[] = []
  mock.env(on, { HOME, MEEPO_SESSION_ID: '7', MEEPO_PORT: '47800' })
  on('session.root', () => ({ value: root }))
  on('session.cwd', () => ({ value: root }))
  on('session.id', () => ({ value: 'claude-id' }))
  on('fs.read', ($: any, e: any) => {
    if (e.path === `${HOME}/.meepo/guard.json`) return { value: JSON.stringify({ commands: COMMANDS, projects: { '/work/app': ['prod_db'] } }) }
    if (e.path === `${HOME}/.meepo/token`) return { value: 'secret\n' }
    return { deny: `no such file: ${e.path}` }
  })
  on('http.fetch', ($: any, e: any) => {
    posts.push({ url: e.url, headers: e.init.headers, body: JSON.parse(e.init.body) })
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

test('PreToolUse reaches Meepo in the shape meepo-bridge.sh sent', async ($, on) => {
  const { posts } = world(on, '/work/other')
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(posts[0].url).toBe('http://127.0.0.1:47800/event')
  expect(posts[0].headers).toEqual({ 'Content-Type': 'application/json', 'X-Meepo-Token': 'secret', 'X-Meepo-Session': '7' })
  expect(posts[0].body).toEqual(expect.objectContaining({
    hook_event_name: 'PreToolUse', session_id: 'claude-id', cwd: '/work/other', tool_name: 'Bash', tool_input: { command: 'ls' } }))
})

test("Meepo's reply to a prompt becomes context for Claude", async ($, on) => {
  const { posts } = world(on, '/work/app', '[Meepo] Teammates pushed 1 new commit')
  on('classic.UserPromptSubmit', () => ({}))
  const result: any = await ($ as any).classic.UserPromptSubmit({ prompt: 'hi' })
  expect(result.additionalContext).toEqual(['[Meepo] Teammates pushed 1 new commit'])
  expect(posts[0].body.hook_event_name).toBe('UserPromptSubmit')
})
