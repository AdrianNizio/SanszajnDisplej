$VddTemplate = @'
<?xml version='1.0' encoding='utf-8'?>
<vdd_settings>
    <monitors>
        <count>1</count>
    </monitors>
    <gpu>
        <friendlyname></friendlyname>
    </gpu>
    <resolutions>
        <resolution>
            <width>3840</width>
            <height>2160</height>
            <refresh_rate>60</refresh_rate>
        </resolution>
    </resolutions>
    <options>
        <CustomEdid>false</CustomEdid>
        <HardwareCursor>true</HardwareCursor>
        <HDRPlus>true</HDRPlus>
        <logging>false</logging>
        <debuglogging>false</debuglogging>
    </options>
</vdd_settings>
'@

function Restart-Vdd {
    $devs = @(Get-Vdd)
    if ($devs.Count -eq 0) { return $false }
    foreach ($d in $devs) {
        Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
    }
    Start-Sleep -Seconds 5
    return $true
}

function Write-VddSettings([int]$w, [int]$h, [int]$hz, [bool]$hdr) {
    $dir = Split-Path -Parent $VddSettings
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $xml = $null
    if (Test-Path $VddSettings) {
        Copy-Item -Path $VddSettings -Destination "$VddSettings.bak-$Stamp" -Force
        try { $xml = [xml](Get-Content -Path $VddSettings -Raw) } catch { $xml = $null }
    }
    if ($null -eq $xml) { $xml = [xml]$VddTemplate }
    $root = $xml.DocumentElement

    # exactly one virtual monitor (the switcher handles one virtual screen)
    $mon = $root.SelectSingleNode('monitors')
    if ($null -eq $mon) { $mon = $xml.CreateElement('monitors'); [void]$root.AppendChild($mon) }
    $cnt = $mon.SelectSingleNode('count')
    if ($null -eq $cnt) { $cnt = $xml.CreateElement('count'); [void]$mon.AppendChild($cnt) }
    $cnt.InnerText = '1'

    # one resolution entry with the chosen refresh rate
    $resNode = $root.SelectSingleNode('resolutions')
    if ($null -eq $resNode) { $resNode = $xml.CreateElement('resolutions'); [void]$root.AppendChild($resNode) }
    $resNode.RemoveAll()
    $r = $xml.CreateElement('resolution')
    foreach ($pair in @(@('width', "$w"), @('height', "$h"), @('refresh_rate', "$hz"))) {
        $e = $xml.CreateElement($pair[0])
        $e.InnerText = $pair[1]
        [void]$r.AppendChild($e)
    }
    [void]$resNode.AppendChild($r)

    # HDR
    $opt = $root.SelectSingleNode('options')
    if ($null -eq $opt) { $opt = $xml.CreateElement('options'); [void]$root.AppendChild($opt) }
    $hn = $opt.SelectSingleNode('HDRPlus')
    if ($null -eq $hn) { $hn = $xml.CreateElement('HDRPlus'); [void]$opt.AppendChild($hn) }
    $hn.InnerText = $hdr.ToString().ToLower()

    # save as UTF-8 without BOM
    $ws = New-Object System.Xml.XmlWriterSettings
    $ws.Indent = $true
    $ws.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($VddSettings, $ws)
    try { $xml.Save($writer) } finally { $writer.Close() }
}

Step 'Step 4/8: Apply the virtual screen settings'
Write-VddSettings $width $height $hz $hdr
Say "Wrote $VddSettings (a backup of the old file was kept if there was one)." 'Green'
try {
    if (Restart-Vdd) { Say 'Driver restarted so the settings take effect.' 'Green' }
    else { Say 'Driver device not found, so no restart was possible. The settings apply once it is installed.' 'Yellow' }
}
catch {
    Say ('Could not restart the driver automatically: ' + $_.Exception.Message) 'Yellow'
    Say 'Please restart the PC (or disable and enable "Virtual Display Driver" in Device Manager) and run this installer again.' 'Yellow'
    if (-not (Ask-YesNo 'Continue without restarting?' $false)) { throw 'Stopped so you can restart the driver.' }
}