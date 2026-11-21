$ErrorActionPreference = 'Stop'
if (!('JellyShips.SettingsDpi' -as [type])) {
    Add-Type -Name SettingsDpi -Namespace JellyShips -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@
    [void][JellyShips.SettingsDpi]::SetProcessDPIAware()
}
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

$path = Join-Path $PSScriptRoot 'Beat.seq'
$effectsTool = Join-Path $PSScriptRoot 'Effects.ps1'
$hasEffects = Test-Path -LiteralPath $effectsTool -PathType Leaf
$musicTool = Join-Path $PSScriptRoot 'Music.ps1'
$hasMusic = Test-Path -LiteralPath $musicTool -PathType Leaf
$musicPlayer = $null
$musicTimer = $null
$editorLock = $null
$settingsBackupError = $null
try {
    $curveSources = 'BeatCurve.cs', 'HeightCurve.cs', 'SpeedGraph.cs', 'HeightGraph.cs', 'BeatTimeline.cs', 'VolumeSlider.cs'
    Add-Type -LiteralPath @($curveSources | ForEach-Object { Join-Path $PSScriptRoot $_ }) -ReferencedAssemblies System.Drawing,System.Windows.Forms
    . (Join-Path $PSScriptRoot 'Beat-Amplitude.ps1')
    . (Join-Path $PSScriptRoot 'Bow-Preview.ps1')
    . (Join-Path $PSScriptRoot 'GameMusicFiles.ps1')
    if ($hasMusic) { Import-GameMusicHotkeys -WithCapture }
    . (Join-Path $PSScriptRoot 'Profiles.ps1')
    try {
        $editorLock = [IO.File]::Open((Join-Path $PSScriptRoot 'editor.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        throw '无法锁定设置。请关闭其他正在使用此安装目录的 Q 弹工具后重试。'
    }
    if ([IO.File]::Exists((Join-Path $PSScriptRoot 'uninstall.request'))) {
        throw '请等待莱斯塔-保持Q弹完成更新或卸载，再打开设置。'
    }
    $effectMode = '11'
    if ($hasEffects) {
        . $effectsTool
        Restore-EffectSave
        $effectMode = Read-EffectMode
    }
    $sequence = Read-BeatSequence $path
    $saved = @(Get-BeatAmplitudes $sequence)
    $enabled = Test-ModEffectEnabled
    [object[]]$musicTracks = @(Read-BuiltInMusicTracks)
    if (!$musicTracks) { $hasMusic = $false }
    if ($hasMusic) { $musicTracks += @(Read-UserMusicTracks) }
    $musicPreferences = Read-GameMusicJson $gameMusicPrefs
    $profileLibrary = Read-PlayerProfiles $sequence $effectMode $musicTracks $musicPreferences
    if (![IO.File]::Exists($profileFile)) { Write-GameMusicJson $profileFile $profileLibrary 7 }
    if ($launcherSession) {
        try { Save-PlayerSettings $launcherSession }
        catch { $settingsBackupError = "无法备份方案。$($_.Exception.Message)" }
    }
} catch {
    if ($editorLock) { $editorLock.Dispose() }
    [void][Windows.Forms.MessageBox]::Show("无法打开设置。请确认 Mod 文件已完整解压。`n`n$($_.Exception.Message)", '莱斯塔-保持Q弹')
    return
}

. (Join-Path $PSScriptRoot 'Settings-Layout.ps1')
$form = New-SettingsWindow '保持Q弹' 760 564
$header = New-SettingsControl $form Panel '' 0 0 760 66
$header.Dock = 'Top'
$title = New-SettingsControl $header Label '莱斯塔-保持Q弹' 22 13 228 40
$title.Font = [Drawing.Font]::new($form.Font.FontFamily, 17, [Drawing.FontStyle]::Bold)
$title.TextAlign = 'MiddleLeft'
$enableBox = New-SettingsControl $header CheckBox '启用mod效果' 252 18 150 30
$enableBox.Font = [Drawing.Font]::new($form.Font.FontFamily, 11, [Drawing.FontStyle]::Bold)
$enableBox.ForeColor = $accent
$enableBox.Checked = $enabled
$profileLabel = New-SettingsControl $header Label '当前方案' 434 18 72 30
$profileLabel.TextAlign = 'MiddleRight'
$profileList = New-SettingsControl $header ComboBox '' 518 20 218 29
$profileList.Anchor = 'Top, Left, Right'
$profileList.DropDownWidth = 440
$profileList.DropDownStyle = 'DropDownList'
$profileList.AccessibleName = '当前方案'

$navigation = New-SettingsControl $form FlowLayoutPanel '' 0 66 760 40
$navigation.Dock = 'Top'
$navigation.WrapContents = $false
$navigation.Padding = [Windows.Forms.Padding]::new(14, 0, 0, 0)
$navigation.AccessibleName = '设置页面'
$navigation.AccessibleRole = 'PageTabList'
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $key)
    if (!$key.Control -or $key.KeyCode -ne 'Tab' -or $musicBindingUI.Target) { return }
    $tabs = $navigation.Controls
    $active = $tabs | Where-Object Checked
    $step = if ($key.Shift) { -1 } else { 1 }
    $next = $tabs[($tabs.IndexOf($active) + $step + $tabs.Count) % $tabs.Count]
    $next.Checked = $true
    [void]$next.Focus()
    $key.SuppressKeyPress = $true
})
$divider = New-SettingsControl $form Panel '' 0 106 760 1
$divider.BackColor = $rule
$divider.Dock = 'Top'
$footer = New-SettingsControl $form Panel '' 0 506 760 58
$footer.Dock = 'Bottom'
$footer.BackColor = [Drawing.Color]::FromArgb(246, 247, 247)
$pageHost = New-SettingsControl $form Panel '' 0 107 760 399
$pageHost.Dock = 'Fill'
foreach ($part in $navigation, $divider, $footer, $pageHost) { $part.BringToFront() }

