<#
DPSReportKeyExport.ps1 -- proof of concept (2026-10-21).

Reads your WoW combat log, finds the most recent COMPLETED Mythic+ key or RAID
BOSS PULL (kill or wipe) -- whichever finished last -- and copies a compact
text string to the clipboard. In game: DPS Graph > Import, then Ctrl+V. It
shows as a fight with real per-second damage and healing for every player --
the detail the game hides from addons while you play.

Reads the log only, opened shared, so it works while WoW is running and while
Archon (or anything else) reads the same log. Logs are streamed, so a raid
night's 600+ MB file takes a few seconds. Nothing is uploaded anywhere.

Usage (or run "Export Last Key.cmd" next to this file):
    powershell -ExecutionPolicy Bypass -File DPSReportKeyExport.ps1
    ... -Mode key | raid | boss       # only keys / only raid pulls / any boss pull
    ... -LogFolder "D:\Games\World of Warcraft\_retail_\Logs"   # if not the default
    ... -File WoWCombatLog-102026_172229.txt                     # a specific log

What is counted:
    Damage   every damage event by a group member or their pets (owners from
             SPELL_SUMMON and the advanced-log owner field), to targets that
             are not friendly, plus the part an enemy shield absorbed.
    Healing  heals minus overhealing, plus damage their shields absorbed.
Advanced Combat Logging must be on (it is already, if you use Archon).
#>
param(
    [string]$LogFolder = "",
    [string]$File = "",
    [ValidateSet("auto", "key", "raid", "boss")]
    [string]$Mode = "auto",   # auto = whichever finished last: a key or a raid boss pull
    [string]$OutFile = "",    # testing: write here instead of the clipboard
    [switch]$Watch            # keep running: copy each boss pull / key the moment it ends
)

$ErrorActionPreference = "Stop"

if (-not $LogFolder) {
    # This script lives in Interface\AddOns\DPSReport\Tools; Logs is four levels up.
    $LogFolder = Join-Path $PSScriptRoot "..\..\..\..\Logs"
}
$LogFolder = [System.IO.Path]::GetFullPath($LogFolder)

# The exporter itself is Exporter.cs, shared with the tray app (Build.cmd).
Add-Type -Path (Join-Path $PSScriptRoot "Exporter.cs")

function Copy-Export([string]$text) {
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $text) } else { Set-Clipboard -Value $text }
}

function Describe-Export([string]$text) {
    $head = ($text.Split("~")[1]).Split("^")
    if ($head[6] -eq "raid") {
        $what = "{0} ({1}) {2}" -f $head[1], $head[2], $(if ($head[4] -eq "1") { "Kill" } else { "Wipe" })
    } else {
        $what = "{0} +{1}" -f $head[1], $head[2]
    }
    return "{0}, {1}:{2:00}, {3} KB" -f $what, [math]::Floor([int]$head[3] / 60), ([int]$head[3] % 60), [math]::Round($text.Length / 1KB)
}

