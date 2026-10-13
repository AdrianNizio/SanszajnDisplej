function Find-Mmt {
    foreach ($p in @((Join-Path $InstallDir 'MultiMonitorTool.exe'), (Join-Path $env:ProgramFiles 'Sunshine\MultiMonitorTool.exe'))) {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command 'MultiMonitorTool.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

Step 'Step 1/8: MultiMonitorTool (NirSoft)'
$script:mmt = Find-Mmt
$mmtFromTemp = $false
if ($script:mmt) {
    Say "Found MultiMonitorTool: $script:mmt" 'Green'
    Say 'It will be used as it is. Nothing to download.'
}
else {
    Say 'MultiMonitorTool is a small free tool from NirSoft. It is used to turn screens on and off and to save layouts.'
    Say "Official download: $MmtZipUrl"
    if (Ask-YesNo 'Download it now?') {
        try {
            New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
            $zip = Join-Path $TempDir 'multimonitortool-x64.zip'
            $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
            Invoke-WebRequest -Uri $MmtZipUrl -OutFile $zip -UseBasicParsing -UserAgent $ua -Headers @{ Referer = $MmtPageUrl }
            $out = Join-Path $TempDir 'mmt'
            if (Test-Path $out) { Remove-Item -Path $out -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $out -Force
            $exe = Join-Path $out 'MultiMonitorTool.exe'
            if (-not (Test-Path $exe)) { throw 'MultiMonitorTool.exe was not found inside the downloaded zip.' }
            Unblock-File -Path $exe -ErrorAction SilentlyContinue
            $script:mmt = $exe
            $mmtFromTemp = $true
            Say 'Downloaded. It will be copied into C:\Sunshine in step 6.' 'Green'
        }
        catch {
            Say ('Download failed: ' + $_.Exception.Message) 'Red'
            Say "You can download it by hand from $MmtPageUrl (the x64 zip) and unpack it anywhere." 'Yellow'
        }
    }
    if (-not $script:mmt) {
        $p = (Read-Host 'Path to an existing MultiMonitorTool.exe (leave empty to quit)').Trim().Trim('"')
        if ($p -and (Test-Path $p)) { $script:mmt = $p }
        else { throw 'MultiMonitorTool is required. Install it and run this installer again.' }
    }
}