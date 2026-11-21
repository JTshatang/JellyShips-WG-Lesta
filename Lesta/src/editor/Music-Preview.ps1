$previewPlay = New-SettingsControl $previewGroup Button '试听' 0 245 73 29
$previewProgress = New-SettingsControl $previewGroup TrackBar '' 82 248 240 26
$previewProgress.AccessibleName = '歌曲进度'
$previewProgress.AutoSize = $false
$previewProgress.Height = 26
$previewProgress.TickStyle = 'None'
$previewTime = New-SettingsControl $previewGroup Label '' 0 283 173 22
$previewTime.AutoEllipsis = $true
[void](New-SettingsControl $previewGroup Label '试听音量' 181 283 60 22)
$previewVolume = New-SettingsControl $previewGroup NumericUpDown '' 243 280 52 26
$previewVolume.AccessibleName = '试听音量百分比'
$previewVolume.Value = 20
[void](New-SettingsControl $previewGroup Label '%' 298 283 20 22)
$statusTips.SetToolTip($previewProgress, '拖动定位。选中进度条后，用方向键微调 10 毫秒。')

try {
    Import-MusicPlayer @('MusicImport.cs', 'SongBeatAnalysis.cs')
    $previewProgress.SmallChange = [BeatSchedule]::SampleRate / 100
    $previewProgress.LargeChange = 5 * [BeatSchedule]::SampleRate
    $musicPlayer = [MusicPlayer]::new()
    $musicPlayer.Volume = [int]$previewVolume.Value
} catch {
    $previewPlay.Enabled = $previewProgress.Enabled = $previewVolume.Enabled = $false
    $previewTime.Text = '试听播放器不可用'
    $statusTips.SetToolTip($previewTime, $_.Exception.Message)
    return
}

$musicPreview = @{ Track = $null; Schedule = $null; Frame = 0L; Active = $false; Running = $false; ResumeAfterSeek = $false }

function Format-PreviewTime([long]$frame) {
    $ms = [long][Math]::Floor($frame * 1000 / [BeatSchedule]::SampleRate)
    $seconds = [long][Math]::Floor($ms / 1000)
    return '{0}:{1:00}.{2:000}' -f [Math]::Floor($seconds / 60), ($seconds % 60), ($ms % 1000)
}

function Show-MusicPreviewProgress {
    if (!$musicPreview.Track) {
        $previewTime.Text = ''
        $previewPlay.Text = '试听'
        return
    }
    $length = [long]$musicPreview.Track.frames
    $frame = [Math]::Min($length, $musicPreview.Frame)
    $previewProgress.Value = [int]$frame
    $previewPlay.Text = if ($musicPreview.Running -or $musicPreview.ResumeAfterSeek) { '暂停' } else { '试听' }
    $gap = if ($musicPreview.Frame -gt $length) { ' · 留白' } else { '' }
    $previewTime.Text = "$(Format-PreviewTime $frame) / $(Format-PreviewTime $length)$gap"
}

function Close-MusicPreview {
    $musicPlayer.Stop()
    $musicPreview.Active = $musicPreview.Running = $musicPreview.ResumeAfterSeek = $false
    $musicPreview.Frame = 0L
    if (!$clock.IsRunning) { $timer.Stop() }
    Show-MusicPreviewProgress
}

function Set-MusicPreviewTrack($track, $beat) {
    $musicPreview.Track = $track
    $musicPreview.Schedule = [BeatSchedule]::new($beat.bpm, $beat.drumFrame)
    $previewPlay.Enabled = $previewProgress.Enabled = $previewVolume.Enabled = $null -ne $track
    $previewProgress.Maximum = [int]$track.frames
    Show-MusicPreviewProgress
}

function Start-MusicPreview {
    $track = $musicPreview.Track
    $repeat = $loopMode.Checked
    if (!$repeat -and $musicPreview.Frame -ge [long]$track.frames) { $musicPreview.Frame = 0L }
    Stop-BowPlayback
    $musicPlayer.PlayPreview($track.path, $musicPreview.Schedule, $repeat, $musicPreview.Frame)
    $musicPreview.Active = $musicPreview.Running = $true
    $timer.Start()
    Show-MusicPreviewProgress
    Show-BowPose
}

function Update-MusicPreviewPlayback {
    $state = $musicPlayer.State
    $musicPreview.Frame = $musicPlayer.PreviewPosition
    if ($state -in 'Finished', 'Failed') {
        if ($state -eq 'Failed') { $status.Text = "试听失败。$($musicPlayer.Error)" }
        $musicPreview.Running = $false
        $timer.Stop()
    }
    Show-MusicPreviewProgress
}

function Complete-MusicPreviewSeek {
    if (!$musicPreview.ResumeAfterSeek) { return }
    $musicPreview.ResumeAfterSeek = $false
    if ($loopMode.Checked -or $musicPreview.Frame -lt [long]$musicPreview.Track.frames) {
        Start-MusicPreview
    } else { Show-MusicPreviewProgress }
}

function Stop-MusicPreviewAtPosition {
    $musicPlayer.Stop()
    $musicPreview.Frame = $musicPlayer.PreviewPosition
    $musicPreview.Running = $false
    $timer.Stop()
    Show-MusicPreviewProgress
    Show-BowPose
}

$previewPlay.Add_Click({
    if ($musicPreview.Running) { Stop-MusicPreviewAtPosition }
    else { Start-MusicPreview }
})
$previewProgress.Add_Scroll({
    $frame = $previewProgress.Value
    if ($musicPreview.Running) {
        $musicPlayer.Stop()
        $musicPreview.Running = $false
        $musicPreview.ResumeAfterSeek = $true
    }
    Stop-BowPlayback
    $musicPreview.Active = $true
    $musicPreview.Frame = [long]$frame
    Show-MusicPreviewProgress
    Show-BowPose
    if (!$previewProgress.Capture) { Complete-MusicPreviewSeek }
})
$previewProgress.Add_MouseUp({ Complete-MusicPreviewSeek })
$previewProgress.Add_MouseCaptureChanged({ if (!$previewProgress.Capture) { Complete-MusicPreviewSeek } })
$previewVolume.Add_ValueChanged({ $musicPlayer.Volume = [int]$previewVolume.Value })
$loopMode.Add_CheckedChanged({
    if ($profileUI.Loading -or !$musicPreview.Active) { return }
    Close-MusicPreview
    Start-BowPlayback
})
