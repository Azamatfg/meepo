import type { Register } from 'claude-code'
import { askReason, importantProject, type Guard } from './guard'

// Loaded only into the sessions Meepo starts (`claude --plugin-dir ~/.meepo/mod`), which carry MEEPO_SESSION_ID.
// It does what meepo-bridge.sh does for them (that script steps aside when MEEPO_MOD is set), plus the guard.

/** A file of Meepo's in ~/.meepo, '' when missing. */
async function meepoFile($: any, name: string): Promise<string> {
  return $.fs.read(`${await $.env.get('HOME')}/.meepo/${name}`).catch(() => '')
}

/** Sends a hook event to Meepo's EventServer, as meepo-bridge.sh does; returns Meepo's reply. */
async function post($: any, payload: object) {
  const session = await $.env.get('MEEPO_SESSION_ID')
  const port = await $.env.get('MEEPO_PORT')
  if (!session || !port) return ''
  const token = (await meepoFile($, 'token')).trim()
  const res = await $.http.fetch(`http://127.0.0.1:${port}/event`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Meepo-Token': token, 'X-Meepo-Session': session },
    body: JSON.stringify(payload),
  }).catch(() => undefined)
  return res?.ok ? res.text.trim() : ''
}

async function forward($: any, e: any, next: any) {
  await post($, e)
  return next(e)
}

/** ~/.meepo/guard.json, which Meepo rewrites on every Important toggle: a running session follows it, no restart. */
async function readGuard($: any): Promise<Guard> {
  return { commands: [], projects: {}, ...JSON.parse((await meepoFile($, 'guard.json')) || '{}') }
}

export const register: Register = on => {
  // Same events as BridgeInstaller.events; Meepo's reply to a prompt is context for Claude.
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
    const reply = await post($, e)
    const result = await next(e)
    return reply ? { ...result, additionalContext: [...(result.additionalContext ?? []), reply] } : result
  })

  // classic.PreToolUse carries only the tool call: Meepo gets the hook's stdin shape rebuilt.
  on('classic.PreToolUse', async ($, e, next) => {
    const { tool, tool_use_id, mcp_server, ...input } = e as any
    await post($, { hook_event_name: 'PreToolUse', session_id: await $.session.id(), cwd: await $.session.cwd(),
      tool_name: tool, tool_use_id, tool_input: input })
    if (tool !== 'Bash' && !tool.startsWith('mcp__')) return next(e)
    const guard = await readGuard($)
    const mcp = importantProject(guard.projects, await $.session.root())
    const reason = mcp && askReason(tool, input, mcp, guard.commands)
    return reason ? { ask: reason } : next(e)
  }).catch(($, e, next) => next.called ? next(e) : { ask: 'Meepo couldn’t check this against the important project, so it asks.' })
}
