$SwitchScriptTemplate = @'
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Start', 'Restore')]
    [string]$Mode
)

# Sunshine display switcher.
#   Prepare: snapshot current layout, refresh Name fields in physical.cfg and virtual.cfg (matched by MonitorID)
#   Start:   Prepare + enable virtual display, make it primary, disable physical screens
#   Restore: wake all displays, refresh names again, load physical.cfg, set the main display as primary
# Everything lives in C:\Sunshine. Log: C:\Sunshine\display-switch.log

$ErrorActionPreference = 'Stop'

$dir  = 'C:\Sunshine'
$mmt  = '__MMT_PATH__'
$phys = Join-Path $dir 'physical.cfg'
$virt = Join-Path $dir 'virtual.cfg'
$tpl  = Join-Path $dir 'virtual.template.cfg'
$snap = Join-Path $dir 'snapshot.cfg'
$log  = Join-Path $dir 'display-switch.log'

function Log([string]$msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Mode] $msg" | Add-Content -Path $log
}

function Run-Mmt([string[]]$MmtArgs) {
    $quoted = $MmtArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    Start-Process -FilePath $mmt -ArgumentList $quoted -Wait
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

function Write-Cfg([string]$path, $blocks) {
    $out = @()
    $i = 0
    foreach ($b in $blocks) {
        $out += "[Monitor$i]"
        foreach ($k in $b.Keys) { $out += "$k=$($b[$k])" }
        $i++
    }
    Set-Content -Path $path -Value $out -Encoding ASCII
}

function Save-Snapshot {
    Remove-Item -Path $snap -ErrorAction SilentlyContinue
    Run-Mmt '/SaveConfig', $snap
    $t = 0
    while (-not (Test-Path $snap) -and $t -lt 20) { Start-Sleep -Milliseconds 250; $t++ }
    if (-not (Test-Path $snap)) {
        throw "MultiMonitorTool did not write $snap (needs admin rights; folder must exist)"
    }
    Read-Cfg $snap
}

function Get-NameMap($blocks) {
    $map = @{}
    foreach ($b in $blocks) { if ($b.MonitorID) { $map[$b.MonitorID] = $b.Name } }
    $map
}

function Update-Names($blocks, $map) {
    foreach ($b in $blocks) {
        if ($map.ContainsKey($b.MonitorID)) {
            if ($b.Name -ne $map[$b.MonitorID]) { Log "name $($b.Name) -> $($map[$b.MonitorID]) ($($b.MonitorID))" }
            $b.Name = $map[$b.MonitorID]
        }
        else {
            Log "WARNING: $($b.MonitorID) not found in snapshot, name left as $($b.Name)"
        }
    }
}

try {
    if (-not (Test-Path $tpl)) { throw "Template missing: $tpl" }
    $tplBlocks = Read-Cfg $tpl
    $virtualId = ($tplBlocks | Where-Object { [int]$_.Width -gt 0 } | Select-Object -First 1).MonitorID
    if (-not $virtualId) { throw 'Template has no active monitor (the virtual one needs Width > 0)' }

    if ($Mode -eq 'Prepare' -or $Mode -eq 'Start') {
        $snapBlocks = Save-Snapshot
        $names = Get-NameMap $snapBlocks

        # Only trust the snapshot as the "physical" layout if every physical screen is on and the virtual one is off.
        $physOk = $true
        foreach ($b in $snapBlocks) {
            $active = [int]$b.Width -gt 0
            if ($b.MonitorID -eq $virtualId) { if ($active) { $physOk = $false } }
            elseif (-not $active) { $physOk = $false }
        }

        if ($physOk) {
            $layout = $snapBlocks
            Log 'snapshot looks like a valid physical layout, using it as physical.cfg'
        }
        elseif (Test-Path $phys) {
            $layout = Read-Cfg $phys
            Log 'WARNING: snapshot is not a clean physical layout, keeping the previous physical.cfg and only refreshing names'
        }
        else {
            throw 'Snapshot is not a clean physical layout and there is no earlier physical.cfg'
        }

        Update-Names $layout $names
        Write-Cfg $phys $layout

        Update-Names $tplBlocks $names
        Write-Cfg $virt $tplBlocks
        Log 'physical.cfg and virtual.cfg written'

        if ($Mode -eq 'Start') {
            # 1) Turn the virtual display on FIRST, so Windows never ends up with zero active screens.
            Run-Mmt '/enable', $names[$virtualId]
            Start-Sleep -Seconds 3

            # 2) Names can change once it is on, so re-read them with everything awake.
            $awake = Save-Snapshot
            $names = Get-NameMap $awake
            $virtActive = $awake | Where-Object { $_.MonitorID -eq $virtualId -and [int]$_.Width -gt 0 }
            if (-not $virtActive) {
                throw 'Virtual display did not turn on after /enable, leaving the physical screens alone'
            }

            # 3) Make it primary, then turn the physical screens off.
            Run-Mmt '/SetPrimary', $names[$virtualId]
            Start-Sleep -Seconds 2
            $physNames = @($awake | Where-Object { $_.MonitorID -ne $virtualId -and [int]$_.Width -gt 0 } | ForEach-Object { $_.Name })
            if ($physNames.Count -gt 0) {
                Run-Mmt (@('/disable') + $physNames)
                Start-Sleep -Seconds 3
            }
            Log "virtual enabled, disabled: $($physNames -join ', ')"

            # 4) Polish resolution/position with the template config now that the virtual display is active.
            Update-Names $tplBlocks $names
            Write-Cfg $virt $tplBlocks
            Run-Mmt '/LoadConfig', $virt
            Start-Sleep -Seconds 3

            $final = Save-Snapshot
            $ok = $final | Where-Object { $_.MonitorID -eq $virtualId -and [int]$_.Width -gt 0 }
            $left = @($final | Where-Object { $_.MonitorID -ne $virtualId -and [int]$_.Width -gt 0 } | ForEach-Object { $_.Name })
            if ($ok) { Log "final state: virtual active, physical still on: [$($left -join ', ')]" }
            else { Log 'WARNING: virtual display is NOT active at the end' }
        }
    }
    else {
        Start-Process -FilePath "$env:windir\System32\DisplaySwitch.exe" -ArgumentList '/extend' -Wait
        Start-Sleep -Seconds 5

        $snapBlocks = Save-Snapshot
        $names = Get-NameMap $snapBlocks

        if (-not (Test-Path $phys)) { throw "No saved physical layout: $phys" }
        $layout = Read-Cfg $phys
        Update-Names $layout $names
        Write-Cfg $phys $layout

        Run-Mmt '/LoadConfig', $phys
        Start-Sleep -Seconds 3

        $main = $layout | Where-Object {
            [int]$_.Width -gt 0 -and [int]$_.PositionX -eq 0 -and [int]$_.PositionY -eq 0
        } | Select-Object -First 1
        if ($main) {
            Run-Mmt '/SetPrimary', $main.Name
            Log "primary set to $($main.Name) ($($main.MonitorID))"
        }
        else {
            Log 'WARNING: no active monitor at 0,0 in physical.cfg, primary not set'
        }
        Log 'restore finished'
    }
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
'@

$DoBat = @'
@echo off
rem Stream start: refresh names, turn the virtual display on, then turn the physical ones off.
rem If anything fails the script leaves the physical screens alone (see C:\Sunshine\display-switch.log).
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Sunshine\display-switch.ps1" -Mode Start
exit /b 0
'@

$UndoBat = @'
@echo off
rem Stream stop: wake everything, refresh names, restore the physical layout.
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Sunshine\display-switch.ps1" -Mode Restore
'@

function Write-FileSafe([string]$path, [string]$content) {
    $text = ($content -replace "`r?`n", "`r`n")
    if (Test-Path $path) {
        $old = [IO.File]::ReadAllText($path)
        if ($old -ne $text) { Copy-Item -Path $path -Destination "$path.bak-$Stamp" -Force }
    }
    [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII)
}

Step 'Step 6/8: Create the C:\Sunshine folder and the script files'
Say "Folder: $InstallDir"
Say 'Why this folder:' 'Yellow'
Say '  - Outside Program Files, so writing configs and logs never needs special permissions.'
Say '  - Readable by the Sunshine service (it runs as SYSTEM and cannot see your user profile).'
Say '  - Everything (scripts, saved layouts, log) stays in one place and is easy to delete.'
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
try { Start-Transcript -Path (Join-Path $InstallDir 'install.log') -Append | Out-Null; $transcriptOn = $true } catch { }

if ($mmtFromTemp) {
    $target = Join-Path $InstallDir 'MultiMonitorTool.exe'
    Copy-Item -Path $script:mmt -Destination $target -Force
    $script:mmt = $target
    Say "Copied MultiMonitorTool to $target" 'Green'
}
$switchScript = $SwitchScriptTemplate.Replace('__MMT_PATH__', $script:mmt)
Write-FileSafe (Join-Path $InstallDir 'display-switch.ps1') $switchScript
Write-FileSafe (Join-Path $InstallDir 'do.bat') $DoBat
Write-FileSafe (Join-Path $InstallDir 'undo.bat') $UndoBat
Say 'Wrote display-switch.ps1, do.bat and undo.bat (existing files were backed up as .bak-timestamp).' 'Green'