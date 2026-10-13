# Sunshine Virtual Display Switcher

Windows installer and display-switching scripts for using [Sunshine](https://github.com/LizardByte/Sunshine) with a virtual monitor. When a Moonlight session starts, the physical displays can be disabled and the virtual display made primary. When the session ends, the physical layout is restored.

The installer configures:

- [NirSoft MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html)
- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
- Sunshine command preparations
- Virtual and physical monitor layouts
- Automatic recovery and a guarded display-switching test

## Requirements

- Windows 10 or Windows 11
- Administrator access
- Internet access during installation
- A physical display connected during setup
- Sunshine and a Moonlight client
- Microsoft Visual C++ Redistributable if required by Virtual Display Driver

## Installation

1. Download or clone the complete repository.
2. Keep `install.bat` and the `installation scripts` folder together.
3. Double-click **`install.bat`**.
4. Accept the administrator prompt.
5. Follow the questions shown by the installer.

Do not launch individual PowerShell files directly. They share state and are run in order by the master script.

## Installer Steps

1. Find or download MultiMonitorTool.
2. Choose the virtual resolution, refresh rate, and HDR support.
3. Detect or install Virtual Display Driver.
4. Write the VDD settings and restart the driver.
5. Detect or install Sunshine.
6. Create the runtime files in `C:\Sunshine`.
7. Detect physical and virtual monitors and build both layouts.
8. Test switching to the virtual display and restoring the physical displays.

The VDD installation first tries WinGet. If the package is staged without creating its root device, the installer uses the Windows SetupAPI equivalent of the legacy hardware installation path.

## Generated Files

The runtime installation is stored in `C:\Sunshine`:

| File | Purpose |
| --- | --- |
| `display-switch.ps1` | Prepares, activates, and restores monitor layouts |
| `do.bat` | Runs when a Sunshine session starts |
| `undo.bat` | Runs when a Sunshine session ends |
| `physical.cfg` | Normal physical-monitor layout |
| `virtual.template.cfg` | Virtual-only layout template |
| `virtual.cfg` | Runtime virtual layout with refreshed display names |
| `MultiMonitorTool.exe` | Controls and snapshots monitor layouts |
| `display-switch.log` | Runtime switching log |
| `install.log` | Installer transcript |

Existing configuration files are backed up before replacement.

## Sunshine Configuration

After a successful test, the installer can add the following command preparation to `sunshine.conf`:

```json
[{"do":"C:\\Sunshine\\do.bat","elevated":true,"undo":"C:\\Sunshine\\undo.bat"}]
```

Sunshine's own **Display Device** option should remain disabled so it does not compete with these scripts.

## Safety

Display switching can temporarily make physical screens go black. The installer includes:

- Verification before disabling the virtual or physical display
- A background watchdog during the test
- Physical-display recovery after installer failures
- Stable monitor-ID matching instead of relying on changing `DISPLAY1` names
- Confirmation before retaining a tested layout

Before major GPU or chipset driver updates, uninstall Virtual Display Driver. Virtual display drivers can affect display priority while Windows re-enumerates hardware.

## Recovery

If the physical display does not return:

1. Run `C:\Sunshine\undo.bat` as administrator.
2. Press **Win+P** and select a physical-display mode.
3. Press **Win+Ctrl+Shift+B** to reset the graphics driver.
4. Connect another physical display if Windows has assigned the virtual monitor as the only active output.
5. Check `C:\Sunshine\display-switch.log` and `C:\Sunshine\install.log`.

The installer also attempts to restore a verified non-virtual monitor whenever a failure occurs after display topology has been changed.

## Repository Layout

```text
install.bat                         User-facing launcher
installation scripts/
  install-sunshine-display-switch.ps1  Master orchestrator
  Installer-Support.ps1                Shared helpers and constants
  Step-01-MultiMonitorTool.ps1
  Step-02-VirtualDisplaySettings.ps1
  Step-03-InstallVirtualDisplayDriver.ps1
  Step-04-ApplyVirtualDisplaySettings.ps1
  Step-05-InstallSunshine.ps1
  Step-06-CreateFiles.ps1
  Step-07-CreateLayouts.ps1
  Step-08-TestAndFinish.ps1
```

The master dot-sources every step in one elevated PowerShell process so settings and detected monitor IDs remain available throughout installation.

## Third-Party Software

MultiMonitorTool, Virtual Display Driver, Sunshine, and Moonlight are separate third-party projects. Refer to their repositories or websites for their respective licenses and support policies.