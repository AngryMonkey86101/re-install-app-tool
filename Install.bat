@echo off
rem Starts the batch installer GUI (asks for administrator rights).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Installer.ps1"
