param(
    [string]$GameRootArg = '',
    [int]$QArg = -1,
    [int]$FXArg = -1,
    [int]$WArg = -1,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$toolDir = $PSScriptRoot
$manifest = Join-Path $toolDir 'manifest.tsv'
$stateFile = Join-Path $toolDir 'state.ini'
$settings = Join-Path $toolDir 'settings.ini'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Resolve-Root([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    $p = $p.Trim().Trim('"').TrimEnd('\')
    if (-not (Test-Path $p)) { return $null }
    $item = Get-Item $p
    if (Test-Path (Join-Path $item.FullName 'bin')) { return $item.FullName }
    if ($item.Name -ieq 'bin') { return (Split-Path $item.FullName -Parent) }
    if ($item.Name -match '^\d+$' -and (Split-Path $item.Parent -Leaf) -ieq 'bin') {
        return (Split-Path $item.Parent -Parent)
    }
    return $null
}

function Find-RunningRoot {
    $proc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'WorldOfWarships' } | Select-Object -First 1
    if (-not $proc -or -not $proc.Path) { return $null }
    $d = Split-Path $proc.Path -Parent
    while ($d) {
        if (Test-Path (Join-Path $d 'bin')) { return $d }
        $parent = Split-Path $d -Parent
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

function Read-Settings {
    if (Test-Path $settings) {
        foreach ($line in Get-Content $settings -Encoding UTF8) {
            if ($line -match '^GameRoot=(.+)$') { return $Matches[1].Trim() }
        }
    }
    return ''
}

function Save-Settings([string]$root) {
    [System.IO.File]::WriteAllText($settings, "GameRoot=$root`r`n", $utf8)
}

function Read-State {
    $q = 1; $fx = 1; $w = 1
    if (Test-Path $stateFile) {
        foreach ($line in Get-Content $stateFile -Encoding UTF8) {
            if ($line -match '^Q=(\d)') { $q = [int]$Matches[1] }
            if ($line -match '^FX=(\d)') { $fx = [int]$Matches[1] }
            if ($line -match '^W=(\d)') { $w = [int]$Matches[1] }
        }
    }
    return @($q, $fx, $w)
}

function Save-State([int]$q, [int]$fx, [int]$w) {
    [System.IO.File]::WriteAllText($stateFile, "Q=$q`r`nFX=$fx`r`nW=$w`r`n", $utf8)
}

function Ask-Root {
    Write-Host ''
    Write-Host '请把游戏根目录（里面有 bin 文件夹）拖到本窗口，回车：'
    Write-Host '例如：E:\steam\steamapps\common\World of Warships'
    $p = Read-Host '路径'
    $r = Resolve-Root $p
    if (-not $r) {
        Write-Host '路径无效：没找到 bin 文件夹。提示：控制台里 Ctrl+V 可能无效，请右键粘贴，或直接把文件夹拖进来。' -ForegroundColor Red
        return $null
    }
    Save-Settings $r
    return $r
}

function Find-SteamRoots {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($reg in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty -Path $reg -ErrorAction Stop).SteamPath
            if ($p) { $candidates.Add($p) }
        } catch {}
    }
    foreach ($p in @('C:\Program Files (x86)\Steam','C:\Program Files\Steam','D:\Steam','E:\Steam')) {
        if (Test-Path $p) { $candidates.Add($p) }
    }
    $seen = @{}
    foreach ($steam in $candidates) {
        if (-not $steam -or $seen.ContainsKey($steam)) { continue }
        $seen[$steam] = 1
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($line in Get-Content $vdf -ErrorAction SilentlyContinue) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $libs += $Matches[1].Replace('\\','\')
                }
            }
        }
        foreach ($lib in $libs) {
            foreach ($name in @('World of Warships','World_of_Warships_CN360','World of Warships CN')) {
                $root = Join-Path $lib ('steamapps\common\' + $name)
                if (Test-Path (Join-Path $root 'bin')) { return $root }
            }
        }
    }
    return $null
}

function Find-CommonRoots {
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($rel in @('steamapps\common\World of Warships','World_of_Warships_CN360','Games\World of Warships','World of Warships')) {
            $root = Join-Path $drive.Root $rel
            if (Test-Path (Join-Path $root 'bin')) { return $root }
        }
    }
    return $null
}

