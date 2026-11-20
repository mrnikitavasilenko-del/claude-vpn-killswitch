# Ставит килл-свитч: копирует скрипт и значок в Program Files, регистрирует автозапуск сторожа,
# кладёт ярлыки окна на рабочий стол и в меню «Пуск».
# С -Uninstall — убирает всё обратно. Права администратора запросит сам.
param([switch]$Uninstall)

$TASK_NAME = 'Claude kill-switch'
$UPDATE_TASK_NAME = 'Claude kill-switch update'
$RULE_GROUP = 'Claude kill-switch'
$installDir = "$env:ProgramFiles\ClaudeKillSwitch"
# Сторож работает с правами администратора, поэтому лежит там, куда без админа не записать
$installedScriptPath = "$installDir\killswitch.ps1"
$installedIconPath = "$installDir\icon.ico"
$userTunnelDescriptionsPath = "$installDir\vpn-adapters.txt"
$menuShortcutPaths = @("$([Environment]::GetFolderPath('Desktop'))\Claude kill-switch.lnk",
                       "$([Environment]::GetFolderPath('Programs'))\Claude kill-switch.lnk")
$stateDir = "$env:LOCALAPPDATA\ClaudeKillSwitch"
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
# Аудит «Подключение платформы фильтрации»: пишет в журнал безопасности, кого и куда заблокировал брандмауэр.
# GUID вместо имени — имя подкатегории в auditpol зависит от языка Windows
$FIREWALL_CONNECTION_AUDIT_GUID = '{0CCE9226-69AE-11D9-BED3-505054503030}'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $elevatedArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Uninstall) { $elevatedArgs += ' -Uninstall' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $elevatedArgs -ErrorAction Stop
    } catch {
        # Отказ в окне UAC — иначе окно консоли молча закрылось бы
        'Установка отменена: без прав администратора килл-свитч не поставить.'
        Read-Host 'Нажмите Enter, чтобы закрыть окно'
    }
    return
}

# Сторожа останавливаем до удаления правил, иначе он их тут же пересоздаст
Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
# После установки защита в исходном состоянии: пауза и выключение сброшены. Выключенные уведомления оставляем
Remove-Item "$stateDir\paused-until-reboot", "$stateDir\autostart-off", "$stateDir\update-available" -Force -ErrorAction SilentlyContinue

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $UPDATE_TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Group $RULE_GROUP -ErrorAction SilentlyContinue
    auditpol /set /subcategory:$FIREWALL_CONNECTION_AUDIT_GUID /failure:disable | Out-Null
    Remove-Item (@($installDir, $stateDir) + $menuShortcutPaths) -Recurse -Force -ErrorAction SilentlyContinue
    'Claude kill-switch удалён.'
    Read-Host 'Нажмите Enter, чтобы закрыть окно'
    return
}

New-Item -ItemType Directory -Force $installDir | Out-Null
Remove-Item "$installDir\install.ps1" -ErrorAction SilentlyContinue   # оставался от версии с кнопкой «Удалить» в меню
Copy-Item "$PSScriptRoot\killswitch.ps1" $installedScriptPath -Force
Copy-Item "$PSScriptRoot\icon.ico" $installedIconPath -Force
Unblock-File $installedScriptPath   # снять пометку «скачано из интернета», если проект скачан с GitHub
# Файл своих VPN-адаптеров создаём один раз — переустановка и обновление его не трогают
if (-not (Test-Path $userTunnelDescriptionsPath)) {
    Set-Content $userTunnelDescriptionsPath -Encoding UTF8 -Value @(
        '# Описания адаптеров VPN, которые килл-свитч не узнаёт сам, — по одному в строке, целиком.'
        '# Описание адаптера показывает команда PowerShell: Get-NetAdapter | ft Name, InterfaceDescription'
        '# Пример строки: My VPN Virtual Adapter')
}
# Нужен для уведомления «Запрос Claude заблокирован»
auditpol /set /subcategory:$FIREWALL_CONNECTION_AUDIT_GUID /failure:enable | Out-Null

$watcherArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScriptPath`""
$taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $watcherArgs
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
# Без лимита времени (по умолчанию планировщик убивает задачу через 72 ч) и с перезапуском при падении
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TASK_NAME -Action $taskAction -Trigger $taskTrigger `
    -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
Start-ScheduledTask -TaskName $TASK_NAME

# Задача обновления: без расписания, её запускает кнопка «Обновить». С правами администратора — поэтому без окна UAC,
# а ставит она только последний релиз с GitHub. Перерегистрация во время обновления текущий запуск не обрывает (проверено)
$updateTaskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$watcherArgs -Update"
$updateTaskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $UPDATE_TASK_NAME -Action $updateTaskAction -Principal $taskPrincipal `
    -Settings $updateTaskSettings -Force | Out-Null

$shell = New-Object -ComObject WScript.Shell
foreach ($menuShortcutPath in $menuShortcutPaths) {
    $menuShortcut = $shell.CreateShortcut($menuShortcutPath)
    $menuShortcut.TargetPath = 'powershell.exe'
    $menuShortcut.Arguments = "$watcherArgs -Menu"
    $menuShortcut.IconLocation = "$installedIconPath,0"
    # 7 — свёрнутым: -WindowStyle Hidden прячет консоль не сразу, без этого она мелькает на экране
    $menuShortcut.WindowStyle = 7
    $menuShortcut.Save()
}

# Через explorer окно откроется без прав администратора, как при обычном щелчке по ярлыку
Start-Process explorer.exe "`"$($menuShortcutPaths[0])`""
