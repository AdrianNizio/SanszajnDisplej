<#
    Shared constants and helpers used by multiple installer steps.
    Step-specific code belongs in its Step-*.ps1 file.
#>

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- constants
$InstallDir  = 'C:\Sunshine'
$TempDir     = Join-Path $env:TEMP 'sunshine-display-installer'
$VddSettings = 'C:\VirtualDisplayDriver\vdd_settings.xml'
$MmtZipUrl   = 'https://www.nirsoft.net/utils/multimonitortool-x64.zip'
$MmtPageUrl  = 'https://www.nirsoft.net/utils/multi_monitor_tool.html'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$DisplaySwitchExe = Join-Path $env:windir 'System32\DisplaySwitch.exe'

# ---------------------------------------------------------------- UI helpers
function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

function Step([string]$title) {
    Write-Host ''
    Write-Host ('=== ' + $title + ' ===') -ForegroundColor Cyan
}

function Ask-YesNo([string]$question, [bool]$default = $true) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = (Read-Host "$question $hint").Trim().ToLower()
        if ($a -eq '') { return $default }
        if ($a -eq 'y' -or $a -eq 'yes') { return $true }
        if ($a -eq 'n' -or $a -eq 'no') { return $false }
        Say 'Please answer y or n.' 'Yellow'
    }
}

# ---------------------------------------------------------------- config helpers
function Run-Mmt([string[]]$MmtArgs) {
    $quoted = $MmtArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    Start-Process -FilePath $script:mmt -ArgumentList $quoted -Wait
}

function Read-Cfg([string]$path) {
    $blocks = @()
    $cur = $null
    foreach ($line in Get-Content -Path $path) {
        if ($line -match '^\[Monitor\d+\]') {
            $cur = [ordered]@{}
            $blocks += , $cur
        }
        elseif ($null -ne $cur -and $line -match '^([^=]+)=(.*)$') {
            $cur[$matches[1]] = $matches[2]
        }
    }
    , $blocks
}

function Save-Snapshot([string]$path) {
    Remove-Item -Path $path -ErrorAction SilentlyContinue
    Run-Mmt '/SaveConfig', $path
    $t = 0
    while (-not (Test-Path $path) -and $t -lt 20) { Start-Sleep -Milliseconds 250; $t++ }
    if (-not (Test-Path $path)) {
        throw "MultiMonitorTool did not write $path (admin rights? does the folder exist?)"
    }
    Read-Cfg $path
}

# ---------------------------------------------------------------- detection helpers

function Get-Vdd {
    @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object {
        $device = $_
        $hardwareIds = @((Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data)
        $device.Status -eq 'OK' -and ($device.FriendlyName -match 'Virtual Display Driver' -or $hardwareIds -contains 'Root\MttVDD')
    })
}

function Test-VddInstalled {
    if (@(Get-Vdd).Count -gt 0) { return $true }
    $monitor = Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'OK' -and $_.InstanceId -match '^DISPLAY\\MTT1337\\'
    } | Select-Object -First 1
    return $null -ne $monitor
}

# Returns the folder that contains sunshine.exe (and the config folder), or $null.
function Find-SunshineDir {
    $cands = @()
    $cands += (Join-Path $env:ProgramFiles 'Sunshine')
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'Sunshine') }

    # the Windows service points at ...\Sunshine\tools\sunshinesvc.exe, so also try the parent folder
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='SunshineService'" -ErrorAction Stop
        if ($svc -and $svc.PathName -match '^\s*"?([^"]+?\.exe)') {
            $svcDir = Split-Path -Parent $matches[1]
            $cands += $svcDir
            $cands += (Split-Path -Parent $svcDir)
        }
    }
    catch { }

    # the uninstall entry usually records the install location
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try {
            Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Sunshine*' -and $_.InstallLocation } |
                ForEach-Object { $cands += $_.InstallLocation.TrimEnd('\') }
        }
        catch { }
    }

    foreach ($d in ($cands | Select-Object -Unique)) {
        if ($d -and (Test-Path (Join-Path $d 'sunshine.exe'))) { return $d }
    }
    return $null
}

# ---------------------------------------------------------------- failsafe + test helpers

function Restore-PhysicalDisplays {
    if (-not $script:mmt -or -not (Test-Path $script:mmt)) { throw 'MultiMonitorTool is unavailable.' }

    Say 'Recovery: restoring a verified physical display...' 'Yellow'
    Start-Process -FilePath $DisplaySwitchExe -ArgumentList '/extend' -Wait
    Start-Sleep -Seconds 5
    $recoveryPath = Join-Path $env:TEMP 'sunshine-display-recovery.cfg'
    $blocks = Save-Snapshot $recoveryPath
    $physical = @($blocks | Where-Object {
        $_.MonitorID -and $_.MonitorID -notmatch 'MTT1337' -and [int]$_.Width -gt 0
    })
    if ($physical.Count -eq 0) {
        throw 'Windows did not expose an active physical monitor; the virtual display was left unchanged.'
    }

    $primary = @($physical | Where-Object { $_.MonitorID -match 'BOE|AUO|LGD|SDC' } | Select-Object -First 1)
    if ($primary.Count -eq 0) { $primary = @($physical | Select-Object -First 1) }
    Run-Mmt '/SetPrimary', $primary[0].Name

    $virtual = @($blocks | Where-Object { $_.MonitorID -match 'MTT1337' -and [int]$_.Width -gt 0 })
    foreach ($monitor in $virtual) { Run-Mmt '/disable', $monitor.Name }
    Start-Sleep -Seconds 3

    $verified = Save-Snapshot $recoveryPath
    $physicalOn = @($verified | Where-Object {
        $_.MonitorID -and $_.MonitorID -notmatch 'MTT1337' -and [int]$_.Width -gt 0
    })
    $virtualOn = @($verified | Where-Object { $_.MonitorID -match 'MTT1337' -and [int]$_.Width -gt 0 })
    if ($physicalOn.Count -eq 0 -or $virtualOn.Count -gt 0) {
        throw "Recovery verification failed (physical active: $($physicalOn.Count), virtual active: $($virtualOn.Count))."
    }
    Say "Recovery complete: $($primary[0].Name) is primary and the virtual display is off." 'Green'
}
