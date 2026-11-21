param([string]$SongsRoot)

$gameMusicRoot = Join-Path $PSScriptRoot 'music'
$gameMusicPrefs = Join-Path $gameMusicRoot 'preferences.json'
$modFolder = [IO.DirectoryInfo]::new($PSScriptRoot)
$userMusicRoot = if ($SongsRoot) { [IO.Path]::GetFullPath($SongsRoot) }
    elseif ($modFolder.Parent.Name -eq 'PnFMods' -and $modFolder.Parent.Parent.Name -eq 'res_mods') {
        Join-Path $modFolder.Parent.Parent.FullName '莱斯塔-保持Q弹\玩家数据\Songs'
    } else { Join-Path $PSScriptRoot '玩家数据\Songs' }
$gameMusicRuntime = Join-Path $gameMusicRoot 'runtime'
$gameMusicStatus = Join-Path $gameMusicRuntime 'status.json'
$gameMusicCommand = Join-Path $gameMusicRuntime 'command.json'
$gameMusicHost = Join-Path $PSScriptRoot 'GameMusicHost.ps1'
$gameMusicWindowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$gameMusicHostArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $gameMusicHost + '"'

function Import-MusicPlayer([string[]]$additionalSources = @()) {
    $libraries = @('NAudio.Core.dll', 'NAudio.Wasapi.dll' | ForEach-Object { Join-Path $gameMusicRoot $_ })
    foreach ($library in $libraries) { [void][Reflection.Assembly]::LoadFrom($library) }
    $standard = [Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51')
    $sources = @(@('BeatSchedule.cs', 'MusicPlayer.cs') + $additionalSources |
        ForEach-Object { Join-Path $PSScriptRoot $_ })
    Add-Type -LiteralPath $sources -ReferencedAssemblies ($libraries + $standard.Location)
}

function Import-SongBeatAnalyzer {
    $core = Join-Path $gameMusicRoot 'NAudio.Core.dll'
    # The installer renames the staged directory after restoring player settings.
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($core))
    $standard = [Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51')
    $sources = @('BeatSchedule.cs', 'SongBeatAnalysis.cs' | ForEach-Object { Join-Path $PSScriptRoot $_ })
    Add-Type -LiteralPath $sources -ReferencedAssemblies @($core, $standard.Location)
}

function Get-MusicTrigger($value) {
    # Older profiles used Game for automatic playback.
    if ($value -cin 'Battle', 'Game') { return 'Battle' }
    if ($value -ceq 'Silent') { return 'Silent' }
    return 'Manual'
}

function Get-MusicVolume($value) {
    if ($null -eq $value) { return 100 }
    return [Math]::Min(100, [Math]::Max(0, [int]$value))
}

function Get-MusicKey($value) {
    $binding = 0
    if (![int]::TryParse([string]$value, [ref]$binding) -or !$binding) { return 0 }
    Import-GameMusicHotkeys
    return [GameMusicHotkeys]::Normalize($binding)
}

function Import-GameMusicHotkeys([switch]$WithCapture) {
    if (!('GameMusicHotkeys' -as [type])) {
        $source = Join-Path $PSScriptRoot 'GameMusicHotkeys.cs'
        if ($WithCapture) {
            Add-Type -LiteralPath @($source, (Join-Path $PSScriptRoot 'MusicHotkeyCapture.cs')) -ReferencedAssemblies System.Windows.Forms
        } else {
            Add-Type -LiteralPath $source
        }
    }
}

function Read-GameMusicJson($file) {
    try {
        $stream = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite,Delete')
        $reader = [IO.StreamReader]::new($stream)
        try { $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
    } catch { $null }
}

function Test-SonglessMusic($preferences) {
    return $preferences.songless -is [bool] -and $preferences.songless
}

function Test-GameMusicPlayback($preferences) {
    return !(Test-SonglessMusic $preferences) -and (Get-MusicTrigger $preferences.trigger) -cne 'Silent'
}

function Test-ModEffectEnabled {
    $file = [IO.FileInfo]::new((Join-Path $PSScriptRoot 'settings.txt'))
    return $file.Exists -and $file.Length -le 128 -and
        [IO.File]::ReadAllText($file.FullName).Trim() -ceq 'enabled=true'
}

function Get-ConfiguredMusicTrackId($preferences, [string]$defaultTrack) {
    if (Test-SonglessMusic $preferences) { return }
    if ($preferences.track) { return $preferences.track }
    return $defaultTrack
}

function Read-BuiltInMusicTracks {
    foreach ($track in (Read-GameMusicJson (Join-Path $gameMusicRoot 'tracks.json'))) {
        $track | Add-Member -NotePropertyName path -NotePropertyValue (Join-Path $gameMusicRoot ($track.id + '.wav')) -PassThru
    }
}

function Read-UserMusicTrack([string]$id) {
    if ($id -cnotmatch '^user-[0-9a-f]{32}$') { return }
    $folder = Join-Path $userMusicRoot $id
    $track = Read-GameMusicJson (Join-Path $folder 'track.json')
    $wav = Join-Path $folder 'audio.wav'
    if ($track.id -cne $id -or $track.title -isnot [string] -or !$track.title.Trim() -or ![IO.File]::Exists($wav)) { return }
    try {
        $bpm = [double]$track.bpm
        $frames = [int]$track.frames
        $drum = [int]$track.drumFrame
    } catch { return }
    if ($bpm -ge 1 -and $bpm -le 600 -and $frames -gt 0 -and $drum -ge 0 -and $drum -lt $frames) {
        $beatStatus = if ($track.beatStatus -cin 'detected', 'uncertain', 'unavailable') { $track.beatStatus }
            elseif ($drum -gt 0 -or [IO.File]::Exists((Join-Path $folder 'edit.lock'))) { 'calibrated' }
            else { 'pending' }
        return [pscustomobject]@{
            id = $id; title = $track.title; bpm = $bpm; frames = $frames
            drumFrame = $drum; beatStatus = $beatStatus; path = $wav
        }
    }
}

function Read-UserMusicTracks {
    if ([IO.Directory]::Exists($userMusicRoot)) {
        Get-ChildItem -LiteralPath $userMusicRoot -Directory -Filter 'user-*' | ForEach-Object {
            Read-UserMusicTrack $_.Name
        } | Sort-Object title, id
    }
}

function Get-SongBeat($track, $applied = $null) {
    if (Test-SonglessMusic $applied) {
        $bpm = if ($applied.bpm -ge 1 -and $applied.bpm -le 600) { [double]$applied.bpm } else { 130.0 }
        return @{ bpm = $bpm; drumFrame = 0 }
    }
    if ($track) {
        if ($applied.track -ceq $track.id -and $applied.bpm -ge 1 -and $applied.bpm -le 600 -and
            $null -ne $applied.drumFrame -and $applied.drumFrame -ge 0 -and $applied.drumFrame -lt $track.frames) {
            return @{ bpm = [double]$applied.bpm; drumFrame = [int]$applied.drumFrame }
        }
        if ($track.beatStatus -cnotin 'pending', 'unavailable') {
            return @{ bpm = [double]$track.bpm; drumFrame = [int]$track.drumFrame }
        }
    }
    return @{ bpm = 130.0; drumFrame = 0 }
}

function Find-UserSongBeat([string]$wav, [int]$frames) {
    $candidates = [SongBeatAnalysis]::Start($wav).GetAwaiter().GetResult().Candidates
    $candidate = $candidates | Where-Object { $_.DrumFrame -lt $frames } | Select-Object -First 1
    if ($candidate) {
        return @{
            bpm = $candidate.Bpm; drumFrame = $candidate.DrumFrame
            beatStatus = if ($candidate.Uncertain) { 'uncertain' } else { 'detected' }
        }
    }
    return (Get-SongBeat $null) + @{ beatStatus = 'unavailable' }
}

function Import-UserMusicTrack([string]$source) {
    $title = [IO.Path]::GetFileNameWithoutExtension($source).Trim()
    if (!$title) { $title = [IO.Path]::GetFileName($source) }
    $id = 'user-' + [Guid]::NewGuid().ToString('N')
    $folder = Join-Path $userMusicRoot $id
    $pending = Join-Path $userMusicRoot ('.import-' + $id)
    [void][IO.Directory]::CreateDirectory($pending)
    try {
        $wav = Join-Path $pending 'audio.wav'
        $frames = [MusicImport]::Decode($source, $wav)
        $beat = Find-UserSongBeat $wav $frames
        Write-GameMusicJson (Join-Path $pending 'track.json') ($beat + @{ id = $id; title = $title; frames = $frames })
        [IO.Directory]::Move($pending, $folder)
    } finally {
        if ([IO.Directory]::Exists($pending)) {
            [IO.File]::Delete((Join-Path $pending 'audio.wav'))
            [IO.File]::Delete((Join-Path $pending 'track.json'))
            [IO.Directory]::Delete($pending)
        }
    }
    Read-UserMusicTrack $id
}

function Resolve-UserSongBeat($track) {
    if ($track.beatStatus -cne 'pending') { return $track }
    $folder = Join-Path $userMusicRoot $track.id
    $lock = [IO.File]::Open((Join-Path $folder 'beat-analysis.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $savedTrack = Read-UserMusicTrack $track.id
        if (!$savedTrack) { throw '无法读取这首歌的对拍设置。' }
        if ($savedTrack.beatStatus -ceq 'pending') {
            $beat = Find-UserSongBeat $savedTrack.path $savedTrack.frames
            Write-GameMusicJson (Join-Path $folder 'track.json') ($beat + @{
                id = $savedTrack.id; title = $savedTrack.title; frames = $savedTrack.frames
            })
            $savedTrack = Read-UserMusicTrack $track.id
        }
        return $savedTrack
    } finally {
        $lock.Dispose()
    }
}

function Read-LiveGameMusicStatus {
    if (![IO.File]::Exists($gameMusicStatus)) { return }
    $view = Read-GameMusicJson $gameMusicStatus
    $processId = 0
    if (!$view.startTicks -or $view.token -cnotmatch '^[0-9a-f]{32}$' -or
        ![int]::TryParse([string]$view.pid, [ref]$processId) -or $processId -lt 1) { return }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    try {
        if ($process -and $process.ProcessName -eq 'powershell' -and
            $process.StartTime.ToUniversalTime().Ticks -eq $view.startTicks) { return $view }
    } catch [InvalidOperationException] {
        # The session can finish between reading its status and looking up its process.
    } finally { if ($process) { $process.Dispose() } }
}

function Write-GameMusicJson($file, $value, [int]$depth = 2) {
    $pending = $file + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($pending, ($value | ConvertTo-Json -Depth $depth -Compress))
        if ([IO.File]::Exists($file)) {
            [IO.File]::Replace($pending, $file, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($pending, $file)
        }
    } finally {
        if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    }
}

function Get-GameMusicClientPath {
    $mod = [IO.DirectoryInfo]::new($PSScriptRoot)
    $version = $mod.Parent.Parent.Parent
    if ($mod.Name -ne 'JellyShips04Coverage' -or $mod.Parent.Name -ne 'PnFMods' -or
        $mod.Parent.Parent.Name -ne 'res_mods' -or $version.Name -notmatch '^\d+$' -or $version.Parent.Name -ne 'bin') { return }
    $root = $version.Parent.Parent.FullName
    $exe = Join-Path $version.FullName 'bin64\Korabli64.exe'
    $client = Select-Xml -LiteralPath (Join-Path $root 'game_info.xml') -XPath '//game/part_versions/version[@name="client"]' -ErrorAction SilentlyContinue
    if (($client.Node.installed -split '\.')[-1] -ne $version.Name -or ![IO.File]::Exists($exe)) { return }
    return @{ Exe = $exe; Log = Join-Path $root 'profile\python.log' }
}

function Start-GameMusicMonitor {
    if (!(Test-ModEffectEnabled) -or !(Test-GameMusicPlayback (Read-GameMusicJson $gameMusicPrefs)) -or
        !(Get-GameMusicClientPath) -or (Read-LiveGameMusicStatus)) { return }
    $sessionId = [Guid]::NewGuid().ToString('N')
    $launch = [Diagnostics.ProcessStartInfo]::new($gameMusicWindowsPowerShell, ($gameMusicHostArgs + ' -SessionId ' + $sessionId))
    $launch.UseShellExecute = $false
    $launch.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($launch)
}
