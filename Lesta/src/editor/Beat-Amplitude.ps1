if (-not ('HeightCurve' -as [type])) {
    Add-Type -LiteralPath @((Join-Path $PSScriptRoot 'BeatCurve.cs'), (Join-Path $PSScriptRoot 'HeightCurve.cs'))
}
$beatCulture = [Globalization.CultureInfo]::InvariantCulture
$beatDefaults = @(80.0, 120.0, 120.0, 80.0)
$beatHeightOrderError = '最扁船高需小于或等于最高船高。'
$beatWidthOrderError = '最扁船宽需大于或等于最高船宽。'
$beatIntervals = 48
$defaultBeatBpm = 130.0

function Read-ShipMotion($settings) {
    if ($settings.HeightKeys) { return [HeightCurve]::new([HeightKey[]]$settings.HeightKeys) }
    $motion = [BeatCurve]::new([BounceKey[]]$settings.Keys)
    if ($motion.IsUniform -and !$motion.Keys[0].HasSavedHandles) { return [HeightCurve]::Default() }
    return $motion
}

function Get-ShipMotionSettings([ShipMotion]$motion) {
    if ($motion -is [HeightCurve]) { return @{ HeightKeys = $motion.Keys } }
    return @{ Keys = $motion.Keys }
}

function Format-BeatPercent([double]$value) {
    $value.ToString('G15', $beatCulture)
}

function ConvertTo-BeatPercent([string]$inputText) {
    $value = 0.0
    if ([double]::TryParse($inputText, [Globalization.NumberStyles]::Float, $beatCulture, [ref]$value) -and
        $value -gt 0 -and -not [double]::IsInfinity($value)) {
        return $value
    }
    return $null
}

function ConvertTo-AnimationBpm([string]$inputText) {
    $bpm = ConvertTo-BeatPercent $inputText
    if ($null -eq $bpm -or $bpm -lt 1 -or $bpm -gt 600) {
        throw '动画 BPM 请输入 1 到 600 之间的数字，小数用英文句点。'
    }
    return $bpm
}

function Read-BeatSequence([string]$path) {
    $document = [xml]::new()
    $document.PreserveWhitespace = $false
    $document.Load($path)
    $track = $document.SelectSingleNode('/Beat.seq/sequenceObject[name="Root"]/track[name="scale" and type="vector3"]')
    $frames = @($track.SelectNodes('frame'))
    $duration = [double]::Parse($document.DocumentElement.duration, $beatCulture)
    $metadata = $document.SelectSingleNode('/Beat.seq/comment()[starts-with(., "Q-Bounce-16 ") or starts-with(., "Q-Bounce-29 ")]')
    $curve = [HeightCurve]::Default()
    $values = $null
    $bpm = $defaultBeatBpm
    if ($metadata) {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($metadata.Value.Substring(12)))
        $config = ConvertFrom-Json $json
        $curve = Read-ShipMotion $config
        $values = [double[]]$config.values
        if ($values.Count -ne 4 -or -not $curve.CanPlay) { throw '保存的曲线或幅度无效。' }
        if ($null -ne $config.bpm) { $bpm = ConvertTo-AnimationBpm ([double]$config.bpm).ToString('R', $beatCulture) }
    }
    $beatPeriod = 60.0 / $bpm
    if ((-not $metadata -and $frames.Count -ne ($beatIntervals + 1)) -or $frames.Count -lt 2 -or [math]::Abs($duration - $beatPeriod) -gt 1e-9) {
        throw '动画周期与设置不一致。'
    }
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $frame = $frames[$i]
        $time = [double]::Parse($frame.startTime, $beatCulture)
        if ((-not $metadata -and [math]::Abs($time - $beatPeriod * $i / $beatIntervals) -gt 1e-9) -or
            $frame.tangentMode -ne '0' -or -not ($frame.value -and $frame.inTangent -and $frame.outTangent)) {
            throw '动画的关键帧格式与试玩版不一致。'
        }
    }
    return @{ Document = $document; Frames = $frames; Curve = $curve; Values = $values; Metadata = $metadata; Bpm = $bpm }
}

function Get-BeatAmplitudes($sequence) {
    if ($sequence.Values) { return $sequence.Values }
    foreach ($frame in $sequence.Frames[0, ($beatIntervals / 2)]) {
        $width, $height, $length = $frame.value.Trim() -split '\s+'
        [double]::Parse($height, $beatCulture) * 100
        [double]::Parse($width, $beatCulture) * 100
    }
}

