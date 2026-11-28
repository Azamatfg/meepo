import { test, expect } from 'claude-code/testing'
import { contextReport } from './context'

test('the breakdown reaches Meepo as parts, files, skills and MCP servers summed per server', () => {
  const context = { percent: 41, tokens: 82000, window: 200000, breakdown: {
    isAutoCompactEnabled: true, autoCompactThreshold: 167000,
    categories: [{ name: 'Messages', tokens: 61000, kind: 'used', color: 'x', isDeferred: false }],
    memoryFiles: [{ path: '/p/CLAUDE.md', type: 'Project', tokens: 2400 }],
    skills: { totalSkills: 1, includedSkills: 1, tokens: 90, skillFrontmatter: [{ name: 'deliver', source: 'projectSettings', tokens: 90 }] },
    mcpTools: [{ name: 'a', serverName: 'figma', tokens: 4000, isLoaded: true }, { name: 'b', serverName: 'figma', tokens: 3000, isLoaded: false }],
  } }
  expect(contextReport(context, 'c1')).toEqual({
    hook_event_name: 'ContextUsage', session_id: 'c1', percent: 41, tokens: 82000, window: 200000, autoCompactAt: 167000,
    categories: [{ name: 'Messages', tokens: 61000, kind: 'used' }],
    memoryFiles: [{ path: '/p/CLAUDE.md', type: 'Project', tokens: 2400 }],
    skills: [{ name: 'deliver', tokens: 90 }],
    mcp: [{ server: 'figma', tokens: 7000 }],
  })
})

test('auto-compact off and no breakdown', () => {
  expect(contextReport({ window: 1, breakdown: { isAutoCompactEnabled: false, autoCompactThreshold: 5 } }, 'c1')?.autoCompactAt).toBeUndefined()
  expect(contextReport({ window: 1 }, 'c1')).toBeUndefined()
})
