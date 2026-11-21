param([switch]$BackgroundCheck)

function Get-ReleaseSource($package) {
    if ($package.github_repository) {
        if ($package.github_repository -cnotmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') { throw '发布源配置无效。' }
        return @{ Index = [uri]"https://api.github.com/repos/$($package.github_repository)/releases"
            Repository = $package.github_repository; Local = $false }
    }
    if (!$env:JELLYSHIPS_LOCAL_RELEASES) { return }
    $uri = [uri]$env:JELLYSHIPS_LOCAL_RELEASES
    if (!$uri.IsAbsoluteUri -or !$uri.IsLoopback -or $uri.Scheme -ne 'http' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw '本地更新测试源必须使用回环 HTTP 地址。'
    }
    return @{ Index = $uri; Local = $true }
}

function Get-PlayerReleaseLabel($release) {
    if ($release.version) { return $release.version }
    return "r$($release.revision)"
}

function Find-PlayerUpdate($layout, $package, $installed) {
    $source = Get-ReleaseSource $package
    if (!$source) { return @{ Message = '更新源尚未配置' } }
    $legacyPattern = '^JellyShips-Lesta-' + [regex]::Escape($layout.Build) + '-r([1-9][0-9]*)\.zip$'
    $buildMarker = "<!-- lesta-build: $($layout.Build) -->"
    $best = $null
    $page = 1
    do {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "$($source.Index)?per_page=100&page=$page" -MaximumRedirection 0 -Headers @{
            Accept = 'application/vnd.github+json'; 'User-Agent' = 'JellyShips-Updater'
        } -TimeoutSec 15
        foreach ($release in ($response.Content | ConvertFrom-Json)) {
            if ($release.draft -isnot [bool] -or $release.prerelease -isnot [bool] -or $release.draft -or $release.prerelease) { continue }
            foreach ($asset in $release.assets) {
                if ($asset.state -cne 'uploaded') { continue }
                $version = $null
                if ($asset.name -cmatch '^([0-9]+\.[0-9]+\.(0|[1-9][0-9]*))\.zip$') {
                    $version = $Matches[1]
                    $revisionText = $Matches[2]
                    if ($release.tag_name -cne "lesta-$version" -or !([string]$release.body).Contains($buildMarker)) { continue }
                } elseif ($asset.name -cmatch $legacyPattern) {
                    $revisionText = $Matches[1]
                } else { continue }
                $revision = 0
                if (![int]::TryParse($revisionText, [ref]$revision) -or
                    ($version -and $version -cne (Get-PlayerVersion $layout.Build $revision))) { continue }
                $candidate = @{ Revision = $revision; Version = $version; Size = [long]$asset.size; Digest = $asset.digest
                    Url = $asset.browser_download_url; Name = $asset.name }
                if ((Compare-PlayerRelease $candidate $best) -gt 0) { $best = $candidate }
            }
        }
        $page++
    } while ($response.Headers['Link'] -match 'rel="next"')
    if (!$best) { return @{ Message = "暂无适用于莱服 $($layout.Build) 的更新" } }
    if ((Compare-PlayerRelease $best $installed) -le 0) { return @{ Message = "已是最新版本：$(Get-PlayerReleaseLabel $installed)" } }
    $url = [uri]$best.Url
    if (!$url.IsAbsoluteUri -or $url.UserInfo -or $url.Fragment -or $best.Digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $best.Size -le 0 -or
        ($source.Local -and $url.GetLeftPart('Authority') -ne $source.Index.GetLeftPart('Authority')) -or
        (!$source.Local -and ($url.Scheme -ne 'https' -or $url.Authority -ne 'github.com' -or
            !$url.AbsolutePath.StartsWith("/$($source.Repository)/releases/download/", [StringComparison]::OrdinalIgnoreCase) -or
            $url.Segments[-1] -cne $best.Name))) {
        throw '发布附件的来源或校验信息无效。'
    }
    return @{ Message = "发现$(Get-PlayerReleaseLabel $best)"; Offer = $best }
}

function Save-ReleaseAsset($source, $offer, [string]$path) {
    $uri = [uri]$offer.Url
    for ($hop = 0; $hop -le 5; $hop++) {
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 20000
        $request.ReadWriteTimeout = 30000
        $request.UserAgent = 'JellyShips-Updater'
        $response = $request.GetResponse()
        try {
            if ([int]$response.StatusCode -in 301,302,303,307,308) {
                $next = [uri]::new($uri, $response.Headers['Location'])
                if ($next.UserInfo -or ($source.Local -and $next.GetLeftPart('Authority') -ne $source.Index.GetLeftPart('Authority')) -or
                    (!$source.Local -and ($next.Scheme -ne 'https' -or !$next.IsDefaultPort -or
                      $next.Host -notin 'release-assets.githubusercontent.com','objects.githubusercontent.com','github-releases.githubusercontent.com'))) {
                    throw '下载重定向指向未知来源。'
                }
                $uri = $next
                continue
            }
            if ([int]$response.StatusCode -ne 200 -or ($response.ContentLength -ge 0 -and $response.ContentLength -ne $offer.Size)) {
                throw '下载包大小与发布记录不符。'
            }
            $stream = $response.GetResponseStream()
            $file = [IO.File]::Open($path,'CreateNew','Write','None')
            try {
                $buffer = [byte[]]::new(131072)
                while (($count = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if ($file.Position + $count -gt $offer.Size) { throw '下载超过发布大小。' }
                    $file.Write($buffer,0,$count)
                }
                if ($file.Position -ne $offer.Size) { throw '下载不完整。' }
            } finally { $file.Dispose(); $stream.Dispose() }
            return
        } finally { $response.Dispose() }
    }
    throw '下载重定向次数过多。'
}

function Test-PlayerPayload([string]$path) {
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\','/')
            if (!$name -or $name -match '^/|/$|//|(^|/)\.{1,2}(/|$)|[<>:"|?*\x00-\x1f]|[. ](/|$)' -or !$names.Add($name)) {
                throw '更新资源存在无效或重复路径。'
            }
            $stream = $entry.Open()
            try { $stream.CopyTo([IO.Stream]::Null) } finally { $stream.Dispose() }
        }
        foreach ($required in 'Main.py','Q-Bounce.ps1','Beat.seq','settings.txt','effects.txt','music/tracks.json') {
            if (!$names.Contains($required)) { throw '更新包缺少游戏资源。' }
        }
    } finally { $archive.Dispose() }
}

