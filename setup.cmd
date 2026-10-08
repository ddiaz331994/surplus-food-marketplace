@echo off
rem Windows one-step setup. Double-click this file, or run "setup.cmd" from the repo root.
rem Pass -ProjectOnly to skip installing tools.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1" %*
echo.
pause
