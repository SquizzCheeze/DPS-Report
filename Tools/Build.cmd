@echo off
rem Builds "DPS Report Exporter.exe" (the tray app) from TrayApp.cs and
rem Exporter.cs, with the C# compiler that ships with Windows - nothing to
rem install. Run it again after either file changes. The .exe is not
rem committed (.gitignore) and not packaged (.pkgmeta ignores Tools).
setlocal
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo Couldn't find the .NET Framework 4 C# compiler.
    if not defined CI pause
    exit /b 1
)
set REFS=/r:System.Windows.Forms.dll /r:System.Drawing.dll
set OUT=DPS Report Exporter.exe

rem Close a running copy first: Windows won't let the file be replaced.
taskkill /im "%OUT%" >nul 2>&1

rem Pass 1 builds without an icon, only to draw icon.ico; pass 2 embeds it.
"%CSC%" /nologo /target:winexe /optimize %REFS% /out:"%OUT%" TrayApp.cs Exporter.cs || goto failed
if exist icon.ico del icon.ico
start "" /wait "%~dp0%OUT%" --write-icon icon.ico
if not exist icon.ico goto failed
"%CSC%" /nologo /target:winexe /optimize %REFS% /win32icon:icon.ico /out:"%OUT%" TrayApp.cs Exporter.cs || goto failed
echo Built "%OUT%".
exit /b 0

:failed
echo Build failed.
if not defined CI pause
exit /b 1
