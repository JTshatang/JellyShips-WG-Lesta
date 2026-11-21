$profileFile = Join-Path $PSScriptRoot 'profiles.json'

function Read-PlayerProfiles($sequence, [string]$effects, $tracks, $preferences) {
    $songs = @($tracks | Where-Object id -CNotLike 'user-*')
    if ([IO.File]::Exists($profileFile)) {
        $library = [IO.File]::ReadAllText($profileFile) | ConvertFrom-Json
        if (!$library.Profiles -or $library.Selected -cnotin @($library.Profiles.Id)) {
            throw '方案文件无效，请检查 profiles.json。'
        }
        $legacyTriggers = @($library.Profiles | Where-Object { $_.Music.trigger -ceq 'Game' })
        foreach ($profile in $legacyTriggers) { $profile.Music.trigger = Get-MusicTrigger $profile.Music.trigger }
        if ($null -ne $library.Profiles[0].BuiltIn) {
            if ($legacyTriggers.Count) { Write-GameMusicJson $profileFile $library 7 }
            return $library
        }

        # Libraries before song-bound profiles stored a BPM per profile and
        # let custom profiles pick either bundled recording.
        foreach ($song in $songs) {
            $matches = @($library.Profiles | Where-Object { $null -eq $_.Bpm -and $_.Music.track -ceq $song.id })
            $builtIn = $matches | Where-Object Name -CEQ $song.title | Select-Object -First 1
            if (!$builtIn) { $builtIn = $matches | Select-Object -First 1 }
            if (!$builtIn) {
                $name = Get-AvailableProfileName $song.title $library.Profiles.Name
                $builtIn = New-PlayerProfile $name $song.id ([HeightCurve]::Default()) $beatDefaults '11' $null $true
                $library.Profiles += $builtIn
            } else { $builtIn | Add-Member -NotePropertyName BuiltIn -NotePropertyValue $true }
        }
        foreach ($profile in $library.Profiles | Where-Object { $null -eq $_.BuiltIn }) {
            $profile | Add-Member -NotePropertyName BuiltIn -NotePropertyValue $false
        }
        Write-GameMusicJson $profileFile $library 7
        return $library
    }
    $track = Get-ConfiguredMusicTrackId $preferences $tracks[0].id
    if (!$songs -or $track -cnotin $songs.id) {
        $song = $tracks | Where-Object id -CEQ $track
        $title = if ($song -and $song.title -notin $songs.title) { $song.title } else { '当前设置' }
        $songs += [pscustomobject]@{ id = $track; title = $title }
    }
    $profiles = @(foreach ($song in $songs) {
        $applied = if ($song.id -ceq $track) { $preferences }
        $builtIn = $song.id -and $song.id -cnotlike 'user-*'
        $profile = New-PlayerProfile $song.title $song.id $sequence.Curve @(Get-BeatAmplitudes $sequence) $effects $applied $builtIn
        if (Test-SonglessMusic $applied) { $profile.ManualBpm = (Get-SongBeat $null $applied).bpm }
        $profile
    })
    $selected = $profiles | Where-Object { $_.Music.track -ceq $track } | Select-Object -First 1
    return [pscustomobject]@{ Selected = $selected.Id; Profiles = $profiles }
}

function New-PlayerProfile($name, $track, $motion, $values, $effects, $preferences, [bool]$builtIn) {
    [pscustomobject]((Get-ShipMotionSettings $motion) + @{
        Id = [Guid]::NewGuid().ToString('N'); Name = $name; BuiltIn = $builtIn
        Values = $values; Effects = $effects; ManualBpm = $null
        Music = @{
            track = $track
            mode = if ($preferences.mode -ceq 'loop') { 'loop' } else { 'once' }
            trigger = Get-MusicTrigger $preferences.trigger
            volume = Get-MusicVolume $preferences.volume
            pauseKey = Get-MusicKey $preferences.pauseKey
            playKey = Get-MusicKey $preferences.playKey
        }
    })
}

function Get-AppliedMusicProfile {
    if ($musicPreferences.profile) { return $musicPreferences.profile }
    $track = Get-ConfiguredMusicTrackId $musicPreferences $musicTracks[0].id
    $mode = if ($musicPreferences.mode -ceq 'loop') { 'loop' } else { 'once' }
    $trigger = Get-MusicTrigger $musicPreferences.trigger
    $curve = Get-ShipMotionSettings $sequence.Curve | ConvertTo-Json -Depth 4 -Compress
    $matches = @($profileLibrary.Profiles | Where-Object {
        $_.Music.track -ceq $track -and $_.Music.mode -ceq $mode -and $_.Music.trigger -ceq $trigger -and
        $_.Effects -ceq $effectMode -and
        ($_.Values -join '|') -ceq ($saved -join '|') -and
        ((Get-ShipMotionSettings (Read-ShipMotion $_)) | ConvertTo-Json -Depth 4 -Compress) -ceq $curve
    })
    if ($matches.Count -eq 1) { return $matches[0].Id }
}

