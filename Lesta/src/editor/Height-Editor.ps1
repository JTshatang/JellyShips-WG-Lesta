$heightWindow = New-SettingsWindow '动画曲线' 750 456
$heightWindow.KeyPreview = $true
$heightScroll = [Windows.Forms.Panel]::new()
$heightScroll.AutoScroll = $true
$heightScroll.Dock = 'Fill'
$heightWindow.Controls.Add($heightScroll)
$heightPreview = New-BowPreview (Join-Path $PSScriptRoot 'bow.svg')
$heightPreview.SetBounds(16, 16, 394, 126)
$heightPreview.Anchor = 'Top, Left'
$heightScroll.Controls.Add($heightPreview)
$heightTempo = New-SettingsControl $heightScroll Label '' 430 24 300 25
$heightReadout = New-SettingsControl $heightScroll Label '' 430 54 304 28
$heightPlay = New-SettingsControl $heightScroll Button '播放' 430 95 100 32
$heightMusic = New-SettingsControl $heightScroll CheckBox '配乐' 547 95 124 32

$views = New-SettingsControl $heightScroll TabControl '' 16 154 718 242
$views.AccessibleName = '动画编辑视图'
$views.Padding = [Drawing.Point]::new(12, 3)
$timingPage = [Windows.Forms.TabPage]::new('简易编辑')
$finePage = [Windows.Forms.TabPage]::new('自定义曲线')
$views.TabPages.AddRange(@($timingPage, $finePage))
$timingPage.BackColor = $finePage.BackColor = [Drawing.Color]::White

$timeline = [BeatTimeline]::new()
$timeline.SetBounds(5, 4, 700, 163)
$timeline.Ratios = $previewRatios
if ($heightPreview.Tag) {
    $box = $heightPreview.Tag.Size
    $scale = 160.0 / [Math]::Max($box.Width, $box.Height)
    try { $timeline.Bow = $heightPreview.Tag.Art.Draw([int][Math]::Max(1.0, $box.Width * $scale),
            [int][Math]::Max(1.0, $box.Height * $scale)) }
    catch { $timeline.AccessibleDescription = $_.Exception.Message }
}
$timingPage.Controls.Add($timeline)
$heightWindow.Add_Disposed({ if ($timeline.Bow) { $timeline.Bow.Dispose() } })

$timingFields = New-SettingsControl $timingPage Panel '' 14 174 680 35
$peakLabel = New-SettingsControl $timingFields Label '' 0 5 130 25
$peakField = New-SettingsControl $timingFields NumericUpDown '' 133 2 77 27
$holdLabel = New-SettingsControl $timingFields Label '' 243 5 135 25
$holdField = New-SettingsControl $timingFields NumericUpDown '' 380 2 77 27
foreach ($field in $peakField, $holdField) {
    $field.DecimalPlaces = 1
    $field.Increment = 1
}
$applySimple = New-SettingsControl $timingPage Button '套用简单动作' 14 174 135 31
$heightUndo = New-SettingsControl $heightScroll Button '撤销' 16 408 82 32
$closeHeight = New-SettingsControl $heightScroll Button '返回设置' 619 408 115 32
$closeHeight.DialogResult = 'OK'

$heightGraph.SetBounds(5, 4, 700, 163)
$finePage.Controls.Add($heightGraph)
$heightSpeed = [SpeedGraph]::new()
$heightSpeed.Bounds = $heightGraph.Bounds
$finePage.Controls.Add($heightSpeed)
$fineTools = New-SettingsControl $finePage Panel '' 14 174 680 35
[void](New-SettingsControl $fineTools Label '选中线段' 0 6 75 25)
$heightSmooth = New-SettingsControl $fineTools RadioButton '平滑曲线' 80 0 101 31
$heightLine = New-SettingsControl $fineTools RadioButton '直线' 186 0 62 31
$heightDelete = New-SettingsControl $fineTools Button '删除选中点' 396 0 126 31
$heightMirror = New-SettingsControl $fineTools Button '镜像后半拍' 536 0 140 31
$heightConvert = New-SettingsControl $fineTools Button '转为船高曲线' 536 0 140 31
$edit = @{
    Fine = $false; Updating = $false; Gesture = $null; Resume = $false; SpeedSource = $null; Pinned = $false
    History = [Collections.Generic.Stack[ShipMotion]]::new()
}

