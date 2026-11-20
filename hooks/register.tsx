import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { KillSwitchStatus } from '../types'

// Один запрос состояния — около 2 с процессорного времени (PowerShell грузит сетевые модули):
// раз в 30 с строка отстаёт ненамного, а ноутбук не греется. /killswitch status спрашивает сразу
const STATUS_POLL_PERIOD_MS = 30_000
const SCRIPT_TIMEOUT_MS = 20_000

// Тег меняется, когда меняются поля KillSwitchStatus: старое значение переживает перезагрузку мода
const lastStatus = atom({ plugin: 'killswitch', key: 'lastStatus' } as const, null, { shape: 'status-2' })

const THEME_COLOR_BY_STATUS = { Ok: 'success', Bad: 'error', Warn: 'warning', Neutral: 'inactive' } as const

const USAGE_TEXT = [
  '/killswitch          — состояние',
  '/killswitch menu     — открыть окно с настройками',
  '/killswitch install  — установить или переустановить (попросит UAC)',
  'Пауза и выключение — только в окне: так модель не выключит защиту по ошибочной просьбе.',
].join('\n')

// Скрипты лежат в папке windows/ плагина
async function runPowerShellScript($: any, scriptName: string, scriptArgs: string[]) {
  const { CLAUDE_PLUGIN_ROOT } = await $.process.hookEnv()
  const argv = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', `${CLAUDE_PLUGIN_ROOT}\\windows\\${scriptName}`, ...scriptArgs]
  return $.process.run(argv, { timeoutMs: SCRIPT_TIMEOUT_MS })
}

async function refreshStatus($: any): Promise<KillSwitchStatus | null> {
  try {
    const { exitCode, stdout } = await runPowerShellScript($, 'killswitch.ps1', ['-Status', '-Json'])
    const status: KillSwitchStatus | null = exitCode === 0 ? JSON.parse(stdout) : null
    await update($, lastStatus, () => status)
    return status
  } catch {
    // Не Windows или PowerShell не запустился — строку просто не показываем
    await update($, lastStatus, () => null)
    return null
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'killswitch',
      description: 'Claude VPN kill-switch: состояние, окно настроек, установка',
      argumentHint: '[status|menu|install]',
      // Без VPN Claude висит на повторах запроса — команда должна отвечать сразу
      immediate: true,
    })
    void refreshStatus($)
    $.clock.every(STATUS_POLL_PERIOD_MS, () => refreshStatus($))

    return next(e)
  })

  // Ответы команды только для человека: ни одного запроса к модели, работает и без VPN
  on('command.run', { command: 'killswitch' }, async ($, e) => {
    const subcommand = e.args.trim().toLowerCase() || 'status'

    if (subcommand === 'status') {
      const status = await refreshStatus($)
      const text = status === null
        ? 'Не удалось узнать состояние килл-свитча: он работает только в Windows, либо PowerShell не ответил за 20 с.'
        : `${status.title}. ${status.subtitle}\nVPN-туннель: ${status.tunnel}\nПравил брандмауэра: ${status.ruleCount}\nВерсия: ${status.version}`
      return { text, isTextDisplayOnly: true }
    }
    if (subcommand === 'menu') {
      await runPowerShellScript($, 'killswitch.ps1', ['-OpenMenu'])
      return { text: 'Окно Claude kill-switch открыто.', isTextDisplayOnly: true }
    }
    if (subcommand === 'install') {
      // Отдельным процессом: install.ps1 ждёт ответа в окне UAC, а хук команды столько ждать не может
      await runPowerShellScript($, 'killswitch.ps1', ['-StartInstall'])
      return { text: 'Установка запущена: подтвердите окно UAC. В конце откроется окно килл-свитча.', isTextDisplayOnly: true }
    }
    return { text: USAGE_TEXT, isTextDisplayOnly: true }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const status = await read($, lastStatus)
    if (e.props.hasSurvey || status === null) {
      return next(e)
    }
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box>
        <Text color={THEME_COLOR_BY_STATUS[status.color]}>◆ Килл-свитч: {status.title}</Text>
        <Text dimColor> · {status.subtitle}</Text>
      </Box>
    )
  })
}
