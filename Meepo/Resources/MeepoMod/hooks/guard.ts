/** ~/.meepo/guard.json as Meepo writes it (AppStore.writeGuard): the commands an important project asks before
 *  ("ssh", "docker exec"), and each important project's path → its Postgres MCP servers. */
export type Guard = { commands: string[], projects: Record<string, string[]> }

/** Why an important project's session asks before this tool call, or undefined to let it through. A command
 *  counts anywhere in the line: after ; && | $( ` a quote or `bash -c`. `mcp`: the project's Postgres servers. */
export function askReason(tool: string, input: Record<string, unknown>, mcp: string[], commands: string[]): string | undefined {
  if (tool === 'Bash' && commands.length > 0) {
    const words = commands.map(c => c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/ +/g, '\\s+')).join('|')
    const found = String(input.command).match(new RegExp(`(^|[\\s;&|(\`'"])(${words})(?=\\s|$|['"])`))
    if (found) return `Important project: this command reaches a server or a database (${found[2]}).`
  }
  if (mcp.some(name => tool.startsWith(`mcp__${name}__`))) return `Important project: ${tool} queries its database.`
  return undefined
}

/** The important project containing `root` (a worktree sits inside its project); undefined when there's none. */
export function importantProject(projects: Record<string, string[]>, root: string): string[] | undefined {
  const path = Object.keys(projects).filter(p => root === p || root.startsWith(p + '/')).sort((a, b) => b.length - a.length)[0]
  return path === undefined ? undefined : projects[path]
}
