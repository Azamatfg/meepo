import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'
import type { Waiting } from '../types'
import { askReason, checkFailure, FILE_TOOLS, findCommand, guidedReason, importantProject, projectCheck, SHIP_COMMANDS, type Guard } from './guard'

/** What waits for the person's click in this session's project (a deploy), as of Meepo's last answer. */
const waiting = atom({ plugin: 'meepo', key: 'waiting' } as const, [])

// Loaded only into the sessions Meepo starts (`claude --plugin-dir ~/.meepo/mod`), which carry MEEPO_SESSION_ID.
// It does what meepo-bridge.sh does for them (that script steps aside when MEEPO_MOD is set), plus the guard.

/** A file of Meepo's in ~/.meepo, '' when missing. */
async function meepoFile($: any, name: string): Promise<string> {
  return $.fs.read(`${await $.env.get('HOME')}/.meepo/${name}`).catch(() => '')
}

/** Asks Meepo's EventServer: `/event` with a hook event, as meepo-bridge.sh does, `/inbox` or `/run`; returns its
 *  reply. */
async function post($: any, path: '/event' | '/inbox' | '/run', payload: object = {}) {
  const session = await $.env.get('MEEPO_SESSION_ID')
  const port = await $.env.get('MEEPO_PORT')
  if (!session || !port) return ''
  const token = (await meepoFile($, 'token')).trim()
  const res = await $.http.fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Meepo-Token': token, 'X-Meepo-Session': session },
    body: JSON.stringify(payload),
  }).catch(() => undefined)
  return res?.ok ? res.text.trim() : ''
}

/** Meepo's news for this session (CI and deploy of its branch, …), every 10 s: Claude reads each as context on
 *  its next step — a quiet session isn't woken — and the person sees it as a toast. Also what waits for them. */
async function startInbox($: any, e: any, next: any) {
  const started = await next(e)
  $.clock.every(10_000, () => checkInbox($))
  return started
}

async function checkInbox($: any) {
  const reply: { notes?: string[], waiting?: Waiting[] } = JSON.parse((await post($, '/inbox')) || '{}')
  // Kept as it is when nothing changed: a write redraws the band in every session, every 10 s.
  const fresh = reply.waiting ?? []
  await update($, waiting, old => (JSON.stringify(old) === JSON.stringify(fresh) ? old : fresh))
  for (const text of reply.notes ?? []) {
    $.ui.toast(text, { timeoutMs: 8000 })
    await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } })
  }
}

/** Above the prompt, only while there's something: "ocpi · Deploy waits for you — “…” [Run]", and once started
 *  "… is running · 2 min" or "… is queued · 6 min, no runner has taken it". Run asks Meepo, which confirms in its
 *  window as its CI panel does — nothing starts from the terminal alone. */
async function waitingBand($: any, e: any, next: any) {
  const items: Waiting[] = await read($, waiting)
  if (items.length === 0 || e.props.hasSurvey) return next(e)
  const { Box, Button, Text } = $.ui.resolve(e)
  return (
    <Box flexDirection="column">
      {items.map(item => (
        <Box>
          <Text color={item.canRun ? 'yellow' : 'cyan'}>{item.text} </Text>
          {item.canRun && (
            <Button key={item.key} label="Run" onPress={async () => {
              await post($, '/run', { key: item.key })
              $.ui.toast('Confirm it in meepo’s window')
            }} />
          )}
        </Box>
      ))}
    </Box>
  )
}

async function forward($: any, e: any, next: any) {
  await post($, '/event', e)
  return next(e)
}

/** Git trees (every file's content, as `git write-tree` names it) the project's check passed on, with the
 *  check: the same files aren't checked twice, and a push of a commit whose tree is here was checked. */
const checkedTrees = new Set<string>()
/** Failed checks in a row. A check Claude can't fix (a missing tool, no network) would block every Stop again:
 *  after the third the turn ends — Meepo shows "check failed" and gets the Stop. */
let failures = 0
const MAX_FAILURES = 3
/** Files may have changed since the last check: a file tool or a Bash command ran. A turn that only talked ends
 *  at once. */
let touched = false

/** Meepo's method, VERIFY: a turn that changed files ends only once the project's check passes; a failure goes
 *  back to Claude with the output (Claude Code caps how often a Stop may be blocked in a row). Meepo gets the
 *  result as a Verify event — the proof shown in What changed. */
async function verify($: any, e: any, next: any) {
  const root = await $.session.root()
  const command = projectCheck((await readGuard($)).checks ?? {}, root)
  if (!command || !touched) return forward($, e, next)
  const tree = await workingTree($, root)
  if (tree && checkedTrees.has(`${command}\n${tree}`)) { touched = false; return forward($, e, next) }
  const failure = await runCheck($, root, command, tree)
  if (failure && ++failures < MAX_FAILURES) return { block: failure }
  failures = 0
  touched = false
  return forward($, e, next)
}

/** Runs the check in the project folder with the person's shell and tells Meepo how it went (a Verify event).
 *  Passed: `tree` counts as checked, and the result is undefined; failed: what Claude reads. */
