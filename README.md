# DPS Report

A lightweight damage meter for World of Warcraft (Retail), built on the game's own damage meter data. No combat log parsing in game and almost no CPU cost, but everything you'd want from a meter: live windows, breakdowns, fight history, personal bests, a threat meter and a second-by-second graph.

**[Download on CurseForge](https://www.curseforge.com/projects/1504877)**

Type **/dps** to open the settings.

## Features

### Meters
- **Live meter windows:** as many as you like, each with its own metric: DPS, HPS, damage, healing, absorbs, interrupts, dispels, damage taken, avoidable damage or deaths. Resizable and movable, and they snap together when dragged.
- **Breakdowns:** click a bar for per-spell and per-target detail.
- **Threat meter:** your group and their pets ranked by threat on your target. Whoever has aggro is marked, and your own bar turns orange when you're close to pulling and red when you have it. Click the **T** on any meter, or type **/dpsthreat**.
- **Real names in combat:** shows player names even when the game hides them.

### History and personal bests
- **Fight history:** every boss pull ("Boss (Heroic) Kill" or "Wipe") and every whole Mythic+ run, trash included, with each player's DPS, damage, HPS, healing and interrupts. The last 200 are kept per character. Search as you type (a boss, a dungeon, +10, heroic, wipe, a date), and right-click another fight to compare: every number gets a green or red % against it. Click the **H** on any meter, or type **/dpshistory**.
- **Personal bests:** your best DPS and best total on every boss you kill, by difficulty, with a line in chat when you beat one.
- **Saved runs and raid pulls:** look back at your recent keys and raid attempts with full breakdowns. Who did what on pull 7 against pull 12?

### DPS Graph
Click the **G** on any meter, or type **/dpsgraph**.
- **Every fight this session**, one bar per second, for you and each group member: DPS, damage, HPS or healing. Hover for the value at that moment, and step back through your last 10 fights.
- **Import a whole key or boss pull** with the real per-second numbers the game hides during play, using the free **[DPS Report Exporter](https://squizzcheeze.github.io/DPS-Report/)** app for Windows. An imported fight adds:
  - an **ability breakdown** for every second
  - a **cast timeline**, with every cast and every DoT, HoT, buff and channel's uptime
  - **everyone stacked** in class colours
  - an **event log** of casts and aura changes
  - **compare** against another saved key or pull
- Imported fights are saved, so they survive /reload and logging out.

### Mythic+
- **End-of-key summary:** finish a key and announce a run summary with a role-weighted **MVP**, top DPS, HPS, interrupts and dispels, least avoidable damage and deaths. "Explain Last Run MVP" shows how the score was worked out.
- **Compare with your last run** (optional): a line in your own chat comparing your DPS, HPS and deaths with your last run of that dungeon.
- **Combat logging** (optional): turns WoW's combat log on in dungeons and raids and off when you leave, and leaves logging started by Archon, /combatlog or another addon alone.

### Everything else
- **Chat reports:** post any meter, the whole session or a saved fight to your group, /say or a whisper.
- **Profiles:** account-wide settings profiles, with a per-character active profile.
- **Nicknames:** friendly names for group members, shared automatically with others running the addon.
- **Minimap button and addon compartment** entry, and a **class-coloured** interface.

## DPS Report Exporter (Windows)

A small free companion app that sits in your system tray while you play. The moment a boss pull or Mythic+ key ends, it's copied to your clipboard, ready for the graph's **Import** and **Ctrl+V**. It only reads the combat log file the game writes, needs no installer and is open source.

**[Download DPS Report Exporter](https://squizzcheeze.github.io/DPS-Report/)**

## Installation

1. Download or clone this repository.
2. Place the folder in your WoW AddOns directory so the path looks like:

   ```
   World of Warcraft/_retail_/Interface/AddOns/DPSReport/DPSReport.toc
   ```

   The folder **must** be named `DPSReport` to match the `.toc` file.
3. Type `/reload` if the game is already running.

## Usage

Type `/dps` to open the settings panel. Everything the addon does is driven
from there, from the minimap button, or from the addon compartment — the slash
command takes no arguments.

**Live meters.** Add as many meter windows as you like, each with its own
metric: DPS, HPS, damage, healing, absorbs, interrupts, dispels, damage taken,
avoidable damage or deaths. Click a bar to drill into per-spell and per-target
detail. Meters snap to each other when dragged, and remember their position,
size and mode per profile.

**Reporting to chat.** Each meter has a report button that posts its current
contents to chat. The quick-report widget does the same for a chosen metric,
session or saved segment.

**End-of-dungeon summary.** With auto-report enabled, finishing a Mythic+ key
announces a highlight summary to chat:

```
--- Ara-Kara, City of Echoes +12 completed in 28:41 ---
MVP: Bobhealz
Top DPS: Squizzcheeze (1.68M)
Top HPS: Bobhealz (1.10M)
Top Interrupts: Tankboi (14)
Top Dispels: Bobhealz (9)
Least Avoidable DMG: Squizzcheeze (412K)
Deaths: 3 total (most: Tankboi with 2)
```

Every line can be switched off individually under **Auto Report**, along with
the channel and the delay before it posts. MVP is a role-weighted score: each
player's share of the group's damage, healing, interrupts and dispels, weighted
by what their role is actually responsible for, minus penalties for dying and
for taking avoidable damage.

Prefer one metric instead? Set **Format** to *Single metric* and pick which one
— DPS, HPS, damage, healing, absorbs, interrupts, dispels, damage taken,
avoidable damage or deaths. That announces the whole group for that metric,
ranked highest to lowest:

```
--- Avoidable Damage Report (Ara-Kara, City of Echoes +12 28:41) - Total: 4.1M ---
1. Tankboi - 1.2M (1.2M, 29.3%)
2. Bobhealz - 890K (890K, 21.7%)
3. Grubmage - 780K (780K, 19.0%)
4. Stabbyboi - 618K (618K, 15.1%)
5. Squizzcheeze (*) - 412K (412K, 10.1%)
```

**Previewing.** Under **Tools**, *Preview Last Run Announce* prints what the
most recent run would have announced, using your current Auto Report settings.
It goes to your own chat frame only — nothing is sent to the group — so it is
safe to click while you tune the settings.

## Requirements

- World of Warcraft retail, interface version **12.01.00** or later
  (`C_DamageMeter` is a 12.0 API).

## Development

There is no build step or package manager — this is a plain Lua addon loaded
directly by the WoW client. Testing means loading it in-game and exercising it
in a group or raid.

- `DPSReport.lua` — the entire addon.
- `DPSReport.toc` — addon manifest.
- `Textures/` — minimap icon.
- `.luarc.json` — Lua language server config (Lua 5.1, WoW API globals). Add
  any newly used Blizzard globals to `diagnostics.globals` there.

See `CLAUDE.md` for a section-by-section tour of the code and notes on the
combat taint / secret-value constraints that shape much of it.

## Author

Squizzcheeze

## Releasing

Releases are tag-driven via `.github/workflows/release.yml`, which runs
[BigWigsMods/packager](https://github.com/BigWigsMods/packager) to build the
zip, upload it to CurseForge (project `1504877`, read from
`## X-Curse-Project-ID` in the TOC) and attach it to a GitHub release.

1. Write the release notes in `changelog.txt`. This file is uploaded
   **verbatim** as the CurseForge release notes, so it must contain only the
   version being released — move the previous section to
   `CHANGELOG-ARCHIVE.txt` first (that file is never shipped).
2. Bump `## Version:` in `DPSReport.toc`, commit, and push.
3. Tag and push:

   ```sh
   git tag -a v1.20 -m "V1.20"
   git push origin v1.20
   ```

To check a build without publishing, run the workflow manually from the
**Actions** tab with `dry_run` left ticked — it packages, uploads nothing, and
leaves the zip as a downloadable artifact. Worth doing every time, since a
CurseForge file is visible to players the moment it uploads and the version
number can't be reused.

Requires a `CF_API_KEY` (or `CF_API_TOKEN`) repository secret, from
<https://authors.curseforge.com/#/settings/api-tokens>.

## Support

If you enjoy using DPS Report, consider supporting development on
[Ko-fi](https://ko-fi.com/squizz) ❤️

## More addons by Squizz

- **[SquizzFrames](https://www.curseforge.com/projects/1649203)** — party, raid, pet and unit frames with a full indicator system, click-casting and a tank tracker
- **[Squizzumables](https://www.curseforge.com/projects/1483099)** — one-click reminders for food, flasks, oils and class buffs, plus raid tools and a restyled Cooldown Manager
- **[Squizzcap](https://www.curseforge.com/projects/1713974)** — what killed you, how hard it hit and how fast you went down, with every death of a key saved to look back on
- **[SquizzTalents](https://www.curseforge.com/projects/1705647)** — all your talent builds in one list, with a reminder when your build doesn't match the content
- **[Avatar Continued](https://www.curseforge.com/projects/1533608)** — your character model on screen as part of your UI
- **[KSLBestDungeon](https://www.curseforge.com/projects/1599575)** — ranks Mythic+ dungeons by how many of your KeystoneLoot favorites drop there

## Licence

MIT — see [LICENSE](LICENSE).