function Receive-PlayerUpdate($layout, $package, $offer, [string]$folder) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $download = Join-Path $folder 'download.zip'
    Save-ReleaseAsset (Get-ReleaseSource $package) $offer $download
    if ((Get-InstallHash $download) -ne $offer.Digest.Substring(7)) { throw '下载包 SHA-256 校验失败。' }
    [void][IO.Directory]::CreateDirectory((Join-Path $folder '组件'))
    $zip = [IO.Compression.ZipFile]::OpenRead($download)
    try {
        $paths = @("$playerBrand.exe") + @($launcherFiles + @('资源包.zip') | ForEach-Object { "组件/$_" })
        if ($zip.Entries.Count -ne $paths.Count) { throw '自动更新需要完整的便携版玩家包。' }
        $hashes = @{}
        foreach ($name in $paths) {
            $entry = $zip.GetEntry("$playerBrand/$name")
            if (!$entry -or !$entry.Length) { throw '更新包缺少启动程序或安装组件。' }
            $path = Join-Path $folder $name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path)
            $hashes[$name] = Get-InstallHash $path
        }
    } finally { $zip.Dispose() }
    $meta = Read-InstallJson (Join-Path $folder '组件/package.json')
    if (!(Test-PlayerPackage $meta) -or $meta.build -cne $layout.Build -or $meta.revision -ne $offer.Revision -or
        [string]$meta.version -cne [string]$offer.Version -or
        [string]$meta.github_repository -ne [string]$package.github_repository) { throw '下载包的格式、游戏版本、修订或仓库与发布记录不符。' }
    foreach ($name in $hashes.Keys) {
        if ($name -ceq '组件/package.json') { continue }
        $leaf = [IO.Path]::GetFileName($name)
        if ($hashes[$name] -ne $meta.launcher_hashes.$leaf) { throw "便携包文件校验失败：$leaf" }
    }
    Test-PlayerPayload (Join-Path $folder '组件/资源包.zip')
    [IO.File]::Delete($download)
    return $hashes
}