$shapePage = New-SettingsPage '效果预览'
$profilePage = New-SettingsPage '方案管理'
if ($hasMusic) { $musicPage = New-SettingsPage '音乐设置' }
if ($launcherSession) { $maintenancePage = New-SettingsPage '程序维护' }

New-SettingsHeading $profilePage '方案名称' 22 18 250
$profileName = New-SettingsControl $profilePage TextBox '' 22 55 324 29
$profileName.AccessibleName = '方案名称'
$profileName.MaxLength = 60
$newProfile = New-SettingsControl $profilePage Button '新建方案' 22 101 104 32
$deleteProfile = New-SettingsControl $profilePage Button '删除方案…' 138 101 104 32
New-SettingsHeading $profilePage '关联歌曲' 22 167 250
$profileSong = New-SettingsControl $profilePage Label '' 22 205 486 29
$profileSong.AutoEllipsis = $true
if (!$hasMusic) { $profileSong.Text = '此安装未包含音乐' }
$songDropHint = New-SettingsControl $profilePage Label '或将文件拖入此处' 150 248 168 23
$songFormatHint = New-SettingsControl $profilePage Label '支持 WAV、MP3、M4A、FLAC、NCM' 22 286 350 24
$songFormatHint.ForeColor = $songDropHint.ForeColor = $muted
$importSong = New-SettingsControl $profilePage Button '添加歌曲…' 22 241 113 32
$removeSong = New-SettingsControl $profilePage Button '移除歌曲' 150 241 100 32
$songFormatHint.Visible = $songDropHint.Visible = $removeSong.Visible = $importSong.Visible = $false