function Update-HeightEditor {
    $motion = $heightGraph.Motion
    $simple = $heightGraph.Editable -and $motion.HasSimpleTiming
    $timeline.Motion = $motion
    $timeline.Invalidate()
    $heightGraph.Visible = $edit.Fine -and $heightGraph.Editable
    $heightSpeed.Visible = $edit.Fine -and !$heightGraph.Editable
    $timingFields.Visible = $simple
    $applySimple.Visible = !$simple
    $edit.Updating = $true
    try {
        if ($edit.Fine -and !$heightGraph.Editable -and $edit.SpeedSource -ne $motion) {
            $edit.SpeedSource = $motion
            $heightSpeed.SetCurve($motion)
            $heightSpeed.Position = $heightGraph.Position
        }
        if ($simple) {
            $peakField.Value = [decimal]($motion.PeakTime * 100)
            $holdField.Value = [decimal]($motion.HoldEnd * 100)
        }
        $peakLabel.Text = $peakField.AccessibleName = $timeline.PeakLabel + '拍位（%）'
        $holdLabel.Text = $holdField.AccessibleName = $timeline.LowLabel + '保持至（%）'
    } finally { $edit.Updating = $false }
    $heightMirror.Visible = $heightGraph.Editable
    $heightConvert.Visible = !$heightGraph.Editable
    $heightConvert.Enabled = $motion.CanPlay
    $heightSmooth.Checked = (Get-FineGraph).Smooth
    $heightLine.Checked = !$heightSmooth.Checked
    $heightDelete.Enabled = if ($heightGraph.Editable) { $heightGraph.CanDelete } else { $heightSpeed.CanDelete }
    $heightUndo.Enabled = $edit.History.Count -gt 0
    $heightPlay.Enabled = $motion.CanPlay
    $advancedButton.Visible = !$heightGraph.Editable
}

# Keep the song frame while inspecting a pose. On release, seek to the
# corresponding phase of the nearest beat and continue the selected transport.
function Suspend-HeightPlayback {
    if ($musicPreview.Running) { Stop-MusicPreviewAtPosition }
    if ($musicPreview.Active) { $musicPreview.Active = $false }
    Stop-BowPlayback
}

function Sync-HeightSongPosition {
    $schedule = $musicPreview.Schedule
    $period = $schedule.Period * [BeatSchedule]::SampleRate
    $origin = $schedule.DrumFrame + $heightGraph.Position * $period
    $cycle = [Math]::Round(($musicPreview.Frame - $origin) / $period)
    $last = [long]$musicPreview.Track.frames - 1
    $cycle = [Math]::Max([Math]::Ceiling(-$origin / $period),
        [Math]::Min([Math]::Floor(($last - $origin) / $period), $cycle))
    $musicPreview.Frame = [long][Math]::Max(0, [Math]::Min($last, [Math]::Round($origin + $cycle * $period)))
    $musicPreview.Active = $true
    Show-MusicPreviewProgress
}

function Resume-HeightPlayback([bool]$run) {
    $run = $run -and $heightGraph.Motion.CanPlay
    $edit.Pinned = !$run
    if ($heightMusic.Checked) {
        Sync-HeightSongPosition
        if ($run) { Start-MusicPreview }
    } elseif ($run) { Start-BowPlayback }
    Show-BowPose
}

function Begin-HeightGesture {
    if ($edit.Gesture) { return }
    $edit.Gesture = $heightGraph.Motion
    $edit.Resume = $clock.IsRunning -or $musicPreview.Running
    Suspend-HeightPlayback
}

function End-HeightGesture([bool]$cancel) {
    if (!$edit.Gesture) { return }
    $before = $edit.Gesture
    $edit.Gesture = $null
    if ($before -ne $heightGraph.Motion) {
        if ($cancel) { $heightGraph.SetMotion($before) }
        else { $edit.History.Push($before) }
    }
    Update-HeightEditor
    Resume-HeightPlayback $edit.Resume
}

