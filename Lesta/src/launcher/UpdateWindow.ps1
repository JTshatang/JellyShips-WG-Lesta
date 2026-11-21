param($updateForm, $updateParent, $updateSession, [int]$updateTop, [int]$updateWidth)

$updateLabel = [Windows.Forms.Label]::new()
$updateLabel.SetBounds(20, $updateTop, ($updateWidth - 40), 40)
$updateLabel.TextAlign = 'MiddleLeft'
$updateLabel.AutoEllipsis = $true
$updateLabel.UseMnemonic = $false
$updateLabel.Text = '正在检查更新…'
$updateLabel.AccessibleName = '自动更新状态'
$updateParent.Controls.Add($updateLabel)
$updateTip = [Windows.Forms.ToolTip]::new()
$updateLabel.Add_TextChanged({ $updateTip.SetToolTip($updateLabel, $updateLabel.Text) })
$updateWork = @{ Process = $null; Line = $null }
$updateTimer = [Windows.Forms.Timer]::new()
$updateTimer.Interval = 150

$updateForm.Add_Shown({
    try {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
            (Join-Path $updateSession.Components 'Updates.ps1') + '" -BackgroundCheck'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.WindowStyle = 'Hidden'
        $start.WorkingDirectory = [Environment]::SystemDirectory
        $start.RedirectStandardOutput = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.EnvironmentVariables['JELLYSHIPS_UPDATE_GAME'] = $updateSession.Layout.Game
        $start.EnvironmentVariables['JELLYSHIPS_UPDATE_HOME'] = $updateSession.Home
        $updateWork.Process = [Diagnostics.Process]::Start($start)
        $updateWork.Line = $updateWork.Process.StandardOutput.ReadLineAsync()
        $updateTimer.Start()
    } catch { $updateLabel.Text = "无法启动自动更新。$($_.Exception.Message)" }
})
$updateTimer.Add_Tick({
    if (!$updateWork.Line.IsCompleted) { return }
    try {
        $line = $updateWork.Line.GetAwaiter().GetResult()
        if ($null -eq $line) { $updateTimer.Stop(); return }
        $updateLabel.Text = $line
        $updateWork.Line = $updateWork.Process.StandardOutput.ReadLineAsync()
    } catch { $updateTimer.Stop(); $updateLabel.Text = '自动更新暂未完成' }
})
$updateForm.Add_FormClosed({
    $updateTimer.Dispose()
    $updateTip.Dispose()
    if ($updateWork.Process) {
        # The worker owns only a private staging directory. A committed pending record survives close.
        try { if (!$updateWork.Process.HasExited) { $updateWork.Process.Kill() } }
        catch [InvalidOperationException] { }
        finally { $updateWork.Process.Dispose() }
    }
})
