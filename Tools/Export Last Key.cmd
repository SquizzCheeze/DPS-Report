@echo off
rem Exports your most recent completed Mythic+ key or raid boss pull from the
rem combat log to the clipboard. Then in game: DPS Graph (G on a meter, or
rem /dpsgraph) > Import > Ctrl+V.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DPSReportKeyExport.ps1"
echo.
pause
