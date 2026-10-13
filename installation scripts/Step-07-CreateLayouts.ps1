function Copy-Block($b) {
    $n = [ordered]@{}
    foreach ($k in $b.Keys) { $n[$k] = $b[$k] }
    $n
}

function Zero-Block($b) {
    $b['BitsPerPixel'] = '0'
    $b['Width'] = '0'
    $b['Height'] = '0'
    $b['DisplayFlags'] = '0'
    $b['DisplayFrequency'] = '0'
    $b['DisplayOrientation'] = '0'
    $b['PositionX'] = '0'
    $b['PositionY'] = '0'
}

function Set-VirtualBlock($b, [int]$w, [int]$h, [int]$hz) {
    $b['BitsPerPixel'] = '32'
    $b['Width'] = "$w"
    $b['Height'] = "$h"
    $b['DisplayFlags'] = '0'
    $b['DisplayFrequency'] = "$hz"
    $b['DisplayOrientation'] = '0'
    $b['PositionX'] = '0'
    $b['PositionY'] = '0'
}

function Write-Cfg([string]$path, $blocks) {
    $out = @()
    $i = 0
    foreach ($block in $blocks) {
        $out += "[Monitor$i]"
        foreach ($key in $block.Keys) { $out += "$key=$($block[$key])" }
        $i++
    }
    Set-Content -Path $path -Value $out -Encoding ASCII
}

Step 'Step 7/8: Detect your screens and create the layouts'
Say 'First all connected screens are switched on (DisplaySwitch /extend). The picture may flicker for a moment.'
$topologyTouched = $true
Start-Process -FilePath $DisplaySwitchExe -ArgumentList '/extend' -Wait
Start-Sleep -Seconds 5

$masterPath = Join-Path $InstallDir 'master.cfg'
$all = Save-Snapshot $masterPath
$mons = @($all | Where-Object { $_.MonitorID })
if ($mons.Count -lt 2) {
    $vddMonitor = Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^DISPLAY\\MTT1337\\' -and $_.Status -eq 'OK' } |
        Select-Object -First 1
    $inactiveNames = @($all | Where-Object { -not $_.MonitorID -and $_.Name } | ForEach-Object { $_.Name })
    if ($vddMonitor -and $inactiveNames.Count -gt 0) {
        Say 'The virtual monitor exists but is inactive (common after Duplicate mode). Enabling it now...' 'Yellow'
        foreach ($name in $inactiveNames) { Run-Mmt '/enable', $name }
        Start-Sleep -Seconds 3
        Start-Process -FilePath $DisplaySwitchExe -ArgumentList '/extend' -Wait
        for ($attempt = 1; $attempt -le 5 -and $mons.Count -lt 2; $attempt++) {
            Start-Sleep -Seconds 3
            $all = Save-Snapshot $masterPath
            $mons = @($all | Where-Object { $_.MonitorID })
        }
    }
}
if ($mons.Count -lt 2) {
    $seen = @($all | ForEach-Object { "$($_.Name) ID='$($_.MonitorID)' $($_.Width)x$($_.Height)" }) -join '; '
    throw "Fewer than two usable screens were detected after enabling Extend. MultiMonitorTool reported: $seen"
}

Write-Host ''
Say 'Screens found (saved to master.cfg for now):'
$cand = @()
for ($i = 0; $i -lt $mons.Count; $i++) {
    $m = $mons[$i]
    $state = if ([int]$m.Width -gt 0) { 'ON ' } else { 'off' }
    Say ('  {0}) {1,-14} {2}  {3}x{4} @{5}Hz  pos {6},{7}' -f ($i + 1), $m.Name, $state, $m.Width, $m.Height, $m.DisplayFrequency, $m.PositionX, $m.PositionY)
    Say ('       ' + $m.MonitorID) 'DarkGray'
    if ($m.MonitorID -match 'MTT1337') { $cand += $i }
}

$virtIdx = -1
if ($cand.Count -eq 1) {
    $c = $mons[$cand[0]]
    Write-Host ''
    Say ('Looks like the virtual screen: {0}  ({1})' -f $c.Name, $c.MonitorID) 'Green'
    if (Ask-YesNo 'Is this the virtual screen?') { $virtIdx = $cand[0] }
}
while ($virtIdx -lt 0) {
    $a = (Read-Host ('Enter the number of the VIRTUAL screen (1-{0})' -f $mons.Count)).Trim()
    $n = 0
    if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $mons.Count) { $virtIdx = $n - 1 }
    else { Say 'Not a valid number.' 'Yellow' }
}

$virtualMon = $mons[$virtIdx]
$physIdx = @()
for ($i = 0; $i -lt $mons.Count; $i++) {
    if ($i -eq $virtIdx) { continue }
    if ([int]$mons[$i].Width -gt 0) { $physIdx += $i }
    else { Say ('Note: {0} is not active even after /extend, so it is treated as not connected and left out.' -f $mons[$i].Name) 'Yellow' }
}
if ($physIdx.Count -eq 0) { throw 'No active physical screen found besides the virtual one.' }

Write-Host ''
Say ('Virtual:  {0}' -f $virtualMon.Name) 'Green'
foreach ($i in $physIdx) { Say ('Physical: {0}  {1}x{2} @{3}Hz  pos {4},{5}' -f $mons[$i].Name, $mons[$i].Width, $mons[$i].Height, $mons[$i].DisplayFrequency, $mons[$i].PositionX, $mons[$i].PositionY) 'Green' }
if (-not (Ask-YesNo 'Is this correct?')) { throw 'Cancelled. Run the installer again and pick the right virtual screen.' }

$script:VirtualId = $virtualMon.MonitorID
$script:PhysicalIds = @($physIdx | ForEach-Object { $mons[$_].MonitorID })

$physBlocks = @()
$virtBlocks = @()
for ($i = 0; $i -lt $mons.Count; $i++) {
    $m = $mons[$i]
    if ($i -eq $virtIdx) {
        $p = Copy-Block $m; Zero-Block $p
        $v = Copy-Block $m; Set-VirtualBlock $v $width $height $hz
    }
    elseif ($physIdx -contains $i) {
        $p = Copy-Block $m
        $v = Copy-Block $m; Zero-Block $v
    }
    else { continue }
    $physBlocks += , $p
    $virtBlocks += , $v
}
$physCfg = Join-Path $InstallDir 'physical.cfg'
$tplCfg  = Join-Path $InstallDir 'virtual.template.cfg'
$virtCfg = Join-Path $InstallDir 'virtual.cfg'
foreach ($f in @($physCfg, $tplCfg, $virtCfg)) { if (Test-Path $f) { Copy-Item -Path $f -Destination "$f.bak-$Stamp" -Force } }
Write-Cfg $physCfg $physBlocks
Write-Cfg $tplCfg $virtBlocks
Write-Cfg $virtCfg $virtBlocks
Say 'Created physical.cfg (your normal layout, virtual off) and virtual.template.cfg (only the virtual screen on).' 'Green'