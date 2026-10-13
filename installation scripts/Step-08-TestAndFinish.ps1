function Set-SunshineGlobalPrep([string]$sunshineDir) {
    $confDir  = Join-Path $sunshineDir 'config'
    $conf     = Join-Path $confDir 'sunshine.conf'
    $doPath   = Join-Path $InstallDir 'do.bat'
    $undoPath = Join-Path $InstallDir 'undo.bat'
    if (-not (Test-Path $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }

    $existed = Test-Path $conf
    $raw = ''
    if ($existed) { $raw = [IO.File]::ReadAllText($conf) }
    $nl = if ($raw.Length -eq 0 -or $raw -match "`r`n") { "`r`n" } else { "`n" }

    $lines = @()
    if ($raw.Length -gt 0) {
        $lines = @($raw -split "`r?`n")
        if ($lines[$lines.Count - 1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    }

    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*global_prep_cmd\s*=') { $idx = $i; break }
    }

    $entries = @()
    if ($idx -ge 0) {
        $val = ($lines[$idx] -replace '^\s*global_prep_cmd\s*=\s*', '').Trim()
        if ($val.Length -gt 0) {
            $parsed = $null
            try { $parsed = ConvertFrom-Json -InputObject $val }
            catch { throw "The global_prep_cmd line in $conf is not valid JSON. Fix or remove it, then run the installer again." }
            if ($null -ne $parsed) { $entries = @($parsed) }
        }
    }

    foreach ($e in $entries) {
        $eDo = $e.'do'    # quoted because "do" is a PowerShell keyword
        if ($eDo -and ([string]$eDo).ToLower() -eq $doPath.ToLower()) { return 'already' }
    }

    $entries += [pscustomobject][ordered]@{ 'do' = $doPath; 'elevated' = $true; 'undo' = $undoPath }
    $json = ConvertTo-Json -InputObject @($entries) -Compress
    $newLine = 'global_prep_cmd = ' + $json
    if ($idx -ge 0) { $lines[$idx] = $newLine } else { $lines += $newLine }

    if ($existed) { Copy-Item -Path $conf -Destination "$conf.bak-$Stamp" -Force }
    $text = (($lines -join $nl) + $nl)
    [IO.File]::WriteAllText($conf, $text, (New-Object System.Text.UTF8Encoding($false)))
    if ($existed) { return 'added' } else { return 'created' }
}

function Add-ToSunshine {
    $sunDir = Find-SunshineDir
    if (-not $sunDir) {
        Say 'Sunshine was not found on this PC, so its config could not be edited.' 'Yellow'
        Say 'Install Sunshine and run this installer again (it skips everything already done), or add the scripts by hand.' 'Yellow'
        return $false
    }
    $conf = Join-Path $sunDir 'config\sunshine.conf'
    Say "Sunshine found in: $sunDir" 'Green'
    Say "Config file:       $conf"
    Say 'This adds do.bat and undo.bat to global_prep_cmd, so they run for every app you stream.'
    Say 'All other settings and any existing global_prep_cmd entries are kept. A backup is saved as sunshine.conf.bak-<time>.'
    if (-not (Ask-YesNo 'Add C:\Sunshine\do.bat and undo.bat to Sunshine now?')) { return $false }

    try { $result = Set-SunshineGlobalPrep $sunDir }
    catch {
        Say ('Could not edit the Sunshine config: ' + $_.Exception.Message) 'Red'
        return $false
    }
    if ($result -eq 'already') { Say 'Already in sunshine.conf - nothing to change.' 'Green' }
    elseif ($result -eq 'created') { Say 'sunshine.conf did not exist, so it was created with the scripts in it.' 'Green' }
    else { Say 'Added to sunshine.conf (backup saved next to it).' 'Green' }

    $svc = Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
    if ($svc) {
        Say 'Sunshine only reads its config when it starts, so it needs a restart to pick this up (this ends any running stream).'
        if (Ask-YesNo 'Restart the Sunshine service now?') {
            try { Restart-Service -Name 'SunshineService' -Force; Say 'Sunshine restarted.' 'Green' }
            catch { Say ('Could not restart the service automatically: ' + $_.Exception.Message + ' Restart Sunshine yourself.') 'Yellow' }
        }
        else { Say 'Restart Sunshine (or reboot) before your next stream.' 'Yellow' }
    }
    else {
        Say 'Sunshine does not run as a Windows service here. Restart it yourself so it picks up the change.' 'Yellow'
    }
    return $true
}

function Invoke-Failsafe {
    Say 'Failsafe: waking all screens...' 'Yellow'
    try {
        # /extend wakes every connected display. (/internal means "PC screen only" on the PRIMARY display,
        # which is the virtual one while a stream is active, so it would not bring the real screens back.)
        Start-Process -FilePath $DisplaySwitchExe -ArgumentList '/extend' -Wait
        Start-Sleep -Seconds 5
        $p = Join-Path $InstallDir 'physical.cfg'
        if ((Test-Path $p) -and $script:mmt) {
            Run-Mmt '/LoadConfig', $p
            Start-Sleep -Seconds 3
        }
    }
    catch { Say ('Failsafe error: ' + $_.Exception.Message) 'Red' }
}

function Get-LayoutState([string]$path) {
    $blocks = Save-Snapshot $path
    $virtOn = $false
    $physOn = 0
    foreach ($b in $blocks) {
        $active = [int]$b.Width -gt 0
        if ($b.MonitorID -eq $script:VirtualId) { if ($active) { $virtOn = $true } }
        elseif ($script:PhysicalIds -contains $b.MonitorID -and $active) { $physOn++ }
    }
    [pscustomobject]@{ VirtualOn = $virtOn; PhysOn = $physOn; PhysTotal = $script:PhysicalIds.Count }
}

Step 'Step 8/8: Safe test'
Say 'The test runs exactly what Sunshine will run:' 'Yellow'
Say '  1. do.bat   -> ALL your real screens turn off, only the virtual screen stays on (about 15 seconds of black).'
Say '  2. undo.bat -> your real screens come back.'
Say '  3. A pop-up appears on your main screen: "Are all screens back?"  Click Yes within 30 seconds to keep the setup.'
Say '     No answer, or No: everything is switched back and the generated settings are NOT kept.'
Write-Host ''
Say 'Black-screen protection:' 'Yellow'
Say '  - A separate background watchdog wakes all screens (DisplaySwitch /extend + physical.cfg) after 4 minutes if this test did not finish.'
Say '  - If you are stuck on black: wait, or press Win+P and cycle the options, or Win+Ctrl+Shift+B to reset the graphics driver.'
Say '  - The failsafe uses /extend rather than /internal: /internal keeps only the PRIMARY screen, which is the virtual one during the test.'
Write-Host ''
if (-not (Ask-YesNo 'Run the test now?')) {
    Say 'Test skipped. The files are in place but UNTESTED. Run this installer again to test later.' 'Yellow'
}
else {
    $watchdog = @"
Start-Sleep -Seconds 240
if (Test-Path '$flagPath') {
    Start-Process -FilePath '$DisplaySwitchExe' -ArgumentList '/extend' -Wait
    Start-Sleep -Seconds 5
    Start-Process -FilePath '$($script:mmt)' -ArgumentList '/LoadConfig','$physCfg' -Wait
    Remove-Item -Path '$flagPath' -Force -ErrorAction SilentlyContinue
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdog))
    Set-Content -Path $flagPath -Value $Stamp -Encoding ASCII
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)

    $keep = $false
    $startOk = $false
    $restoreInfo = $null
    try {
        Say 'Putting your screens into the normal layout first...'
        Run-Mmt '/LoadConfig', $physCfg
        Start-Sleep -Seconds 3

        Say 'Starting the test in:'
        foreach ($s in 5, 4, 3, 2, 1) { Write-Host "  $s" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }

        & (Join-Path $InstallDir 'do.bat') | Out-Null
        $state1 = Get-LayoutState (Join-Path $InstallDir 'test-snapshot.cfg')
        $startOk = ($state1.VirtualOn -and $state1.PhysOn -eq 0)

        if ($startOk) {
            Say 'Virtual-only mode is active (you cannot see this on the real screens). Waiting 15 seconds...' 'Green'
            Start-Sleep -Seconds 15
        }
        else {
            Say ('do.bat did not reach virtual-only mode (virtual on: {0}, physical still on: {1}). Restoring now.' -f $state1.VirtualOn, $state1.PhysOn) 'Red'
        }

        & (Join-Path $InstallDir 'undo.bat') | Out-Null
        Start-Sleep -Seconds 3
        $restoreInfo = Get-LayoutState (Join-Path $InstallDir 'test-snapshot.cfg')
        $restoreOk = ($restoreInfo.PhysOn -eq $restoreInfo.PhysTotal -and -not $restoreInfo.VirtualOn)
        Say ('After undo: physical screens on {0}/{1}, virtual still on: {2}' -f $restoreInfo.PhysOn, $restoreInfo.PhysTotal, $restoreInfo.VirtualOn)

        if (-not $startOk) {
            Say 'The virtual screen did not take over, so nothing will be kept. See C:\Sunshine\display-switch.log for the reason.' 'Red'
        }
        else {
            $note = if ($restoreOk) { 'Automatic check: all physical screens are back.' } else { 'Automatic check: some screens may NOT be back - look carefully.' }
            Say 'Waiting for your confirmation pop-up (30 seconds)...' 'Cyan'
            $sh = New-Object -ComObject WScript.Shell
            $msg = "Test finished.`n`nAre ALL your screens back on and arranged correctly?`n`n$note`n`nYes = keep this setup`nNo, or no answer within 30 seconds = switch back and discard"
            $ans = $sh.Popup($msg, 30, 'Sunshine display switch - confirm', (4 + 32 + 4096))
            if ($ans -eq 6) { $keep = $true }
        }
    }
    catch {
        Say ('Test error: ' + $_.Exception.Message) 'Red'
    }
    finally {
        Remove-Item -Path $flagPath -Force -ErrorAction SilentlyContinue
    }

    if ($keep) {
        Say 'Confirmed - the setup is kept.' 'Green'
        $testKept = $true
        Remove-Item -Path $masterPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $InstallDir 'test-snapshot.cfg') -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $InstallDir 'snapshot.cfg') -Force -ErrorAction SilentlyContinue
    }
    else {
        Invoke-Failsafe
        $failDir = Join-Path $InstallDir ('failed-install-' + $Stamp)
        New-Item -ItemType Directory -Path $failDir -Force | Out-Null
        foreach ($f in @($physCfg, $tplCfg, $virtCfg, $masterPath)) {
            if (Test-Path $f) { Move-Item -Path $f -Destination $failDir -Force }
        }
        Say 'Not confirmed (or the test failed): the generated settings were NOT kept.' 'Red'
        Say "They were moved to $failDir for inspection. Log: C:\Sunshine\display-switch.log and C:\Sunshine\install.log" 'Yellow'
        $exitCode = 2
    }
}

