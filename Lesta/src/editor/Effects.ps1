Add-Type -LiteralPath (Join-Path $PSScriptRoot 'EffectBindings.cs')

function Read-EffectMode {
    $mode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'effects.txt')).Trim()
    if ($mode -cnotmatch '^[01]{2}$') { throw '特效设置无效。请从试玩包恢复 effects.txt。' }
    return $mode
}

function Complete-EffectSave([string]$previous) {
    $pending = Join-Path $PSScriptRoot 'effects.pending'
    $draft = [IO.File]::ReadAllText($pending) | ConvertFrom-Json
    $beat = [Convert]::FromBase64String($draft.beat)
    [EffectBindings]::Apply($PSScriptRoot, $previous, $draft.mode, $false)
    [EffectBindings]::Write((Join-Path $PSScriptRoot 'Beat.seq'), $beat)
    [EffectBindings]::Write((Join-Path $PSScriptRoot 'effects.txt'), [Text.Encoding]::ASCII.GetBytes($draft.mode))
    if ($null -ne $draft.enabled) {
        $switchValue = if ($draft.enabled) { 'enabled=true' } else { 'enabled=false' }
        [EffectBindings]::Write((Join-Path $PSScriptRoot 'settings.txt'), [Text.Encoding]::ASCII.GetBytes($switchValue))
    }
    if ($draft.music) { Write-GameMusicJson $gameMusicPrefs $draft.music }
    [IO.File]::Delete($pending)
}

function Restore-EffectSave {
    if ([IO.File]::Exists((Join-Path $PSScriptRoot 'effects.pending'))) {
        if (Get-Process Korabli,Korabli64,WorldOfWarships,WorldOfWarships64 -ErrorAction SilentlyContinue) {
            throw '上次应用中断。请退出游戏，再打开工具完成保存。'
        }
        # A previous attempt could have reached any model. Verify every binding on retry.
        Complete-EffectSave ''
    }
}

function Save-EffectDraft([string]$path, [string[]]$values, $curve, [string]$mode, [double]$bpm = 0, $enabled = $null, $music = $null) {
    Restore-EffectSave
    $old = Read-EffectMode
    $current = Read-BeatSequence $path
    $oldValues = @(Get-BeatAmplitudes $current | ForEach-Object { Format-BeatPercent $_ })
    if ($bpm -eq 0) { $bpm = $current.Bpm }
    $sameMotion = $bpm -eq $current.Bpm -and ($oldValues -join '|') -ceq ($values -join '|') -and
        (ConvertTo-Json -InputObject $curve.Keys -Compress) -ceq (ConvertTo-Json -InputObject $current.Curve.Keys -Compress)
    $temp = Join-Path $PSScriptRoot ('.draft-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::Copy($path, $temp)
        if (-not $sameMotion) { Save-BeatAmplitudes $temp $values $curve $bpm }
        if ($mode -cne $old) { [EffectBindings]::Apply($PSScriptRoot, $old, $mode, $true) }
        $json = @{
            mode = $mode; beat = [Convert]::ToBase64String([IO.File]::ReadAllBytes($temp)); enabled = $enabled; music = $music
        } | ConvertTo-Json -Depth 4 -Compress
        [EffectBindings]::Write((Join-Path $PSScriptRoot 'effects.pending'), [Text.Encoding]::UTF8.GetBytes($json))
        Complete-EffectSave $old
    } finally {
        [IO.File]::Delete($temp)
    }
}