function Set-AppliedMusicVolume([int]$volume) {
    $id = Get-AppliedMusicProfile
    if (!(Test-AppliedProfileSong $profileUI.Drafts[$profileUI.Index] $id)) { return }
    $profile = $profileLibrary.Profiles | Where-Object Id -CEQ $id
    $preferences = @{
        profile = $id
        track = Get-ConfiguredMusicTrackId $musicPreferences $musicTracks[0].id
        mode = if ($musicPreferences.mode -ceq 'loop') { 'loop' } else { 'once' }
        trigger = Get-MusicTrigger $musicPreferences.trigger
        pauseKey = Get-MusicKey $musicPreferences.pauseKey
        playKey = Get-MusicKey $musicPreferences.playKey
        volume = $volume
    }
    if ($null -ne $musicPreferences.bpm -and $null -ne $musicPreferences.drumFrame) {
        $preferences.bpm = $musicPreferences.bpm
        $preferences.drumFrame = $musicPreferences.drumFrame
    }
    Write-GameMusicJson $gameMusicPrefs $preferences
    $script:musicPreferences = $preferences
    if ($profile.Music -is [Collections.IDictionary]) { $profile.Music['volume'] = $volume }
    else { $profile.Music | Add-Member -NotePropertyName volume -NotePropertyValue $volume -Force }
    Write-GameMusicJson $profileFile $profileLibrary 7
    if ($launcherSession) { Save-PlayerSettings $launcherSession }
}

function Test-AppliedProfileSong($draft, $id) {
    $track = Get-ConfiguredMusicTrackId $musicPreferences $musicTracks[0].id
    return $track -and $id -and $draft.Id -ceq $id -and $draft.Music.track -ceq $track
}

function Get-ProfileNameError([string]$name) {
    $current = $profileUI.Drafts[$profileUI.Index]
    if (!$name) { return '请输入方案名称。' }
    foreach ($profile in @($profileUI.Drafts.ToArray()) + @($profileLibrary.Profiles)) {
        if ($profile.Id -cne $current.Id -and $profile.Name -eq $name) { return '方案名称已存在。' }
    }
    return ''
}

function Get-AvailableProfileName([string]$title, [string[]]$names) {
    $name = $title
    for ($number = 2; $name -in $names; $number++) { $name = "$title ($number)" }
    return $name
}

function Get-ProfileManualBpm($profile) {
    $bpm = $profile.ManualBpm -as [double]
    if ($bpm -ge 1 -and $bpm -le 600) { return $bpm }
    if (!$profile.Music.track) {
        $bpm = $profile.Bpm -as [double]
        if ($bpm -ge 1 -and $bpm -le 600) { return $bpm }
    }
    return $null
}

function Get-ProfileDraft {
    $current = $profileUI.Drafts[$profileUI.Index]
    $name = $profileName.Text.Trim()
    $nameError = Get-ProfileNameError $name
    if ($nameError) { throw $nameError }
    $values = @($rows | ForEach-Object { $_.Field.Text })
    [void](Get-BeatRatios $values)
    if (!$heightGraph.Motion.CanPlay) { throw '整拍速度都为零。请提高至少一段速度，再保存。' }
    $music = if ($hasMusic) {
        $pauseKey = [int]$pauseBinding.Tag
        $playKey = [int]$playBinding.Tag
        if ($pauseKey -and $pauseKey -eq $playKey) { throw "$(Format-MusicHotkey $pauseKey) 已同时用于两个动作，请更换。" }
        @{
            track = $current.Music.track
            mode = if ($loopMode.Checked) { 'loop' } else { 'once' }
            trigger = if ($battleTrigger.Checked) { 'Battle' } elseif ($silentTrigger.Checked) { 'Silent' } else { 'Manual' }
            volume = [int]$musicVolume.Value
            pauseKey = $pauseKey
            playKey = $playKey
        }
    } else { $current.Music }
    $manualBpm = Get-ProfileManualBpm $current
    if ($hasMusic -and !$current.BuiltIn -and !$current.Music.track) {
        $inputBpm = ConvertTo-AnimationBpm $profileBpm.Text
        if ($null -ne $manualBpm -or $profileUI.ManualBpmEdited) { $manualBpm = $inputBpm }
    }
    $effects = if ($hasEffects) { $current.Effects.Substring(0, 1) + [int]$wakeBox.Checked } else { $current.Effects }
    return [pscustomobject]((Get-ShipMotionSettings $heightGraph.Motion) + @{
        Id = $current.Id; Name = $name; BuiltIn = $current.BuiltIn
        Values = [double[]]$values; Music = $music; ManualBpm = $manualBpm
        Effects = $effects
    })
}

function Write-ProfileDraft($draft) {
    $saved = $profileLibrary.Profiles.Clone()
    $index = [array]::IndexOf(@($saved.Id), $draft.Id)
    if ($index -lt 0) { $saved += $draft }
    else { $saved[$index] = $draft }
    Write-GameMusicJson $profileFile @{ Selected = $draft.Id; Profiles = $saved } 7
    $profileLibrary.Profiles = $saved
    $profileLibrary.Selected = $draft.Id
}