function Invoke-HeightEdit([scriptblock]$change) {
    Begin-HeightGesture
    $completed = $false
    try { & $change; $completed = $true }
    finally { End-HeightGesture (!$completed) }
}

function Set-HeightTiming([bool]$peak, [double]$value) {
    $motion = $heightGraph.Motion
    $hold = $motion.HoldEnd
    $top = $motion.PeakTime
    # Allow pre-existing, sub-percent intervals even when the other handle is moved.
    if ($peak) {
        $top = [Math]::Max([Math]::Min($top, $hold + .001), [Math]::Min([Math]::Max($top, .999), $value))
        $heightGraph.Position = $top
    } else {
        $hold = [Math]::Max(0.0, [Math]::Min([Math]::Max($hold, $top - .001), $value))
        $heightGraph.Position = $hold
    }
    $updated = $motion.WithTiming($hold, $top)
    if ($updated -ne $motion) { $heightGraph.SetMotion($updated) }
    else { Update-HeightEditor; Show-BowPose }
}

$views.Add_SelectedIndexChanged({ $edit.Fine = $views.SelectedTab -eq $finePage; Update-HeightEditor })
$heightUndo.Add_Click({
    if ($edit.History.Count) { $heightGraph.SetMotion($edit.History.Pop()) }
})
$applySimple.Add_Click({ Invoke-HeightEdit { $heightGraph.SetMotion([HeightCurve]::Default()) } })
$heightSmooth.Add_Click({ if (!(Get-FineGraph).Smooth) { Invoke-HeightEdit { (Get-FineGraph).SetSmooth($true) } } })
$heightLine.Add_Click({ if ((Get-FineGraph).Smooth) { Invoke-HeightEdit { (Get-FineGraph).SetSmooth($false) } } })
$heightDelete.Add_Click({ Invoke-HeightEdit { (Get-FineGraph).DeleteSelected() } })
$heightMirror.Add_Click({ Invoke-HeightEdit { $heightGraph.SetMotion($heightGraph.Motion.MirrorFirstHalf()) } })
$heightConvert.Add_Click({ Invoke-HeightEdit { $heightGraph.SetMotion([HeightCurve]::FromSpeedCurve($heightGraph.Motion)) } })
$heightGraph.Add_SelectionChanged({ Update-HeightEditor })
$heightGraph.Add_CursorMoved({ Show-BowPose })
$heightGraph.Add_MotionChanged({ Update-HeightEditor; Update-BowPlaybackButton; Show-BowPose })
function Get-FineGraph {
    if ($heightGraph.Editable) { return $heightGraph }
    return $heightSpeed
}
$heightSpeed.Add_SelectionChanged({ if (!$edit.Updating) { Update-HeightEditor } })
$heightSpeed.Add_CursorMoved({ $heightGraph.Position = $heightSpeed.Position; Show-BowPose })
$heightSpeed.Add_CurveEdited({
    if ($edit.Updating) { return }
    $edit.SpeedSource = $heightSpeed.Curve
    $heightGraph.Position = $heightSpeed.Position
    $heightGraph.SetMotion($heightSpeed.Curve)
})
foreach ($surface in $heightGraph, $heightSpeed, $timeline) {
    $surface.Add_MouseDown({ param($sender, $e) if ($e.Button -eq 'Left') { Begin-HeightGesture } })
    $surface.Add_MouseUp({ param($sender, $e) if ($e.Button -eq 'Left') { End-HeightGesture $false } })
    $surface.Add_MouseCaptureChanged({ param($sender, $e) if (!$sender.Capture) { End-HeightGesture $false } })
}
$timeline.Add_SeekRequested({ $heightGraph.Position = $timeline.RequestedTime; Show-BowPose })
$timeline.Add_PeakRequested({ Set-HeightTiming $true $timeline.RequestedTime })
$timeline.Add_HoldRequested({ Set-HeightTiming $false $timeline.RequestedTime })
foreach ($surface in $timeline, $heightGraph, $heightSpeed, $graph) {
    $surface.TabStop = $true
    $surface.AccessibleDescription = if ($surface -eq $timeline) { '左右方向键按一拍的 1% 查看船形。' }
        else { '左右方向键选点，Delete 删除选中的中间点。' }
    $statusTips.SetToolTip($surface, $surface.AccessibleDescription)
    $surface.Add_GotFocus({ param($sender, $e) $sender.Invalidate() })
    $surface.Add_LostFocus({ param($sender, $e) $sender.Invalidate() })
    $surface.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.KeyCode -in 'Left', 'Right' -and $e.Modifiers -eq 'None') { $e.IsInputKey = $true }
    })
    $surface.Add_KeyDown({
        param($sender, $e)
        if ($e.Modifiers -ne 'None' -or $sender.Capture) { return }
        if ($e.KeyCode -in 'Left', 'Right') {
            $step = if ($e.KeyCode -eq 'Left') { -1 } else { 1 }
            if ($sender -eq $graph) { $graph.SelectAdjacentKey($step) }
            else {
                Begin-HeightGesture
                try {
                    if ($sender -eq $timeline) {
                        $heightGraph.Position = [Math]::Max(0.0, [Math]::Min(1.0, $heightGraph.Position + $step / 100.0))
                    } else { $sender.SelectAdjacentKey($step) }
                } finally { End-HeightGesture $false }
            }
            $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Delete' -and $sender -ne $timeline) {
            if ($sender -eq $graph) { $delete.PerformClick() } else { $heightDelete.PerformClick() }
            $e.SuppressKeyPress = $true
        }
    })
}
foreach ($field in $peakField, $holdField) {
    $field.Add_ValueChanged({
        param($sender, $e)
        if ($edit.Updating) { return }
        Invoke-HeightEdit { Set-HeightTiming ($sender -eq $peakField) ([double]$sender.Value / 100) }
    })
}
$heightWindow.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Escape') {
        if ($edit.Gesture) {
            End-HeightGesture $true
            $heightGraph.Capture = $heightSpeed.Capture = $timeline.Capture = $false
        } else { $heightWindow.Close() }
        $e.SuppressKeyPress = $true
    } elseif ($e.Control -and $e.KeyCode -eq 'Z' -and !$edit.Gesture) {
        $heightUndo.PerformClick()
        $e.SuppressKeyPress = $true
    }
})
$heightPlay.Add_Click({
    $edit.Pinned = $false
    if ($musicPreview.Running) { Stop-MusicPreviewAtPosition }
    elseif ($clock.IsRunning) { Show-BowPose; Stop-BowPlayback }
    elseif ($heightMusic.Checked) { Start-MusicPreview }
    else { Start-BowPlayback }
    Show-BowPose
})
$heightMusic.Add_Click({
    $running = $clock.IsRunning -or $musicPreview.Running
    Suspend-HeightPlayback
    Resume-HeightPlayback $running
})
$heightButton.Add_Click({
    $wasMusic = [bool]$musicPreview.Active
    $wasRunning = $clock.IsRunning -or $musicPreview.Running
    $entryFrame = $musicPreview.Frame
    $heightMusic.Enabled = $null -ne $musicPreview.Track
    $heightMusic.Checked = $wasMusic
    $heightTempo.Text = '每分钟 {0:G6} 拍' -f $profileUI.Beat.bpm
    $views.SelectedTab = $timingPage
    $edit.Pinned = $false
    $edit.History.Clear()
    Update-HeightEditor
    Fit-SettingsWindow $heightWindow
    [void]$heightWindow.ShowDialog($form)
    $running = $clock.IsRunning -or $musicPreview.Running
    $songEnded = $wasMusic -and $heightMusic.Checked -and $musicPlayer.State -in 'Finished', 'Failed'
    if (!$songEnded -and ($wasMusic -ne $heightMusic.Checked -or $wasRunning -ne $running)) {
        Suspend-HeightPlayback
        if ($wasMusic) {
            if (!$heightMusic.Checked) { $musicPreview.Frame = $entryFrame }
            $musicPreview.Active = $true
            if ($wasRunning) { Start-MusicPreview } else { Show-MusicPreviewProgress }
        } elseif ($wasRunning) { Start-BowPlayback }
    }
    Show-BowPose
})
