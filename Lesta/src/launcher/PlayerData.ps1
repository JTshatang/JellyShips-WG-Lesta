# Earlier launchers registered one home per game and shared a song library across installs.
function Get-LegacyPlayerHome([string]$game) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($game.ToUpperInvariant()))
        $id = [BitConverter]::ToString($digest, 0, 8).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    $base = Join-Path $env:LOCALAPPDATA 'JellyShips'
    $homeDir = Join-Path $base $id
    foreach ($path in $base, $homeDir, (Join-Path $homeDir 'game.txt')) { Assert-RegularPath $path }
    $mapping = Join-Path $homeDir 'game.txt'
    if ([IO.File]::Exists($mapping) -and [IO.File]::ReadAllText($mapping).Trim() -eq $game) { $homeDir }
}

function Get-PortableSongFiles([string]$songs) {
    Assert-RegularPath $songs
    if (![IO.Directory]::Exists($songs)) { return }
    foreach ($track in Get-ChildItem -LiteralPath $songs -Directory -Filter 'user-*' -ErrorAction Stop) {
        if ($track.Name -cnotmatch '^user-[0-9a-f]{32}$') { continue }
        Assert-RegularPath $track.FullName
        foreach ($name in 'track.json', 'audio.wav', 'edit.lock') {
            $path = Join-Path $track.FullName $name
            Assert-RegularPath $path
            if ([IO.File]::Exists($path)) { Get-Item -LiteralPath $path }
        }
    }
}

function Get-PreviousPlayerData($layout, [string]$sourcePortal) {
    $bin = Join-Path $layout.Game 'bin'
    $candidates = foreach ($version in Get-ChildItem -LiteralPath $bin -Directory -ErrorAction Stop) {
        if ($version.Name -cnotmatch '^[0-9]+$' -or ($version.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $mods = Join-Path $version.FullName 'res_mods'
        $portal = Join-Path $mods $playerBrand
        if ($portal -eq $layout.Portal) { continue }
        $data = Join-Path $portal '玩家数据'
        $saved = Join-Path $data 'player.json'
        try {
            foreach ($path in $mods, $portal, $data, $saved) { Assert-RegularPath $path }
            if (![IO.File]::Exists($saved)) { continue }
            $info = Read-InstallJson $saved
        } catch { continue }
        if (!$info.settings -or ($info.build -split '\.')[-1] -cne $version.Name) { continue }
        [pscustomobject]@{ Source = $portal; File = $saved; Songs = (Join-Path $data 'Songs')
            Preferred = ($portal -eq $sourcePortal); Date = [IO.File]::GetLastWriteTimeUtc($saved); Legacy = $false }
    }
    $candidate = $candidates | Sort-Object Preferred,Date -Descending | Select-Object -First 1
    if ($candidate) { return $candidate }
    $old = Get-LegacyPlayerHome $layout.Game
    if ($old) {
        $saved = Join-Path $old 'player.json'
        $songs = Join-Path (Split-Path $old -Parent) 'Songs'
        Assert-RegularPath $saved
        Assert-RegularPath $songs
        if ([IO.File]::Exists($saved) -or [IO.Directory]::Exists($songs)) {
            return [pscustomobject]@{ Source = $old; File = $saved; Songs = $songs; Legacy = $true }
        }
    }
}

function Confirm-PlayerDataImport($candidate) {
    Add-Type -AssemblyName System.Windows.Forms
    $message = if ($candidate.Legacy) {
        "导入旧版备份的方案和本机旧曲库中的歌曲？文件将复制到这份游戏的模组目录，旧文件保留。"
    } else { "沿用上一版的方案和歌曲？文件将复制到当前游戏版本，上一版的文件保留。" }
    return [Windows.Forms.MessageBox]::Show("$message`n`n$($candidate.Source)", $playerBrand, 'YesNo', 'Question') -eq 'Yes'
}

function Initialize-PortablePlayerData($layout, [string]$sourcePortal) {
    $target = Join-Path $layout.Portal '玩家数据'
    Assert-RegularPath $layout.Portal
    Assert-RegularPath $target
    if ([IO.Directory]::Exists($target)) { return }
    $candidate = Get-PreviousPlayerData $layout $sourcePortal
    if (!$candidate -or !(Confirm-PlayerDataImport $candidate)) {
        [void][IO.Directory]::CreateDirectory($target)
        return
    }
    # Publish only after all songs and settings have been copied successfully.
    $stage = Join-Path $layout.Portal ('.player-import-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        if ([IO.File]::Exists($candidate.File)) {
            if (!(Read-InstallJson $candidate.File).settings) { throw '旧版方案备份无法读取。' }
            [IO.File]::Copy($candidate.File, (Join-Path $stage 'player.json'))
        }
        foreach ($file in Get-PortableSongFiles $candidate.Songs) {
            $dir = Join-Path (Join-Path $stage 'Songs') $file.Directory.Name
            [void][IO.Directory]::CreateDirectory($dir)
            [IO.File]::Copy($file.FullName, (Join-Path $dir $file.Name))
        }
        [IO.Directory]::Move($stage, $target)
    } finally { Remove-InstallDirectory $layout.Portal $stage }
}

function Export-PortablePlayerData($session, [string]$destination) {
    Save-PlayerSettings $session
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $data = Join-Path $session.Layout.Portal '玩家数据'
    $saved = Join-Path $data 'player.json'
    Assert-RegularPath $saved
    $temp = Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.player-export-' + [Guid]::NewGuid().ToString('N'))
    try {
        $archive = [IO.Compression.ZipFile]::Open($temp, 'Create')
        try {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $saved, '玩家数据/player.json')
            foreach ($file in Get-PortableSongFiles (Join-Path $data 'Songs')) {
                $entry = '玩家数据/Songs/' + $file.Directory.Name + '/' + $file.Name
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry)
            }
        } finally { $archive.Dispose() }
        if ([IO.File]::Exists($destination)) { [IO.File]::Replace($temp, $destination, [NullString]::Value) }
        else { [IO.File]::Move($temp, $destination) }
    } finally { [IO.File]::Delete($temp) }
}

