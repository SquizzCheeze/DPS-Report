@echo off
rem Exports your most recent completed Mythic+ key from the combat log to the
rem clipboard. Then in game: DPS Graph (G on a meter, or /dpsgraph) > Import > Ctrl+V.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DPSReportKeyExport.ps1"
echo.
pause
