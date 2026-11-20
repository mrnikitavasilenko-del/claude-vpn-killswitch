# Килл-свитч: Claude Code и десктопный Claude ходят в сеть только через VPN-туннель.
# Без параметров — фоновый сторож (запускает планировщик при входе, с правами администратора).
# С -Menu — окно с состоянием и настройками (права администратора не нужны).
# С -OpenMenu — открыть окно отдельным процессом и сразу вернуться (для /killswitch menu).
# С -StartInstall — запустить install.ps1 отдельным процессом и сразу вернуться (для /killswitch install):
#   окно UAC ждёт человека сколько угодно, а команда мода не может висеть.
# С -Status — состояние текстом (для /killswitch status).
# С -Status -Json — то же одной строкой JSON (для строки над полем ввода в Claude Code).
# С -Update — скачать последний релиз с GitHub и запустить его install.ps1 (кнопка «Обновить» в окне).
# С -LoadOnly — только объявить функции (окно так загружает их в фоновый поток).
param([switch]$Menu, [switch]$OpenMenu, [switch]$StartInstall, [switch]$Status, [switch]$Json, [switch]$Update, [switch]$LoadOnly)

# Версия = тег релиза на GitHub без «v». Кнопка «Обновить» ставит только релизы. Плагин и /killswitch install
# берут код из ветки main — поэтому в main только готовое к выпуску
$VERSION = '0.3.0'
$GITHUB_REPO = 'mrnikitavasilenko-del/claude-vpn-killswitch'
$LATEST_RELEASE_API_URL = "https://api.github.com/repos/$GITHUB_REPO/releases/latest"
$LATEST_RELEASE_ZIP_URL = "https://github.com/$GITHUB_REPO/releases/latest/download/claude-vpn-killswitch.zip"
$UPDATE_CHECK_PERIOD_H = 24
# При входе в Windows сеть поднимается не сразу — неудачную проверку повторяем скоро, а не через сутки
$UPDATE_RETRY_PERIOD_MIN = 10
# Проверка идёт в цикле сторожа — долго ждать GitHub нельзя
$UPDATE_CHECK_TIMEOUT_S = 10
$UPDATE_DOWNLOAD_TIMEOUT_S = 60

$TASK_NAME = 'Claude kill-switch'
$RULE_GROUP = 'Claude kill-switch'
$POLL_PERIOD_S = 5
$MENU_REFRESH_PERIOD_MS = 5000
# Как часто окно проверяет, готов ли фоновый опрос состояния
$MENU_POLL_PERIOD_MS = 100
# Claude Code повторяет запрос до 10 раз — уведомляем о блокировке не чаще раза в минуту
$BLOCKED_TOAST_COOLDOWN_S = 60
# Событие 5157 «WFP заблокировала подключение»; %%14593 — исходящее. Пишется, если установщик включил аудит
$BLOCKED_CONNECTION_EVENT_ID = 5157
$OUTBOUND_DIRECTION = '%%14593'
# Адаптеры VPN-клиентов узнаём по описанию драйвера. Адаптер неизвестного VPN попадёт под блок:
# Claude через него работать не будет, но и мимо VPN не уйдёт
$TUNNEL_ADAPTER_DESCRIPTION_PATTERN = 'Tunnel|Wintun|WireGuard|Amnezia|TAP-Win|OpenVPN|Happ|sing-box|AnyConnect|Fortinet'
# Свои описания адаптеров, по одному в строке. Лежит в Program Files: обновление его не трогает,
# а дописать в него адаптер (то есть разрешить Claude ходить через него) может только администратор
$userTunnelDescriptionsPath = "$env:ProgramFiles\ClaudeKillSwitch\vpn-adapters.txt"

# Флаги лежат у пользователя, чтобы меню переключало их без UAC; сторож только читает их
$stateDir = Join-Path $env:LOCALAPPDATA 'ClaudeKillSwitch'
$pausedUntilRebootFlagPath = Join-Path $stateDir 'paused-until-reboot'
$autostartOffFlagPath = Join-Path $stateDir 'autostart-off'
$notificationsOffFlagPath = Join-Path $stateDir 'notifications-off'
# Внутри — номер новой версии; пишет сторож, читают окно и /killswitch status
$availableUpdateFlagPath = Join-Path $stateDir 'update-available'

# PowerShell 5.1 по умолчанию не включает TLS 1.2, а GitHub без него не отвечает
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -EvenIfMuted — для ответа на действие человека (кнопка «Обновить»): его он ждёт и при выключенных уведомлениях
function Show-Toast($title, $body, [switch]$EvenIfMuted) {
    if ((Test-Path $notificationsOffFlagPath) -and -not $EvenIfMuted) { return }
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $toastXml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $toastXml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$title</text><text>$body</text></binding></visual></toast>")
    $powershellAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($powershellAppId).Show([Windows.UI.Notifications.ToastNotification]::new($toastXml))
}

