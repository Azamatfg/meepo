import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'
import type { Waiting } from '../types'
import { askReason, FILE_TOOLS, guidedReason, importantProject, type Guard } from './guard'

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
  on('classic.PostToolUse', forward)
  on('classic.PostToolUseFailure', forward)
  on('classic.PermissionRequest', forward)
  on('classic.PermissionDenied', forward)
  on('classic.Notification', forward)
  on('classic.Stop', forward)
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
    return reason ? { ask: reason } : next(e)
  }).catch(($, e, next) => next.called ? next(e) : { ask: 'Meepo couldn’t check this call, so it asks.' })
}