function Ensure-Root {
    if ($GameRootArg) {
        $r = Resolve-Root $GameRootArg
        if ($r) { Save-Settings $r; return $r }
    }
    $saved = Read-Settings
    if ($saved) {
        $r = Resolve-Root $saved
        if ($r) { return $r }
    }
    $running = Find-RunningRoot
    if ($running) { Save-Settings $running; return $running }
    $steam = Find-SteamRoots
    if ($steam) { Save-Settings $steam; return $steam }
    $common = Find-CommonRoots
    if ($common) { Save-Settings $common; return $common }
    return Ask-Root
}

function Get-Builds([string]$root) {
    $bin = Join-Path $root 'bin'
    if (-not (Test-Path $bin)) { return @() }
    return @(Get-ChildItem $bin -Directory | Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object { [int64]$_.Name } | Select-Object -Last 1)
}

function Apply-Switch([int]$q, [int]$fx, [int]$w) {
    $root = Ensure-Root
    if (-not $root) { throw '未设置有效的游戏根目录' }
    if (-not (Test-Path $manifest)) { throw "找不到 manifest.tsv" }
    $builds = Get-Builds $root
    if ($builds.Count -eq 0) { throw "在 $root\bin 下没找到数字版本目录" }
    $latest = $builds[0]
    $latestPnf = Join-Path $latest.FullName 'res_mods\PnFMods'
    if (-not (Test-Path $latestPnf)) { throw ("最新版本 " + $latest.Name + " 里没有 res_mods\PnFMods，请先用 Aslain 安装 Q弹") }

    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'WorldOfWarships' }
    if ($running) { Write-Host '提示：游戏正在运行，改动会在下次启动生效。' -ForegroundColor Yellow }

    $lines = Get-Content $manifest -Encoding UTF8
    $totalChanged = 0
    foreach ($build in $builds) {
        $pnf = Join-Path $build.FullName 'res_mods\PnFMods'
        $backup = Join-Path $toolDir ('backup\' + $build.Name)
        if (-not (Test-Path $backup)) {
            Write-Host ("首次应用，备份 " + $build.Name + " ...")
            Copy-Item $pnf $backup -Recurse -Force
        }
        Write-Host ("处理版本 " + $build.Name + " ...")
        $i = 0; $changed = 0
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -lt 3) { continue }
            $rel = $parts[0]; $ssm = $parts[1]; $ep = $parts[2]
            $p = Join-Path $pnf ($rel -replace '/', '\')
            if (-not (Test-Path $p)) { continue }
            $t = [System.IO.File]::ReadAllText($p)
            $orig = $t

            if ($q -eq 0) {
            if ($t -match '(?s)<animations\s*>.*?</animations>') {
                $t = [regex]::Replace($t, '(?s)\s*<animations\s*>.*?</animations>', "`r`n`t<animations/>")
            } elseif ($t -match '<animations\s*/>') {
                # already empty
            } else {
                $t = $t -replace '(\s*</visual>)', ('$1' + "`r`n`t<animations/>")
            }
        } elseif ($q -eq 1 -and $ssm -ne '-') {
            $block = "`r`n`t<animations>`r`n`t`t<animation>`t$ssm`t</animation>`r`n`t</animations>"
            if ($t -match '(?s)<animations\s*>\s*<animation>') {
                # already animated
            } elseif ($t -match '<animations\s*/>') {
                $t = $t -replace '<animations\s*/>', $block
            } elseif ($t -notmatch '<animations') {
                $t = $t -replace '(\s*</visual>)', ('$1' + $block)
            }
        }

        if ($fx -eq 0) {
                $t = [regex]::Replace($t, '(?s)\s*<skeletonExtenders>.*?</skeletonExtenders>', "`r`n`t<skeletonExtenders/>")
            } elseif ($fx -eq 1 -and $ep -ne '-' -and $t -match '<skeletonExtenders\s*/>') {
                $block = "`t<skeletonExtenders>`r`n`t`t<skeletonExtender>`t$ep`t</skeletonExtender>`r`n`t</skeletonExtenders>"
                $t = $t -replace '<skeletonExtenders\s*/>', $block
            }

            if ($t -ne $orig) {
                [System.IO.File]::WriteAllText($p, $t, $utf8)
                $changed++
            }
            $i++
            if ($i % 500 -eq 0) { Write-Progress -Activity ("应用 " + $build.Name) -Status "$i / $($lines.Count)" -PercentComplete (($i / $lines.Count) * 100) }
        }
        Write-Progress -Activity ("应用 " + $build.Name) -Completed
        $totalChanged += $changed
        Write-Host ("  " + $build.Name + "：改动 " + $changed + " 个 model")
        $wakeChanged = 0
        if ($w -eq 0) {
            Get-ChildItem $pnf -Directory -Filter 'GlobalStretchLean_*' | ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter '*.splash' -File } | ForEach-Object {
                Move-Item -LiteralPath $_.FullName -Destination ($_.FullName + '.off') -Force
                $wakeChanged++
            }
        } elseif ($w -eq 1) {
            Get-ChildItem $pnf -Directory -Filter 'GlobalStretchLean_*' | ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter '*.splash.off' -File } | ForEach-Object {
                $orig = $_.FullName.Substring(0, $_.FullName.Length - 4)
                if (Test-Path $orig) { Remove-Item $orig -Force }
                Move-Item -LiteralPath $_.FullName -Destination $orig -Force
                $wakeChanged++
            }
        }
        if ($wakeChanged -gt 0) { Write-Host ("   航迹: 变动 " + $wakeChanged + " 个 .splash") }
    }
    Save-State $q $fx $w
    Write-Host ''
    Write-Host ("完成：共改动 $totalChanged 个 model；Q弹=$q，起火/进水=$fx，航迹=$w")
    Write-Host "游戏根目录：$root"
    Write-Host '请完全退出游戏后重新启动生效。'
}