function Get-LegacyMusicShortcut([string]$game) {
    $startup = [Environment]::GetFolderPath('Startup')
    if (!$startup) { return }
    $file = Join-Path $startup 'Lesta Jelly Ships Music.lnk'
    if (![IO.File]::Exists($file)) { return }
    Assert-RegularPath $file
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($file)
    try {
        $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $prefix = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $game 'bin') + '\'
        if ($link.TargetPath -eq $powershell -and $link.Arguments -match ('^' + [regex]::Escape($prefix) +
            '\d+\\res_mods\\PnFMods\\JellyShips04Coverage\\GameMusicHost\.ps1"$')) { $file }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-LegacyProgramFiles([string]$game) {
    $old = Get-LegacyPlayerHome $game
    if (!$old) { return }
    $pointer = Join-Path $old 'program.txt'
    Assert-RegularPath $pointer
    if (![IO.File]::Exists($pointer)) { return }
    $active = [IO.File]::ReadAllText($pointer).Trim()
    if ($active -cnotmatch '^program-[0-9a-f]{32}$') { return }
    $names = @('Launcher.ps1', 'Install.ps1', 'Updates.ps1', 'UpdateWindow.ps1', 'package.json')
    foreach ($dir in Get-ChildItem -LiteralPath $old -Directory -Filter 'program-*') {
        if ($dir.Name -cnotmatch '^program-[0-9a-f]{32}$') { continue }
        Assert-RegularPath $dir.FullName
        $items = @(Get-ChildItem -LiteralPath $dir.FullName -Force)
        if ($items.Count -ne $names.Count -or @($items | Where-Object { $_.PSIsContainer -or $_.Name -notin $names -or
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) { continue }
        $manifest = Read-InstallJson (Join-Path $dir.FullName 'package.json')
        if ($manifest.build -notmatch '^\d+(\.\d+){4}$' -or [int]$manifest.revision -lt 1 -or $manifest.portable_format) { continue }
        $dir
        if ($dir.Name -eq $active) {
            foreach ($name in $playerBrand,$previousBrand) {
                $exe = Join-Path $old "$name.exe"
                Assert-RegularPath $exe
                if ([IO.File]::Exists($exe)) {
                    try { $identity = [Reflection.AssemblyName]::GetAssemblyName($exe).Name } catch { continue }
                    if ($identity -eq $name) { Get-Item -LiteralPath $exe }
                }
            }
            Get-Item -LiteralPath $pointer
        }
    }
}

function Move-LegacyProgramToRecycleBin([string]$game) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $shortcut = Get-LegacyMusicShortcut $game
    if ($shortcut) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($shortcut, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
    }
    $old = Get-LegacyPlayerHome $game
    foreach ($item in @(Get-LegacyProgramFiles $game | Sort-Object { $_.Name -eq 'program.txt' })) {
        if ([IO.Path]::GetDirectoryName($item.FullName) -ne $old) { throw '旧版程序目录无效。' }
        if ($item.PSIsContainer) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
        }
    }
}
