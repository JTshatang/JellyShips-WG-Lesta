New-SettingsHeading $musicPage '播放设置' 20 12 125
[void](New-SettingsControl $musicPage Label '播放时机' 20 50 106 24)
$musicTrigger = New-SettingsControl $musicPage Panel '' 144 42 350 30
$musicTrigger.AccessibleName = '播放时机'
$manualTrigger = New-SettingsControl $musicTrigger RadioButton '手动' 0 0 98 30
$battleTrigger = New-SettingsControl $musicTrigger RadioButton '成功进入战斗' 110 0 168 30
[void](New-SettingsControl $musicPage Label '重复方式' 20 88 106 24)
$musicMode = New-SettingsControl $musicPage Panel '' 144 80 350 30
$musicMode.AccessibleName = '重复方式'
$onceMode = New-SettingsControl $musicMode RadioButton '单次' 0 0 98 30
$loopMode = New-SettingsControl $musicMode RadioButton '循环' 110 0 98 30
[void](New-SettingsControl $musicPage Label '战斗音量' 20 126 106 24)
$musicVolumeSlider = [VolumeSlider]::new()
$musicVolumeSlider.SetBounds(138, 120, 224, 28)
$musicVolumeSlider.AccessibleName = '战斗音量'
$musicVolumeSlider.BackColor = $musicPage.BackColor
$musicVolumeSlider.ForeColor = $accent
$musicVolumeSlider.Value = 100
$musicPage.Controls.Add($musicVolumeSlider)
$musicVolume = New-SettingsControl $musicPage NumericUpDown '' 368 122 68 28
$musicVolume.AccessibleName = '音乐音量百分比'
$musicVolume.Value = 100
[void](New-SettingsControl $musicPage Label '%' 443 126 24 22)

New-SettingsHeading $musicPage '快捷键' 20 171 125
[void](New-SettingsControl $musicPage Label '暂停／恢复' 20 215 112 24)
$pauseBinding = New-SettingsControl $musicPage Button '未设置' 144 208 172 30
$pauseBinding.AccessibleName = '暂停或恢复快捷键'
$clearPauseBinding = New-SettingsControl $musicPage Button '清除' 324 208 62 30
$clearPauseBinding.AccessibleName = '清除暂停或恢复快捷键'
[void](New-SettingsControl $musicPage Label '重头播放' 20 253 112 24)
$playBinding = New-SettingsControl $musicPage Button '未设置' 144 246 172 30
$playBinding.AccessibleName = '重头播放快捷键'
$clearPlayBinding = New-SettingsControl $musicPage Button '清除' 324 246 62 30
$clearPlayBinding.AccessibleName = '清除重头播放快捷键'
$cancelMusicBinding = New-SettingsControl $musicPage Button '取消录入' 400 208 96 30
$cancelMusicBinding.Visible = $false
$musicKeyHint = New-SettingsControl $musicPage Label '' 144 280 520 23
$musicKeyHint.ForeColor = [Drawing.Color]::Firebrick
$musicKeyHint.UseMnemonic = $false

New-SettingsHeading $musicPage '本次游戏音乐' 20 321 125
$musicStatus = New-SettingsControl $musicPage Label '尚未启用' 144 321 520 25
$musicStatus.AutoEllipsis = $true
$musicStatus.Add_TextChanged({ $statusTips.SetToolTip($musicStatus, $musicStatus.Text) })
$musicPause = New-SettingsControl $musicPage Button '暂停／恢复' 144 355 106 31
$musicPause.Enabled = $false
$musicPlay = New-SettingsControl $musicPage Button '重头播放' 258 355 102 31
$musicPlay.Enabled = $false
$statusTips.SetToolTip($musicPlay, '对齐本舰拍点，从歌曲开头播放')
$musicSession = New-SettingsControl $musicPage Button '启用本次游戏音乐' 380 355 152 31
$statusTips.SetToolTip($musicSession, '可先启用再打开游戏。关闭设置后继续，退出游戏时结束。')

$musicCapture = [MusicHotkeyCapture]::new($form)
$musicBindingUI = @{ Target = $null }
foreach ($binding in $pauseBinding, $playBinding) { $binding.UseMnemonic = $false }

function Format-MusicHotkey([int]$key) {
    if (!$key) { return '未设置' }
    return [MusicHotkeyCapture]::Describe($key)
}

function Show-MusicHotkeys {
    foreach ($binding in $pauseBinding, $playBinding) {
        $binding.Text = if ($binding -eq $musicBindingUI.Target) { '请按键' } else { Format-MusicHotkey $binding.Tag }
    }
    $clearPauseBinding.Enabled = $pauseBinding.Enabled -and ($pauseBinding.Tag -or $musicBindingUI.Target -eq $pauseBinding)
    $clearPlayBinding.Enabled = $playBinding.Enabled -and ($playBinding.Tag -or $musicBindingUI.Target -eq $playBinding)
    if ($musicCapture.Active) { $cancelMusicBinding.Top = $musicBindingUI.Target.Top }
    $cancelMusicBinding.Visible = $musicCapture.Active
}