$q, $fx, $w = Read-State
if ($QArg -ge 0) { $q = $QArg }
if ($FXArg -ge 0) { $fx = $FXArg }
if ($WArg -ge 0) { $w = $WArg }

if ($Apply) { Apply-Switch $q $fx $w; return }

while ($true) {
    $root = Read-Settings
    if ($root) { $root = Resolve-Root $root }
    if (-not $root) { $root = Ensure-Root }
    $builds = if ($root) { Get-Builds $root } else { @() }
    Clear-Host
    Write-Host '=============================='
    Write-Host ' Q弹MOD 开关（自动跟版本）'
    Write-Host '=============================='
    Write-Host ("  游戏根目录: " + $(if ($root) { $root } else { '未设置' }))
    Write-Host ("  检测到版本: " + $(if ($builds.Count -gt 0) { ($builds | ForEach-Object { $_.Name }) -join ', ' } else { '无' }))
    Write-Host ("  1. Q弹          : " + $(if ($q -eq 1) { '开' } else { '关' }))
    Write-Host ("  2. 起火/进水    : " + $(if ($fx -eq 1) { '开' } else { '关' }))
    Write-Host ("  3. 航迹          : " + $(if ($w -eq 1) { '开' } else { '关' }))
    Write-Host '  4. 应用到最新版本并退出'
    Write-Host '  5. 取消退出'
    Write-Host '  6. 修改游戏根目录'
    Write-Host '=============================='
    $c = Read-Host '选择'
    switch ($c) {
        '1' { $q = 1 - $q }
        '2' { $fx = 1 - $fx }
        '3' { $w = 1 - $w }
        '4' { Apply-Switch $q $fx $w; Read-Host '按回车退出' | Out-Null; return }
        '5' { return }
        '6' { Ask-Root | Out-Null }
    }
}