$columns = [Windows.Forms.FlowLayoutPanel]::new()
$columns.Dock = 'Fill'
$columns.AutoScroll = $true
$shapePage.Controls.Add($columns)
$previewColumn = New-SettingsControl $columns Panel '' 0 0 322 $(if ($hasMusic) { 357 } else { 281 })
$previewColumn.Margin = [Windows.Forms.Padding]::new(22, 14, 0, 10)
New-SettingsHeading $previewColumn '效果预览' 0 0 180
$previewGroup = New-SettingsControl $previewColumn Panel '' 0 36 322 $(if ($hasMusic) { 312 } else { 245 })
$preview = New-BowPreview (Join-Path $PSScriptRoot 'bow.svg')
$preview.SetBounds(0, 0, 322, 200)
$preview.Anchor = 'Top, Left'
$previewGroup.Controls.Add($preview)
$flat = New-SettingsControl $previewGroup Button '看最扁' 0 207 73 31
$tall = New-SettingsControl $previewGroup Button '看最高' 82 207 73 31
$play = New-SettingsControl $previewGroup Button '暂停预览' 220 207 102 31

$animation = New-SettingsControl $columns Panel '' 0 0 361 363
$animation.Margin = [Windows.Forms.Padding]::new(24, 14, 12, 10)
New-SettingsHeading $animation '变形幅度' 0 0 154
$songBeatReadout = New-SettingsControl $animation Label '' 160 0 198 33
$songBeatReadout.TextAlign = 'MiddleRight'
$songBeatReadout.ForeColor = $muted
$songBeatReadout.AccessibleName = '歌曲节拍'
$profileBpmLabel = New-SettingsControl $animation Label '动画 BPM' 183 5 76 23
$profileBpm = New-SettingsControl $animation TextBox '' 266 2 75 26
$profileBpm.AccessibleName = '动画 BPM'
$profileBpmLabel.Visible = $profileBpm.Visible = $false
$flatLabel = New-SettingsControl $animation Label '最扁时' 0 40 78 22
$tallLabel = New-SettingsControl $animation Label '最高时' 0 137 78 22
foreach ($label in $flatLabel, $tallLabel) { $label.Font = [Drawing.Font]::new($form.Font, [Drawing.FontStyle]::Bold) }
$heightButton = New-SettingsControl $animation Button '动画曲线…' 0 241 100 32
$advancedButton = New-SettingsControl $animation Button '速度曲线…' 110 241 101 32
$resetBoth = New-SettingsControl $animation Button '恢复默认动画' 226 241 127 32
$optionRule = New-SettingsControl $animation Panel '' 0 293 353 1
$optionRule.BackColor = $rule
$errors = [Windows.Forms.ErrorProvider]::new($form)
$errors.BlinkStyle = 'NeverBlink'
[double[]]$previewRatios = @($saved | ForEach-Object { $_ / 100 })
$clock = [Diagnostics.Stopwatch]::new()
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 25
$playback = @{ Start = 0.0 }
$advancedPreview = $null
$heightPreview = $null
$heightGraph = [HeightGraph]::new()
$heightGraph.SetMotion($sequence.Curve)
$graph = [SpeedGraph]::new()

function Show-BowPose {
    if ($musicPreview.Active -and (!$heightWindow.Visible -or !$edit.Pinned -or $musicPreview.Running)) {
        $heightGraph.Position = $musicPreview.Schedule.PositionAt($musicPreview.Frame)
    } elseif ($clock.IsRunning) {
        $heightGraph.Position = ($playback.Start + $clock.Elapsed.TotalSeconds * $profileUI.Beat.bpm / 60.0) % 1.0
    }
    $progress = $heightGraph.Motion.ProgressAt($heightGraph.Position)
    Set-BowPreviewPose $preview $previewRatios $progress
    if ($advanced.Visible) { Set-BowPreviewPose $advancedPreview $previewRatios $progress }
    if ($heightWindow.Visible) {
        Set-BowPreviewPose $heightPreview $previewRatios $progress
        $height = 100 * ($previewRatios[0] * (1 - $progress) + $previewRatios[2] * $progress)
        $width = 100 * ($previewRatios[1] * (1 - $progress) + $previewRatios[3] * $progress)
        $heightReadout.Text = '拍位 {0:P1} · 船高 {1:G4}% · 船宽 {2:G4}%' -f $heightGraph.Position, $height, $width
        $timeline.Position = $heightGraph.Position
        $timeline.Invalidate()
        if ($heightSpeed.Visible) { $heightSpeed.Position = $heightGraph.Position }
        $heightPlay.Text = if ($clock.IsRunning -or $musicPreview.Running) { '暂停' } else { '播放' }
    }
}

