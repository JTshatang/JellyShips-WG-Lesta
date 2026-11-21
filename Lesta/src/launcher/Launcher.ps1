param([string]$UninstallBuild, [int]$EditorProcessId, [switch]$RemovePlayerData, [switch]$FinishUpdate)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install.ps1')
. (Join-Path $PSScriptRoot 'Portable.ps1')
. (Join-Path $PSScriptRoot 'Updates.ps1')

function Show-UpdateWindow($session) {
    $window = [Windows.Forms.Form]::new()
    try {
        $window.Text = "$playerBrand · 更新"
        $window.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
        $window.AutoScaleDimensions = [Drawing.SizeF]::new(96, 96)
        $window.AutoScaleMode = 'Dpi'
        $window.ClientSize = [Drawing.Size]::new(600, 152)
        $window.BackColor = [Drawing.SystemColors]::Window
        $window.FormBorderStyle = 'FixedDialog'
        $window.MaximizeBox = $false
        $window.StartPosition = 'CenterScreen'
        $client = [Windows.Forms.Label]::new()
        $client.SetBounds(20, 16, 560, 25)
        $client.Font = [Drawing.Font]::new($window.Font, [Drawing.FontStyle]::Bold)
        $client.Text = "莱服 $($session.Layout.Build) · 当前构建需要匹配的玩家包"
        $window.Controls.Add($client)
        . (Join-Path $session.Components 'UpdateWindow.ps1') $window $window $session 48 600
        [void]$window.ShowDialog()
    } finally { $window.Dispose() }
}

function Start-LauncherMaintenance([string]$options) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -WorkingDirectory ([Environment]::SystemDirectory) -ArgumentList (
        '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -EditorProcessId ' + $PID + ' ' + $options)
}

if ($MyInvocation.InvocationName -eq '.') { return }
Add-Type -Name SettingsDpi -Namespace JellyShips -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@
[void][JellyShips.SettingsDpi]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()
$gate = $null
$acquired = $false
$reopen = $null
try {
    $location = Get-PortalLocation $PSScriptRoot
    $layout = $location.Layout
    $portal = $location.Home
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($location.Game.ToUpperInvariant())),0,8).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($UninstallBuild -or $FinishUpdate) {
        if ($EditorProcessId -le 0 -or $EditorProcessId -eq $PID) { throw '维护请求无效，请从启动器重新打开。' }
        $editor = Get-Process -Id $EditorProcessId -ErrorAction SilentlyContinue
        if ($editor -and !$editor.WaitForExit(15000)) { throw '设置窗口仍在使用，请稍后重试。' }
    }
    $gate = [Threading.Mutex]::new($false, ('Local\JellyShips-' + $id))
    try { $acquired = $gate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (!$acquired) { return }

    $package = Read-InstallJson (Join-Path $PSScriptRoot 'package.json')
    $launcherSession = @{ Home=$portal; Components=$PSScriptRoot; Layout=$layout; Uninstall=$false; RemovePlayerData=$false }
    Restore-ModInstall $layout
    $record = Get-InstallReceipt $layout
    if ($UninstallBuild) {
        if ($layout.Build -cne $UninstallBuild -or $portal -ne $layout.Portal -or !$record) { throw '游戏构建或安装位置已变更，请重新打开设置。' }
        Assert-GameClosed
        Save-PlayerSettings $launcherSession
        $pending = Get-PendingPlayerUpdate $layout $package $portal
        if ($pending) { Clear-PendingPlayerUpdate $portal $pending }
        Clear-AbandonedPlayerUpdates $portal
        Uninstall-Mod $layout
        if ($RemovePlayerData) { Remove-PortablePlayerData $portal }
        Remove-PortableProgram $portal $record.manifest
        Remove-EmptyPortableFolder $portal
        [void][Windows.Forms.MessageBox]::Show('已卸载本构建的保持Q弹。',$playerBrand)
        return
    }

    $failedUpdate = $false
    $pendingFile = Join-Path $portal 'pending-update.json'
    if ([IO.File]::Exists($pendingFile) -and !(Get-Process -Name Korabli,Korabli64 -ErrorAction SilentlyContinue)) {
        try {
            $candidate = Get-PendingPlayerUpdate $layout $package $portal
            if ($candidate) {
                Install-PendingProgram $layout $candidate $portal
                Clear-PendingPlayerUpdate $portal $candidate
                if ($FinishUpdate) {
                    $musicFiles = Join-Path $layout.Mod 'GameMusicFiles.ps1'
                    if ([IO.File]::Exists($musicFiles)) {
                        try {
                            . $musicFiles
                            if (Get-Command Start-GameMusicMonitor -ErrorAction SilentlyContinue) {
                                $monitor = Start-GameMusicMonitor
                                if ($monitor) { $monitor.Dispose() }
                            }
                        } catch {
                            [void][Windows.Forms.MessageBox]::Show('音乐模块出了点小问题，请退出重新打开软件',$playerBrand)
                        }
                    }
                } else { $reopen = Join-Path $layout.Portal "$playerBrand.exe" }
            }
        } catch {
            $failedUpdate = $true
            [void][Windows.Forms.MessageBox]::Show(("更新尚未完成。关闭占用窗口后，重新打开启动器可重试。" + [Environment]::NewLine + $_.Exception.Message),$playerBrand)
        }
    }
    if (!$FinishUpdate -and !$reopen) {
        if ($portal -eq $layout.Portal -and $package.build -ceq $layout.Build) {
            $archive = Join-Path $PSScriptRoot '资源包.zip'
            if ([IO.File]::Exists($archive)) {
                Assert-PortableProgram $PSScriptRoot $package
                Assert-RegularPath $archive
                if ((Get-InstallHash $archive) -ne $package.launcher_hashes.'资源包.zip') { throw '安装资源校验失败，请重新解压完整玩家包。' }
                if ((Compare-PlayerRelease $record $package) -lt 0) { Install-Mod $layout $package $portal $portal }
                [IO.File]::Delete($archive)
                $record = Get-InstallReceipt $layout
            }
        }
        if ($portal -ne $layout.Portal -and $record.portable_format -eq 1 -and [IO.File]::Exists((Join-Path $layout.Portal "$playerBrand.exe"))) {
            $reopen = Join-Path $layout.Portal "$playerBrand.exe"
        } else {
            if ($portal -eq $layout.Portal -and $record.portable_format -eq 1) { & (Join-Path $layout.Mod 'Q-Bounce.ps1') }
            else { Show-UpdateWindow $launcherSession }
            if ($launcherSession.Uninstall) {
                $options = '-UninstallBuild ' + $layout.Build
                if ($launcherSession.RemovePlayerData) { $options += ' -RemovePlayerData' }
                Start-LauncherMaintenance $options
            } elseif (!$failedUpdate -and [IO.File]::Exists($pendingFile)) { Start-LauncherMaintenance '-FinishUpdate' }
        }
    }
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,$playerBrand)
} finally {
    if ($acquired) { $gate.ReleaseMutex() }
    if ($gate) { $gate.Dispose() }
}
if ($reopen) { Start-Process -FilePath $reopen }
