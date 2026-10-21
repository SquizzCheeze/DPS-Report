<#
DPSReportKeyExport.ps1 -- proof of concept (2026-10-21).

Reads your WoW combat log, finds the most recent COMPLETED Mythic+ key, and
copies a compact text string to the clipboard. In game: DPS Graph > Import,
then Ctrl+V. The key shows as a fight with real per-second damage and healing
for every player -- the detail the game hides from addons while you play.

Reads the log only; Archon (or anything else using the same log) is not
affected. Nothing is uploaded anywhere.

Usage (or run "Export Last Key.cmd" next to this file):
    powershell -ExecutionPolicy Bypass -File DPSReportKeyExport.ps1
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
    [string]$OutFile = ""     # testing: write here instead of the clipboard
)

$ErrorActionPreference = "Stop"

if (-not $LogFolder) {
    # This script lives in Interface\AddOns\DPSReport\Tools; Logs is four levels up.
    $LogFolder = Join-Path $PSScriptRoot "..\..\..\..\Logs"
}
$LogFolder = [System.IO.Path]::GetFullPath($LogFolder)

Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

public static class DRKeyExport
{
    // Split one log line's fields (after the timestamp) on commas, keeping
    // quoted names intact even if they contain a comma.
    static List<string> Split(string s, int start)
    {
        var f = new List<string>(48);
        var sb = new StringBuilder();
        bool q = false;
        for (int i = start; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '"') { q = !q; continue; }
            if (c == ',' && !q) { f.Add(sb.ToString()); sb.Length = 0; continue; }
            sb.Append(c);
        }
        f.Add(sb.ToString());
        return f;
    }

    static bool TryTime(string line, out DateTime t, out int bodyStart)
    {
        t = DateTime.MinValue;
        bodyStart = line.IndexOf("  ", StringComparison.Ordinal);
        if (bodyStart < 0) return false;
        string ts = line.Substring(0, bodyStart);
        bodyStart += 2;
        string[] formats = { "M/d/yyyy HH:mm:ss.fffff", "M/d/yyyy H:mm:ss.fffff", "M/d/yyyy HH:mm:ss.ffff", "M/d/yyyy HH:mm:ss.fff" };
        return DateTime.TryParseExact(ts, formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out t);
    }

    static long Num(string s)
    {
        long v;
        if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) return v;
        return 0;
    }

    static int Flags(string s)
    {
        int v;
        if (s.StartsWith("0x")) s = s.Substring(2);
        if (int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) return v;
        return 0;
    }

    static string Clean(string s)
    {
        // Our record separators, and the realm's region suffix.
        s = s.Replace("^", "").Replace("~", "");
        if (s.EndsWith("-US") || s.EndsWith("-EU") || s.EndsWith("-KR") || s.EndsWith("-TW") || s.EndsWith("-CN"))
            s = s.Substring(0, s.Length - 3);
        return s;
    }

    class Player { public int Index; public string Guid; public string Name = "?"; public string Spec = "0"; public long[] Dmg; public long[] Heal; }

    // Returns the export string, or a line starting with "ERROR:".
    public static string Export(string path)
    {
        string[] lines = File.ReadAllLines(path);

        // The last CHALLENGE_MODE_START that has a CHALLENGE_MODE_END after it.
        int start = -1, end = -1;
        for (int i = lines.Length - 1; i >= 0 && start < 0; i--)
        {
            string l = lines[i];
            if (end < 0 && l.Contains("  CHALLENGE_MODE_END,")) { end = i; continue; }
            if (end >= 0 && l.Contains("  CHALLENGE_MODE_START,")) start = i;
        }
        if (start < 0) return "ERROR: no completed key in " + Path.GetFileName(path);

        DateTime t0, t1; int b;
        TryTime(lines[start], out t0, out b);
        var startF = Split(lines[start], b);
        TryTime(lines[end], out t1, out b);
        var endF = Split(lines[end], b);
        string dungeon = startF.Count > 1 ? startF[1] : "?";
        string level = startF.Count > 4 ? startF[4] : "?";
        string success = endF.Count > 2 ? endF[2] : "0";
        int seconds = (int)Math.Ceiling((t1 - t0).TotalSeconds) + 1;

        var players = new Dictionary<string, Player>();
        var order = new List<Player>();
        var petOwner = new Dictionary<string, string>();
        var bosses = new List<string>();
        var bossStart = new Dictionary<string, double>();

        for (int i = start; i <= end; i++)
        {
            string l = lines[i];
            DateTime t;
            if (!TryTime(l, out t, out b)) continue;
            int comma = l.IndexOf(',', b);
            if (comma < 0) continue;
            string ev = l.Substring(b, comma - b);
            double at = (t - t0).TotalSeconds;

            if (ev == "COMBATANT_INFO")
            {
                var f = Split(l, b);
                if (f.Count > 25 && f[1].StartsWith("Player-") && !players.ContainsKey(f[1]))
                {
                    var p = new Player { Index = order.Count + 1, Guid = f[1], Spec = f[25], Dmg = new long[seconds], Heal = new long[seconds] };
                    players[p.Guid] = p;
                    order.Add(p);
                }
                continue;
            }
            if (ev == "ENCOUNTER_START" || ev == "ENCOUNTER_END")
            {
                var f = Split(l, b);
                if (f.Count < 3) continue;
                if (ev == "ENCOUNTER_START") bossStart[f[1]] = at;
                else if (bossStart.ContainsKey(f[1]))
                {
                    string kill = f.Count > 5 ? f[5] : "0";
                    bosses.Add("B^" + Clean(f[2]) + "^" + ((int)bossStart[f[1]]) + "^" + ((int)at) + "^" + kill);
                    bossStart.Remove(f[1]);
                }
                continue;
            }

            bool spellDmg = ev == "SPELL_DAMAGE" || ev == "SPELL_PERIODIC_DAMAGE" || ev == "RANGE_DAMAGE" || ev == "DAMAGE_SHIELD";
            bool swing = ev == "SWING_DAMAGE";
            bool heal = ev == "SPELL_HEAL" || ev == "SPELL_PERIODIC_HEAL";
            bool absorbed = ev == "SPELL_ABSORBED";
            bool summon = ev == "SPELL_SUMMON";
            if (!(spellDmg || swing || heal || absorbed || summon)) continue;

            var fl = Split(l, b);
            if (fl.Count < 9) continue;
            int sec = (int)at;
            if (sec < 0 || sec >= seconds) continue;

            if (summon)
            {
                if (players.ContainsKey(fl[1])) petOwner[fl[5]] = fl[1];
                continue;
            }

            // Advanced-log owner field: whoever the info block describes.
            int info = swing ? 9 : 12;
            if (fl.Count > info + 1 && fl[info + 1] != "0000000000000000" && players.ContainsKey(fl[info + 1]))
                petOwner[fl[info]] = fl[info + 1];

            if (absorbed)
            {
                // ... absorberGUID, name, flags, raidFlags, spellId, name, school, amount, base, critical
                int n = fl.Count;
                if (n < 12) continue;
                string absorber = fl[n - 10];
                Player ap = Resolve(absorber, players, petOwner);
                if (ap != null) ap.Heal[sec] += Num(fl[n - 3]);
                continue;
            }

            Player src = Resolve(fl[1], players, petOwner);
            if (src == null) continue;
            if (src.Guid == fl[1] && src.Name == "?") src.Name = Clean(fl[2]);

            if (heal)
            {
                if (fl.Count > 33) src.Heal[sec] += Math.Max(0, Num(fl[31]) - Num(fl[33]));
                continue;
            }

            int destFlags = Flags(fl[7]);
            if ((destFlags & 0x10) != 0) continue;              // friendly target
            int a = swing ? 28 : 31;
            if (fl.Count > a + 6) src.Dmg[sec] += Num(fl[a]) + Num(fl[a + 6]);
        }

        var sb = new StringBuilder();
        sb.Append("DRK1~K^").Append(Clean(dungeon)).Append("^").Append(level).Append("^").Append(seconds)
          .Append("^").Append(success).Append("^").Append(t0.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
        foreach (var p in order)
            sb.Append("~P^").Append(p.Index).Append("^").Append(p.Name).Append("^").Append(p.Spec);
        foreach (var x in bosses) sb.Append("~").Append(x);
        foreach (var p in order)
        {
            sb.Append("~D^").Append(p.Index).Append("^").Append(Join(p.Dmg));
            sb.Append("~H^").Append(p.Index).Append("^").Append(Join(p.Heal));
        }
        return sb.ToString();
    }

    static Player Resolve(string guid, Dictionary<string, Player> players, Dictionary<string, string> petOwner)
    {
        Player p;
        if (players.TryGetValue(guid, out p)) return p;
        string owner;
        if (petOwner.TryGetValue(guid, out owner) && players.TryGetValue(owner, out p)) return p;
        return null;
    }

    // Per-second values, empty for zero, so quiet seconds cost one comma.
    static string Join(long[] v)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < v.Length; i++)
        {
            if (i > 0) sb.Append(',');
            if (v[i] != 0) sb.Append(v[i].ToString(CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }
}
"@

if ($File) {
    $candidates = @(Get-Item (Join-Path $LogFolder $File))
} else {
    $candidates = @(Get-ChildItem -Path $LogFolder -Filter "WoWCombatLog*.txt" | Sort-Object LastWriteTime -Descending)
}
if ($candidates.Count -eq 0) { Write-Host "No combat logs found in $LogFolder" -ForegroundColor Red; exit 1 }

foreach ($log in $candidates) {
    Write-Host "Reading $($log.Name) ($([math]::Round($log.Length / 1MB, 1)) MB)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = [DRKeyExport]::Export($log.FullName)
    if ($out.StartsWith("ERROR:")) { Write-Host "  $out" -ForegroundColor DarkGray; continue }
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $out) } else { Set-Clipboard -Value $out }
    $head = ($out.Split("~")[1]).Split("^")
    Write-Host ("Copied: {0} +{1}, {2}:{3:00}, {4} KB, in {5:0.0}s" -f $head[1], $head[2], [math]::Floor([int]$head[3] / 60), ([int]$head[3] % 60), [math]::Round($out.Length / 1KB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host "In game: open the DPS Graph (G on a meter, or /dpsgraph), click Import, press Ctrl+V."
    exit 0
}
Write-Host "No completed Mythic+ key found in the logs." -ForegroundColor Yellow
exit 1