function Set-MusicRecordingTarget($binding) {
    $musicKeyHint.Text = ''
    if (!$binding) { $musicCapture.Stop() }
    elseif (!$musicCapture.Start()) {
        $binding = $null
        $musicKeyHint.Text = '无法开始快捷键录入，请重试。'
    }
    $musicBindingUI.Target = $binding
    Show-MusicHotkeys
}

function Set-MusicHotkey($binding, [int]$key) {
    $binding.Tag = $key
    Set-MusicRecordingTarget $null
    Update-MusicHotkeyErrors
}

function Update-MusicHotkeyErrors {
    if ($musicCapture.Active) { return }
    $pauseKey = [int]$pauseBinding.Tag
    $playKey = [int]$playBinding.Tag
    if ($pauseKey -and $pauseKey -eq $playKey) {
        $musicKeyHint.Text = "$(Format-MusicHotkey $pauseKey) 已同时用于两个动作，请更换。"
        return
    }
    $conflicts = if ($pauseKey -eq (Get-MusicKey $musicPreferences.pauseKey) -and
        $playKey -eq (Get-MusicKey $musicPreferences.playKey)) { $musicUI.KeyConflicts } else { 0 }
    $probeHere = [GameMusicHotkeys]::IsForeground($PID)
    $unavailable = @(for ($i = 0; $i -lt 2; $i++) {
        $key = @($pauseKey, $playKey)[$i]
        if ($key -and (($conflicts -band (1 -shl $i)) -or
            ($probeHere -and ![GameMusicHotkeys]::CanRegister($key)))) { Format-MusicHotkey $key }
    })
    $musicKeyHint.Text = if ($unavailable.Count) { "$($unavailable -join '、') 无法注册，请更换。" } else { '' }
}

$pauseBinding.Add_Click({ Set-MusicRecordingTarget $pauseBinding })
$playBinding.Add_Click({ Set-MusicRecordingTarget $playBinding })
$clearPauseBinding.Add_Click({ Set-MusicHotkey $pauseBinding 0 })
$clearPlayBinding.Add_Click({ Set-MusicHotkey $playBinding 0 })
$cancelMusicBinding.Add_Click({ Set-MusicRecordingTarget $null; Update-MusicHotkeyErrors })
$musicCapture.Add_KeyPressed({
    param($key)
    $label = Format-MusicHotkey $key
    $target = $musicBindingUI.Target
    $other = if ($target -eq $pauseBinding) { $playBinding } else { $pauseBinding }
    if (!$key) { $musicKeyHint.Text = '此按键无法用作快捷键，请换一个键。' }
    elseif ($key -eq $other.Tag) { $musicKeyHint.Text = "$label 已分配给另一个动作，请换一个键。" }
    elseif (![GameMusicHotkeys]::CanRegister($key)) { $musicKeyHint.Text = "$label 无法注册，请换一个键。" }
    else { Set-MusicHotkey $target $key }
})
$form.Add_FormClosed({ $musicCapture.Dispose() })
$form.Add_Deactivate({
    $musicCapture.Dispose()
    if ($musicBindingUI.Target) { Set-MusicRecordingTarget $null }
})
$form.Add_Shown({ Update-MusicHotkeyErrors })
$musicPage.Add_VisibleChanged({
    if (!$musicPage.Visible -and $musicBindingUI.Target) { Set-MusicRecordingTarget $null }
})

$musicInstall = Get-GameMusicClientPath
$musicVolumeSlider.Add_ValueChanged({ $musicVolume.Value = $musicVolumeSlider.Value })
$musicVolume.Add_ValueChanged({
    $musicVolumeSlider.Value = [int]$musicVolume.Value
    if ($profileUI.Loading -or !$musicInstall) { return }
    try {
        Set-AppliedMusicVolume ([int]$musicVolume.Value)
        $musicUI.Error = ''
    } catch { $musicUI.Error = $_.Exception.Message }
})
if (!$musicInstall) {
    $musicStatus.Text = '尚未连接游戏'
    $musicSession.Enabled = $false
    return
}
$musicUI = @{
    Error = ''; Host = $null; SessionId = ''
    Pending = ''; Sent = $null; KeyConflicts = 0
}

