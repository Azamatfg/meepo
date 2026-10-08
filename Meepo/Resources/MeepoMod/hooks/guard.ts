/** ~/.meepo/guard.json as Meepo writes it (AppStore.writeGuard): the commands an important project asks before
 *  ("ssh", "docker exec"), each important project's path → its Postgres MCP servers, and while guided mode is on,
 *  what it asks before everywhere: commands hard to take back ("git push") and secrets files (".env"). */
export type Guard = { commands: string[], projects: Record<string, string[]>, guided?: { commands: string[], files: string[] },
  checks?: Record<string, string> }

/** What sends commits out: Meepo's method asks before them when the commit wasn't checked. */
export const SHIP_COMMANDS = ['git push', 'gh pr create']

/** The tools that change files: guided mode asks before they touch a secrets file. */
export const FILE_TOOLS = ['Edit', 'Write', 'MultiEdit']

/** The first of `commands` a Bash call runs, anywhere in its line: after ; && | $( ` a quote or `bash -c`. */
export function findCommand(tool: string, input: Record<string, unknown>, commands: string[]): string | undefined {
  if (tool !== 'Bash' || commands.length === 0) return undefined
  const line = String(input.command)
  const words = commands.map(c => c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/ +/g, '\\s+')).join('|')
  return line.match(new RegExp(`(^|[\\s;&|(\`'"])(${words})(?=\\s|$|['"])`))?.[2]
}

/** Why an important project's session asks before this tool call, or undefined to let it through.
 *  `mcp`: the project's Postgres servers. */
export function askReason(tool: string, input: Record<string, unknown>, mcp: string[], commands: string[]): string | undefined {
  const found = findCommand(tool, input, commands)
  if (found) return `Important project: this command reaches a server or a database (${found}).`
  if (mcp.some(name => tool.startsWith(`mcp__${name}__`))) return `Important project: ${tool} queries its database.`
  return undefined
}

/** Why guided mode asks before this tool call, or undefined to let it through. */
export function guidedReason(tool: string, input: Record<string, unknown>, guided: { commands: string[], files: string[] }): string | undefined {
  const found = findCommand(tool, input, guided.commands)
  if (found) return `Guided mode: ${found} is hard to take back, so it asks first.`
  const file = typeof input.file_path === 'string' ? input.file_path.split('/').at(-1) : undefined
  if (FILE_TOOLS.includes(tool) && file && guided.files.some(prefix => file.startsWith(prefix))) {
    return `Guided mode: ${file} holds secrets, so changing it asks first.`
  }
  return undefined
}

/** The important project containing `root` (a worktree sits inside its project); undefined when there's none. */
export function importantProject(projects: Record<string, string[]>, root: string): string[] | undefined {
  return containing(projects, root)
}

/** Meepo's method, VERIFY: the check of the project containing `root`, as `importantProject` finds it. */
export function projectCheck(checks: Record<string, string>, root: string): string | undefined {
  return containing(checks, root)
}

function containing<T>(byPath: Record<string, T>, root: string): T | undefined {
  const path = Object.keys(byPath).filter(p => root === p || root.startsWith(p + '/')).sort((a, b) => b.length - a.length)[0]
  return path === undefined ? undefined : byPath[path]
}

/** What Claude reads when the check fails: the command and the end of its output, where the error usually is. */
export function checkFailure(command: string, output: string): string {
  const tail = output.trimEnd().split('\n').slice(-40).join('\n')
  return `The project's check failed: ${command}\nFix it, then finish.\n\n${tail}`
}