function Get-BeatRatios([string[]]$inputValues) {
    $labels = '最扁船高', '最扁船宽', '最高船高', '最高船宽'
    $ratios = for ($i = 0; $i -lt $labels.Count; $i++) {
        $percent = ConvertTo-BeatPercent $inputValues[$i]
        if ($null -eq $percent) { throw "$($labels[$i])请输入有限的正数。" }
        $ratio = $percent / 100
        if ($ratio -gt [single]::MaxValue -or [single]$ratio -eq 0) {
            throw "$($labels[$i])超出游戏动画可表示的范围。"
        }
        $ratio
    }
    $flatHeight, $flatWidth, $tallHeight, $tallWidth = $ratios
    if ($flatHeight -gt $tallHeight) { throw $beatHeightOrderError }
    if ($flatWidth -lt $tallWidth) { throw $beatWidthOrderError }
    return $ratios
}

function Save-BeatAmplitudes([string]$path, [string[]]$inputValues, $curve = $null, [double]$bpm = 0) {
    $flatHeight, $flatWidth, $tallHeight, $tallWidth = Get-BeatRatios $inputValues
    $sequence = Read-BeatSequence $path
    if ($null -eq $curve) { $curve = $sequence.Curve }
    if ($bpm -eq 0) { $bpm = $sequence.Bpm }
    $bpm = ConvertTo-AnimationBpm $bpm.ToString('R', $beatCulture)
    $beatPeriod = 60.0 / $bpm
    $times = $curve.ExportTimes($beatIntervals, $beatPeriod)
    $sequence.Document.DocumentElement.duration = $beatPeriod.ToString('R', $beatCulture)
    $template = $sequence.Frames[0].CloneNode($true)
    $track = $sequence.Frames[0].ParentNode
    foreach ($old in $sequence.Frames) { [void]$track.RemoveChild($old) }
    foreach ($time in $times) {
        $progress = $curve.ProgressAt($time)
        $width = $flatWidth * (1 - $progress) + $tallWidth * $progress
        $height = $flatHeight * (1 - $progress) + $tallHeight * $progress
        $frame = $template.CloneNode($true)
        $frame.startTime = ($time * $beatPeriod).ToString('R', $beatCulture)
        [void]$track.AppendChild($frame)
        $frame.value = [string]::Format($beatCulture, '{0:R} {1:R} 1', $width, $height)
        foreach ($outgoing in $false, $true) {
            $rate = $curve.ProgressRate($time, $outgoing) / $beatPeriod
            $widthSlope = ($tallWidth - $flatWidth) * $rate
            $heightSlope = ($tallHeight - $flatHeight) * $rate
            if ([double]::IsNaN($widthSlope) -or [double]::IsNaN($heightSlope) -or
                [math]::Abs($widthSlope) -gt [single]::MaxValue -or [math]::Abs($heightSlope) -gt [single]::MaxValue) {
                throw '曲线变化过快，超出游戏动画可表示的范围。'
            }
            $member = if ($outgoing) { 'outTangent' } else { 'inTangent' }
            $frame.$member = [string]::Format($beatCulture, '{0:R} {1:R} 0', $widthSlope, $heightSlope)
        }
    }

    # Keep the editable settings independent of the sampled frames in the same
    # atomic file replacement. The XML comment is ignored by the sequence player.
    $settings = Get-ShipMotionSettings $curve
    $settings.values = [double[]]$inputValues
    $settings.bpm = $bpm
    $json = $settings | ConvertTo-Json -Depth 4 -Compress
    $tag = if ($curve -is [HeightCurve]) { 'Q-Bounce-29 ' } else { 'Q-Bounce-16 ' }
    $data = $tag + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    if ($sequence.Metadata) { $sequence.Metadata.Value = $data }
    else { [void]$sequence.Document.DocumentElement.AppendChild($sequence.Document.CreateComment($data)) }

    $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ('.Beat-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $sequence.Document.Save($temporary)
        # A short-lived reader can prevent Windows from exchanging the two files.
        for ($attempt = 1; ; $attempt++) {
            try {
                [IO.File]::Replace($temporary, $path, [NullString]::Value)
                break
            } catch {
                $failure = $_.Exception.InnerException
                if ($attempt -ge 4 -or $failure -isnot [IO.IOException] -or
                    ($failure.HResult -band 0xFFFF) -notin 32, 33, 1175) { throw }
                Start-Sleep -Milliseconds 150
            }
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
}
