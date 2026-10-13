function Test-SunshineInstalled {
    if (Find-SunshineDir) { return $true }
    if (Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue) { return $true }
    return $false
}

Step 'Step 5/8: Sunshine'
if (Test-SunshineInstalled) {
    $sd = Find-SunshineDir
    if ($sd) { Say "Sunshine is already installed in: $sd - skipping the install." 'Green' }
    else { Say 'Sunshine is already installed - skipping the install.' 'Green' }
}
else {
    Say 'Sunshine is not installed. It is the streaming host that Moonlight connects to.'
    if (Ask-YesNo 'Install the newest Sunshine now (via winget)?') {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            & winget install --id=LizardByte.Sunshine -e --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { Say "winget reported exit code $LASTEXITCODE." 'Yellow' }
        }
        else {
            Say 'winget is not available. Opening the Sunshine releases page; run the Windows installer from there.' 'Yellow'
            Start-Process 'https://github.com/LizardByte/Sunshine/releases/latest'
            [void](Read-Host 'Press Enter when Sunshine is installed')
        }
        if (Test-SunshineInstalled) { Say 'Sunshine detected.' 'Green' }
        else { Say 'Could not confirm the Sunshine install. You can install it later; the display scripts do not depend on it.' 'Yellow' }
    }
    else {
        Say 'Skipped. Install Sunshine whenever you like; the display scripts work independently.' 'Yellow'
    }
}