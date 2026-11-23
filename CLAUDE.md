# Claude VPN kill-switch

Windows-брандмауэр не даёт exe Claude (CLI, десктоп, десктоп из Store, вкладка Code) выходить в сеть мимо VPN-адаптера.
Пользовательская документация — `README.md` (на русском). Код, комментарии, коммиты и релизы — тоже на русском.

## Устройство

- `windows/killswitch.ps1` — всё приложение: сторож (без параметров, от администратора, задача планировщика),
  окно (`-Menu`), статус (`-Status [-Json]`), обновление (`-Update`). PowerShell 5.1, файл в UTF-8 **с BOM**
  (без BOM 5.1 читает кириллицу как ANSI и ломается).
- `windows/install.ps1` — копирует в `C:\Program Files\ClaudeKillSwitch`, создаёт задачи и ярлыки, включает аудит 5157.
- `.claude-plugin/`, `hooks/register.tsx`, `types/` — плагин Claude Code: только строка состояния и `/killswitch`, ничего не блокирует.

## Правила

- Версия в двух местах, менять вместе: `$VERSION` в `windows/killswitch.ps1` и `version` в `.claude-plugin/plugin.json`.
- В `main` только готовое к выпуску: плагин и `/killswitch install` берут код прямо из `main`.
- Ничего не должно ослаблять блокировку. Правки уведомлений и UI — только поверх неизменных правил брандмауэра.

## Проверка

- Синтаксис: `[System.Management.Automation.Language.Parser]::ParseFile(...)` — 0 ошибок.
- Живая: `install.cmd` (UAC) → `& "$env:ProgramFiles\ClaudeKillSwitch\killswitch.ps1" -Status` → «Защищено».
- Блокировки (от администратора): `Get-WinEvent -FilterHashtable @{LogName='Security'; Id=5157}`;
  в событии `Properties[1]` — путь exe, `[5]`/`[6]` — адрес/порт назначения, `[2]` = `%%14593` — исходящее.

## Релиз

1. Поднять версию, закоммитить, запушить `main`.
2. Архив: `git archive --format=zip --prefix=claude-vpn-killswitch/ -o claude-vpn-killswitch.zip HEAD`
   (`.gitattributes` выкидывает `.github` и `CLAUDE.md`).
3. Релиз `v<версия>` с заголовком `Claude VPN kill-switch <версия>` и ассетом `claude-vpn-killswitch.zip` —
   кнопка «Обновить» качает именно `releases/latest/download/claude-vpn-killswitch.zip`.
   Текст релиза — как у прошлых: строка про установку, список изменений, ссылка «Все изменения» (compare).
