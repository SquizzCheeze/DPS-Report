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

The slash command is `/dps` (`/dpsreport` also works).

| Command | Description |
| --- | --- |
| `/dps` | Report DPS for the current session to party/instance chat |
| `/dps dps` | Report DPS |
| `/dps hps` | Report HPS |
| `/dps damage` | Report total damage done |
| `/dps healing` | Report total healing done |
| `/dps all` | Report DPS + HPS combined |
| `/dps overall` | Use the "Overall" session instead of the current fight |
| `/dps dps 5` | Report the top 5 only (works with any report type) |
| `/dps say` | Output to `/say` instead of group chat |
| `/dps whisper PlayerName` | Whisper the report to a player |

Open the options panel from the minimap button or the addon compartment to
configure meters, profiles, auto-reporting, and nicknames.

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