function Get-PendingPlayerUpdate($layout, $package, [string]$appRoot) {
    # The unpacked files are rechecked even when the network is offline.
    try {
        $pointer = Join-Path $appRoot 'pending-update.json'
        Assert-RegularPath $pointer
        $pending = Read-InstallJson $pointer
        $source = Get-ReleaseSource $package
        if ($pending.Product -cne 'JellyShips' -or !$source -or $pending.Source -cne $source.Index.AbsoluteUri -or
            $pending.Folder -cnotmatch '^download-[a-f0-9]{32}$' -or $pending.Build -cne $layout.Build) { return }
        $folder = Join-Path $appRoot $pending.Folder
        Assert-RegularPath $folder
        $marker = Join-Path $folder 'update-stage.txt'
        Assert-RegularPath $marker
        if (![IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $pending.Folder) { return }
        Assert-RegularPath (Join-Path $folder '组件')
        $installed = Get-InstallReceipt $layout
        if ((Compare-PlayerRelease $pending $installed) -lt 0 -or
            ($layout.Build -ceq $package.build -and (Compare-PlayerRelease $pending $package) -lt 0)) { return }
        foreach ($name in @("$playerBrand.exe") + @($launcherFiles + @('资源包.zip') | ForEach-Object { "组件/$_" })) {
            $path = Join-Path $folder $name
            Assert-RegularPath $path
            if (![IO.File]::Exists($path) -or (Get-InstallHash $path) -ne $pending.Hashes.$name) { return }
        }
        $meta = Read-InstallJson (Join-Path $folder '组件/package.json')
        if (!(Test-PlayerPackage $meta) -or $meta.build -cne $layout.Build -or $meta.revision -ne $pending.Revision -or
            [string]$meta.version -cne [string]$pending.Version -or [string]$meta.github_repository -ne [string]$package.github_repository) { return }
        return $folder
    } catch { return }
}

function Clear-PendingPlayerUpdate([string]$appRoot, [string]$candidate) {
    $pointer = Join-Path $appRoot 'pending-update.json'
    Assert-RegularPath $pointer
    $pending = Read-InstallJson $pointer
    if ($pending.Product -cne 'JellyShips' -or $pending.Folder -cnotmatch '^download-[a-f0-9]{32}$' -or
        (Join-Path $appRoot $pending.Folder) -ne $candidate) { return }
    [IO.File]::Delete($pointer)
    Clear-AbandonedPlayerUpdates $appRoot
}

function Clear-AbandonedPlayerUpdates([string]$appRoot, [switch]$PreparingDownload) {
    # Called under the download lock, or by the launcher after the editor and worker have exited.
    foreach ($dir in Get-ChildItem -LiteralPath $appRoot -Directory -Filter 'download-*') {
        if ($dir.Name -cnotmatch '^download-[a-f0-9]{32}$') { continue }
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $marker = Join-Path $dir.FullName 'update-stage.txt'
        $file = Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        if ($file -and !$file.PSIsContainer -and !($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $file.Length -eq $dir.Name.Length -and [IO.File]::ReadAllText($marker) -ceq $dir.Name) {
            Remove-InstallDirectory $appRoot $dir.FullName
        }
    }
    $pointer = Join-Path $appRoot 'pending-update.json'
    if ([IO.File]::Exists($pointer)) {
        try { Assert-RegularPath $pointer; $pending = Read-InstallJson $pointer }
        catch { if ($PreparingDownload) { throw }; return }
        if ($pending.Product -ceq 'JellyShips' -and $pending.Folder -cmatch '^download-[a-f0-9]{32}$') {
            [IO.File]::Delete($pointer)
        } elseif ($PreparingDownload) { throw '自动更新记录的位置已被其他文件占用。' }
    }
}

function Invoke-AutomaticPlayerUpdate([string]$components, [string]$game, [string]$appRoot) {
    $layout = Get-ClientLayout $game
    $package = Read-InstallJson (Join-Path $components 'package.json')
    $source = Get-ReleaseSource $package
    if (!$source) { '更新源尚未配置'; return }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($appRoot.ToUpperInvariant()))).Replace('-','') }
    finally { $sha.Dispose() }
    $lock = [Threading.Mutex]::new($false, ('Local\JellyShips-Download-' + $id))
    $acquired = $false
    try {
        try { $acquired = $lock.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { '正在后台检查更新'; return }
        if (Get-PendingPlayerUpdate $layout $package $appRoot) { '更新已就绪，退出游戏后自动安装'; return }
        Clear-AbandonedPlayerUpdates $appRoot -PreparingDownload
        $installed = Get-InstallReceipt $layout
        if ($package.build -ceq $layout.Build -and (Compare-PlayerRelease $package $installed) -gt 0) { $installed = $package }
        $result = Find-PlayerUpdate $layout $package $installed
        if (!$result.Offer) { $result.Message; return }
        $id = 'download-' + [Guid]::NewGuid().ToString('N')
        $folder = Join-Path $appRoot $id
        [void][IO.Directory]::CreateDirectory($folder)
        $ready = $false
        try {
            [IO.File]::WriteAllText((Join-Path $folder 'update-stage.txt'),$id)
            $label = Get-PlayerReleaseLabel $result.Offer
            "正在下载并校验$label…"
            $hashes = Receive-PlayerUpdate $layout $package $result.Offer $folder
            $current = Get-ClientLayout $game
            if ($current.Build -cne $layout.Build) { throw '莱服版本已变更。' }
            Write-InstallJson (Join-Path $appRoot 'pending-update.json') @{
                Product = 'JellyShips'; Folder = $id; Source = $source.Index.AbsoluteUri; Build = $layout.Build
                Revision = $result.Offer.Revision; Version = $result.Offer.Version; Hashes = $hashes
            }
            $ready = $true
            "$label 已就绪，退出游戏并关闭窗口后自动安装"
        } finally { if (!$ready) { Remove-InstallDirectory $appRoot $folder } }
    } finally {
        if ($acquired) { $lock.ReleaseMutex() }
        $lock.Dispose()
    }
}

if ($BackgroundCheck -and $MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    try {
        . (Join-Path $PSScriptRoot 'Install.ps1')
        Invoke-AutomaticPlayerUpdate $PSScriptRoot $env:JELLYSHIPS_UPDATE_GAME $env:JELLYSHIPS_UPDATE_HOME |
            ForEach-Object { [Console]::WriteLine($_) }
    } catch { [Console]::WriteLine("自动更新暂未完成。$($_.Exception.GetBaseException().Message)"); exit 1 }
}
