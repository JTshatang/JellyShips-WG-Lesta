$ink = [Drawing.ColorTranslator]::FromHtml('#253139')
$muted = [Drawing.ColorTranslator]::FromHtml('#58656b')
$accent = [Drawing.ColorTranslator]::FromHtml('#365d70')
$rule = [Drawing.ColorTranslator]::FromHtml('#d7dddf')
$paper = [Drawing.Color]::White

function New-SettingsWindow($title, $width, $height) {
    $window = [Windows.Forms.Form]::new()
    $window.SuspendLayout()
    $window.Text = $title
    $window.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
    $window.ForeColor = $ink
    $window.BackColor = $paper
    $window.AutoScaleMode = 'None'
    $window.ClientSize = [Drawing.Size]::new($width, $height)
    $window.StartPosition = 'CenterScreen'
    return $window
}

function Scale-SettingsWindow($window) {
    $graphics = $window.CreateGraphics()
    try { $window.Scale([Drawing.SizeF]::new($graphics.DpiX / 96, $graphics.DpiY / 96)) }
    finally { $graphics.Dispose() }
    $window.ResumeLayout($true)
}

function Fit-SettingsWindow($window) {
    $workArea = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $window.Size = [Drawing.Size]::new([math]::Min($window.Width, $workArea.Width),
        [math]::Min($window.Height, $workArea.Height))
    $window.StartPosition = 'Manual'
    $window.Location = [Drawing.Point]::new(($workArea.Left + ($workArea.Width - $window.Width) / 2),
        ($workArea.Top + ($workArea.Height - $window.Height) / 2))
}

function New-SettingsControl($parent, $kind, $caption, $x, $y, $width, $height) {
    $control = New-Object ("Windows.Forms." + $kind)
    if ($caption) { $control.Text = $caption }
    $control.SetBounds($x, $y, $width, $height)
    if ($kind -eq 'Button') {
        $control.FlatStyle = 'Flat'
        $control.FlatAppearance.BorderColor = $rule
        $control.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(239, 242, 243)
        $control.BackColor = $paper
    } elseif ($kind -eq 'Label') {
        $control.UseMnemonic = $false
    }
    $parent.Controls.Add($control)
    return $control
}

function New-SettingsHeading($parent, $caption, $x, $y, $width) {
    $heading = New-SettingsControl $parent Label $caption $x $y $width 28
    $heading.Font = [Drawing.Font]::new($parent.Font.FontFamily, 11, [Drawing.FontStyle]::Bold)
    $heading.TextAlign = 'MiddleLeft'
}

function New-SettingsPage($caption) {
    $page = [Windows.Forms.Panel]::new()
    $page.Dock = 'Fill'
    $page.AutoScroll = $true
    $page.Visible = $false
    $page.AccessibleName = $caption
    $pageHost.Controls.Add($page)

    $tab = [Windows.Forms.RadioButton]::new()
    $tab.Appearance = 'Button'
    $tab.FlatStyle = 'Flat'
    $tab.FlatAppearance.BorderSize = 0
    $tab.FlatAppearance.CheckedBackColor = $paper
    $tab.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(239, 242, 243)
    $tab.Text = $caption
    $tab.TextAlign = 'MiddleCenter'
    $tab.Size = [Drawing.Size]::new(105, 39)
    $tab.Margin = [Windows.Forms.Padding]::Empty
    $tab.Tag = $page
    $tab.AccessibleRole = 'PageTab'
    $tab.Add_CheckedChanged({
        param($sender, $eventArgs)
        $sender.Tag.Visible = $sender.Checked
        $sender.ForeColor = if ($sender.Checked) { $accent } else { $muted }
        if ($sender.Checked) {
            $sender.Tag.BringToFront()
            $footer.Visible = $sender.Tag -ne $maintenancePage
        }
    })
    $tab.Add_Paint({
        param($sender, $paint)
        if ($sender.Checked) {
            $lineHeight = [Math]::Max(2, [int](2 * $paint.Graphics.DpiY / 96))
            $brush = [Drawing.SolidBrush]::new($accent)
            try { $paint.Graphics.FillRectangle($brush, 0, ($sender.Height - $lineHeight), $sender.Width, $lineHeight) }
            finally { $brush.Dispose() }
        }
    })
    $navigation.Controls.Add($tab)
    return $page
}