function Update-BowPlaybackButton {
    $play.Text = if ($clock.IsRunning) { '暂停预览' } else { '循环预览' }
    $play.Enabled = $heightGraph.Motion.CanPlay -and $null -ne $preview.Tag
}

function Stop-BowPlayback {
    if (!$musicPreview.Running) { $timer.Stop() }
    $clock.Reset()
    Update-BowPlaybackButton
}

function Start-BowPlayback {
    if (!$heightGraph.Motion.CanPlay -or !$preview.Tag) { return }
    if ($musicPreview.Active) { Close-MusicPreview }
    $playback.Start = $heightGraph.Position
    $clock.Restart()
    $timer.Start()
    Update-BowPlaybackButton
}

function Show-SelectedPose([bool]$atPeak) {
    if ($musicPreview.Active) { Close-MusicPreview }
    Stop-BowPlayback
    $heightGraph.Position = if ($atPeak) { $heightGraph.Motion.PeakTime } else { 0 }
    Show-BowPose
}

$timer.Add_Tick({
    if ($musicPreview.Running) { Update-MusicPreviewPlayback }
    Show-BowPose
})
$play.Add_Click({
    if ($clock.IsRunning) { Show-BowPose; Stop-BowPlayback } else { Start-BowPlayback }
})
$flat.Add_Click({ Show-SelectedPose $false })
$tall.Add_Click({ Show-SelectedPose $true })

$labels = '最扁船高', '最扁船宽', '最高船高', '最高船宽'
$rows = for ($i = 0; $i -lt $labels.Count; $i++) {
    $y = 63 + [int][math]::Floor($i / 2) * 97 + ($i % 2) * 33
    $label = New-SettingsControl $animation Label ($labels[$i].Substring(2)) 0 ($y + 5) 47 23
    $slider = New-SettingsControl $animation TrackBar '' 48 $y 184 30
    $slider.AccessibleName = $labels[$i] + '滑块'
    $slider.Minimum = 1
    $slider.Maximum = 200
    $slider.LargeChange = 10
    $slider.TickStyle = 'None'
    $slider.AutoSize = $false
    $slider.Height = 30
    $field = New-SettingsControl $animation TextBox (Format-BeatPercent $saved[$i]) 238 ($y + 2) 72 26
    $field.AccessibleName = $labels[$i] + '百分比'
    $field.TextAlign = 'Right'
    $unit = New-SettingsControl $animation Label '%' 314 ($y + 5) 16 23

    $row = @{ Slider = $slider; Field = $field; Index = $i }
    $slider.Tag = $field.Tag = $row
    $slider.Value = [math]::Min(200, [math]::Max(1, [math]::Round($saved[$i])))
    $field.Add_TextChanged({
        param($sender, $eventArgs)
        $current = $sender.Tag
        $value = ConvertTo-BeatPercent $sender.Text
        $ratio = $value / 100
        if ($null -ne $value -and $ratio -le [single]::MaxValue -and [single]$ratio -gt 0) {
            $previewRatios[$current.Index] = $ratio
            $current.Slider.Value = [math]::Min($current.Slider.Maximum,
                [math]::Max($current.Slider.Minimum, [math]::Round($value)))
        }
        Update-InputErrors
        Show-BowPose
    })
    $slider.Add_Scroll({
        param($sender, $eventArgs)
        $sender.Tag.Field.Text = Format-BeatPercent $sender.Value
    })
    $row
}

