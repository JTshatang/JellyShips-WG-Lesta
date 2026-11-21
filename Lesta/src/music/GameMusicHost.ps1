param([string]$SessionId)
$ErrorActionPreference = 'Stop'
if ($SessionId -cnotmatch '^[0-9a-f]{32}$') { return }
. (Join-Path $PSScriptRoot 'GameMusicFiles.ps1')
$install = Get-GameMusicClientPath
if (!$install) { return }

[void][IO.Directory]::CreateDirectory($gameMusicRuntime)
try {
    $hostLock = [IO.File]::Open((Join-Path $gameMusicRuntime 'host.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch [IO.IOException] { return }

$player = $null
$hotkeys = $null
$client = $null
$token = $SessionId
$endSession = Get-MusicSessionEndFile $token
$startTicks = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
$status = @{ token = $token; pid = $PID; startTicks = $startTicks; client = ''; scene = 0; beat = $null; ack = ''; state = 'Starting'; error = '' }
try {
    Write-GameMusicJson $gameMusicStatus $status
    if ([IO.File]::Exists($endSession)) { return }
    [object[]]$tracks = @(Read-BuiltInMusicTracks)
    if (!$tracks) { throw '找不到随包歌曲。' }
    Import-MusicPlayer @('GameMusic.cs')
    Import-GameMusicHotkeys

    $player = [MusicPlayer]::new()
    $hotkeys = [GameMusicHotkeys]::new()
    $session = [GameMusicSession]::new()
    $pauseCue = $null
    $lastTrack = ''
    $trackError = ''
    $lastState = ''
    $lastPublish = [DateTime]::MinValue
    $nextScan = [DateTime]::MinValue
    $reader = $null
    $prefs = $null
    $sessionPath = Join-Path $gameMusicRuntime 'session.json'
    $uninstallSignal = Join-Path $PSScriptRoot 'uninstall.request'
    while (![IO.File]::Exists($uninstallSignal) -and ![IO.File]::Exists($endSession)) {
        if ($client -and $client.HasExited) { break }
        $now = [DateTime]::UtcNow
        $preferenceUpdate = Read-GameMusicJson $gameMusicPrefs
        if ($preferenceUpdate) { $prefs = $preferenceUpdate }
        $trackId = Get-ConfiguredMusicTrackId $prefs $tracks[0].id
        $session.Mode = if ($trackId) { Get-MusicTrigger $prefs.trigger } else { 'Manual' }
        $loop = $prefs.mode -ceq 'loop'

        if (!$client -and $now -ge $nextScan) {
            $nextScan = $now.AddMilliseconds(250)
            $client = Get-Process -Name Korabli64 -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $install.Exe } | Select-Object -First 1
            if ($client) {
                try {
                    $identity = "$($client.Id)-$($client.StartTime.ToUniversalTime().Ticks)"
                    $reader = [BattleBeatLog]::new($install.Log, $client.StartTime)
                    [void]$session.Observe($identity, 0, $null)
                    $checkpoint = Read-GameMusicJson $sessionPath
                    if ($checkpoint.client -ceq $identity) {
                        $session.Restore($checkpoint.battle)
                    }
                } catch [InvalidOperationException] {
                    $client.Dispose()
                    $client = $null
                    $reader = $null
                }
            }
        }

        if ($reader) {
            $reader.Poll()
            if ($session.Observe($identity, $reader.Scene, $reader.Beat)) {
                $pauseCue = $null
                $player.FadeOut()
            }
        }

        $activeStates = @('Waiting', 'Playing', 'BetweenRepeats')
        if ($trackId -cne $lastTrack) {
            $trackError = ''
            if (!$trackId) {
                $pauseCue = $null
                $player.Stop()
                $session.Stop()
            } elseif (!$player.IsFading -and ($session.Paused -or $player.State -in $activeStates)) {
                $pauseCue = $null
                $player.FadeOut()
                $session.Play()
            }
        }
        $lastTrack = $trackId
        $player.Loop = $loop
        $player.Volume = Get-MusicVolume $prefs.volume

        $pauseKey = if ($trackId) { Get-MusicKey $prefs.pauseKey } else { 0 }
        $playKey = if ($trackId) { Get-MusicKey $prefs.playKey } else { 0 }
        $focused = $trackId -and $reader -and $reader.Scene -ne 0 -and
            $null -ne $session.Beat -and $client -and [GameMusicHotkeys]::IsForeground($client.Id)
        $hotkeys.Configure($(if ($focused) { $client.Id } else { 0 }), $pauseKey, $playKey)
        $saveSession = $false
        $actions = @()
        $command = Read-GameMusicJson $gameMusicCommand
        if ($command.token -ceq $token -and $command.id -cne $status.ack) {
            if ($trackId) { $actions += $command.action }
            $status.ack = $command.id
        }
        while ($focused -and ($keyAction = $hotkeys.TakeAction()) -and [GameMusicHotkeys]::IsForeground($client.Id)) {
            $actions += $keyAction
        }
        foreach ($action in $actions) {
            switch -CaseSensitive ($action) {
                'Play' {
                    if ($null -ne $session.Beat) {
                        $player.Stop()
                        $pauseCue = $null
                        $session.Play()
                        $saveSession = $true
                    }
                }
                'TogglePause' {
                    if ($session.Paused) {
                        $session.Play()
                        $saveSession = $true
                    } elseif (!$player.IsFading -and $player.State -in $activeStates -and $session.Pause()) {
                        $captured = $player.Pause()
                        if ($captured) { $pauseCue = $captured }
                        $saveSession = $true
                    }
                }
                'Stop' {
                    $pauseCue = $null
                    $trackError = ''
                    $player.FadeOut()
                    $session.Stop()
                    $saveSession = $true
                }
            }
        }
        $startMusic = $trackId -and !$player.IsFading -and $session.TakeStart()
        if ($client -and ($saveSession -or $startMusic)) {
            Write-GameMusicJson $sessionPath @{
                client = $identity; battle = $session.LastHandledBattle
            }
        }
        if ($startMusic) {
            $track = if ($trackId -clike 'user-*') { Read-UserMusicTrack $trackId }
                else { $tracks | Where-Object id -CEQ $trackId }
            $trackError = if (!$track) { '找不到已应用的歌曲，请重新选择并应用方案。' } else { '' }
            if ($track) {
                $beat = Get-SongBeat $track $prefs
                $schedule = [BeatSchedule]::new($beat.bpm, $beat.drumFrame)
                $player.Play($track.path, $schedule, $loop, $session.Beat, $pauseCue)
            }
        } elseif ($player.State -notin 'Waiting', 'Stopped' -and !$session.Paused) {
            $pauseCue = $null
        }

        $status.client = if ($client) { $identity } else { '' }
        $status.scene = if ($reader) { $reader.Scene } else { 0 }
        $status.beat = $session.Beat
        $status.keyConflicts = $hotkeys.Conflicts
        $status.pauseFrame = if ($session.Paused) { $pauseCue.Frame }
        $status.state = if (!$trackId) { 'Silent' }
            elseif ($player.IsFading) { 'Fading' }
            elseif ($session.Paused) { 'Paused' }
            elseif ($session.Waiting) { 'AwaitingBeat' }
            elseif ($trackError) { 'Failed' }
            elseif ($pauseCue -and $player.State -eq 'Waiting') { 'Resuming' } else { $player.State.ToString() }
        $status.error = if ($trackError) { $trackError } else { $player.Error }
        $summary = "$($status.client)|$($status.scene)|$($status.beat)|$($status.state)|$($status.ack)|$($status.keyConflicts)"
        if ($summary -cne $lastState -or $now -ge $lastPublish.AddSeconds(1)) {
            try {
                Write-GameMusicJson $gameMusicStatus $status
                $lastPublish = $now
                $lastState = $summary
            } catch [IO.IOException] {
                # A reader can hold the old file briefly. Retry the next tick.
            }
        }

        Start-Sleep -Milliseconds $(if ($client) { 30 } else { 200 })
    }
} catch {
    $status.state = 'Unavailable'
    $status.error = $_.Exception.Message
    Write-GameMusicJson $gameMusicStatus $status
} finally {
    if ($hotkeys) { $hotkeys.Dispose() }
    if ($player) {
        $player.FadeOut()
        $deadline = [DateTime]::UtcNow.AddSeconds(1)
        while ($player.IsFading -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        $player.Dispose()
    }
    if ($client) { $client.Dispose() }
    try {
        [IO.File]::Delete($endSession)
        [IO.File]::Delete($gameMusicCommand)
        if ($status.state -ne 'Unavailable') { [IO.File]::Delete($gameMusicStatus) }
    } finally { $hostLock.Dispose() }
}
