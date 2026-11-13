@echo off
rem Windows: installs or updates the whole stack. Options: see install.ps1 / install.sh --help.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set CODE=%ERRORLEVEL%
if "%~1"=="" pause
exit /b %CODE%
