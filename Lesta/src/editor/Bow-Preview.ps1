function New-BowPreview([string]$assetPath) {
    $panel = [Windows.Forms.Panel]::new()
    $panel.AccessibleName = '效果预览'
    $panel.BackColor = [Drawing.Color]::FromArgb(244, 246, 247)
    $panel.Anchor = 'Top, Bottom, Left, Right'
    $flags = [Reflection.BindingFlags]'Instance, NonPublic'
    [Windows.Forms.Control].GetProperty('DoubleBuffered', $flags).SetValue($panel, $true, $null)

    try {
        $library = Join-Path $PSScriptRoot 'preview-lib'
        foreach ($name in 'System.Numerics.Vectors', 'System.Runtime.CompilerServices.Unsafe',
            'System.Buffers', 'System.Memory', 'ExCSS', 'Svg') {
            [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $library "$name.dll")))
        }
        [Svg.SvgDocument]::DisableDtdProcessing = $true
        [Svg.SvgDocument]::ResolveExternalImages = 'None'
        [Svg.SvgDocument]::ResolveExternalElements = 'None'
        $art = [Svg.SvgDocument]::Open($assetPath)
        $box = $art.ViewBox
        $right = [double]$box.MinX + $box.Width
        $bottom = [double]$box.MinY + $box.Height
        if (-not ($box.Width -gt 0 -and $box.Height -gt 0 -and $box.MinX -le 0 -and $right -ge 0 -and
            $box.MinY -le 0 -and $bottom -ge 0) -or
            @($box.MinX, $box.MinY, $box.Width, $box.Height).Where({ [single]::IsInfinity($_) }).Count) {
            throw 'viewBox 须包含原点 (0, 0)，且宽高为有限正数。'
        }
        # Render at one coordinate unit per logical pixel before the viewport transform.
        $art.Width = [Svg.SvgUnit]::new($box.Width)
        $art.Height = [Svg.SvgUnit]::new($box.Height)
        $panel.Tag = @{
            Art = $art
            Box = $box
            Size = [Drawing.SizeF]::new($box.Width, $box.Height)
            Width = 1.0
            Height = 1.0
            WidthLimit = 1.5
            HeightLimit = 1.5
        }
    } catch {
        $notice = [Windows.Forms.Label]::new()
        $notice.Text = "效果预览无法加载 bow.svg。`n请检查素材和随包文件。"
        $notice.Dock = 'Fill'
        $notice.TextAlign = 'MiddleCenter'
        $panel.AccessibleDescription = $_.Exception.Message
        $panel.Controls.Add($notice)
        return $panel
    }

    $panel.Add_SizeChanged({ param($sender, $eventArgs) $sender.Invalidate() })
    $panel.Add_Paint({
        param($sender, $eventArgs)
        $preview = $sender.Tag
        $graphics = $eventArgs.Graphics
        if (-not $preview.Art) {
            $alignment = [Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'
            [Windows.Forms.TextRenderer]::DrawText($graphics, '无法绘制舰艏。请检查 bow.svg。',
                $sender.Font, $sender.ClientRectangle, $sender.ForeColor, $alignment)
            return
        }
        $padding = 16.0 * $graphics.DpiX / 96.0
        $center = $sender.ClientSize.Width / 2.0
        $waterline = $sender.ClientSize.Height * 0.73
        $lowerSpace = $sender.ClientSize.Height - $waterline - $padding
        if ($center -le $padding -or $waterline -le $padding -or $lowerSpace -le 0) { return }

        $graphics.SmoothingMode = 'AntiAlias'
        $graphics.DrawLine([Drawing.Pens]::LightSlateGray, [single]$padding, [single]$waterline,
            [single](2 * $center - $padding), [single]$waterline)
        $box = $preview.Box
        $horizontalExtent = [math]::Max(-[double]$box.MinX, [double]$box.MinX + $box.Width)
        $upperExtent = -[double]$box.MinY
        $lowerExtent = [double]$box.MinY + $box.Height
        # Fit ordinary poses with a shared origin and let the viewport clip larger values.
        $horizontalFit = $horizontalExtent * $preview.WidthLimit / ($center - $padding)
        $verticalFit = [math]::Max($upperExtent / ($waterline - $padding), $lowerExtent / $lowerSpace)
        $fit = [math]::Max($horizontalFit, $verticalFit * $preview.HeightLimit)
        $sx = $preview.Width / $fit
        $sy = $preview.Height / $fit
        if ($sx * $box.Width -lt 0.5 -or $sy * $box.Height -lt 0.5) { return }

        $matrix = $null
        $state = $graphics.Save()
        try {
            $matrix = [Drawing.Drawing2D.Matrix]::new($sx, 0, 0, $sy,
                ($center + $box.MinX * $sx), ($waterline + $box.MinY * $sy))
            $graphics.Transform = $matrix
            $preview.Art.Draw($graphics, $preview.Size)
        } catch {
            $sender.AccessibleDescription = $_.Exception.Message
            if ($preview.Width -le 2 -and $preview.Height -le 2) {
                $preview.Art = $null
                $sender.Invalidate()
            }
        } finally {
            $graphics.Restore($state)
            if ($matrix) { $matrix.Dispose() }
        }
    })
    return $panel
}

function Set-BowPreviewPose($panel, [double[]]$ratios, [double]$progress) {
    if (-not $panel.Tag) { return }
    $preview = $panel.Tag
    $preview.Height = $ratios[0] * (1 - $progress) + $ratios[2] * $progress
    $preview.Width = $ratios[1] * (1 - $progress) + $ratios[3] * $progress
    $preview.HeightLimit = [math]::Min(2.0, [math]::Max(1.5, [math]::Max($ratios[0], $ratios[2])))
    $preview.WidthLimit = [math]::Min(2.0, [math]::Max(1.5, [math]::Max($ratios[1], $ratios[3])))
    $panel.Invalidate()
}
