@echo off
rem Runs build.ps1 from anywhere: cmd, Explorer, the Run box or PowerShell.
rem Started directly, a .ps1 opens in Notepad outside PowerShell, and
rem PowerShell's default execution policy may refuse to run it.
rem
rem   build.cmd run ^| test ^| app ^| check ^| installer ^| install ^| release ^| clean
setlocal
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
%PS% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %errorlevel%