async function runCheck($: any, root: string, command: string, tree: string): Promise<string | undefined> {
  const shell = (await $.env.get('SHELL')) || '/bin/zsh'
  const run = await $.process.run([shell, '-l', '-c', command], { cwd: root, timeoutMs: 600_000 })
    .catch((error: any) => ({ exitCode: -1, stdout: '', stderr: `${error}` }))
  const passed = run.exitCode === 0
  await post($, '/event', { hook_event_name: 'Verify', session_id: await $.session.id(), cwd: root,
    message: `${passed ? 'passed' : 'failed'}: ${command}` })
  if (!passed) return checkFailure(command, `${run.stdout}\n${run.stderr}`)
  if (tree) checkedTrees.add(`${command}\n${tree}`)
  return undefined
}

/** The tree of the files as they are now, untracked ones included and ignored ones not — through an index of
 *  its own, so the person's staging stays as it was. '' outside git. */
async function workingTree($: any, root: string): Promise<string> {
  // Its own file per call: a Stop and a push asked at once mustn't share one.
  const env = { GIT_INDEX_FILE: `${await $.env.get('HOME')}/.meepo/index-${await $.env.get('MEEPO_SESSION_ID')}-${Math.random().toString(36).slice(2)}` }
  try {
    for (const argv of [['git', 'read-tree', 'HEAD'], ['git', 'add', '-A']]) {
      const step = await $.process.run(argv, { cwd: root, env }).catch(() => undefined)
      if (step?.exitCode !== 0) return ''
    }
    const tree = await $.process.run(['git', 'write-tree'], { cwd: root, env }).catch(() => undefined)
    return tree?.exitCode === 0 ? tree.stdout.trim() : ''
  } finally {
    await $.process.run(['rm', '-f', env.GIT_INDEX_FILE]).catch(() => undefined)
  }
}

/** Meepo's method, SHIP: why pushing asks — the commit going out has files the check didn't pass on — or
 *  undefined. Only in a project with a check: without one there's nothing to hold it to. When the files on disk
 *  are the commit's, the check just runs here: passing, the push goes on without a question. */
async function shipReason($: any, tool: string, input: Record<string, unknown>, guard: Guard): Promise<string | undefined> {
  const root = await $.session.root()
  const command = projectCheck(guard.checks ?? {}, root)
  if (!command || !findCommand(tool, input, SHIP_COMMANDS)) return undefined
  const head = await $.process.run(['git', 'rev-parse', 'HEAD^{tree}'], { cwd: root }).catch(() => undefined)
  if (head?.exitCode !== 0 || checkedTrees.has(`${command}\n${head.stdout.trim()}`)) return undefined
  if (await workingTree($, root) === head.stdout.trim()) {
    const failure = await runCheck($, root, command, head.stdout.trim())
    return failure && `Meepo's method: the check fails on what this pushes. Fix it, or allow to push anyway.\n\n${failure}`
  }
  return `Meepo's method: what this pushes wasn't checked since it last changed (${command}), and files changed since the commit. Commit or check first, or allow to push anyway.`
}

/** ~/.meepo/guard.json, which Meepo rewrites on every Important toggle: a running session follows it, no restart. */
async function readGuard($: any): Promise<Guard> {
  return { commands: [], projects: {}, ...JSON.parse((await meepoFile($, 'guard.json')) || '{}') }
}

export const register: Register = on => {
  // Same events as BridgeInstaller.events; Meepo's reply to a prompt is context for Claude.
  on('session.start', startInbox)
  on('ui.render', { component: 'AbovePrompt' }, waitingBand)
  on('classic.SessionStart', forward)
  on('classic.SessionEnd', forward)
  on('classic.PostToolUse', async ($, e, next) => {
    if ((e as any).tool_name === 'Bash' || FILE_TOOLS.includes((e as any).tool_name)) touched = true
    return forward($, e, next)
  })
  on('classic.PostToolUseFailure', forward)
  on('classic.PermissionRequest', forward)
  on('classic.PermissionDenied', forward)
  on('classic.Notification', forward)
  on('classic.Stop', verify)
  on('classic.StopFailure', forward)
  on('classic.PreCompact', forward)
  on('classic.UserPromptExpansion', forward)
  on('classic.UserPromptSubmit', async ($, e, next) => {
    const reply = await post($, '/event', e)
    const result = await next(e)
    return reply ? { ...result, additionalContext: [...(result.additionalContext ?? []), reply] } : result
  })

  // classic.PreToolUse carries only the tool call: Meepo gets the hook's stdin shape rebuilt.
  on('classic.PreToolUse', async ($, e, next) => {
    const { tool, tool_use_id, mcp_server, ...input } = e as any
    await post($, '/event', { hook_event_name: 'PreToolUse', session_id: await $.session.id(), cwd: await $.session.cwd(),
      tool_name: tool, tool_use_id, tool_input: input })
    if (tool !== 'Bash' && !tool.startsWith('mcp__') && !FILE_TOOLS.includes(tool)) return next(e)
    const guard = await readGuard($)
    const mcp = importantProject(guard.projects, await $.session.root())
    const reason = (mcp && askReason(tool, input, mcp, guard.commands)) || (guard.guided && guidedReason(tool, input, guard.guided))
      || await shipReason($, tool, input, guard)
    return reason ? { ask: reason } : next(e)
  }).catch(($, e, next) => next.called ? next(e) : { ask: 'Meepo couldn’t check this call, so it asks.' })
}
