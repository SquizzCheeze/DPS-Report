# DPS Report

A lightweight World of Warcraft (retail) damage meter addon built on Blizzard's
built-in `C_DamageMeter` API — no combat log parsing, no heavy CPU cost.

Report DPS/HPS and other stats straight to chat, or keep live meter windows on
screen with per-spell and per-target breakdowns.

## Features

- **Live meter windows** — resizable, movable, snap-to-align meters with DPS,
  HPS, damage, and healing modes.
- **Breakdown drill-down** — click a bar to see per-spell and per-target detail.
- **Chat reports** — post the current fight or the overall session to your
  group, `/say`, or a whisper.
- **Auto-report on combat end** — optional, configurable per profile.
- **Profiles** — account-wide settings profiles with a per-character active
  profile pointer.
- **Nicknames** — set friendly names for group members; shared automatically
  between group members also running the addon.
- **Minimap button and addon compartment** entry.

## Installation

1. Download or clone this repository.
2. Place the folder in your WoW AddOns directory so the path looks like:

   ```
   World of Warcraft/_retail_/Interface/AddOns/DPSReport/DPSReport.toc
   ```

   The folder **must** be named `DPSReport` to match the `.toc` file.
3. Restart WoW, or type `/reload` if the client is already running.

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
Top DMG: Squizzcheeze (48.2M)
Top Healing: Bobhealz (31.7M)
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
   git tag -a v1.8 -m "V1.8"
   git push origin v1.8
   ```

To check a build without publishing, run the workflow manually from the
**Actions** tab with `dry_run` left ticked — it packages, uploads nothing, and
leaves the zip as a downloadable artifact. Worth doing every time, since a
CurseForge file is visible to players the moment it uploads and the version
number can't be reused.

Requires a `CF_API_KEY` (or `CF_API_TOKEN`) repository secret, from
<https://authors.curseforge.com/#/settings/api-tokens>.

## Licence

MIT — see [LICENSE](LICENSE).