function Save-ProfileDraft($draft) {
    Write-ProfileDraft $draft
    $profileUI.Drafts[$profileUI.Index] = $draft
    Update-ProfileList $profileUI.Index
    if ($launcherSession) { Save-PlayerSettings $launcherSession }
}

function Update-ProfileList([int]$index) {
    $profileUI.Loading = $true
    try {
        $profileList.Items.Clear()
        $profileList.Items.AddRange([object[]]@($profileUI.Drafts.Name))
        $profileList.SelectedIndex = $index
    } finally { $profileUI.Loading = $false }
}

function Show-ProfileDraft([int]$index) {
    if ($musicPreview.Active) { Close-MusicPreview }
    $profileUI.Index = $index
    $profileUI.ManualBpmEdited = $false
    $draft = $profileUI.Drafts[$index]
    $deleteProfile.Enabled = !$draft.BuiltIn -and $profileUI.Drafts.Count -gt 1
    Stop-BowPlayback
    $profileUI.Loading = $true
    try {
        $profileName.Text = $draft.Name
        $heightGraph.SetMotion((Read-ShipMotion $draft))
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $rows[$i].Field.Text = Format-BeatPercent $draft.Values[$i]
        }
        if ($hasEffects) {
            $wakeBox.Checked = $draft.Effects[1] -eq '1'
        }
        if ($hasMusic) {
            $bpm = Get-ProfileManualBpm $draft
            if ($null -eq $bpm) { $bpm = $defaultBeatBpm }
            $profileBpm.Text = $bpm.ToString('R', $beatCulture)
            $errors.SetError($profileBpm, '')
            $loopMode.Checked = $draft.Music.mode -ceq 'loop'
            $onceMode.Checked = !$loopMode.Checked
            $trigger = Get-MusicTrigger $draft.Music.trigger
            $battleTrigger.Checked = $trigger -ceq 'Battle'
            $silentTrigger.Checked = $trigger -ceq 'Silent'
            $manualTrigger.Checked = $trigger -ceq 'Manual'
            $applied = Test-AppliedProfileSong $draft (Get-AppliedMusicProfile)
            $volume = if ($applied -and $null -ne $musicPreferences.volume) { $musicPreferences.volume }
                else { $draft.Music.volume }
            $musicVolume.Value = Get-MusicVolume $volume
            $pauseBinding.Tag = Get-MusicKey $draft.Music.pauseKey
            $playBinding.Tag = Get-MusicKey $draft.Music.playKey
            Set-MusicRecordingTarget $null
            $statusTips.SetToolTip($musicVolume, $(if ($applied) { '当前战斗音乐即时生效' } else { '应用此方案后生效' }))
        }
    } finally {
        $profileUI.Loading = $false
    }
    if ($hasMusic) { Update-MusicHotkeyErrors }
    Update-InputErrors
    if ($hasMusic) { Set-ProfileSong $draft.Music.track }
    Show-SelectedPose $false
    Start-BowPlayback
}

function Add-EmptyProfile {
    $current = Get-ProfileDraft
    $names = @($profileUI.Drafts.Name) + @($profileLibrary.Profiles.Name) + @($current.Name)
    $name = Get-AvailableProfileName '新方案' $names
    $draft = New-PlayerProfile $name $null ([HeightCurve]::Default()) $beatDefaults '11' $null $false
    Write-ProfileDraft $draft
    $profileUI.Drafts[$profileUI.Index] = $current
    $profileUI.Drafts.Add($draft)
    $index = $profileUI.Drafts.Count - 1
    Update-ProfileList $index
    Show-ProfileDraft $index
    $status.Text = '方案已新建。可调整船形或导入歌曲。'
    if ($launcherSession) { Save-PlayerSettings $launcherSession }
}

function Remove-CurrentProfile {
    $index = $profileUI.Index
    $draft = $profileUI.Drafts[$index]
    if ($draft.BuiltIn -or $profileUI.Drafts.Count -le 1) { return }
    if ([Windows.Forms.MessageBox]::Show("删除「$($draft.Name)」？", '删除方案',
            'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
    $remaining = @($profileLibrary.Profiles | Where-Object Id -CNE $draft.Id)
    $selected = if ($index -eq 0) { $profileUI.Drafts[1].Id } else { $profileUI.Drafts[0].Id }
    Write-GameMusicJson $profileFile @{ Selected = $selected; Profiles = $remaining } 7
    $profileLibrary.Profiles = $remaining
    $profileLibrary.Selected = $selected
    $profileUI.Drafts.RemoveAt($index)
    Update-ProfileList 0
    Show-ProfileDraft 0
    $status.Text = '方案已删除。'
    if ($launcherSession) { Save-PlayerSettings $launcherSession }
}