# Сравнивает свою версию с последним релизом на GitHub. Новее — флаг и уведомление (одно на каждую версию).
# Возвращает, удалось ли узнать версию
function Update-AvailableUpdateFlag {
    try {
        $latestRelease = Invoke-RestMethod $LATEST_RELEASE_API_URL -TimeoutSec $UPDATE_CHECK_TIMEOUT_S
    } catch {
        return $false
    }
    $latestVersion = "$($latestRelease.tag_name)".TrimStart('v')
    if ($latestVersion -notmatch '^\d+(\.\d+)+$') { return $false }
    if ([version]$latestVersion -le [version]$VERSION) {
        Remove-Item $availableUpdateFlagPath -ErrorAction SilentlyContinue
        return $true
    }
    $isAlreadyNotified = (Get-Content $availableUpdateFlagPath -ErrorAction SilentlyContinue) -eq $latestVersion
    if (-not $isAlreadyNotified) {
        Set-Content $availableUpdateFlagPath $latestVersion
        Show-Toast 'Доступно обновление Claude kill-switch' "Версия $latestVersion. Обновить можно в окне Claude kill-switch."
    }
    $true
}

function Get-ClaudeExePaths {
    $cliExePaths = @("$env:USERPROFILE\.local\bin\claude.exe") +
        @((Get-ChildItem "$env:USERPROFILE\.local\share\claude\versions" -File -ErrorAction SilentlyContinue).FullName)
    # Десктоп ставит каждую версию в свою папку app-<версия>, поэтому список пересобирается каждый цикл.
    # Глубина 6 — чтобы достать и вспомогательные exe в resources\app.asar.unpacked
    $desktopExePaths = @((Get-ChildItem "$env:LOCALAPPDATA\AnthropicClaude" -Recurse -Depth 6 -Filter *.exe -ErrorAction SilentlyContinue).FullName)
    # Встроенный в десктоп Claude Code (вкладка Code): %APPDATA%\Claude\claude-code\<версия>\<хэш>\claude.exe
    $desktopCodeExePaths = @((Get-ChildItem "$env:APPDATA\Claude\claude-code" -Recurse -Depth 3 -Filter *.exe -ErrorAction SilentlyContinue).FullName)
    # Десктоп, установленный как MSIX (Microsoft Store, корпоративная раскатка)
    $storeExePaths = @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | ForEach-Object {
        (Get-ChildItem $_.InstallLocation -Recurse -Depth 2 -Filter *.exe -ErrorAction SilentlyContinue).FullName })
    @($cliExePaths + $desktopExePaths + $desktopCodeExePaths + $storeExePaths | Where-Object { $_ -and (Test-Path $_) } | Sort-Object)
}

# Встроенный список плюс описания из vpn-adapters.txt. Свои описания — как текст (скобки не ломают) и только целиком:
# слишком общее слово («Adapter», «Intel») иначе объявило бы туннелем физический адаптер
function Get-TunnelAdapterPattern {
    $userDescriptions = @(Get-Content $userTunnelDescriptionsPath -Encoding UTF8 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { "^$([regex]::Escape($_))$" })
    (@($TUNNEL_ADAPTER_DESCRIPTION_PATTERN) + $userDescriptions) -join '|'
}

function Get-TunnelAdapters {
    $tunnelPattern = Get-TunnelAdapterPattern
    @(Get-NetAdapter | Where-Object InterfaceDescription -match $tunnelPattern)
}

