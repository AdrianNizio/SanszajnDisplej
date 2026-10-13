@echo off
rem Launcher for the Sunshine display switch installer.
rem Double-click this file; implementation scripts are kept in the subfolder.
rem The installer asks Windows for administrator rights by itself.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installation scripts\install-sunshine-display-switch.ps1"
