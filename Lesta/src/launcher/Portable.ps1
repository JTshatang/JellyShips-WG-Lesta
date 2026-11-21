function Get-PortalLocation([string]$components) {
    $folder = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($components))
    Assert-RegularPath $folder.FullName
    if ($folder.Name -cmatch '^program-[a-f0-9]{64}$') { $folder = $folder.Parent }
    $portal = $folder.Parent
    if ($folder.Name -cne '组件' -or !$portal -or $portal.Name -cne $playerBrand -or
        $portal.Parent.Name -ine 'res_mods' -or $portal.Parent.Parent.Name -cnotmatch '^[0-9]+$' -or
        $portal.Parent.Parent.Parent.Name -ine 'bin') {
        throw "请将整个「$playerBrand」文件夹放到莱服 bin\构建编号\res_mods，再双击启动器。"
    }
    $game = $portal.Parent.Parent.Parent.Parent.FullName
    foreach ($dir in @($folder,$portal,$portal.Parent,$portal.Parent.Parent,$portal.Parent.Parent.Parent)) {
        Assert-RegularPath $dir.FullName
    }
    return @{ Home=$portal.FullName; Game=$game; Layout=(Get-ClientLayout $game) }
}

function Get-PortalSelection([string]$components) {
    $path = Join-Path $components 'program.txt'
    Assert-RegularPath $path
    if (![IO.File]::Exists($path)) { return }
    $lines = [IO.File]::ReadAllLines($path)
    if ($lines.Length -ne 2 -or $lines[0] -cnotmatch '^program-[a-f0-9]{64}$' -or
        $lines[1] -cnotmatch '^[a-f0-9]{64}$') { throw '组件目录中的 program.txt 已被占用。' }
    return @{ Version=(Join-Path $components $lines[0]); Base=$lines[1] }
}

function Assert-PortableProgram([string]$components, $package) {
    Assert-RegularPath $components
    if ($package.portable_format -ne 1) { throw '更新包缺少便携程序。' }
    foreach ($name in (Get-LauncherProgramFiles $package)) {
        $path = Join-Path $components $name
        Assert-RegularPath $path
        if (![IO.File]::Exists($path)) { throw "缺少启动组件：$name" }
        if ($name -ne 'package.json' -and ($package.launcher_hashes.$name -notmatch '^[a-f0-9]{64}$' -or
            (Get-InstallHash $path) -ne $package.launcher_hashes.$name)) { throw "启动组件校验失败：$name" }
    }
}

function Copy-PortableProgram([string]$source, [string]$target, $package) {
    if ([IO.Directory]::Exists($target)) {
        Assert-PortableProgram $target $package
        if ((Get-InstallHash (Join-Path $target 'package.json')) -ne (Get-InstallHash (Join-Path $source 'package.json'))) {
            throw "程序版本目录已被占用：$target"
        }
        return
    }
    $parent = [IO.Path]::GetDirectoryName($target)
    $stage = Join-Path $parent ('.program-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        foreach ($name in (Get-LauncherProgramFiles $package)) { [IO.File]::Copy((Join-Path $source $name), (Join-Path $stage $name)) }
        Assert-PortableProgram $stage $package
        Move-InstallFolder $stage $target
    } finally { Remove-InstallDirectory $parent $stage }
}

function Install-PendingProgram($layout, [string]$candidate, [string]$sourcePortal) {
    Assert-GameClosed
    $source = Join-Path $candidate '组件'
    $package = Read-InstallJson (Join-Path $source 'package.json')
    Assert-PortableProgram $source $package
    $receipt = Get-InstallReceipt $layout
    if ((Compare-PlayerRelease $receipt $package) -gt 0) { throw '当前构建已安装更新的版本。' }
    $archive = Join-Path $source '资源包.zip'
    Assert-RegularPath $archive
    if ((Get-InstallHash $archive) -ne $package.launcher_hashes.'资源包.zip') { throw '更新包资源校验失败。' }
    $name = "$playerBrand.exe"
    $sourceExe = Join-Path $candidate $name
    $newHash = $package.launcher_hashes.$name
    if (!$newHash -or (Get-InstallHash $sourceExe) -ne $newHash) { throw '更新包启动器校验失败。' }
    $components = Join-Path $layout.Portal '组件'
    $destination = Join-Path $layout.Portal $name
    Assert-RegularPath $layout.Portal
    Assert-RegularPath $components
    Assert-RegularPath $destination
    [void][IO.Directory]::CreateDirectory($layout.Portal)
    $base = Read-InstallJson (Join-Path $components 'package.json')
    $selected = Get-PortalSelection $components
    $current = if ($selected) { Read-InstallJson (Join-Path $selected.Version 'package.json') }
    $oldHash = if ([IO.File]::Exists($destination)) { Get-InstallHash $destination }
    if ($oldHash -and $oldHash -ne $newHash -and $oldHash -ne $base.launcher_hashes.$name -and
        $oldHash -ne $current.launcher_hashes.$name) { throw '目标启动器已被其他文件占用，已保留。' }
    if ($base -and $base.portable_format -ne 1) { throw '该构建已有旧版程序。请先用完整便携包手动升级。' }
    if (!$base) { Copy-PortableProgram $source $components $package }

    $manifest = 'package.json'
    $baseHash = (Get-InstallHash (Join-Path $components $manifest)).ToLowerInvariant()
    $versionHash = (Get-InstallHash (Join-Path $source $manifest)).ToLowerInvariant()
    $version = 'program-' + $versionHash
    if ($baseHash -ne $versionHash) {
        Copy-PortableProgram $source (Join-Path $components $version) $package
    }
    $reopened = Get-ClientLayout $layout.Game
    if ($reopened.Build -cne $package.build) { throw '游戏构建已经变更，请重新检查更新。' }
    Install-Mod $layout $package $candidate $sourcePortal
    Assert-GameClosed
    if ($oldHash -ne $newHash) {
        $temp = Join-Path $layout.Portal ('.launcher-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy($sourceExe,$temp)
            if ([IO.File]::Exists($destination)) {
                if ((Get-InstallHash $destination) -ne $oldHash) { throw '目标启动器已改变，请重新打开后重试。' }
                [IO.File]::Replace($temp,$destination,[NullString]::Value)
            } else { [IO.File]::Move($temp,$destination) }
        } finally { [IO.File]::Delete($temp) }
    }
    if ($baseHash -ne $versionHash) {
        Write-InstallText (Join-Path $components 'program.txt') ($version + [Environment]::NewLine + $baseHash)
    } elseif ($selected) { [IO.File]::Delete((Join-Path $components 'program.txt')) }
}