# Адаптер VPN может остаться Up после отключения — подключённым считаем, только если через него идёт интернет
# (маршрут по умолчанию или пара /1, как у OpenVPN)
function Test-TunnelConnected($tunnelAdapter) {
    $tunnelAdapter.Status -eq 'Up' -and [bool](Get-NetRoute -InterfaceIndex $tunnelAdapter.ifIndex -ErrorAction SilentlyContinue `
        -DestinationPrefix '0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1', '::/0')
}

# Считаем по реестру: Get-NetFirewallRule без прав администратора правил не видит, а вывод netsh зависит от языка Windows
function Get-ActiveRuleCount {
    $firewallRulesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
    $ruleGroupMarker = "|EmbedCtxt=$RULE_GROUP|"
    @((Get-ItemProperty $firewallRulesKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object {
        $_.Value -is [string] -and $_.Value.Contains($ruleGroupMarker) -and $_.Value.Contains('|Active=TRUE|') }).Count
}

# Всё, что показывают меню и /killswitch status, — без прав администратора
function Get-KillSwitchState {
    $tunnelAdapters = Get-TunnelAdapters
    $watcherTask = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    @{
        TunnelAdapters = $tunnelAdapters
        ConnectedTunnel = $tunnelAdapters | Where-Object { Test-TunnelConnected $_ } | Select-Object -First 1
        IsInstalled = [bool]$watcherTask
        IsWatcherRunning = $watcherTask.State -eq 'Running'
        IsPausedUntilReboot = Test-Path $pausedUntilRebootFlagPath
        IsAutostartOff = Test-Path $autostartOffFlagPath
        IsNotificationsOff = Test-Path $notificationsOffFlagPath
        AvailableUpdateVersion = Get-Content $availableUpdateFlagPath -ErrorAction SilentlyContinue
        ActiveRuleCount = Get-ActiveRuleCount
        IsNpmClaudeInstalled = Test-Path "$env:APPDATA\npm\claude.cmd"
    }
}

function Get-TunnelText($state) {
    if ($state.ConnectedTunnel) { "$($state.ConnectedTunnel.Name) · подключён" }
    elseif ($state.TunnelAdapters) { "$($state.TunnelAdapters[0].Name) · отключён" }
    else { 'не найден' }
}

# Итог одной строкой: цвет и значок для меню, заголовок и пояснение для меню и /killswitch status
function Get-ProtectionSummary($state) {
    if (-not $state.IsInstalled) {
        @{ Color = 'Bad'; Glyph = 'Warning'; Title = 'Килл-свитч не установлен'; Subtitle = 'Запустите install.cmd или команду /killswitch install.' }
    } elseif ($state.IsAutostartOff) {
        @{ Color = 'Neutral'; Glyph = 'Shield'; Title = 'Защита выключена'; Subtitle = 'Claude ходит в сеть без VPN.' }
    } elseif ($state.IsPausedUntilReboot) {
        @{ Color = 'Warn'; Glyph = 'Shield'; Title = 'Защита на паузе'; Subtitle = 'До перезагрузки Claude ходит в сеть без VPN.' }
    } elseif (-not $state.IsWatcherRunning) {
        @{ Color = 'Bad'; Glyph = 'Warning'; Title = 'Сторож не запущен'; Subtitle = 'Правила не обновляются. Перезагрузите компьютер или переустановите.' }
    } elseif ($state.ActiveRuleCount -eq 0) {
        # Зелёный щит только при реально действующих правилах. Искать exe Claude дорого — только здесь
        if (@(Get-ClaudeExePaths).Count -eq 0) {
            @{ Color = 'Neutral'; Glyph = 'Shield'; Title = 'Claude не найден'; Subtitle = 'Защита включится сама, когда Claude появится.' }
        } else {
            @{ Color = 'Bad'; Glyph = 'Warning'; Title = 'Защита не работает'; Subtitle = 'Правил блокировки нет — Claude может ходить мимо VPN.' }
        }
    } elseif ($state.ConnectedTunnel) {
        @{ Color = 'Ok'; Glyph = 'Shield'; Title = 'Защищено'; Subtitle = "Claude ходит в сеть только через $($state.ConnectedTunnel.Name)." }
    } else {
        @{ Color = 'Bad'; Glyph = 'Lock'; Title = 'Claude заблокирован'; Subtitle = 'Включите VPN — и Claude заработает.' }
    }
}

if ($LoadOnly) { return }

# Окно меню. WPF, а не WinForms: WPF векторный и не мылится на 4K и при масштабе 150–200 %.
# Цвета подставляются из палитры светлой/тёмной темы Windows через DynamicResource.
$MENU_XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude kill-switch" Width="424" SizeToContent="Height" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Margin" Value="16,0,16,12"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource SubText}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center" Margin="0,0,16,0"/>
              <Border x:Name="Track" Grid.Column="1" Width="40" Height="20" CornerRadius="10" VerticalAlignment="Center"
                      BorderThickness="1" BorderBrush="{DynamicResource SwitchOff}" Background="Transparent">
                <Ellipse x:Name="Thumb" Width="12" Height="12" Margin="4,0" HorizontalAlignment="Left" Fill="{DynamicResource SwitchOff}"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Thumb" Property="Fill" Value="{DynamicResource OnAccent}"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Area" Padding="14,5" CornerRadius="4" Background="{DynamicResource Accent}">
              <ContentPresenter TextElement.Foreground="{DynamicResource OnAccent}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Area" Property="Opacity" Value="0.9"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Кнопки заголовка: значок — Content (шрифт Segoe MDL2 Assets), скругление угла — Tag -->
    <Style x:Key="TitleButton" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Width="46" Height="36" Background="{TemplateBinding Background}"
                    CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}">
              <ContentPresenter TextElement.FontFamily="Segoe MDL2 Assets" TextElement.FontSize="10"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource HoverBg}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource TitleButton}">
      <Setter Property="Tag" Value="0,8,0,0"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#C42B1C"/>
          <Setter Property="Foreground" Value="White"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Border Margin="12" CornerRadius="8" Background="{DynamicResource Bg}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.3"/></Border.Effect>
    <StackPanel>
      <Grid x:Name="TitleBar" Height="36" Background="Transparent">
        <TextBlock x:Name="TitleText" Margin="16,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource SubText}"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="MinimizeButton" Style="{StaticResource TitleButton}" Content="&#xE921;"/>
          <Button x:Name="CloseButton" Style="{StaticResource CloseButton}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <Grid Margin="20,6,20,20">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Grid Width="56" Height="56" VerticalAlignment="Center">
          <Ellipse x:Name="HeroHalo" Opacity="0.16"/>
          <TextBlock x:Name="HeroGlyph" FontFamily="Segoe MDL2 Assets" FontSize="26"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="HeroTitle" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource Text}"/>
          <TextBlock x:Name="HeroSubtitle" Margin="0,3,0,0" Style="{StaticResource Caption}" FontSize="13"/>
        </StackPanel>
      </Grid>

      <Border x:Name="NpmWarning" Margin="16,0,16,12" Padding="14,10" CornerRadius="6" Background="{DynamicResource WarnBg}">
        <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Text}"
                   Text="Claude Code установлен через npm и работает как node.exe — килл-свитч его не блокирует. Поставьте нативную версию."/>
      </Border>

      <Border x:Name="UpdateCard" Style="{StaticResource Card}">
        <DockPanel>
          <Button x:Name="UpdateButton" DockPanel.Dock="Right" Style="{StaticResource AccentButton}" Content="Обновить" VerticalAlignment="Center"/>
          <TextBlock x:Name="UpdateText" VerticalAlignment="Center" Foreground="{DynamicResource Text}"/>
        </DockPanel>
      </Border>

      <Border Style="{StaticResource Card}">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <TextBlock Text="VPN-туннель" Margin="0,0,16,0" Foreground="{DynamicResource SubText}"/>
            <!-- Длинное имя адаптера обрезается многоточием, а не наезжает на подпись -->
            <DockPanel Grid.Column="1" HorizontalAlignment="Right">
              <Ellipse x:Name="TunnelDot" DockPanel.Dock="Left" Width="8" Height="8" Margin="0,1,8,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TunnelStateText" DockPanel.Dock="Right" Foreground="{DynamicResource Text}"/>
              <TextBlock x:Name="TunnelNameText" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource Text}"/>
            </DockPanel>
          </Grid>
          <DockPanel Margin="0,10,0,0">
            <TextBlock Text="Правил брандмауэра" Foreground="{DynamicResource SubText}"/>
            <TextBlock x:Name="RuleCountText" HorizontalAlignment="Right" Foreground="{DynamicResource Text}"/>
          </DockPanel>
        </StackPanel>
      </Border>

      <Border Style="{StaticResource Card}" Margin="16,0,16,16">
        <StackPanel>
          <CheckBox x:Name="ProtectionSwitch" Style="{StaticResource Switch}">
            <StackPanel>
              <TextBlock Text="Защита"/>
              <TextBlock x:Name="ProtectionCaption" Style="{StaticResource Caption}"/>
            </StackPanel>
          </CheckBox>
          <Border Height="1" Margin="0,12" Background="{DynamicResource CardBorder}"/>
          <CheckBox x:Name="AutostartSwitch" Style="{StaticResource Switch}">
            <StackPanel>
              <TextBlock Text="Запуск при входе в Windows"/>
              <TextBlock x:Name="AutostartCaption" Style="{StaticResource Caption}"/>
            </StackPanel>
          </CheckBox>
          <Border Height="1" Margin="0,12" Background="{DynamicResource CardBorder}"/>
          <CheckBox x:Name="NotificationsSwitch" Style="{StaticResource Switch}">
            <StackPanel>
              <TextBlock Text="Уведомления Windows"/>
              <TextBlock Text="О пропавшем VPN, блокировках и обновлениях" Style="{StaticResource Caption}"/>
            </StackPanel>
          </CheckBox>
        </StackPanel>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@

function Show-Menu {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $isDarkTheme = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0
    # Цвета из палитры Windows 11 (Fluent), чтобы окно выглядело как системное
    $palette = if ($isDarkTheme) {
        @{ Bg = '#202020'; Card = '#2B2B2B'; CardBorder = '#3A3A3A'; Text = '#FFFFFF'; SubText = '#ABABAB'
           Accent = '#60CDFF'; OnAccent = '#000000'; SwitchOff = '#9A9A9A'; HoverBg = '#2D2D2D'
           Ok = '#6CCB5F'; Bad = '#FF99A4'; Warn = '#FCE100'; Neutral = '#9A9A9A'; WarnBg = '#433519' }
    } else {
        @{ Bg = '#F3F3F3'; Card = '#FFFFFF'; CardBorder = '#E5E5E5'; Text = '#1B1B1B'; SubText = '#616161'
           Accent = '#005FB8'; OnAccent = '#FFFFFF'; SwitchOff = '#8A8A8A'; HoverBg = '#E5E5E5'
           Ok = '#0F7B0F'; Bad = '#C42B1C'; Warn = '#9D5D00'; Neutral = '#767676'; WarnBg = '#FFF4CE' }
    }
    $window = [Windows.Markup.XamlReader]::Parse($MENU_XAML)
    # Окно живёт в powershell.exe — без своего значка на панели задач был бы значок PowerShell.
    # icon.ico лежит рядом со скриптом (и в Program Files, и в плагине); в нём размеры от 16 до 256 px
    $iconPath = Join-Path $PSScriptRoot 'icon.ico'
    # OnLoad — прочитать в память и отпустить файл, иначе открытое окно не даст установщику заменить значок
    if (Test-Path $iconPath) {
        $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath), 'None', 'OnLoad')
    }
    foreach ($colorName in $palette.Keys) {
        $window.Resources[$colorName] = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($palette[$colorName]))
    }
    $ui = @{}
    $window.Title = "Claude kill-switch $VERSION"
    foreach ($elementName in 'TitleBar', 'MinimizeButton', 'CloseButton', 'HeroHalo', 'HeroGlyph', 'HeroTitle', 'HeroSubtitle', 'NpmWarning',
                             'TitleText', 'TunnelDot', 'TunnelNameText', 'TunnelStateText', 'RuleCountText', 'ProtectionSwitch', 'AutostartSwitch', 'NotificationsSwitch',
                             'UpdateCard', 'UpdateText', 'UpdateButton', 'ProtectionCaption', 'AutostartCaption') {
        $ui[$elementName] = $window.FindName($elementName)
    }
    $ui.TitleText.Text = $window.Title
    # Значки шрифта Segoe MDL2 Assets
    $glyphByName = @{ Shield = [string][char]0xEA18; Lock = [string][char]0xE72E; Warning = [string][char]0xE7BA }

    $setHero = {
        param($colorName, $glyph, $title, $subtitle)
        $ui.HeroHalo.Fill = $window.Resources[$colorName]
        $ui.HeroGlyph.Foreground = $window.Resources[$colorName]
        $ui.HeroGlyph.Text = $glyph
        $ui.HeroTitle.Text = $title
        $ui.HeroSubtitle.Text = $subtitle
    }

    $applyState = {
        param($state)
        $shownTunnel = if ($state.ConnectedTunnel) { $state.ConnectedTunnel } else { $state.TunnelAdapters | Select-Object -First 1 }
        $ui.TunnelNameText.Text = if ($shownTunnel) { $shownTunnel.Name } else { '' }
        $ui.TunnelStateText.Text = if ($state.ConnectedTunnel) { ' · подключён' } elseif ($shownTunnel) { ' · отключён' } else { 'не найден' }
        $ui.TunnelDot.Fill = $window.Resources[$(if ($state.ConnectedTunnel) { 'Ok' } else { 'Bad' })]
        $ui.RuleCountText.Text = "$($state.ActiveRuleCount)"

        $summary = Get-ProtectionSummary $state
        & $setHero $summary.Color $glyphByName[$summary.Glyph] $summary.Title $summary.Subtitle

        # Пока не установлено, переключать нечего: флаги ни на что не влияют
        $ui.ProtectionSwitch.IsChecked = $state.IsInstalled -and -not $state.IsAutostartOff -and -not $state.IsPausedUntilReboot
        $ui.ProtectionSwitch.IsEnabled = $state.IsInstalled -and -not $state.IsAutostartOff
        $ui.ProtectionCaption.Text = if ($state.IsPausedUntilReboot) { 'Выключена до перезагрузки' } else { 'Если выключить — пауза до перезагрузки' }
        $ui.AutostartSwitch.IsChecked = $state.IsInstalled -and -not $state.IsAutostartOff
        $ui.AutostartSwitch.IsEnabled = $state.IsInstalled
        $ui.AutostartCaption.Text = if ($state.IsAutostartOff) { 'Защита выключена совсем' } else { 'Если выключить — защита отключится совсем' }
        $ui.NotificationsSwitch.IsChecked = $state.IsInstalled -and -not $state.IsNotificationsOff
        $ui.NotificationsSwitch.IsEnabled = $state.IsInstalled
        $ui.NpmWarning.Visibility = if ($state.IsNpmClaudeInstalled) { 'Visible' } else { 'Collapsed' }
        $ui.UpdateCard.Visibility = if ($state.AvailableUpdateVersion) { 'Visible' } else { 'Collapsed' }
        $ui.UpdateText.Text = "Доступна версия $($state.AvailableUpdateVersion)"
    }

    # Опрос состояния — около 0,6 с (CIM-запросы к сети и планировщику). В потоке окна он подвешивал бы окно
    # каждые 5 с, поэтому идёт в отдельном потоке; таймер окна только забирает готовый результат
    $stateRunspace = [runspacefactory]::CreateRunspace()
    $stateRunspace.Open()
    $functionsLoader = [powershell]::Create()
    $functionsLoader.Runspace = $stateRunspace
    [void]$functionsLoader.AddScript(". '$($PSCommandPath.Replace("'", "''"))' -LoadOnly").Invoke()
    $functionsLoader.Dispose()
    # IsStale: флаг поменяли, пока опрос шёл, — его результат устарел, опрашиваем заново
    $refresh = @{ Worker = $null; Pending = $null; IsStale = $false; NextStartTime = [datetime]::MinValue }
    $refreshStatus = {
        if ($refresh.Pending) { $refresh.IsStale = $true }
        $refresh.NextStartTime = [datetime]::MinValue
    }
    $pollState = {
        if ($refresh.Pending) {
            if (-not $refresh.Pending.IsCompleted) { return }
            $state = $refresh.Worker.EndInvoke($refresh.Pending) | Select-Object -First 1
            $refresh.Worker.Dispose()
            $refresh.Pending = $null
            if ($refresh.IsStale) { $refresh.IsStale = $false }
            elseif ($state) { & $applyState $state }
        }
        if ((Get-Date) -ge $refresh.NextStartTime) {
            $refresh.Worker = [powershell]::Create()
            $refresh.Worker.Runspace = $stateRunspace
            [void]$refresh.Worker.AddScript('Get-KillSwitchState')
            $refresh.Pending = $refresh.Worker.BeginInvoke()
            $refresh.NextStartTime = (Get-Date).AddMilliseconds($MENU_REFRESH_PERIOD_MS)
        }
    }

    # Click, а не Checked/Unchecked: те срабатывают и когда refreshStatus сам выставляет переключатель
    $ui.ProtectionSwitch.Add_Click({
        if ($ui.ProtectionSwitch.IsChecked) { Remove-Item $pausedUntilRebootFlagPath -ErrorAction SilentlyContinue }
        else { New-Item -ItemType File -Force $pausedUntilRebootFlagPath | Out-Null }
        & $refreshStatus
    })
    $ui.AutostartSwitch.Add_Click({
        if ($ui.AutostartSwitch.IsChecked) {
            Remove-Item $autostartOffFlagPath -ErrorAction SilentlyContinue
            # Задача запускается от имени пользователя, UAC не нужен
            Start-ScheduledTask -TaskName $TASK_NAME
        } else {
            # Сторож увидит флаг, снимет правила и завершится; при входе в Windows — так же
            New-Item -ItemType File -Force $autostartOffFlagPath | Out-Null
        }
        & $refreshStatus
    })
    $ui.NotificationsSwitch.Add_Click({
        if ($ui.NotificationsSwitch.IsChecked) { Remove-Item $notificationsOffFlagPath -ErrorAction SilentlyContinue }
        else { New-Item -ItemType File -Force $notificationsOffFlagPath | Out-Null }
        & $refreshStatus
    })
    # Окно закрываем: установщик в конце откроет его заново, уже новой версии
    $ui.UpdateButton.Add_Click({
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Update"
        $window.Close()
    })
    $ui.MinimizeButton.Add_Click({ $window.WindowState = 'Minimized' })
    $ui.CloseButton.Add_Click({ $window.Close() })
    $ui.TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
    $window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } })
    $window.Add_Loaded({ $window.Activate() })

    $refreshTimer = New-Object Windows.Threading.DispatcherTimer
    $refreshTimer.Interval = [TimeSpan]::FromMilliseconds($MENU_POLL_PERIOD_MS)
    $refreshTimer.Add_Tick($pollState)
    # Первый раз — сразу, чтобы окно не открылось пустым
    & $applyState (Get-KillSwitchState)
    $refresh.NextStartTime = (Get-Date).AddMilliseconds($MENU_REFRESH_PERIOD_MS)
    $refreshTimer.Start()
    [void]$window.ShowDialog()
    $refreshTimer.Stop()
    $stateRunspace.Dispose()
}

if ($Menu) {
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    Show-Menu
    return
}
if ($OpenMenu) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Menu"
    return
}
if ($StartInstall) {
    # Без -WindowStyle Hidden: при отказе в UAC install.ps1 пишет об этом и ждёт Enter — в скрытом окне он повис бы
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\install.ps1`""
    return
}
if ($Update) {
    $updateDir = Join-Path $env:TEMP 'ClaudeKillSwitch-update'
    Remove-Item $updateDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $updateDir | Out-Null
    $zipPath = Join-Path $updateDir 'claude-vpn-killswitch.zip'
    # Окно уже закрыто, а скачивание и окно UAC — не мгновенно: говорим, что работа идёт
    Show-Toast 'Обновление Claude kill-switch' 'Скачиваю новую версию — потом Windows попросит разрешение на установку.' -EvenIfMuted
    try {
        Invoke-WebRequest $LATEST_RELEASE_ZIP_URL -OutFile $zipPath -UseBasicParsing -TimeoutSec $UPDATE_DOWNLOAD_TIMEOUT_S
        Expand-Archive $zipPath $updateDir
    } catch {
        Show-Toast 'Не удалось скачать обновление' 'Проверьте интернет и попробуйте ещё раз.' -EvenIfMuted
        return
    }
    # В архиве всё лежит в папке claude-vpn-killswitch; install.ps1 сам спросит UAC и откроет окно
    $downloadedInstallScriptPath = (Get-ChildItem $updateDir -Recurse -Filter install.ps1 | Select-Object -First 1).FullName
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$downloadedInstallScriptPath`""
    return
}
if ($Status) {
    # Claude Code читает вывод как UTF-8, а консоль PowerShell 5.1 по умолчанию пишет в кодировке OEM
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $state = Get-KillSwitchState
    $summary = Get-ProtectionSummary $state
    if ($Json) {
        @{ color = $summary.Color; title = $summary.Title; subtitle = $summary.Subtitle
           tunnel = Get-TunnelText $state; ruleCount = $state.ActiveRuleCount; version = $VERSION } | ConvertTo-Json -Compress
        return
    }
    "$($summary.Title). $($summary.Subtitle)"
    "VPN-туннель: $(Get-TunnelText $state)"
    "Правил брандмауэра: $($state.ActiveRuleCount)"
    "Найдено программ Claude: $(@(Get-ClaudeExePaths).Count)"
    "Версия килл-свитча: $VERSION"
    if ($state.AvailableUpdateVersion) { "Доступна версия $($state.AvailableUpdateVersion) — обновить можно в окне: /killswitch menu." }
    if ($state.IsNpmClaudeInstalled) { 'Внимание: Claude Code установлен через npm (node.exe) — килл-свитч его не блокирует.' }
    return
}

# На каждый exe два правила: все адаптеры, кроме туннеля, по именам — и все подключения удалённого доступа
# (PPPoE, встроенный VPN Windows) по типу: своего адаптера у них нет, по имени их брандмауэр не всегда принимает.
# Wintun, TAP и другие адаптеры VPN-клиентов к удалённому доступу не относятся
function New-ClaudeBlockRules($claudeExePaths, $blockedAdapterNames) {
    foreach ($claudeExePath in $claudeExePaths) {
        if ($blockedAdapterNames.Count -gt 0) {
            New-NetFirewallRule -DisplayName "$RULE_GROUP - $claudeExePath" -Group $RULE_GROUP `
                -Direction Outbound -Action Block -Program $claudeExePath `
                -InterfaceAlias $blockedAdapterNames -ErrorAction Stop | Out-Null
        }
        New-NetFirewallRule -DisplayName "$RULE_GROUP - $claudeExePath (удалённый доступ)" -Group $RULE_GROUP `
            -Direction Outbound -Action Block -Program $claudeExePath `
            -InterfaceType RemoteAccess -ErrorAction Stop | Out-Null
    }
}

# После перезагрузки пауза снимается
Remove-Item $pausedUntilRebootFlagPath -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stateDir | Out-Null

$nextUpdateCheckTime = [datetime]::MinValue

$lastAppliedRulesKey = ''
$wasTunnelWarningShown = $false
# Блокировки, случившиеся до запуска сторожа, не показываем
$lastSeenSecurityRecordId = [long](Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
$lastBlockedToastTime = [datetime]::MinValue
while ($true) {
    try {
        # Защита выключена совсем: снимаем правила и выходим с кодом 0, чтобы планировщик не перезапускал
        if (Test-Path $autostartOffFlagPath) {
            Remove-NetFirewallRule -Group $RULE_GROUP -ErrorAction SilentlyContinue
            # Переключатель могли вернуть, пока снимали правила: тогда окно не смогло запустить задачу
            # (она ещё работала) — остаёмся и ставим правила заново
            if (Test-Path $autostartOffFlagPath) { exit 0 }
            $lastAppliedRulesKey = ''
        }
        $isKillSwitchOn = -not (Test-Path $pausedUntilRebootFlagPath)
        $claudeExePaths = Get-ClaudeExePaths
        # Блокируем все адаптеры, кроме туннеля, — так закрыт и новый адаптер (раздача с телефона)
        $tunnelPattern = Get-TunnelAdapterPattern
        $allAdapters = @(Get-NetAdapter)
        $tunnelAdapters = @($allAdapters | Where-Object InterfaceDescription -match $tunnelPattern)
        $blockedAdapterNames = @($allAdapters | Where-Object InterfaceDescription -notmatch $tunnelPattern | ForEach-Object Name | Sort-Object)

        $rulesKey = "$isKillSwitchOn|$($claudeExePaths -join ';')|$($blockedAdapterNames -join ';')"
        if ($rulesKey -ne $lastAppliedRulesKey) {
            $outdatedRules = @(Get-NetFirewallRule -Group $RULE_GROUP -ErrorAction SilentlyContinue)
            # Сначала новые правила, потом удаляем старые — чтобы не было момента без блокировки
            if ($isKillSwitchOn) {
                New-ClaudeBlockRules $claudeExePaths $blockedAdapterNames
            }
            $outdatedRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            $lastAppliedRulesKey = $rulesKey
        }

        $isTunnelUp = [bool]($tunnelAdapters | Where-Object { Test-TunnelConnected $_ })
        $isClaudeRunning = [bool](Get-Process claude -ErrorAction SilentlyContinue)
        $isTunnelWarningNeeded = $isKillSwitchOn -and $isClaudeRunning -and -not $isTunnelUp
        # Уведомляем один раз на каждое пропадание туннеля, а не каждые 5 секунд
        if ($isTunnelWarningNeeded -and -not $wasTunnelWarningShown) {
            Show-Toast 'VPN не включён' 'Запросы Claude заблокированы. Включите VPN.'
        }
        $wasTunnelWarningShown = $isTunnelWarningNeeded

        $newOutboundBlocksXPath = "*[System[EventID=$BLOCKED_CONNECTION_EVENT_ID and EventRecordID>$lastSeenSecurityRecordId]]" +
            " and *[EventData[Data[@Name='Direction']='$OUTBOUND_DIRECTION']]"
        $newOutboundBlocks = @(Get-WinEvent -LogName Security -FilterXPath $newOutboundBlocksXPath -ErrorAction SilentlyContinue)
        if ($newOutboundBlocks.Count -gt 0) {
            $lastSeenSecurityRecordId = ($newOutboundBlocks | Measure-Object RecordId -Maximum).Maximum
            # В журнале путь вида \device\harddiskvolume3\users\...\claude.exe — сравниваем без буквы диска
            $claudeExePathsWithoutDrive = @($claudeExePaths | ForEach-Object { $_.Substring(2).ToLower() })
            $blockedClaudeConnection = $newOutboundBlocks | Where-Object {
                $blockedAppPath = "$($_.Properties[1].Value)".ToLower()
                @($claudeExePathsWithoutDrive | Where-Object { $blockedAppPath.EndsWith($_) }).Count -gt 0
            } | Select-Object -First 1
            $isBlockedToastCooledDown = ((Get-Date) - $lastBlockedToastTime).TotalSeconds -ge $BLOCKED_TOAST_COOLDOWN_S
            if ($blockedClaudeConnection -and $isBlockedToastCooledDown) {
                $blockedAppName = Split-Path "$($blockedClaudeConnection.Properties[1].Value)" -Leaf
                $blockedDestination = "$($blockedClaudeConnection.Properties[5].Value):$($blockedClaudeConnection.Properties[6].Value)"
                Show-Toast 'Запрос Claude заблокирован' "$blockedAppName → $blockedDestination пытался выйти в сеть мимо VPN. Ничего не ушло."
                $lastBlockedToastTime = Get-Date
            }
        }

        # После правил: GitHub может отвечать долго, а правила ждать не должны
        if ((Get-Date) -ge $nextUpdateCheckTime) {
            $isUpdateCheckDone = Update-AvailableUpdateFlag
            $nextUpdateCheckTime = if ($isUpdateCheckDone) { (Get-Date).AddHours($UPDATE_CHECK_PERIOD_H) }
                                   else { (Get-Date).AddMinutes($UPDATE_RETRY_PERIOD_MIN) }
        }
    } catch {
        # Не смогли применить правила (адаптер пропал посреди цикла и т.п.) — повторим на следующем цикле
        $lastAppliedRulesKey = ''
    }
    Start-Sleep -Seconds $POLL_PERIOD_S
}
