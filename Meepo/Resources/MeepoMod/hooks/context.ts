/** What Meepo's Context panel shows of `$.session.usage({ breakdown })`: the parts, memory files, skills and MCP
 *  servers with their tokens — the grid and per-tool lists stay here (ContextUsage.swift reads this shape). */
export function contextReport(context: any, sessionId: string) {
  const b = context?.breakdown
  if (!b) return undefined
  const servers: Record<string, number> = {}
  for (const tool of b.mcpTools ?? []) servers[tool.serverName] = (servers[tool.serverName] ?? 0) + tool.tokens
  return {
    hook_event_name: 'ContextUsage', session_id: sessionId,
    percent: context.percent, tokens: context.tokens, window: context.window,
    autoCompactAt: b.isAutoCompactEnabled ? b.autoCompactThreshold : undefined,
    categories: (b.categories ?? []).map((c: any) => ({ name: c.name, tokens: c.tokens, kind: c.kind })),
    memoryFiles: (b.memoryFiles ?? []).map((f: any) => ({ path: f.path, type: f.type, tokens: f.tokens })),
    skills: (b.skills?.skillFrontmatter ?? []).map((s: any) => ({ name: s.name, tokens: s.tokens })),
    mcp: Object.entries(servers).map(([server, tokens]) => ({ server, tokens })),
  }
}