function Show-GameMusicState {
    $songless = Test-SonglessMusic $musicPreferences
    $view = Read-LiveGameMusicStatus
    if ($musicUI.Host -and $musicUI.Host.HasExited) {
        $musicUI.Host.Dispose()
        $musicUI.Host = $null
        $last = Read-GameMusicJson $gameMusicStatus
        if ($last.token -ceq $musicUI.SessionId -and $last.state -eq 'Unavailable') { $musicUI.Error = $last.error }
    }
    $token = if ($view) { $view.token } elseif ($musicUI.Host) { $musicUI.SessionId }
    $ending = $token -and [IO.File]::Exists((Get-MusicSessionEndFile $token))
    $musicSession.Tag = $token
    $musicSession.Text = if ($token) { '结束本次游戏音乐' } else { '启用本次游戏音乐' }
    $musicSession.Enabled = !$ending -and ($token -or !$songless)
    if (!$view -or $ending -or $songless) { $musicUI.Pending = ''; $musicUI.Sent = $null }
    if ($musicUI.Sent -and ($musicUI.Sent.id -ceq $view.ack -or $musicUI.Sent.token -cne $view.token)) {
        $musicUI.Sent = $null
    }
    if ($musicUI.Pending -and !$musicUI.Sent -and $view -and $view.state -ne 'Unavailable') {
        try {
            $message = @{
                id = [Guid]::NewGuid().ToString('N'); token = $view.token; action = $musicUI.Pending
            }
            Write-GameMusicJson $gameMusicCommand $message
            $musicUI.Sent = $message
            $musicUI.Pending = ''
        } catch [IO.IOException] {
            # A reader may briefly hold the old file on Windows.
        }
    }
    if ($musicUI.KeyConflicts -ne [int]$view.keyConflicts) {
        $musicUI.KeyConflicts = [int]$view.keyConflicts
        Update-MusicHotkeyErrors
    }
    $current = if ($view) { $view.state } else { 'Stopped' }
    $musicPlay.Enabled = !$ending -and !$songless -and $profileUI.HasSong -and $null -ne $view.beat -and $current -ne 'Unavailable'
    $musicPause.Enabled = $musicPlay.Enabled -and $current -in 'Waiting', 'Playing', 'BetweenRepeats', 'Resuming', 'Paused'
    $label = switch ($current) {
        'AwaitingBeat' { '等待本舰拍点' }
        'Waiting' { '等待起播' }
        'Playing' { '播放中' }
        'Paused' { '已暂停' }
        'Resuming' { '等待对应拍位' }
        'Fading' { '淡出中' }
        'BetweenRepeats' { '等待下一遍' }
        'Finished' { '已播完' }
        'Failed' { "播放失败。$($view.error)" }
        'Unavailable' { "播放器无法启动。$($view.error)" }
        default { '已停止' }
    }
    $musicStatus.Text = if ($ending) { '正在结束本次游戏音乐…' }
        elseif ($musicUI.Error) { $musicUI.Error }
        elseif ($songless) { '已应用无歌方案' }
        elseif (!$token) { '尚未启用' }
        elseif (!$view -or $view.state -eq 'Starting') { '正在启用…' }
        elseif (!$view.client) { '已启用，等待游戏启动' }
        elseif ($musicUI.Pending -and $current -ne 'Unavailable') { '等待播放器…' }
        elseif ($current -eq 'Stopped' -and $null -eq $view.beat) { '等待本舰拍点' }
        else { $label }
}

$musicSession.Add_Click({
    try {
        $musicUI.Error = ''
        if ($musicSession.Tag) {
            [IO.File]::WriteAllText((Get-MusicSessionEndFile $musicSession.Tag), '')
        } else {
            [void][IO.Directory]::CreateDirectory($gameMusicRuntime)
            $musicUI.SessionId = [Guid]::NewGuid().ToString('N')
            $launch = [Diagnostics.ProcessStartInfo]::new($gameMusicWindowsPowerShell, ($gameMusicHostArgs + ' -SessionId ' + $musicUI.SessionId))
            $launch.UseShellExecute = $false
            $launch.CreateNoWindow = $true
            $musicUI.Host = [Diagnostics.Process]::Start($launch)
        }
    } catch { $musicUI.Error = $_.Exception.Message }
    Show-GameMusicState
})
$musicPlay.Add_Click({
    try {
        $musicUI.Pending = 'Play'
        Show-GameMusicState
    } catch { $musicUI.Error = $_.Exception.Message }
})
$musicPause.Add_Click({
    $musicUI.Pending = 'TogglePause'
    Show-GameMusicState
})
$musicTimer = [Windows.Forms.Timer]::new()
$musicTimer.Interval = 100
$musicTimer.Add_Tick({ Show-GameMusicState })
$musicTimer.Start()
$form.Add_FormClosed({ if ($musicUI.Host) { $musicUI.Host.Dispose(); $musicUI.Host = $null } })
Show-GameMusicState
