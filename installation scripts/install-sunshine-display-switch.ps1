<#
  Sunshine virtual display switcher - master installer

    Loads the shared installer support and runs Steps 1-8 in one elevated
    PowerShell process. This file is launched by ..\install.bat.
#>

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administrator rights are needed (driver install, display changes, Program Files).' -ForegroundColor Yellow
    Write-Host 'Asking Windows for elevation - please accept the prompt...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    exit
}

$stepDirectory = $PSScriptRoot
$supportPath = Join-Path $stepDirectory 'Installer-Support.ps1'
if (-not (Test-Path $supportPath)) { throw "Installer support file is missing: $supportPath" }

. $supportPath

$script:mmt = $null
$script:VirtualId = $null
$script:PhysicalIds = @()
$exitCode = 0
$transcriptOn = $false
$testKept = $false
$topologyTouched = $false
$flagPath = Join-Path $InstallDir 'test-in-progress.flag'

$stepFiles = @(
    'Step-01-MultiMonitorTool.ps1'
    'Step-02-VirtualDisplaySettings.ps1'
    'Step-03-InstallVirtualDisplayDriver.ps1'
    'Step-04-ApplyVirtualDisplaySettings.ps1'
    'Step-05-InstallSunshine.ps1'
    'Step-06-CreateFiles.ps1'
    'Step-07-CreateLayouts.ps1'
    'Step-08-TestAndFinish.ps1'
)

try {
    Clear-Host
    Say 'Sunshine virtual display switcher - master installer' 'Cyan'
    Say 'It installs what is missing, sets up the scripts, and tests them with a black-screen failsafe.'
    Say 'Nothing is installed without asking first.'

    foreach ($stepFile in $stepFiles) {
        $stepPath = Join-Path $stepDirectory $stepFile
        if (-not (Test-Path $stepPath)) { throw "Installer step is missing: $stepPath" }
        . $stepPath
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