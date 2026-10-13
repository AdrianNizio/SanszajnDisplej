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
        $vddFound = @(Get-Vdd)
        if ($vddFound.Count -eq 0) { throw 'VDD installation completed, but the device is still missing under Display adapters.' }
        Say 'Virtual Display Driver device created and installed.' 'Green'
        if ($rebootRequired) { Say 'Windows reports that a reboot is required before the driver can start.' 'Yellow' }
    }
}