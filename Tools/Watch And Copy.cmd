@echo off
rem Leave this window open while you play: every boss pull and every finished
rem Mythic+ key is copied to the clipboard the moment it ends (with a chime).
rem Then in game: DPS Graph (G on a meter, or /dpsgraph) > Import > Ctrl+V.
rem Close the window (or Ctrl+C) to stop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DPSReportKeyExport.ps1" -Watch
pause
