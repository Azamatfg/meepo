/** A step to show the person, as Meepo's `/inbox` lists it: waiting for their click (`canRun`, a deploy), or
 *  under way — running, or queued. */
export type Waiting = { key: string; text: string; canRun: boolean }

declare module 'claude-code' {
  interface PluginState {
    meepo: { waiting: Waiting[] }
  }
}
