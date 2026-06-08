@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0run_desktop_pet_wpf.ps1" -Scale 0.6 -Center -ShowTaskbar