function Remove-EmptyPortableFolder([string]$folder) {
    Assert-RegularPath $folder
    if ([IO.Directory]::Exists($folder) -and !(Get-ChildItem -LiteralPath $folder -Force | Select-Object -First 1)) {
        [IO.Directory]::Delete($folder)
    }
}

function Remove-PortableProgram([string]$portal, [string]$receiptHash) {
    $components = Join-Path $portal '组件'
    $selected = Get-PortalSelection $components
    $baseFile = Join-Path $components 'package.json'
    Assert-RegularPath $baseFile
    $baseHash = Get-InstallHash $baseFile
    $hashes = @($receiptHash)
    if ($selected -and $selected.Version -like "*program-$receiptHash") { $hashes += $selected.Base }
    $exeHashes = @()
    $folders = @($components) + @(Get-ChildItem -LiteralPath $components -Directory -Filter 'program-*' | ForEach-Object { $_.FullName })
    foreach ($folder in $folders) {
        Assert-RegularPath $folder
        $manifest = Join-Path $folder 'package.json'
        Assert-RegularPath $manifest
        if (![IO.File]::Exists($manifest)) { continue }
        $digest = Get-InstallHash $manifest
        if ($folder -eq $components -and $digest -notin $hashes) { continue }
        if ($folder -ne $components -and [IO.Path]::GetFileName($folder) -ine ('program-' + $digest)) { continue }
        $package = Read-InstallJson $manifest
        if ($package.portable_format -ne 1) { continue }
        $exeHashes += $package.launcher_hashes."$playerBrand.exe"
        foreach ($name in @(Get-LauncherProgramFiles $package) + @('资源包.zip')) {
            if ($name -eq 'package.json') { continue }
            $file = Join-Path $folder $name
            Assert-RegularPath $file
            if ([IO.File]::Exists($file) -and (Get-InstallHash $file) -eq $package.launcher_hashes.$name) { [IO.File]::Delete($file) }
        }
        [IO.File]::Delete($manifest)
        if ($folder -ne $components) { Remove-EmptyPortableFolder $folder }
    }
    $exe = Join-Path $portal "$playerBrand.exe"
    Assert-RegularPath $exe
    if ([IO.File]::Exists($exe) -and (Get-InstallHash $exe) -in $exeHashes) { [IO.File]::Delete($exe) }
    if ($selected -and $selected.Base -eq $baseHash) { [IO.File]::Delete((Join-Path $components 'program.txt')) }
    Remove-EmptyPortableFolder $components
}

function Remove-PortablePlayerData([string]$portal) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $data = Join-Path $portal '玩家数据'
    $songs = Join-Path $data 'Songs'
    Assert-RegularPath $data
    Assert-RegularPath $songs
    if ([IO.Directory]::Exists($songs)) {
        foreach ($dir in Get-ChildItem -LiteralPath $songs -Directory) {
            if ($dir.Name -cnotmatch '^user-[0-9a-f]{32}$' -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $track = Join-Path $dir.FullName 'track.json'
            Assert-RegularPath $track
            if ((Read-InstallJson $track).id -cne $dir.Name) { continue }
            foreach ($name in 'audio.wav','edit.lock','beat-analysis.lock','track.json') {
                $file = Join-Path $dir.FullName $name
                Assert-RegularPath $file
                if ([IO.File]::Exists($file)) {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file,'OnlyErrorDialogs','SendToRecycleBin','ThrowException')
                }
            }
            Remove-EmptyPortableFolder $dir.FullName
        }
        Remove-EmptyPortableFolder $songs
    }
    $backup = Join-Path $data 'player.json'
    Assert-RegularPath $backup
    $saved = Read-InstallJson $backup
    if ($saved.settings -and $saved.build) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($backup,'OnlyErrorDialogs','SendToRecycleBin','ThrowException')
    }
    Remove-EmptyPortableFolder $data
}
