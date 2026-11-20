// Состояние килл-свитча, как его отдаёт `killswitch.ps1 -Status -Json`
export type KillSwitchStatus = {
  color: 'Ok' | 'Bad' | 'Warn' | 'Neutral'
  title: string
  subtitle: string
  tunnel: string
  ruleCount: number
  version: string
}

// Shaped виден внутри declare module 'claude-code' без import: контракт должен быть самодостаточным
declare module 'claude-code' {
  interface PluginState {
    // Shaped: у атома есть тег shape — он сбрасывает значение, сохранённое прошлой версией мода
    killswitch: { lastStatus: Shaped<KillSwitchStatus | null> }
  }
}