function Update-InputErrors {
    if ($profileUI.Loading) { return }
    $nameError = Get-ProfileNameError $profileName.Text.Trim()
    $errors.SetError($profileName, $nameError)

    $messages = @('', '', '', '')
    foreach ($row in $rows) {
        $value = ConvertTo-BeatPercent $row.Field.Text
        $ratio = $value / 100
        if ($null -eq $value) { $messages[$row.Index] = "$($labels[$row.Index])请输入有限的正数。" }
        elseif ($ratio -gt [single]::MaxValue -or [single]$ratio -eq 0) {
            $messages[$row.Index] = "$($labels[$row.Index])超出游戏动画可表示的范围。"
        }
    }
    if (!$messages[0] -and !$messages[2] -and $previewRatios[0] -gt $previewRatios[2]) {
        $messages[0] = $messages[2] = $beatHeightOrderError
    }
    if (!$messages[1] -and !$messages[3] -and $previewRatios[1] -lt $previewRatios[3]) {
        $messages[1] = $messages[3] = $beatWidthOrderError
    }
    foreach ($row in $rows) {
        $message = $messages[$row.Index]
        $row.Field.ForeColor = if ($message) { $amplitudeNotice.ForeColor } else { $ink }
        $row.Field.AccessibleDescription = $message
    }
    $previous = $amplitudeNotice.Text
    $amplitudeNotice.Text = (@($messages | Where-Object { $_ } | Select-Object -Unique) -join [Environment]::NewLine)
    if ($previous -and $status.Text -in ($previous -split '[\r\n]+')) { $status.Text = '退出游戏后应用' }
    $amplitudeNotice.Visible = [bool]$amplitudeNotice.Text
    $status.Visible = !$amplitudeNotice.Text
    $heightGraph.SetHeightRange(($previewRatios[0] * 100), ($previewRatios[2] * 100))
    Update-HeightEditor
}

