$playerFiles = @('profiles.json', 'Beat.seq', 'settings.txt', 'effects.txt', 'music\preferences.json')
$launcherFiles = @('Launcher.ps1', 'Install.ps1', 'Portable.ps1', 'PlayerData.ps1', 'Updates.ps1', 'UpdateWindow.ps1', 'package.json')
$playerBrand = '莱斯塔-保持Q弹'
$previousBrand = '整舰Q弹'
. (Join-Path $PSScriptRoot 'PlayerData.ps1')

function Get-LauncherProgramFiles($package) {
    $launcherFiles
    foreach ($name in $package.launcher_hashes.PSObject.Properties.Name) {
        if ($name -in $launcherFiles -or $name -in "$playerBrand.exe",'资源包.zip') { continue }
        if ($name -notmatch '^[\p{L}\p{N}_-][\p{L}\p{N}_. -]*\.ps1\z' -or
            $name -match '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])\.') { throw '发布清单包含无效的启动脚本名。' }
        $name
    }
}

function Get-PackageBrand([string]$folder) {
    if ([IO.File]::Exists((Join-Path $folder "$playerBrand.exe"))) { return $playerBrand }
    if ([IO.File]::Exists((Join-Path $folder "$previousBrand.exe"))) { return $previousBrand }
    throw '玩家包缺少启动器，请重新解压完整玩家包。'
}

function Read-InstallJson([string]$path) {
    if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) | ConvertFrom-Json }
}

function Write-InstallText([string]$path, [string]$text) {
    $temp = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, $text)
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp, $path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $path) }
    } finally { [IO.File]::Delete($temp) }
}

function Write-InstallJson([string]$path, $document) {
    Write-InstallText $path ($document | ConvertTo-Json -Depth 5 -Compress)
}