if ($exitCode -eq 0) {
    Step 'Add the scripts to Sunshine'
    $added = $false
    if ($testKept) {
        $added = Add-ToSunshine
    }
    else {
        Say 'The test was skipped, so Sunshine''s config is left alone by default.' 'Yellow'
        if (Ask-YesNo 'Add the scripts to Sunshine anyway (untested)?' $false) { $added = Add-ToSunshine }
    }

    Step 'Done'
    if ($added) {
        Say 'Sunshine now runs do.bat when a stream starts and undo.bat when the app session ends.' 'Green'
    }
    else {
        Say 'To add the scripts by hand, either:' 'Yellow'
        Say '  a) Web UI (https://localhost:47990): Configuration -> General -> Command Preparations -> Add'
        Say '       Do: C:\Sunshine\do.bat    Undo: C:\Sunshine\undo.bat    tick "Run as administrator", Save.'
        Say '  b) or add this line to <Sunshine folder>\config\sunshine.conf and restart Sunshine:'
        Say '       global_prep_cmd = [{"do":"C:\\Sunshine\\do.bat","elevated":true,"undo":"C:\\Sunshine\\undo.bat"}]'
    }
    Say 'Make sure Sunshine''s own "Display Device" setting (Configuration -> Audio/Video) is OFF, or it will fight these scripts.'
    Say 'If one of your apps has "exclude global prep commands" ticked, these scripts will not run for that app.'
    Write-Host ''
    Say 'Good to know:' 'Yellow'
    Say '  - Undo runs when the app session ends: quit the app from Moonlight to be sure your screens come back.'
    Say '  - If you ever get stuck on black: run C:\Sunshine\undo.bat, or press Win+P and cycle the options.'
    Say '  - Every step is logged in C:\Sunshine\display-switch.log.'
    Say '  - Before big GPU or chipset driver updates, uninstall VDD first (it can steal display priority and cause black screens).'
}