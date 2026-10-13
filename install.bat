@echo off
rem Launcher for the Sunshine display switch installer.
rem Keep this file next to install-sunshine-display-switch.ps1 and double-click it.
rem The installer asks Windows for administrator rights by itself.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-sunshine-display-switch.ps1"
