function Set-ProfileSong([string]$id) {
    $draft = $profileUI.Drafts[$profileUI.Index]
    $custom = !$draft.BuiltIn
    $songless = $custom -and !$id
    $importSong.Visible = $custom
    $importSong.Enabled = $custom -and $null -ne $musicPlayer
    $importSong.Text = if ($songless) { '添加歌曲…' } else { '换歌…' }
    $removeSong.Visible = $custom -and !$songless
    $songFormatHint.Visible = $custom -and $null -ne $musicPlayer
    $songDropHint.Visible = $songless -and $null -ne $musicPlayer
    $profileBpmLabel.Visible = $profileBpm.Visible = $songless
    $track = $musicTracks | Where-Object id -CEQ $id
    if ($track.beatStatus -ceq 'pending' -and $musicPlayer) {
        $form.UseWaitCursor = $true
        $songBeatReadout.Text = '正在分析节拍…'
        $songBeatReadout.Refresh()
        try {
            $track = Resolve-UserSongBeat $track
            $musicTracks[[array]::IndexOf(@($musicTracks.id), $id)] = $track
        } catch {
            $status.Text = "节拍分析失败。$($_.Exception.GetBaseException().Message)"
        } finally { $form.UseWaitCursor = $false }
    }
    $profileUI.HasSong = $null -ne $track
    $profileUI.Beat = if ($songless) { @{ bpm = ConvertTo-AnimationBpm $profileBpm.Text; drumFrame = 0 } }
        else { Get-SongBeat $track }
    $profileSong.Text = if ($track) { $track.title }
        elseif ($id) { '找不到方案的歌曲' }
        else { '无歌曲' }
    $apply.Enabled = $songless -or $profileUI.HasSong
    foreach ($control in $musicMode, $musicTrigger, $musicVolume, $musicVolumeSlider, $pauseBinding, $playBinding) {
        $control.Enabled = $null -ne $track
    }
    Show-MusicHotkeys
    if ($musicInstall) { Show-GameMusicState }
    $bpm = $profileUI.Beat.bpm.ToString('0.####', $beatCulture)
    $songBeatReadout.Text = if ($songless) { '' }
        elseif (!$track) { "无声预览 · $bpm BPM" }
        elseif ($track.beatStatus -cin 'unavailable', 'pending') { "未取得拍点，按 $bpm BPM 循环" }
        elseif ($track.beatStatus -ceq 'uncertain') { "$bpm BPM · 部分段落可能错拍" }
        else { "$bpm BPM" }
    if ($musicPreview) { Set-MusicPreviewTrack $track $profileUI.Beat }
}

$profileBpm.Add_TextChanged({
    $draft = $profileUI.Drafts[$profileUI.Index]
    if ($profileUI.Loading -or $draft.BuiltIn -or $draft.Music.track) { return }
    try {
        $bpm = ConvertTo-AnimationBpm $profileBpm.Text
        $errors.SetError($profileBpm, '')
        $profileUI.ManualBpmEdited = $true
        if ($clock.IsRunning) {
            Show-BowPose
            $playback.Start = $heightGraph.Position
            $clock.Restart()
        }
        $profileUI.Beat = @{ bpm = $bpm; drumFrame = 0 }
    } catch { $errors.SetError($profileBpm, $_.Exception.Message) }
})

$removeSong.Add_Click({
    try {
        $draft = Get-ProfileDraft
        if ($draft.BuiltIn -or !$draft.Music.track) { return }
        if ($null -eq $draft.ManualBpm) { $draft.ManualBpm = $profileUI.Beat.bpm }
        $draft.Music.track = $null
        Write-ProfileDraft $draft
        $profileUI.Drafts[$profileUI.Index] = $draft
        Update-ProfileList $profileUI.Index
        Show-ProfileDraft $profileUI.Index
        if ($launcherSession) { Save-PlayerSettings $launcherSession }
        $status.Text = '已移除歌曲。退出游戏后点「应用到游戏」可切换为无声动画。'
    } catch { $status.Text = $_.Exception.Message }
})

$songFilePatterns = '*.wav', '*.mp3', '*.m4a', '*.flac', '*.ncm'

function Import-ProfileSong([string]$source) {
    $track = $null
    $committed = $false
    try {
        $draft = Get-ProfileDraft
        if ($draft.BuiltIn) { return }
        $form.UseWaitCursor = $true
        $status.Text = '正在导入歌曲并分析节拍…'
        $status.Refresh()
        $track = Import-UserMusicTrack $source
        if (!$track) { throw '无法读取导入的歌曲。' }
        $draft.Music.track = $track.id
        Write-ProfileDraft $draft
        $committed = $true
        $script:musicTracks += $track
        $index = $profileUI.Index
        $profileUI.Drafts[$index] = $draft
        Update-ProfileList $index
        Show-ProfileDraft $index
        $status.Text = '歌曲已导入，可直接试听。退出游戏后点「应用到游戏」切换游戏设置。'
        if ($launcherSession) { Save-PlayerSettings $launcherSession }
    } catch {
        $status.Text = if ($committed) { "歌曲已导入。$($_.Exception.GetBaseException().Message)" }
            else { "导入失败。$($_.Exception.GetBaseException().Message)" }
        if ($track -and !$committed) {
            $folder = Split-Path $track.path -Parent
            try {
                [IO.File]::Delete($track.path)
                [IO.File]::Delete((Join-Path $folder 'track.json'))
                [IO.Directory]::Delete($folder)
            } catch { $status.Text += ' 无法清理这次导入的歌曲文件。' }
        }
    } finally {
        $form.UseWaitCursor = $false
    }
}

$importSong.Add_Click({
    $picker = [Windows.Forms.OpenFileDialog]::new()
    try {
        $picker.Title = $importSong.Text.TrimEnd([char]0x2026)
        $patterns = $songFilePatterns -join ';'
        $picker.Filter = "音频文件 ($patterns)|$patterns"
        if ($picker.ShowDialog($form) -eq 'OK') { Import-ProfileSong $picker.FileName }
    } catch {
        $status.Text = "导入失败。$($_.Exception.GetBaseException().Message)"
    } finally {
        $picker.Dispose()
    }
})

function Get-DroppedProfileSong([Windows.Forms.DragEventArgs]$drag) {
    if (!$drag.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop, $false)) { return }
    if ($profileUI.Drafts[$profileUI.Index].BuiltIn) {
        $status.Text = '请先新建或选择自建方案，再拖入歌曲。'
        return
    }
    $files = $drag.Data.GetData([Windows.Forms.DataFormats]::FileDrop, $false)
    if ($files.Count -ne 1 -or
        "*$([IO.Path]::GetExtension($files[0]))" -notin $songFilePatterns -or
        ![IO.File]::Exists($files[0])) {
        $status.Text = '一次可导入一个音频文件（WAV、MP3、M4A、FLAC 或 NCM）。'
        return
    }
    return $files[0]
}

function Enable-ProfileSongDrop([Windows.Forms.Control]$control) {
    $control.AllowDrop = $true
    $control.Add_DragEnter({
        param($sender, $drag)
        $drag.Effect = 'None'
        if (($drag.AllowedEffect -band [Windows.Forms.DragDropEffects]::Copy) -and (Get-DroppedProfileSong $drag)) {
            $drag.Effect = 'Copy'
        }
    })
    $control.Add_DragDrop({
        param($sender, $drag)
        $source = Get-DroppedProfileSong $drag
        if ($source) { Import-ProfileSong $source }
    })
    foreach ($child in $control.Controls) { Enable-ProfileSongDrop $child }
}
