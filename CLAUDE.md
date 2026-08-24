# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DPSReport is a World of Warcraft retail AddOn (Lua) that reports DPS/HPS/stats to chat and displays live meter windows, using Blizzard's built-in `C_DamageMeter` API (no combat log parsing). The entire addon logic lives in a single file: `DPSReport.lua` (~6200 lines). `DPSReport.toc` is the addon manifest; `Textures/` holds the minimap icon.

There is no build step, package manager, or test suite — this is a plain Lua addon loaded directly by the WoW client. "Testing" means loading the addon in-game (`/reload`) and exercising it in a group/raid or via `/dps`.

## Linting

A `.luarc.json` configures the Lua language server (Lua 5.1 runtime, matching WoW's Lua version) with WoW/Blizzard API globals declared under `diagnostics.globals`. When adding calls to new Blizzard API functions or globals, add them to that list or the language server will flag them as undefined.

## Slash commands (user-facing)

`/dps` (defined via `SLASH_DPSREPORT1`) with args: `dps`, `hps`, `damage`, `healing`, `all`, `overall`, `<type> <topN>`, `say`, `whisper <name>`. See the header comment at the top of `DPSReport.lua` for the full list.

## Architecture

The file is organized top-to-bottom into sections separated by `-- ====...====` banners. Reading it roughly in order:

1. **Profile/roster/nickname state** (~L30–220) — per-character active profile, roster name caches (`rosterNameCache`, `specNameCache`, `guidNameCache`, `seenNameCache`), and an out-of-combat inspection queue (`ProcessInspectQueue`/`QueueGroupInspections`) used to resolve player specs/names since `NotifyInspect` is blocked in combat.
2. **Settings** (~L223–480) — `DEFAULT_SETTINGS`, `LoadSettings`/`SaveSettings`, per-character profile switching (`SwitchProfile`), and meter layout persistence (`SaveMeterLayoutToSettings`/`ApplyMeterLayoutFromSettings`).
3. **Chat report building** (~L480–860) — `BuildReport`/`BuildSegmentReport` turn a `C_DamageMeter` session into chat lines; `SendLine(s)` picks the right chat channel.
4. **Main event frame** (~L940–1270) — registers `MAIN_EVENTS` (group/inspect/challenge-mode events), auto-report-on-combat-end logic, and the minimap button.
5. **Options panel** (~L1270–2180) — a hand-rolled settings UI (`DPSReport_OpenOptionsPanel`) built from custom widget helpers (`CreateDRButton`, `CreateDRSlider`, `CreateDRCheckbox`, `CreateDRDropdown`, `ShowDRConfirm`), not Blizzard's Settings API.
6. **Report widget** (~L2180–2820) — a small floating "quick report" frame (`CreateReportWidget`, `DPSReport_ToggleWidget`).
7. **Meter snap system** (~L2840–3135) — `MeterSnapSystem`: drag-to-snap alignment between meter frames (edge detection, snap-line overlays, anchor persistence).
8. **DPSMeter / MeterProto** (~L3135 onward) — the core live meter windows. `DPSMeter` is the manager (`NewMeter`, `RemoveMeter`, `ResetAll`, `SaveAllMeters`/`LoadAllMeters`); `MeterProto` is the per-meter-instance prototype covering frame creation, bar rendering, tooltips, the breakdown window (per-spell/per-target drill-down), chat reporting from a meter, and position persistence.

### The taint/secret-value constraint (critical, non-obvious)

As of WoW 12.0, `C_DamageMeter` values (names, numbers) returned **during combat** are tainted/"secret" Lua values — they cannot be read, concatenated, or converted to plain numbers/strings by addon Lua. This shapes large parts of the code:

- **In the live meter UI**, secret values can only be *displayed* via Blizzard's C-side formatting entry points: `AbbreviateNumbers(secretNum, opts)` produces a tainted-but-renderable string, and `FontString:SetFormattedText("%s", taintedStr)` renders it. They cannot be laundered to plain Lua numbers for arithmetic/sorting during combat.
- **Names** are resolved through `ResolveSourcePlainName` using the strongest available identifier first: `sourceGUID` (when itself not secret) → `seenNameCache`/`guidNameCache` (persisted, GUID-keyed, safe even when the live name is secret) → fall back to `Ambiguate(apiName, "short"|"none")` directly on the raw (possibly secret) API name, which is always safe to call. Do **not** fall back to the class/spec caches for name resolution — they map one name per class/spec slot and will misattribute names when two players share a class/spec.
- **Out of combat**, `SafeStr`/`LaunderNumber`/`FormatSecret` use `pcall(tostring, ...)` to convert secret values to plain Lua, which only succeeds outside combat. Chat report building (`BuildReport`) relies on this.
- When touching any code path that reads `C_DamageMeter.*` results, check whether it can run during combat and use the correct laundering strategy for that context — mixing them up either throws taint errors or silently fails to render.

### Persistence model

`DPSReportDB` (SavedVariables) holds: `profiles` (account-wide, keyed by profile name, each holding a full settings table cloned from `DEFAULT_SETTINGS`), `charData` (per-character active profile pointer, keyed by `charKey` = "Name-Realm"), `nicknames` (account-wide), and `seenNames` (account-wide GUID → name cache). `LoadSettings()` also handles one-time migrations (legacy account-wide `activeProfile` → per-character, legacy `settings` → `profiles.Default`, `"raid"` channel → `"instance"`).

Meter window layout (position, size, mode, session, snap relationships) is stored per-profile in `settings.meterLayout` and reapplied via `ApplyMeterLayoutFromSettings`, separate from `DPSMeter:SaveAllMeters()/LoadAllMeters()` which persists the meter list itself.

### Addon inter-communication

Uses `C_ChatInfo.RegisterAddonMessagePrefix("DPSReport")` + `CHAT_MSG_ADDON` to broadcast/receive nicknames between group members running the addon (`BroadcastNickname`/`OnAddonMessage`), populating the shared `nicknameCache`.