if ($hasEffects) {
    $wakeBox = New-SettingsControl $animation CheckBox '显示航迹效果' 0 312 150 28
    $wakeBox.Checked = $effectMode[1] -eq '1'
}
$status = New-SettingsControl $footer Label '退出游戏后应用' 22 12 447 34
$amplitudeNotice = New-SettingsControl $footer Label '' 22 3 458 52
$amplitudeNotice.Anchor = 'Top, Left, Right'
$amplitudeNotice.TextAlign = 'MiddleLeft'
$amplitudeNotice.ForeColor = [Drawing.Color]::Firebrick
$amplitudeNotice.AutoEllipsis = $true
$amplitudeNotice.Visible = $false
$status.Anchor = 'Top, Left, Right'
$status.TextAlign = 'MiddleLeft'
$status.AutoEllipsis = $true
$saveProfile = New-SettingsControl $footer Button '保存方案' 505 12 104 34
$saveProfile.Anchor = 'Top, Right'
$apply = New-SettingsControl $footer Button '应用到游戏' 621 12 117 34
$apply.BackColor = $ink
$apply.ForeColor = $paper
$apply.FlatAppearance.BorderColor = $ink
$apply.FlatAppearance.MouseOverBackColor = $accent
$apply.Anchor = 'Top, Right'
if ($launcherSession) {
    New-SettingsHeading $maintenancePage '方案和歌曲' 20 85 360
    $exportPlayer = New-SettingsControl $maintenancePage Button '导出方案和歌曲…' 20 124 159 32
    $maintenanceStatus = New-SettingsControl $maintenancePage Label '' 20 328 630 55
    $exportPlayer.Add_Click({
        $dialog = [Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Filter = '玩家数据 ZIP (*.zip)|*.zip'
            $dialog.FileName = '保持Q弹-玩家数据.zip'
            if ($dialog.ShowDialog($form) -ne 'OK') { return }
            Export-PortablePlayerData $launcherSession $dialog.FileName
            $maintenanceStatus.Text = '已导出保存过的方案和歌曲。'
        } catch { $maintenanceStatus.Text = "导出失败。$($_.Exception.Message)" }
        finally { $dialog.Dispose() }
    })
    New-SettingsHeading $maintenancePage '卸载模组' 20 185 360
    $uninstall = New-SettingsControl $maintenancePage Button '卸载Mod资源' 20 227 150 32
    $keepPlayer = New-SettingsControl $maintenancePage CheckBox '保留我的方案和歌曲' 189 227 220 32
    $keepPlayer.Checked = $true
    $uninstall.Add_Click({
        if (Get-Process Korabli,Korabli64 -ErrorAction SilentlyContinue) {
            $maintenanceStatus.Text = '请先退出游戏，再卸载。'
            return
        }
        $details = if ($keepPlayer.Checked) { '保留玩家数据文件夹。' } else { '你的方案和导入的歌曲也会移入回收站。' }
        if ([Windows.Forms.MessageBox]::Show("从当前游戏构建卸载莱斯塔-保持Q弹？$details",
                '卸载莱斯塔-保持Q弹', 'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
        $launcherSession.RemovePlayerData = !$keepPlayer.Checked
        $launcherSession.Uninstall = $true
        $form.Close()
    })
    try {
        $hasLegacyProgram = @(Get-LegacyProgramFiles $launcherSession.Layout.Game).Count -or (Get-LegacyMusicShortcut $launcherSession.Layout.Game)
    } catch {
        $hasLegacyProgram = $false
    }
    if ($hasLegacyProgram) {
        $cleanOld = New-SettingsControl $maintenancePage Button '清理旧版启动器…' 20 276 159 32
        $cleanOld.Add_Click({
            if ([Windows.Forms.MessageBox]::Show('将此游戏对应的旧固定启动器和旧音乐自启项移入回收站？旧版方案备份和曲库会保留。',
                '清理旧版启动器', 'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
            try {
                Move-LegacyProgramToRecycleBin $launcherSession.Layout.Game
                $cleanOld.Enabled = $false
                $maintenanceStatus.Text = '已清理可识别的旧启动器文件。'
            } catch { $maintenanceStatus.Text = "清理未完成。$($_.Exception.Message)" }
        })
    }
}
$statusTips = [Windows.Forms.ToolTip]::new()
$statusTips.SetToolTip($saveProfile, '保存当前方案，下次可继续编辑')
$statusTips.SetToolTip($apply, '保存当前方案并在下次启动游戏时使用')
$statusTips.SetToolTip($importSong, '或将文件拖入此处')
$statusTips.SetToolTip($profileBpm, '1–600 BPM，小数用英文句点')
$status.Add_TextChanged({ $statusTips.SetToolTip($status, $status.Text) })
$profileSong.Add_TextChanged({ $statusTips.SetToolTip($profileSong, $profileSong.Text) })

$advanced = New-SettingsWindow '速度曲线' 750 354
$curveScroll = [Windows.Forms.Panel]::new()
$curveScroll.AutoScroll = $true
$curveScroll.Dock = 'Fill'
$advanced.Controls.Add($curveScroll)
$graph.SetBounds(16, 16, 448, 265)
$curveScroll.Controls.Add($graph)
$advancedPreview = New-BowPreview (Join-Path $PSScriptRoot 'bow.svg')
$advancedPreview.SetBounds(480, 16, 254, 150)
$advancedPreview.Anchor = 'Top, Left'
$curveScroll.Controls.Add($advancedPreview)
[void](New-SettingsControl $curveScroll Label '选中线段' 480 182 95 25)
$speedSmooth = New-SettingsControl $curveScroll RadioButton '平滑曲线' 480 211 100 31
$speedLine = New-SettingsControl $curveScroll RadioButton '直线' 589 211 75 31
$delete = New-SettingsControl $curveScroll Button '删除选中点' 480 251 116 31
$resetCurve = New-SettingsControl $curveScroll Button '恢复默认曲线' 606 251 128 31
$curveError = New-SettingsControl $curveScroll Label '' 16 311 568 26
$curveError.ForeColor = [Drawing.Color]::Firebrick
$closeAdvanced = New-SettingsControl $curveScroll Button '返回设置' 619 304 115 32
$advanced.CancelButton = $closeAdvanced
$closeAdvanced.DialogResult = 'OK'
function Show-SegmentControls {
    $speedSmooth.Checked = $graph.Smooth
    $speedLine.Checked = !$graph.Smooth
    $delete.Enabled = $graph.CanDelete
    $curveError.Text = if ($graph.Curve.CanPlay) { '' } else { '整拍速度为零，请提高速度。' }
}
$speedSmooth.Add_Click({ $graph.SetSmooth($true) })
$speedLine.Add_Click({ $graph.SetSmooth($false) })
$delete.Add_Click({ $graph.DeleteSelected() })
$resetCurve.Add_Click({ $graph.SetCurve([BeatCurve]::Uniform()) })
$graph.Add_SelectionChanged({ Show-SegmentControls })
$graph.Add_CursorMoved({
    $heightGraph.Position = $graph.Position
    Show-BowPose
})
$graph.Add_CurveEdited({
    Show-SegmentControls
    if ($advanced.Visible) {
        $heightGraph.Position = $graph.Position
        $heightGraph.SetMotion($graph.Curve)
    }
})
$advancedButton.Add_Click({
    if ($heightGraph.Editable) { return }
    $resumePreview = $clock.IsRunning -or $musicPreview.Active
    if ($musicPreview.Active) { Close-MusicPreview }
    Stop-BowPlayback
    $graph.SetCurve($heightGraph.Motion)
    $graph.Position = $heightGraph.Position
    Fit-SettingsWindow $advanced
    [void]$advanced.ShowDialog($form)
    if ($resumePreview) { Start-BowPlayback }
})
. (Join-Path $PSScriptRoot 'Height-Editor.ps1')
$heightWindow.Add_VisibleChanged({ if ($heightWindow.Visible) { Show-BowPose } })
$advanced.Add_VisibleChanged({ if ($advanced.Visible) { Show-BowPose } })
$resetBoth.Add_Click({
    $heightGraph.SetMotion([HeightCurve]::Default())
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $rows[$i].Field.Text = Format-BeatPercent $beatDefaults[$i]
    }
    $status.Text = '已恢复默认动画'
})
$apply.Add_Click({
    try {
        if (Get-Process Korabli, Korabli64, WorldOfWarships, WorldOfWarships64 -ErrorAction SilentlyContinue) {
            throw '请完全退出游戏后再应用。'
        }
        $draft = Get-ProfileDraft
        $beat = $profileUI.Beat
        Save-ProfileDraft $draft
        $appliedMusic = if ($hasMusic) {
            $draft.Music + $beat + @{ profile = $draft.Id; songless = !$draft.Music.track }
        }
        if ($hasEffects) {
            $form.UseWaitCursor = $true
            $status.Text = '正在应用设置…'
            $status.Refresh()
            $values = @($draft.Values | ForEach-Object { $_.ToString('R', $beatCulture) })
            Save-EffectDraft $path $values $heightGraph.Motion $draft.Effects $beat.bpm $enableBox.Checked $appliedMusic
            $script:enabled = $enableBox.Checked
        } else {
            Save-BeatAmplitudes $path @($rows | ForEach-Object { $_.Field.Text }) $heightGraph.Motion $beat.bpm
            if ($appliedMusic) { Write-GameMusicJson $gameMusicPrefs $appliedMusic }
        }
        $script:musicPreferences = $appliedMusic
        if ($hasMusic -and $musicInstall) { Sync-GameMusicMonitor }
        if ($launcherSession) { Save-PlayerSettings $launcherSession }
        $status.Text = "已应用「$($draft.Name)」。下次启动游戏生效。"
        if ($hasMusic -and $musicInstall) {
            Show-GameMusicState
            $statusTips.SetToolTip($musicVolume, '当前战斗音乐即时生效')
        }
    } catch {
        $status.Text = "$($_.Exception.Message)"
    } finally {
        $form.UseWaitCursor = $false
    }
})

$initialBeat = if ($hasMusic) { Get-SongBeat $null } else { @{ bpm = $sequence.Bpm; drumFrame = 0 } }
$profileUI = @{ Loading = $false; Index = 0; Beat = $initialBeat; HasSong = $false; ManualBpmEdited = $false; Drafts = [Collections.Generic.List[object]]::new() }
$profileUI.Drafts.AddRange([object[]]$profileLibrary.Profiles)

$profileName.Add_TextChanged({ Update-InputErrors })
$profileList.Add_SelectedIndexChanged({
    $index = $profileList.SelectedIndex
    if ($profileUI.Loading -or $index -lt 0 -or $index -eq $profileUI.Index) { return }
    try {
        $profileUI.Drafts[$profileUI.Index] = Get-ProfileDraft
        Update-ProfileList $index
        $status.Text = '退出游戏后应用'
        Show-ProfileDraft $index
    } catch {
        Update-ProfileList $profileUI.Index
        $status.Text = $_.Exception.Message
    }
})
$saveProfile.Add_Click({
    try {
        Save-ProfileDraft (Get-ProfileDraft)
        $status.Text = '方案已保存。退出游戏后点「应用到游戏」切换游戏设置。'
    } catch { $status.Text = $_.Exception.Message }
})
$newProfile.Add_Click({
    try { Add-EmptyProfile }
    catch { $status.Text = $_.Exception.Message }
})
$deleteProfile.Add_Click({
    try { Remove-CurrentProfile }
    catch { $status.Text = $_.Exception.Message }
})

try {
    if ($hasMusic) {
        . $musicTool
        . (Join-Path $PSScriptRoot 'Music-Preview.ps1')
        . (Join-Path $PSScriptRoot 'Song-Import.ps1')
    }
    $selected = [array]::IndexOf(@($profileLibrary.Profiles.Id), $profileLibrary.Selected)
    Update-ProfileList $selected
    Show-ProfileDraft $selected
    if ($launcherSession) {
        . (Join-Path $launcherSession.Components 'UpdateWindow.ps1') $form $maintenancePage $launcherSession 16 688
    }
    if ($musicPlayer) { Enable-ProfileSongDrop $form }
    if ($settingsBackupError) { $status.Text = $settingsBackupError }
    $navigation.Controls[0].Checked = $true
    Scale-SettingsWindow $advanced
    Scale-SettingsWindow $heightWindow
    Scale-SettingsWindow $form
    $workArea = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $form.MinimumSize = [Drawing.Size]::new([Math]::Min($workArea.Width, [int]($form.Width * 0.74)),
        [Math]::Min($workArea.Height, [int]($form.Height * 0.60)))
    Fit-SettingsWindow $form
    [void]$form.ShowDialog()
} catch {
    [void][Windows.Forms.MessageBox]::Show("无法打开设置窗口。`n`n$($_.Exception.Message)", '莱斯塔-保持Q弹')
} finally {
    if ($musicTimer) { $musicTimer.Dispose() }
    if ($musicPlayer) { $musicPlayer.Dispose() }
    if ($editorLock) { $editorLock.Dispose() }
    $timer.Dispose()
    $errors.Dispose()
    $statusTips.Dispose()
    $advanced.Dispose()
    $heightWindow.Dispose()
    $form.Dispose()
}
