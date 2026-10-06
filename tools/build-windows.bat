@echo off
rem Double-click to build all three MSU-1 bitstreams with Quartus, package the zip, then install it.
rem Arguments are passed through, e.g.  build-windows.bat -Variants ntsc   or   build-windows.bat -PackageOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" -Install %*
echo.
pause
