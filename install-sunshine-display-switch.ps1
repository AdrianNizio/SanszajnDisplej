<#
  Sunshine virtual display switcher - master installer

  What it does (asks before each install):
    1. Finds or downloads NirSoft MultiMonitorTool
    2. Asks how the virtual screen should look (resolution, HDR, refresh rate)
    3. Installs Virtual Display Driver (VDD), including its root device (skips if present)
    4. Writes C:\VirtualDisplayDriver\vdd_settings.xml and restarts the driver
    5. Installs Sunshine via winget (skips if present)
    6. Creates C:\Sunshine and writes display-switch.ps1, do.bat, undo.bat
    7. Detects your screens, lets you pick the virtual one, writes physical.cfg and virtual.template.cfg
    8. Runs a safe test with an automatic black-screen failsafe, and only keeps the setup if you confirm
    9. Finds where Sunshine is installed and adds do.bat/undo.bat to its sunshine.conf (global_prep_cmd),
       but only after you confirmed the test (existing entries are kept, a backup is made)

  Safe to run again: existing files are backed up (name.bak-TIMESTAMP) before being replaced.
  This file is pure ASCII on purpose (Windows PowerShell 5.1 misreads UTF-8 without BOM).
#>

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- self-elevate
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administrator rights are needed (driver install, display changes, Program Files).' -ForegroundColor Yellow
    Write-Host 'Asking Windows for elevation - please accept the prompt...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    exit
}

# ---------------------------------------------------------------- constants
$InstallDir  = 'C:\Sunshine'
$TempDir     = Join-Path $env:TEMP 'sunshine-display-installer'
$VddSettings = 'C:\VirtualDisplayDriver\vdd_settings.xml'
$MmtZipUrl   = 'https://www.nirsoft.net/utils/multimonitortool-x64.zip'
$MmtPageUrl  = 'https://www.nirsoft.net/utils/multi_monitor_tool.html'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$DisplaySwitchExe = Join-Path $env:windir 'System32\DisplaySwitch.exe'

# ---------------------------------------------------------------- embedded files
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

# Writes text as ASCII with CRLF line endings; backs up an existing, different file first.
function Write-FileSafe([string]$path, [string]$content) {
    $text = ($content -replace "`r?`n", "`r`n")
    if (Test-Path $path) {
        $old = [IO.File]::ReadAllText($path)
        if ($old -ne $text) { Copy-Item -Path $path -Destination "$path.bak-$Stamp" -Force }
    }
    [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII)
}