function Get-InstallHash([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($path)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Assert-RegularPath([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "检测到其他安装方式建立的链接，请先核对位置：$path"
    }
}

function Get-ClientLayout([string]$game) {
    $xml = [xml]::new()
    $xml.XmlResolver = $null
    $xml.Load((Join-Path $game 'game_info.xml'))
    $client = $xml.SelectSingleNode('/protocol[@wgc_publisher_id="lesta"]/game/part_versions/version[@name="client"]')
    $build = $client.installed
    if ($build -cnotmatch '^[0-9]+(?:\.[0-9]+){4}$') { throw '无法从 game_info.xml 识别莱服客户端构建。' }
    $bin = Join-Path $game 'bin'
    $version = Join-Path $bin ($build.Split('.')[-1])
    $mods = Join-Path $version 'res_mods'
    $plugins = Join-Path $mods 'PnFMods'
    $layout = @{
        Game = $game; Build = $build; Mods = $mods; Plugins = $plugins
        Portal = Join-Path $mods $playerBrand; PreviousPortal = Join-Path $mods $previousBrand
        Mod = Join-Path $plugins 'JellyShips04Coverage'
        Loader = Join-Path $mods 'PnFModsLoader.py'; Rollback = Join-Path $mods '.JellyShips-rollback'
    }
    foreach ($path in @($bin,$version,$mods,$plugins,$layout.Mod,$layout.Portal,$layout.Loader,$layout.Rollback)) {
        Assert-RegularPath $path
    }
    if (![IO.File]::Exists((Join-Path $version 'bin64\Korabli64.exe')) -or ![IO.Directory]::Exists($mods)) {
        throw "莱服 $build 的安装目录尚未就绪。请等待游戏中心完成安装。"
    }
    return $layout
}

function Get-PlayerVersion([string]$build, [int]$revision) {
    $series = $build -replace '^([0-9]+\.[0-9]+)\..*$', '$1'
    return "$series.$revision"
}

function Test-PlayerPackage($package) {
    $revision = 0
    if ($package.portable_format -ne 1 -or $package.build -cnotmatch '^[0-9]+(?:\.[0-9]+){4}$' -or
        [string]$package.revision -cnotmatch '^(0|[1-9][0-9]*)$' -or
        ![int]::TryParse([string]$package.revision, [ref]$revision)) { return $false }
    if (!$package.version) { return ($revision -gt 0) }
    return ($package.version -ceq (Get-PlayerVersion $package.build $revision))
}

function Compare-PlayerRelease($left, $right) {
    if (!$left -or !$right) { return ([int][bool]$left - [int][bool]$right) }
    # A numbered package succeeds the old rN preview series, even at revision zero.
    $format = [int][bool]$left.version - [int][bool]$right.version
    if ($format) { return $format }
    return ([int]$left.revision).CompareTo([int]$right.revision)
}

function Get-InstallReceipt($layout, [string]$folder = $layout.Mod) {
    Assert-RegularPath (Join-Path $folder 'launcher-install.json')
    $record = Read-InstallJson (Join-Path $folder 'launcher-install.json')
    if ($record.product -ceq 'JellyShips' -and $record.portable_format -eq 1 -and
        $record.portal -ceq $playerBrand -and $record.build -ceq $layout.Build) { return $record }
    if (!$record.portable_format -and $record.product -ceq 'JellyShips' -and $record.portal -and $record.portal -in @($layout.Portal,$layout.PreviousPortal) -and
        (!$record.build -or $record.build -ceq $layout.Build)) { return $record }
}

function Assert-GameClosed {
    if (Get-Process -Name Korabli,Korabli64 -ErrorAction SilentlyContinue) { throw "请先退出游戏，再安装、更新或卸载「$playerBrand」。" }
}

function Remove-OwnedLoader($layout) {
    if ([IO.File]::Exists($layout.Loader) -and (Get-Item -LiteralPath $layout.Loader).Length -eq 0 -and
        !(Get-ChildItem -LiteralPath $layout.Plugins -Force | Select-Object -First 1)) {
        [IO.File]::Delete($layout.Loader)
    }
}

function Wait-ModLock([string]$path) {
    Assert-RegularPath $path
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([IO.File]::Exists($path)) {
        try { [IO.File]::Open($path, 'Open', 'ReadWrite', 'None').Dispose(); return }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw '请先关闭设置窗口和播放器，再重试。' }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Stop-ModHost($layout) {
    $signal = Join-Path $layout.Mod 'uninstall.request'
    Assert-RegularPath $signal
    if ([IO.File]::Exists($signal) -and (Get-Item -LiteralPath $signal).Length -ne 0) {
        throw '卸载或更新标记的位置已被其他文件占用。'
    }
    [IO.File]::Open($signal, 'OpenOrCreate', 'Write', 'None').Dispose()
    return $signal
}

function Remove-InstallDirectory([string]$root, [string]$path) {
    $absolute = [IO.Path]::GetFullPath($path)
    if ([IO.Path]::GetDirectoryName($absolute) -ne [IO.Path]::GetFullPath($root)) { throw '安装临时目录位置无效。' }
    Assert-RegularPath $absolute
    if ([IO.Directory]::Exists($absolute)) { Remove-Item -LiteralPath $absolute -Recurse -Force }
}

function Move-InstallFolder([string]$source, [string]$target) {
    # Virus scanners may briefly open the EXE or DLLs immediately after extraction.
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($true) {
        try { [IO.Directory]::Move($source,$target); return }
        catch {
            $errorCode = $_.Exception.GetBaseException().HResult -band 65535
            if ($errorCode -notin 5,32,33 -or [DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Complete-ModReplacement($layout, $record) {
    if ($record.files) {
        Remove-InstallDirectory $layout.Mods $layout.Rollback
    } else {
        # The legacy receipt cannot prove which colliding files belonged to the ZIP.
        $backup = Join-Path $layout.Mods ('.JellyShips-legacy-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::Delete((Join-Path $layout.Rollback 'uninstall.request'))
        Move-InstallFolder $layout.Rollback $backup
    }
}

function Restore-ModInstall($layout) {
    if (Test-Path -LiteralPath $layout.Rollback) {
        $rollback = Get-InstallReceipt $layout $layout.Rollback
        if (!$rollback) { throw '更新备份位置已被占用。' }
        Assert-GameClosed
        if ([IO.Directory]::Exists($layout.Mod)) {
            if (!(Get-InstallReceipt $layout)) { throw '更新目标目录已被占用。' }
            Complete-ModReplacement $layout $rollback
        } else {
            Move-InstallFolder $layout.Rollback $layout.Mod
        }
    }
    $signal = Join-Path $layout.Mod 'uninstall.request'
    if ([IO.File]::Exists($signal) -and (Get-InstallReceipt $layout)) {
        Assert-RegularPath $signal
        if ((Get-Item -LiteralPath $signal).Length -eq 0) { [IO.File]::Delete($signal) }
    }
}

function Expand-ModArchive([string]$archive, [string]$destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem,System.Windows.Forms
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    $window = [Windows.Forms.Form]::new()
    $ledger = [IO.StreamWriter]::new((Join-Path $destination 'launcher-files.tsv'),$false,[Text.UTF8Encoding]::new($false))
    try {
        $window.Text = "$playerBrand · 安装资源"
        $window.FormBorderStyle = 'FixedDialog'
        $window.ControlBox = $false
        $window.StartPosition = 'CenterScreen'
        $window.ClientSize = [Drawing.Size]::new(400, 70)
        $label = [Windows.Forms.Label]::new()
        $label.SetBounds(12, 9, 376, 23)
        $label.Text = '正在准备舰船资源…'
        $bar = [Windows.Forms.ProgressBar]::new()
        $bar.SetBounds(12, 36, 376, 20)
        $bar.Maximum = $zip.Entries.Count
        $window.Controls.AddRange(@($label,$bar))
        $window.Show()
        $window.Refresh()
        $index = 0
        $prefix = $destination + '\'
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if (!$name -or $name -match '^\\|\\\\|\\$|[<>:"|?*\x00-\x1f]|[. ](?:\\|$)') {
                throw '安装资源路径无效。'
            }
            $path = [IO.Path]::GetFullPath([IO.Path]::Combine($destination,$name))
            if (!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw '安装资源路径无效。' }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path)
            $ledger.WriteLine((Get-InstallHash $path) + [char]9 + $name)
            $name
            $index++
            if ($index % 64 -eq 0 -or $index -eq $bar.Maximum) {
                $bar.Value = $index
                $label.Text = '正在准备舰船资源… {0:P0}' -f ($index / $bar.Maximum)
                [Windows.Forms.Application]::DoEvents()
            }
        }
    } finally { $ledger.Dispose(); $zip.Dispose(); $window.Dispose() }
}

function Read-PlayerSettings([string]$source) {
    $settings = @{}
    Assert-RegularPath $source
    Assert-RegularPath (Join-Path $source 'music')
    foreach ($name in $playerFiles) {
        $path = Join-Path $source $name
        Assert-RegularPath $path
        if ([IO.File]::Exists($path)) { $settings[$name] = [IO.File]::ReadAllText($path) }
    }
    return $settings
}

function Save-PlayerSettings($session) {
    $settings = Read-PlayerSettings $session.Layout.Mod
    $data = Join-Path $session.Layout.Portal '玩家数据'
    Assert-RegularPath $data
    [void][IO.Directory]::CreateDirectory($data)
    $backup = Join-Path $data 'player.json'
    Assert-RegularPath $backup
    Write-InstallJson $backup @{ build = $session.Layout.Build; settings = $settings }
}

function Import-PlayerSettings($settings, [string]$stage, [string]$songs) {
    if (!$settings) { return }
    . (Join-Path $stage 'GameMusicFiles.ps1') -SongsRoot $songs
    $preferences = $null
    try {
        if ($settings.'music\preferences.json') {
            $preferences = ConvertFrom-Json -InputObject $settings.'music\preferences.json' -ErrorAction Stop
        }
    } catch {
        # The music helper also falls back to the default song for unreadable preferences.
    }
    if ($preferences.trigger -ceq 'Game') {
        $preferences.trigger = Get-MusicTrigger $preferences.trigger
    }
    $tracks = @(Read-BuiltInMusicTracks)
    $songless = Test-SonglessMusic $preferences
    $trackId = Get-ConfiguredMusicTrackId $preferences $tracks[0].id
    $track = if ($trackId -clike 'user-*') { Read-UserMusicTrack $trackId }
        else { $tracks | Where-Object id -CEQ $trackId }
    if ($track.beatStatus -ceq 'pending') {
        # Resolve old imports before generating the sequence and preferences together.
        Import-SongBeatAnalyzer
        $track = Resolve-UserSongBeat $track
    }
    $songBeat = Get-SongBeat $track $preferences
    foreach ($name in $playerFiles) {
        $entry = $settings.$name
        if ($null -eq $entry) { continue }
        $target = Join-Path $stage $name
        switch ($name) {
            'Beat.seq' {
                . (Join-Path $stage 'Beat-Amplitude.ps1')
                $sequenceFile = Join-Path $stage ('.player-beat-' + [Guid]::NewGuid().ToString('N'))
                try {
                    [IO.File]::WriteAllText($sequenceFile, $entry)
                    $sequence = Read-BeatSequence $sequenceFile
                    $values = @(Get-BeatAmplitudes $sequence | ForEach-Object { $_.ToString('R', $beatCulture) })
                    $bpm = if ($track -or $songless) { $songBeat.bpm } else { $sequence.Bpm }
                    Save-BeatAmplitudes $target $values $sequence.Curve $bpm
                } finally { [IO.File]::Delete($sequenceFile) }
            }
            'effects.txt' {
                Add-Type -LiteralPath (Join-Path $stage 'EffectBindings.cs')
                [EffectBindings]::Apply($stage, [IO.File]::ReadAllText($target).Trim(), $entry.Trim(), $false)
                [IO.File]::WriteAllText($target, $entry)
            }
            'music\preferences.json' {
                if ($preferences -and ($track -or $songless)) {
                    $preferences | Add-Member -NotePropertyName bpm -NotePropertyValue $songBeat.bpm -Force
                    $preferences | Add-Member -NotePropertyName drumFrame -NotePropertyValue $songBeat.drumFrame -Force
                }
                if ($preferences) { Write-GameMusicJson $target $preferences } else { [IO.File]::WriteAllText($target, $entry) }
            }
            default { [IO.File]::WriteAllText($target, $entry) }
        }
    }
}

function Copy-PlayerAdditions([string]$source, [string]$target, $owned, [string]$prefix = '') {
    foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
        $name = $prefix + $item.Name
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "检测到其他安装方式建立的链接，请先核对位置：$($item.FullName)"
        }
        if ($name -in 'launcher-install.json','editor.lock','uninstall.request','music\runtime' -or $name -in $playerFiles) { continue }
        $destination = Join-Path $target $item.Name
        if ($item.PSIsContainer) {
            [void][IO.Directory]::CreateDirectory($destination)
            Copy-PlayerAdditions $item.FullName $destination $owned ($name + '\')
        } elseif (!$owned.Contains($name)) {
            # Do not overwrite a user addition that collides with a new shipped path.
            [IO.File]::Copy($item.FullName, $destination, $false)
        }
    }
}

function Get-OwnedInstallPaths($record, $fallback, [string]$folder) {
    $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $(if ($record.files) { $record.files } else { $fallback })) { [void]$owned.Add($name) }
    $effectList = Join-Path $folder 'effect-models.tsv'
    Assert-RegularPath $effectList
    $stockModels = @{}
    if ([IO.File]::Exists($effectList)) {
        foreach ($row in [IO.File]::ReadLines($effectList)) {
            $model, $stock, $damage, $wake, $both = $row.Split([char]9)
            if ($model -cnotmatch '^[A-Za-z0-9_]+/ship/[A-Za-z0-9_.-]+_ports[A-Za-z0-9_.-]*\.model$') { continue }
            $stockModels[$model.Replace('/','\')] = $stock
            $name = [IO.Path]::ChangeExtension($model.Replace('/','\'), '.visual')
            if ($owned.Contains($name)) { continue }
            $visual = Join-Path $folder $name
            if ([IO.File]::Exists($visual) -and
                (Get-InstallHash $visual) -in $damage,$wake,$both) { [void]$owned.Add($name) }
        }
    }
    if ($record.ledger) {
        $ledger = Join-Path $folder 'launcher-files.tsv'
        Assert-RegularPath $ledger
        if ((Get-InstallHash $ledger) -ne $record.ledger) { throw '资源清单已改变，已保留现有文件。' }
        $hashes = @{}
        foreach ($line in [IO.File]::ReadLines($ledger)) {
            $hash,$name = $line.Split([char]9,2)
            $hashes[$name] = $hash
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            foreach ($file in Get-InstallChildren $folder) {
                if ($file.PSIsContainer) { continue }
                $name = $file.FullName.Substring($folder.Length + 1)
                if (!$hashes.ContainsKey($name) -or $name -in $playerFiles -or
                    (Get-InstallHash $file.FullName) -eq $hashes[$name]) { continue }
                if ($stockModels.ContainsKey($name)) {
                    $local = 'PnFMods/JellyShips04Coverage/' + [IO.Path]::ChangeExtension($name.Replace('\','/'),$null)
                    $xml = [IO.File]::ReadAllText($file.FullName).Replace("<nodefullVisual>$local</nodefullVisual>", "<nodefullVisual>$($stockModels[$name])</nodefullVisual>")
                    $restored = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($xml))).Replace('-','')
                    if ($restored -eq $hashes[$name]) { continue }
                }
                [void]$owned.Remove($name)
            }
        } finally { $sha.Dispose() }
        [void]$owned.Add('launcher-files.tsv')
    }
    return ,$owned
}

function Install-Mod($layout, $package, [string]$portal, [string]$sourcePortal) {
    Assert-GameClosed
    if ($package.build -cne $layout.Build -or !(Test-PlayerPackage $package)) {
        throw "玩家包与莱服 $($layout.Build) 不匹配。"
    }
    Restore-ModInstall $layout
    $record = Get-InstallReceipt $layout
    if ((Compare-PlayerRelease $record $package) -ge 0) { return }
    if (!$record -and (Test-Path -LiteralPath $layout.Mod)) {
        throw "检测到旧版或另一份安装。请先将该文件夹移出游戏目录备份：$($layout.Mod)"
    }
    Initialize-PortablePlayerData $layout $sourcePortal
    $data = Join-Path $layout.Portal '玩家数据'
    $stage = Join-Path $layout.Mods ('.JellyShips-install-' + [Guid]::NewGuid().ToString('N'))
    $signal = $null
    $created = $false
    $editor = $null
    try {
        [void][IO.Directory]::CreateDirectory($stage)
        $members = @(Expand-ModArchive (Join-Path $portal '组件\资源包.zip') $stage)
        foreach ($member in @('Main.py','Q-Bounce.ps1','Beat.seq','settings.txt','effects.txt','music\tracks.json')) {
            if (![IO.File]::Exists((Join-Path $stage $member))) { throw '安装资源不完整，请重新下载玩家包。' }
        }
        $legacy = Join-Path $portal '旧设置'
        if ($record) {
            $signal = Stop-ModHost $layout
            $lock = Join-Path $layout.Mod 'editor.lock'
            Wait-ModLock $lock
            $editor = [IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None')
            Wait-ModLock (Join-Path $layout.Mod 'music\runtime\host.lock')
            if ([IO.File]::Exists((Join-Path $layout.Mod 'effects.pending'))) {
                throw "设置尚未应用完毕。请在 $($layout.Mod) 双击 Q-Bounce.cmd 完成保存，关闭窗口后再更新。"
            }
            $settings = Read-PlayerSettings $layout.Mod
            $owned = Get-OwnedInstallPaths $record $members $layout.Mod
            Copy-PlayerAdditions $layout.Mod $stage $owned
        } elseif ([IO.Directory]::Exists($legacy)) {
            $settings = Read-PlayerSettings $legacy
        } else { $settings = (Read-InstallJson (Join-Path $data 'player.json')).settings }
        Import-PlayerSettings $settings $stage (Join-Path $data 'Songs')

        $current = Get-ClientLayout $layout.Game
        if ($current.Build -cne $layout.Build) { throw '莱服构建已变更，请重新检查更新。' }
        Assert-GameClosed
        [void][IO.Directory]::CreateDirectory($layout.Plugins)
        if (![IO.File]::Exists($layout.Loader)) {
            [IO.File]::Open($layout.Loader, 'CreateNew', 'Write', 'None').Dispose()
            $created = $true
        }
        Write-InstallJson (Join-Path $stage 'launcher-install.json') @{
            product = 'JellyShips'; portable_format = 1; portal = $playerBrand; build = $package.build; revision = [int]$package.revision
            version = $package.version; manifest = Get-InstallHash (Join-Path $portal '组件\package.json')
            ledger = Get-InstallHash (Join-Path $stage 'launcher-files.tsv')
            createdLoader = $created -or [bool]$record.createdLoader; files = $members
        }
        if ($record) {
            # Windows requires the open handle to be released before the rename.
            # The host/editor stop marker keeps the new editor from opening in this gap.
            $editor.Dispose()
            $editor = $null
            Move-InstallFolder $layout.Mod $layout.Rollback
        }
        try { Move-InstallFolder $stage $layout.Mod }
        catch {
            if ($record) { Move-InstallFolder $layout.Rollback $layout.Mod }
            throw
        }
    } catch {
        if ($created) { Remove-OwnedLoader $layout }
        throw
    } finally {
        if ($editor) { $editor.Dispose() }
        if ($signal -and [IO.File]::Exists($signal)) { [IO.File]::Delete($signal) }
        Remove-InstallDirectory $layout.Mods $stage
    }
    if ($record) { Complete-ModReplacement $layout $record }
}

function Uninstall-Mod($layout) {
    Assert-GameClosed
    $record = Get-InstallReceipt $layout
    if (!$record) { throw '此目录没有本入口的安装记录。' }
    $signal = Stop-ModHost $layout
    try {
        foreach ($lockFile in @('editor.lock','music\runtime\host.lock')) {
            Wait-ModLock (Join-Path $layout.Mod $lockFile)
        }
        if (!$record.files) { throw '此旧收据没有资源清单。请先用完整玩家包升级后再卸载。' }
        $owned = Get-OwnedInstallPaths $record @() $layout.Mod
        # Leave additions by other tools in place. Only walk actual descendants.
        $descendants = @(Get-InstallChildren $layout.Mod)
        $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$directories.Add('music\runtime')
        foreach ($entry in $record.files) {
            $parent = [IO.Path]::GetDirectoryName($entry)
            while ($parent -and $directories.Add($parent)) { $parent = [IO.Path]::GetDirectoryName($parent) }
        }
        foreach ($item in $descendants) {
            $name = $item.FullName.Substring($layout.Mod.Length + 1)
            if ($item.PSIsContainer) {
                if ($directories.Contains($name) -and !(Get-ChildItem -LiteralPath $item.FullName -Force | Select-Object -First 1)) {
                    [IO.Directory]::Delete($item.FullName)
                }
            } elseif ($name -notin 'uninstall.request','launcher-files.tsv' -and ($owned.Contains($name) -or $name -in $playerFiles -or
                      $name -in @('editor.lock','music\runtime\host.lock','music\runtime\status.json','music\runtime\command.json','music\runtime\session.json') -or
                      $name -cmatch '^music\\runtime\\end-[a-f0-9]{32}\.request$')) {
                [IO.File]::Delete($item.FullName)
            }
        }
        if ($record.ledger) { [IO.File]::Delete((Join-Path $layout.Mod 'launcher-files.tsv')) }
        [IO.File]::Delete((Join-Path $layout.Mod 'launcher-install.json'))
        [IO.File]::Delete($signal)
        if (!(Get-ChildItem -LiteralPath $layout.Mod -Force | Select-Object -First 1)) {
            [IO.Directory]::Delete($layout.Mod)
        }
    } finally { if ([IO.File]::Exists($signal)) { [IO.File]::Delete($signal) } }
    if ($record.createdLoader) { Remove-OwnedLoader $layout }
}

function Get-InstallChildren([string]$folder) {
    foreach ($item in Get-ChildItem -LiteralPath $folder -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) { Get-InstallChildren $item.FullName }
        $item
    }
}