# Watch mode: follow the newest combat log as WoW writes it. When a boss pull
# ends (ENCOUNTER_END, outside a key) or a key ends (CHALLENGE_MODE_END), that
# pull or key is exported and copied straight away, with a chime -- in game it
# is just Import > Ctrl+V. Only complete lines are read, so a line WoW is still
# writing waits for the next poll. The same pull is never copied twice: the
# reset CHALLENGE_MODE_END the game logs before a key starts would otherwise
# re-copy the previous key.
if ($Watch) {
    Write-Host "Watching $LogFolder for boss pulls and finished keys. Leave this window open; Ctrl+C stops it." -ForegroundColor Cyan
    $current = $null; $pos = 0; $carry = ""; $inKey = $false; $lastId = ""
    $first = $true
    while ($true) {
        $newest = Get-ChildItem -Path $LogFolder -Filter "WoWCombatLog*.txt" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest -and (-not $current -or $newest.FullName -ne $current)) {
            $current = $newest.FullName
            # The log open at start: only what happens from now on. A log
            # created later (logging restarted): all of it.
            $pos = if ($first) { $newest.Length } else { 0 }
            $carry = ""; $inKey = $false
            Write-Host "Following $($newest.Name)" -ForegroundColor DarkGray
        }
        $first = $false
        if ($current) {
            $trigger = $null
            try {
                $fs = New-Object System.IO.FileStream($current, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try {
                    if ($fs.Length -lt $pos) { $pos = 0; $carry = "" }      # the file was replaced
                    if ($fs.Length -gt $pos) {
                        $fs.Position = $pos
                        $buf = New-Object byte[] ($fs.Length - $pos)
                        $read = $fs.Read($buf, 0, $buf.Length)
                        $pos += $read
                        $text = $carry + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                        $cut = $text.LastIndexOf("`n")
                        if ($cut -lt 0) { $carry = $text; $text = "" } else { $carry = $text.Substring($cut + 1); $text = $text.Substring(0, $cut) }
                        foreach ($line in $text.Split("`n")) {
                            if ($line.Contains("  CHALLENGE_MODE_START,")) { $inKey = $true }
                            elseif ($line.Contains("  CHALLENGE_MODE_END,")) { $inKey = $false; $trigger = "key" }
                            elseif ($line.Contains("  ENCOUNTER_END,") -and -not $inKey) { $trigger = "boss" }
                        }
                    }
                } finally { $fs.Dispose() }
            } catch {
                Write-Host "  Couldn't read the log: $($_.Exception.Message)" -ForegroundColor DarkGray
            }
            if ($trigger) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $out = [DRKeyExport]::Export($current, $trigger)
                if (-not $out.StartsWith("ERROR:")) {
                    $id = $out.Split("~")[1]
                    if ($id -ne $lastId) {
                        $lastId = $id
                        Copy-Export $out
                        Write-Host ("[{0:HH:mm}] Copied: {1}, in {2:0.0}s -- in game: Import, Ctrl+V" -f (Get-Date), (Describe-Export $out), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
                        [System.Media.SystemSounds]::Asterisk.Play()
                    }
                }
            }
        }
        Start-Sleep -Seconds 2
    }
}

if ($File) {
    $candidates = @(Get-Item (Join-Path $LogFolder $File))
} else {
    $candidates = @(Get-ChildItem -Path $LogFolder -Filter "WoWCombatLog*.txt" | Sort-Object LastWriteTime -Descending)
}
if ($candidates.Count -eq 0) { Write-Host "No combat logs found in $LogFolder" -ForegroundColor Red; exit 1 }

foreach ($log in $candidates) {
    Write-Host "Reading $($log.Name) ($([math]::Round($log.Length / 1MB, 1)) MB)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = [DRKeyExport]::Export($log.FullName, $Mode)
    if ($out.StartsWith("ERROR:")) { Write-Host "  $out" -ForegroundColor DarkGray; continue }
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $out) } else { Set-Clipboard -Value $out }
    $head = ($out.Split("~")[1]).Split("^")
    if ($head[6] -eq "raid") {
        $what = "{0} ({1}) {2}" -f $head[1], $head[2], $(if ($head[4] -eq "1") { "Kill" } else { "Wipe" })
    } else {
        $what = "{0} +{1}" -f $head[1], $head[2]
    }
    Write-Host ("Copied: {0}, {1}:{2:00}, {3} KB, in {4:0.0}s" -f $what, [math]::Floor([int]$head[3] / 60), ([int]$head[3] % 60), [math]::Round($out.Length / 1KB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host "In game: open the DPS Graph (G on a meter, or /dpsgraph), click Import, press Ctrl+V."
    exit 0
}
Write-Host "Nothing to export: no completed key or raid boss pull in the logs." -ForegroundColor Yellow
exit 1