# ---------------------------------------------------------------- detection helpers
function Find-Mmt {
    foreach ($p in @((Join-Path $InstallDir 'MultiMonitorTool.exe'), (Join-Path $env:ProgramFiles 'Sunshine\MultiMonitorTool.exe'))) {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command 'MultiMonitorTool.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

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

function Get-VddDriverInf {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'ARM64' } else { 'x86' }
    $assetName = "VirtualDisplayDriver-$arch.Driver.Only.zip"
    $driverDir = Join-Path $TempDir "vdd-driver-$arch"
    $inf = Join-Path $driverDir 'VirtualDisplayDriver\MttVDD.inf'
    if (Test-Path $inf) { return $inf }

    Say "Downloading the official signed VDD driver package ($arch)..."
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/VirtualDrivers/Virtual-Display-Driver/releases/latest' -UseBasicParsing
    $asset = @($release.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
    if (-not $asset) { throw "The latest VDD release does not contain $assetName." }

    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    $zip = Join-Path $TempDir $assetName
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    if (Test-Path $driverDir) { Remove-Item -Path $driverDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $driverDir -Force
    if (-not (Test-Path $inf)) { throw "MttVDD.inf was not found after extracting $assetName." }
    return $inf
}

function Install-VddRootDevice([string]$infPath) {
    if (-not ('RootDeviceInstaller' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class RootDeviceInstaller
{
    private const uint DICD_GENERATE_ID = 0x00000001;
    private const uint SPDRP_HARDWAREID = 0x00000001;
    private const uint DIF_REMOVE = 0x00000005;
    private const uint DIF_REGISTERDEVICE = 0x00000019;
    private const uint INSTALLFLAG_FORCE = 0x00000001;
    private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetINFClassW(string infName, out Guid classGuid,
        StringBuilder className, uint classNameSize, out uint requiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiCreateDeviceInfoW(IntPtr deviceInfoSet, string deviceName,
        ref Guid classGuid, string deviceDescription, IntPtr hwndParent, uint creationFlags,
        ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr deviceInfoSet,
        ref SP_DEVINFO_DATA deviceInfoData, uint property, byte[] propertyBuffer,
        uint propertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(uint installFunction, IntPtr deviceInfoSet,
        ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent,
        string hardwareId, string fullInfPath, uint installFlags, out bool rebootRequired);

    private static void ThrowLastError(string operation)
    {
        throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
    }

    public static bool Install(string infPath, string hardwareId)
    {
        string fullInfPath = Path.GetFullPath(infPath);
        Guid classGuid;
        uint requiredSize;
        StringBuilder className = new StringBuilder(256);
        if (!SetupDiGetINFClassW(fullInfPath, out classGuid, className,
                (uint)className.Capacity, out requiredSize))
            ThrowLastError("Reading the device class from the INF");

        IntPtr deviceInfoSet = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (deviceInfoSet == InvalidHandleValue)
            ThrowLastError("Creating the device information set");

        SP_DEVINFO_DATA deviceInfoData = new SP_DEVINFO_DATA();
        deviceInfoData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
        bool registered = false;
        try
        {
            if (!SetupDiCreateDeviceInfoW(deviceInfoSet, className.ToString(), ref classGuid,
                    null, IntPtr.Zero, DICD_GENERATE_ID, ref deviceInfoData))
                ThrowLastError("Creating the root device");

            byte[] hardwareIds = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryPropertyW(deviceInfoSet, ref deviceInfoData,
                    SPDRP_HARDWAREID, hardwareIds, (uint)hardwareIds.Length))
                ThrowLastError("Setting the root device hardware ID");

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, deviceInfoSet, ref deviceInfoData))
                ThrowLastError("Registering the root device");
            registered = true;

            bool rebootRequired;
            if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, fullInfPath,
                    INSTALLFLAG_FORCE, out rebootRequired))
            {
                int error = Marshal.GetLastWin32Error();
                SetupDiCallClassInstaller(DIF_REMOVE, deviceInfoSet, ref deviceInfoData);
                registered = false;
                throw new Win32Exception(error, "Binding the VDD driver to the root device failed");
            }
            return rebootRequired;
        }
        finally
        {
            if (!registered)
                SetupDiCallClassInstaller(DIF_REMOVE, deviceInfoSet, ref deviceInfoData);
            SetupDiDestroyDeviceInfoList(deviceInfoSet);
        }
    }
}
'@
    }

    [RootDeviceInstaller]::Install($infPath, 'Root\MttVDD')
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

function Test-SunshineInstalled {
    if (Find-SunshineDir) { return $true }
    if (Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue) { return $true }
    return $false
}

# Adds do.bat/undo.bat to global_prep_cmd in <Sunshine>\config\sunshine.conf.
# Keeps every other line and any existing global_prep_cmd entries. Returns 'added', 'already' or 'created'.
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

# Asks, edits sunshine.conf and offers a service restart. Returns $true if Sunshine is now configured.
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

# ---------------------------------------------------------------- failsafe + test helpers
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

# ================================================================ MAIN
$script:mmt = $null
$script:VirtualId = $null
$script:PhysicalIds = @()
$exitCode = 0
$transcriptOn = $false
$testKept = $false
$topologyTouched = $false
$flagPath = Join-Path $InstallDir 'test-in-progress.flag'

try {
    Clear-Host
    Say 'Sunshine virtual display switcher - master installer' 'Cyan'
    Say 'It installs what is missing, sets up the scripts, and tests them with a black-screen failsafe.'
    Say 'Nothing is installed without asking first.'

    # ------------------------------------------------------------ step 1: MultiMonitorTool
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

    # ------------------------------------------------------------ step 2: virtual screen questions
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

    # ------------------------------------------------------------ step 3: install VDD
    Step 'Step 3/8: Install the Virtual Display Driver'
    if ((Test-VddInstalled)) {
        Say 'Already installed - skipping.' 'Green'
    }
    else {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Say 'Trying the normal winget installation first...'
            & winget install --id=VirtualDrivers.Virtual-Display-Driver -e --force --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { Say "winget reported exit code $LASTEXITCODE; checking for the device anyway." 'Yellow' }
            Start-Sleep -Seconds 3
            $vddFound = @(Get-Vdd)
        }
        else {
            Say 'winget is not available on this PC.' 'Yellow'
        }

        if ($vddFound.Count -gt 0) {
            Say 'Virtual Display Driver detected after the winget installation.' 'Green'
        }
        else {
            $vddInf = Get-VddDriverInf
            Say 'winget did not create the display device. Creating the root device automatically...' 'Yellow'
            try {
                $rebootRequired = Install-VddRootDevice $vddInf
            }
            catch {
                throw "Automatic VDD device installation failed: $($_.Exception.Message). Details: $env:windir\inf\setupapi.dev.log"
            }
            Start-Sleep -Seconds 3
            $vddFound = Get-Vdd
            if ($vddFound.Count -eq 0) { throw 'VDD installation completed, but the device is still missing under Display adapters.' }
            Say 'Virtual Display Driver device created and installed.' 'Green'
            if ($rebootRequired) { Say 'Windows reports that a reboot is required before the driver can start.' 'Yellow' }
        }
    }

    # ------------------------------------------------------------ step 4: apply settings
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

    # ------------------------------------------------------------ step 5: Sunshine
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

    # ------------------------------------------------------------ step 6: folder + files
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

    # ------------------------------------------------------------ step 7: screens
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

    # ------------------------------------------------------------ step 8: test
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

    # ------------------------------------------------------------ done
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
}
catch {
    $failureMessage = $_.Exception.Message
    Write-Host ''
    if ($topologyTouched) {
        try { Restore-PhysicalDisplays }
        catch { Say ('Automatic display recovery failed: ' + $_.Exception.Message) 'Red' }
    }
    Say ('Stopped: ' + $failureMessage) 'Red'
    $exitCode = 1
}
finally {
    if (Test-Path $flagPath) { Remove-Item -Path $flagPath -Force -ErrorAction SilentlyContinue }
    if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
}

Write-Host ''
[void](Read-Host 'Press Enter to close this window')
exit $exitCode
