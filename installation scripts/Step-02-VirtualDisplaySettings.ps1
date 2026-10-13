function Parse-Resolution([string]$text) {
    if ($text -match '^(\d{3,5})\s*[xX]\s*(\d{3,5})$') {
        $w = [int]$matches[1]
        $h = [int]$matches[2]
        if ($w -ge 640 -and $w -le 7680 -and $h -ge 480 -and $h -le 4320) { return @($w, $h) }
    }
    return $null
}

function Ask-Resolution {
    Say 'Resolution of the virtual screen:'
    Say '  1) 3840x2160 (4K)   [default]'
    Say '  2) 2560x1440'
    Say '  3) 1920x1080'
    Say '  4) custom (for example 5120x1440)'
    while ($true) {
        $a = (Read-Host 'Choose 1-4, or type WIDTHxHEIGHT directly').Trim()
        if ($a -eq '' -or $a -eq '1') { return @(3840, 2160) }
        if ($a -eq '2') { return @(2560, 1440) }
        if ($a -eq '3') { return @(1920, 1080) }
        if ($a -eq '4') { $a = (Read-Host 'Type WIDTHxHEIGHT').Trim() }
        $r = Parse-Resolution $a
        if ($r) { return $r }
        Say 'Not a valid resolution. Examples: 3840x2160, 2560x1440 (allowed range 640x480 to 7680x4320).' 'Yellow'
    }
}

function Ask-Refresh {
    while ($true) {
        $a = (Read-Host 'Refresh rate in Hz [60]').Trim()
        if ($a -eq '') { return 60 }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 24 -and $n -le 500) { return $n }
        Say 'Enter a whole number between 24 and 500.' 'Yellow'
    }
}

Step 'Step 2/8: Virtual Display Driver - how should the virtual screen look?'
$vddFound = @(Get-Vdd)
if ((Test-VddInstalled)) {
    Say 'Virtual Display Driver is already installed. Its settings file will be updated with your answers.' 'Green'
}
else {
    Say 'Virtual Display Driver (VDD) is not installed yet. It is installed in step 3 after your answers.'
}
Write-Host ''
$res = Ask-Resolution
$width = $res[0]
$height = $res[1]
Write-Host ''
Say 'HDR: makes the driver advertise HDR support (needs Windows 11 23H2 or newer; you still switch HDR on in Windows display settings).'
$hdr = Ask-YesNo 'Enable HDR on the virtual screen?' $true
Write-Host ''
$hz = Ask-Refresh
Write-Host ''
Say ('Virtual screen: {0}x{1} @ {2} Hz, HDR {3}' -f $width, $height, $hz, $(if ($hdr) { 'on' } else { 'off' })) 'Green'
if (-not (Ask-YesNo 'Continue with these settings?')) { throw 'Cancelled. Run the installer again to choose different settings.' }