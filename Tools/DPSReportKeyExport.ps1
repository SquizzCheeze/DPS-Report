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

    class Player
    {
        public int Index; public string Guid; public string Name = "?"; public string Spec = "0";
        public long[] Dmg; public long[] Heal;
        // Per ability (spell ID -> per-second amounts), and cast times in tenths of a second.
        public Dictionary<string, long[]> AbilDmg = new Dictionary<string, long[]>();
        public Dictionary<string, long[]> AbilHeal = new Dictionary<string, long[]>();
        public Dictionary<string, List<int>> Casts = new Dictionary<string, List<int>>();
    }

    static void AddAbil(Dictionary<string, long[]> d, string id, int sec, long v, int seconds)
    {
        if (v == 0) return;
        long[] s;
        if (!d.TryGetValue(id, out s)) { s = new long[seconds]; d[id] = s; }
        s[sec] += v;
    }

    const int TOP_DAMAGE = 8, TOP_HEALING = 6, TOP_CASTS = 16;

    // The `count` biggest series by total, biggest first.
    static List<KeyValuePair<string, long[]>> Top(Dictionary<string, long[]> d, int count)
    {
        var list = new List<KeyValuePair<string, long[]>>(d);
        list.Sort((x, y) => Sum(y.Value).CompareTo(Sum(x.Value)));
        if (list.Count > count) list.RemoveRange(count, list.Count - count);
        return list;
    }

    static long Sum(long[] v) { long s = 0; foreach (var x in v) s += x; return s; }

    // An ability series for the chart: summed into `step`-second blocks and
    // sent in THOUSANDS. The graph draws a few hundred columns at most, so
    // per-second, exact per-ability values only made the paste huge (a 20-man
    // 9-minute pull came to 452 KB). Totals (D/H) stay exact and per second.
    static long[] Coarse(long[] v, int step)
    {
        var o = new long[(v.Length + step - 1) / step];
        for (int i = 0; i < v.Length; i++) o[i / step] += v[i];
        for (int i = 0; i < o.Length; i++) o[i] = (o[i] + 500) / 1000;
        return o;
    }

    // Like Join, but a run of 2+ empty values becomes "_n" -- an ability is
    // idle most of a fight, so this keeps the export small.
    static string Packed(long[] v)
    {
        var sb = new StringBuilder();
        int i = 0;
        bool first = true;
        while (i < v.Length)
        {
            if (!first) sb.Append(',');
            first = false;
            if (v[i] == 0)
            {
                int run = 0;
                while (i < v.Length && v[i] == 0) { run++; i++; }
                if (run >= 2) sb.Append('_').Append(run);
                continue;
            }
            sb.Append(v[i].ToString(CultureInfo.InvariantCulture));
            i++;
        }
        return sb.ToString();
    }

    // Raid difficulty IDs, named. Anything not listed is not a raid (8 is a
    // Mythic+ key, 1/2/23 are dungeons).
    static string RaidDifficulty(string id)
    {
        switch (id)
        {
            case "14": return "Normal";
            case "15": return "Heroic";
            case "16": return "Mythic";
            case "17": return "LFR";
            case "3": return "10 Player";
            case "4": return "25 Player";
            case "5": return "10 Heroic";
            case "6": return "25 Heroic";
            case "7": return "LFR";
            case "9": return "40 Player";
            case "33": return "Timewalking";
        }
        return null;
    }

    // The log line by line, opened SHARED: WoW keeps writing the current log
    // while you play (and Archon reads it too), so an exclusive open fails.
    static IEnumerable<string> ReadLines(string path)
    {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var sr = new StreamReader(fs, Encoding.UTF8))
        {
            string l;
            while ((l = sr.ReadLine()) != null) yield return l;
        }
    }

    static bool Has(string line, string ev)
    {
        return line.IndexOf("  " + ev + ",", StringComparison.Ordinal) >= 0;
    }

    // mode: "auto" (whichever finished last: a completed key or a raid boss
    // pull), "key", "raid", or "boss" (the last boss pull of any kind).
    // Returns the export string, or a line starting with "ERROR:".
    public static string Export(string path, string mode)
    {
        // Two streamed passes rather than loading the file: a raid night's log
        // runs to hundreds of MB.
        //
        // Pass 1: the last completed key, and the last qualifying boss pull.
        // A CHALLENGE_MODE_END with no open START is the reset the game logs
        // just before a key begins, and is ignored.
        int keyStart = -1, keyEnd = -1, openKey = -1;
        int pullStart = -1, pullEnd = -1, openPull = -1;
        string keyStartLine = null, keyEndLine = null, openKeyLine = null;
        string pullStartLine = null, pullEndLine = null, openPullLine = null;
        string pullDifficulty = null;
        int i = -1;
        foreach (string l in ReadLines(path))
        {
            i++;
            if (Has(l, "CHALLENGE_MODE_START")) { openKey = i; openKeyLine = l; continue; }
            if (Has(l, "CHALLENGE_MODE_END"))
            {
                if (openKey >= 0)
                {
                    keyStart = openKey; keyEnd = i;
                    keyStartLine = openKeyLine; keyEndLine = l;
                }
                openKey = -1;
                continue;
            }
            if (Has(l, "ENCOUNTER_START")) { openPull = i; openPullLine = l; continue; }
            if (Has(l, "ENCOUNTER_END") && openPull >= 0)
            {
                DateTime ts; int bs;
                TryTime(openPullLine, out ts, out bs);
                var ef = Split(openPullLine, bs);
                string diff = ef.Count > 3 ? ef[3] : "";
                bool raid = RaidDifficulty(diff) != null;
                if (mode == "boss" || raid)
                {
                    pullStart = openPull; pullEnd = i;
                    pullStartLine = openPullLine; pullEndLine = l;
                    pullDifficulty = diff;
                }
                openPull = -1;
            }
        }

        bool useKey;
        if (mode == "key") useKey = true;
        else if (mode == "raid" || mode == "boss") useKey = false;
        else useKey = keyEnd > pullEnd;
        int start = useKey ? keyStart : pullStart;
        int end = useKey ? keyEnd : pullEnd;
        if (start < 0)
        {
            string what = mode == "key" ? "completed key" : mode == "raid" ? "raid boss pull"
                : mode == "boss" ? "boss pull" : "completed key or raid boss pull";
            return "ERROR: no " + what + " in " + Path.GetFileName(path);
        }
        string startLine = useKey ? keyStartLine : pullStartLine;
        string endLine = useKey ? keyEndLine : pullEndLine;

        DateTime t0, t1; int b;
        TryTime(startLine, out t0, out b);
        var startF = Split(startLine, b);
        TryTime(endLine, out t1, out b);
        var endF = Split(endLine, b);
        string dungeon, level, success, kind;
        if (useKey)
        {
            // CHALLENGE_MODE_START,"Dungeon",mapID,instanceID,level,[affixes]
            dungeon = startF.Count > 1 ? startF[1] : "?";
            level = startF.Count > 4 ? startF[4] : "?";
            success = endF.Count > 2 ? endF[2] : "0";
            kind = "mplus";
        }
        else
        {
            // ENCOUNTER_START,id,"Boss",difficulty,size,instance
            // ENCOUNTER_END,id,"Boss",difficulty,size,success,fightTimeMs
            dungeon = startF.Count > 2 ? startF[2] : "?";
            level = RaidDifficulty(pullDifficulty) ?? (pullDifficulty == "8" ? "Mythic+" : "Dungeon");
            success = endF.Count > 5 ? endF[5] : "0";
            kind = "raid";
        }
        int seconds = (int)Math.Ceiling((t1 - t0).TotalSeconds) + 1;

        var players = new Dictionary<string, Player>();
        var order = new List<Player>();
        var petOwner = new Dictionary<string, string>();
        var bosses = new List<string>();
        var bossStart = new Dictionary<string, double>();

        // Pass 2: count everything between start and end.
        i = -1;
        foreach (string l in ReadLines(path))
        {
            i++;
            if (i < start) continue;
            if (i > end) break;
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
            bool cast = ev == "SPELL_CAST_SUCCESS";
            if (!(spellDmg || swing || heal || absorbed || summon || cast)) continue;

            var fl = Split(l, b);
            if (fl.Count < 9) continue;
            int sec = (int)at;
            if (sec < 0 || sec >= seconds) continue;

            if (summon)
            {
                if (players.ContainsKey(fl[1])) petOwner[fl[5]] = fl[1];
                continue;
            }

            // The player's own casts (not pets'), for the cast timeline.
            if (cast)
            {
                Player cp;
                if (fl.Count > 9 && players.TryGetValue(fl[1], out cp))
                {
                    List<int> times;
                    if (!cp.Casts.TryGetValue(fl[9], out times)) { times = new List<int>(); cp.Casts[fl[9]] = times; }
                    times.Add((int)(at * 10));
                }
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
                if (ap != null)
                {
                    long amount = Num(fl[n - 3]);
                    ap.Heal[sec] += amount;
                    AddAbil(ap.AbilHeal, fl[n - 6], sec, amount, seconds);   // the shield's spell
                }
                continue;
            }

            Player src = Resolve(fl[1], players, petOwner);
            if (src == null) continue;
            if (src.Guid == fl[1] && src.Name == "?") src.Name = Clean(fl[2]);

            if (heal)
            {
                if (fl.Count > 33)
                {
                    long amount = Math.Max(0, Num(fl[31]) - Num(fl[33]));
                    src.Heal[sec] += amount;
                    AddAbil(src.AbilHeal, fl[9], sec, amount, seconds);
                }
                continue;
            }

            int destFlags = Flags(fl[7]);
            if ((destFlags & 0x10) != 0) continue;              // friendly target
            int a = swing ? 28 : 31;
            if (fl.Count > a + 6)
            {
                long amount = Num(fl[a]) + Num(fl[a + 6]);
                src.Dmg[sec] += amount;
                // Melee has no spell: 6603 is Auto Attack, so it gets a name and icon.
                AddAbil(src.AbilDmg, swing ? "6603" : fl[9], sec, amount, seconds);
            }
        }

        var sb = new StringBuilder();
        sb.Append("DRK1~K^").Append(Clean(dungeon)).Append("^").Append(level).Append("^").Append(seconds)
          .Append("^").Append(success).Append("^").Append(t0.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture))
          .Append("^").Append(kind);
        foreach (var p in order)
            sb.Append("~P^").Append(p.Index).Append("^").Append(p.Name).Append("^").Append(p.Spec);
        foreach (var x in bosses) sb.Append("~").Append(x);
        foreach (var p in order)
        {
            sb.Append("~D^").Append(p.Index).Append("^").Append(Join(p.Dmg));
            sb.Append("~H^").Append(p.Index).Append("^").Append(Join(p.Heal));
        }
        // Per ability (A^player^D|H^spellID^packed) and casts (C^player^spellID^tenths,...).
        // Records an older DPS Report doesn't know are skipped by its parser.
        // A^player^D|H^spellID^step^packed thousands-per-step-block.
        int step = Math.Max(1, (seconds + 299) / 300);
        bool big = order.Count > 5;
        int topDamage = TOP_DAMAGE, topHealing = big ? 5 : TOP_HEALING, topCasts = big ? 10 : TOP_CASTS;
        foreach (var p in order)
        {
            foreach (var kv in Top(p.AbilDmg, topDamage))
                sb.Append("~A^").Append(p.Index).Append("^D^").Append(kv.Key).Append("^").Append(step)
                  .Append("^").Append(Packed(Coarse(kv.Value, step)));
            foreach (var kv in Top(p.AbilHeal, topHealing))
                sb.Append("~A^").Append(p.Index).Append("^H^").Append(kv.Key).Append("^").Append(step)
                  .Append("^").Append(Packed(Coarse(kv.Value, step)));
            var casts = new List<KeyValuePair<string, List<int>>>(p.Casts);
            casts.Sort((x, y) => y.Value.Count.CompareTo(x.Value.Count));
            for (int c = 0; c < casts.Count && c < topCasts; c++)
            {
                sb.Append("~C^").Append(p.Index).Append("^").Append(casts[c].Key).Append("^");
                var t = casts[c].Value;
                for (int k = 0; k < t.Count; k++)
                {
                    if (k > 0) sb.Append(',');
                    sb.Append(t[k].ToString(CultureInfo.InvariantCulture));
                }
            }
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
