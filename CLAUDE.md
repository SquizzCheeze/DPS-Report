# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DPSReport is a World of Warcraft retail AddOn (Lua) that reports DPS/HPS/stats to chat and displays live meter windows, using Blizzard's built-in `C_DamageMeter` API (no combat log parsing). The entire addon logic lives in a single file: `DPSReport.lua` (~6200 lines). `DPSReport.toc` is the addon manifest; `Textures/` holds the minimap icon.

There is no build step, package manager, or test suite — this is a plain Lua addon loaded directly by the WoW client. "Testing" means loading the addon in-game (`/reload`) and exercising it in a group/raid or via `/dps`.

## Releasing

Releases are tag-driven. Pushing a `v*` tag runs `.github/workflows/release.yml`, which packages the addon with BigWigsMods/packager, uploads it to CurseForge (project `1504877`, read from `## X-Curse-Project-ID` in the TOC) and attaches the zip to a GitHub release. Ordinary pushes to `main` publish nothing.

Two things are easy to get wrong:

- `changelog.txt` is uploaded **verbatim** as that release's CurseForge notes, so it must hold only the version being released. Older sections move to `CHANGELOG-ARCHIVE.txt`, which `.pkgmeta` ignores so it never ships. Leaving history in `changelog.txt` makes every release repost the entire backlog.
- What ships is controlled by the `ignore:` list in `.pkgmeta`, not by `.gitignore`. Dev files (`CLAUDE.md`, `README.md`, `.luarc.json`, `.github`, `.claude`, the changelog archive) are excluded there; `LICENSE` and `changelog.txt` deliberately are not.

Before a real release, run the workflow manually from the Actions tab with `dry_run` ticked — it builds the zip and uploads nothing. A CurseForge file goes live to players the instant it uploads, and its version number can't be reused.

**Versioning:** increment the last number — 1.20 → 1.21 → 1.22. The jump from 1.7 straight to 1.20 was deliberate (1.20 is "twenty", not "point two"), so do not "correct" it back to 1.8/1.9. Note this sorts below 1.8 under numeric comparison; CurseForge and addon managers key "latest" off upload recency rather than parsing the string, so it does not matter in practice.

## Linting

A `.luarc.json` configures the Lua language server (Lua 5.1 runtime, matching WoW's Lua version) with WoW/Blizzard API globals declared under `diagnostics.globals`. When adding calls to new Blizzard API functions or globals, add them to that list or the language server will flag them as undefined.

## Slash commands (user-facing)

`/dps` (defined via `SLASH_DPSREPORT1`) is the only slash command, and it **ignores its arguments** — the handler just calls `DPSReport_OpenOptionsPanel()`. Earlier revisions of this file and of the header comment in `DPSReport.lua` documented an argument surface (`dps`, `hps`, `overall`, `whisper <name>`, …) that was never implemented; `/dpsreport` was never registered either. Reporting happens through the meter windows, the quick-report widget, and the end-of-dungeon auto-announce.

## Architecture

The file is organized top-to-bottom into sections separated by `-- ====...====` banners. Reading it roughly in order:

1. **Profile/roster/nickname state** (~L30–220) — per-character active profile, roster name caches (`rosterNameCache`, `specNameCache`, `guidNameCache`, `seenNameCache`), and an out-of-combat inspection queue (`ProcessInspectQueue`/`QueueGroupInspections`) used to resolve player specs/names since `NotifyInspect` is blocked in combat. `RefreshRosterCache` also fills `specIconToRole` (specIconID → TANK/HEALER/DAMAGER, never wiped) and `roleByName` (short name → assigned role, wiped with the roster); the MVP score reads them, preferring `specIconToRole` because snapshot entries carry `specIconID` and so stay resolvable after the group disbands.
2. **Settings** (~L223–480) — `DEFAULT_SETTINGS`, `LoadSettings`/`SaveSettings`, per-character profile switching (`SwitchProfile`), and meter layout persistence (`SaveMeterLayoutToSettings`/`ApplyMeterLayoutFromSettings`).
3. **Chat report building** (~L780–900) — `BuildReport`/`BuildSegmentReport` turn a `C_DamageMeter` session into chat lines; `SendLine(s)` picks the right chat channel.
4. **End-of-dungeon announce** (~L900–1230) — `BuildMythicAnnounce` picks the format from `settings.autoReportFormat`: `"summary"` builds the highlight reel via `BuildMythicSummaryReport` (helpers `CollectSummaryPlayers`, `TopBy`/`LowestBy`, `ComputeMVP`; `MVP_WEIGHTS` holds the role weighting), `"single"` delegates to `BuildSegmentReport` with a nil `topCount`, which means "whole group". Both the real announce and the Tools preview button call `BuildMythicAnnounce`, so the preview can't drift from what gets posted. All of it reads only the segment `SnapshotMythicRun` already captured, so every value is plain Lua and none of the taint rules below apply.
5. **Main event frame** (~L1290–1620) — registers `MAIN_EVENTS` (group/inspect/challenge-mode events), the `CHALLENGE_MODE_COMPLETED` snapshot-and-announce chain, and the minimap button.
6. **Options panel** (~L1620–2640) — a hand-rolled settings UI (`DPSReport_OpenOptionsPanel`) built from custom widget helpers (`CreateDRButton`, `CreateDRSlider`, `CreateDRCheckbox`, `CreateDRDropdown`, `ShowDRConfirm`), not Blizzard's Settings API. Split into sidebar categories by a local `NewPage(label)` helper: it opens a nav entry plus its own scroll frame, then reassigns the `content` and `yOffset` upvalues so the section code that follows lays widgets onto whichever page is current. `FinishPage` sets each page's scroll-child height. To add a category, call `NewPage` where the section starts — nothing else needs to change.
7. **Report widget** (~L2640–3300) — a small floating "quick report" frame (`CreateReportWidget`, `DPSReport_ToggleWidget`).
8. **Meter snap system** (~L3300–3600) — `MeterSnapSystem`: drag-to-snap alignment between meter frames (edge detection, snap-line overlays, anchor persistence).
9. **DPSMeter / MeterProto** (~L3600 onward) — the core live meter windows. `DPSMeter` is the manager (`NewMeter`, `RemoveMeter`, `ResetAll`, `SaveAllMeters`/`LoadAllMeters`); `MeterProto` is the per-meter-instance prototype covering frame creation, bar rendering, tooltips, the breakdown window (per-spell/per-target drill-down), chat reporting from a meter, and position persistence.

Two mode-name namespaces exist and are easy to confuse: `TYPE_MAP` keys (`dtaken`, `edamage`, …) name report types, while `METER_MODE_MAP` keys (`taken`, `avoidable`, …) name meter modes *and* the keys under `seg.modes` that `SnapshotMythicRun` writes. Anything reading a segment must use the `METER_MODE_MAP` spelling — `WIDGET_TO_SEG_MODE` in the report widget translates, and the Auto Report metric dropdown sidesteps the problem by storing `METER_MODE_MAP` keys directly. `METER_MODE_MAP` has no `EnemyDamageTaken` entry, so enemy damage is never captured into a segment and that metric is deliberately absent from the auto-report dropdown.

`BuildSegmentReport` sorts a *copy* of `modeData.entries` before ranking. The entry list is shared with the live meter, so sorting it in place would reorder bars underneath the user.

### Deaths

Deaths is the one metric where `C_DamageMeter` is not the source of truth, and `AggregateDeathEntries` (~L4395) is the single choke point every reader goes through: `MeterProto:LoadFromAPI`, `SnapshotMythicRun`, `BuildEntriesFromSessionID`, and the deaths branch of `BuildReport`. Anything new that reads deaths must go through it too.

It gets the list wrong in two ways. The session returns **one `combatSource` per death event**, each with `totalAmount` 0 — a player who died twice appears twice and the count is the number of rows, not any value on them. And it counts **Feign Death as a real death**, so a hunter who never died reports five or six.

Nothing in the session data separates a feign from a death afterwards, so `DeathTracker` (~L259–535) keeps its own tally instead: a 0.5s ticker over group units, edge-detecting `UnitIsDeadOrGhost` false→true. A feigning hunter reads as *alive* there, which is the whole point — `UnitIsFeignDeath` is kept as a second check but is not what does the work. Polling is also the only option left: the combat log is gone from the addon API in 12.0, and `UNIT_DIED` never fired reliably for off-screen members. Squizzumables' M+ death tally works the same way and is where the approach was proven.

**The tracker substitutes the whole list rather than correcting rows.** `AggregateDeathEntries(entries, scope)` calls `DeathTracker:BuildEntries(scope)` first and returns it if it is non-nil, folding the API's rows only as a fallback. Row-by-row correction was tried and cannot work: mid-key the API's rows carry no readable name or GUID to match a tally against, while unit APIs stay plain throughout. An empty list from the tracker is a real answer ("nobody died"), so callers must test it for nil, never for `#`.

`BuildEntries` emits **short** names in `name` (full name in `plainName`). `SnapshotMythicRun` stores every mode under a short name and `CollectSummaryPlayers` keys its rows off it — a "Bob-Realm" here would not merge with the damage list's "Bob", and the summary would rank a phantom player who did nothing but die.

Three scopes, because they answer to different resets: `current` (per-fight, reset on `PLAYER_REGEN_DISABLED`), `overall` (reset with `DPSMeter:ResetAll()`, which is what resets the Overall session), and `run` (reset on `CHALLENGE_MODE_START`, matching Blizzard's own key scope). Inside a key `run` stands in for `overall`, since they cover the same thing.

When the tracker declines to answer, that is deliberate — a tally that started late must not be trusted, because reporting zero for a player we never watched deletes real deaths rather than feigns:

- `runFromStart` is set at `CHALLENGE_MODE_START`. With it, the run tally is used unconditionally. It is deliberately **not** re-checked against `GetDeathCount()`, which can lead the poll by up to one tick and would flicker the list back to the API's on every death.
- Without it (logged in or reloaded mid-key) `C_ChallengeMode.GetDeathCount()` is the tiebreak. It is plain even mid-key and feign-free by construction — it is what adds the timer penalty — but has no per-player breakdown, so it serves only as proof that our breakdown is complete. It stops answering once the key ends, so it is captured at `CHALLENGE_MODE_COMPLETED` into `keyDeaths` alongside the other completion data, and cleared when a non-key fight starts.
- Outside a key there is no such total, so `CoversOverallByDuration` compares watched wall-clock against the session's combat time. Note `durationSeconds` is on the secret list and **comparing a secret throws** — thrown from there it took `MeterProto`'s refresh ticker down with it, which presented as a meter that silently stopped updating rather than as an error.

`UnitIsPlayer` gates the poll, so pets never enter the tally. `IsGroupPlayerEntry` (~L1200) does the same job on the *summary* side for the API-sourced modes: `C_DamageMeter` lists a mage's water elemental as its own source, and since a pet takes no avoidable damage it won "Least Avoidable DMG" outright. The test is the GUID prefix (`Player-` vs `Pet-`/`Creature-`), falling back to `specIconID` for segments saved before GUIDs were stored. It gates `CollectSummaryPlayers` only — the live meters still show pet damage, which is what people want there.

`DeathTracker:PrintDiagnostics()` — the "Death Tracking Diagnostics" button under Tools — prints per unit whether `guid`/`dead`/`feign` came back readable or restricted, plus both totals. Which units the game lets an addon read is not documented and cannot be reasoned about from outside the game.

### The taint/secret-value constraint (critical, non-obvious)

As of WoW 12.0, `C_DamageMeter` values (names, numbers) returned **during combat** are tainted/"secret" Lua values — they cannot be read, concatenated, or converted to plain numbers/strings by addon Lua. This shapes large parts of the code:

- **In the live meter UI**, secret values can only be *displayed* via Blizzard's C-side formatting entry points: `AbbreviateNumbers(secretNum, opts)` produces a tainted-but-renderable string, and `FontString:SetFormattedText("%s", taintedStr)` renders it. They cannot be laundered to plain Lua numbers for arithmetic/sorting during combat.
- **Names** are resolved through `ResolveSourcePlainName` using the strongest available identifier first: `sourceGUID` (when itself not secret) → `seenNameCache`/`guidNameCache` (persisted, GUID-keyed, safe even when the live name is secret) → fall back to `Ambiguate(apiName, "short"|"none")` directly on the raw (possibly secret) API name, which is always safe to call. Do **not** fall back to the class/spec caches for name resolution — they map one name per class/spec slot and will misattribute names when two players share a class/spec.
- **Out of combat**, `SafeStr`/`LaunderNumber`/`FormatSecret` use `pcall(tostring, ...)` to convert secret values to plain Lua, which only succeeds outside combat. Chat report building (`BuildReport`) relies on this.
- When touching any code path that reads `C_DamageMeter.*` results, check whether it can run during combat and use the correct laundering strategy for that context — mixing them up either throws taint errors or silently fails to render.

### Theming

`DR_COLORS` is the palette every custom widget reads. `accent` and `accentDim` are overwritten **in place** with the player's class colour by `ApplyClassAccent()`, which runs at file load and again on `PLAYER_LOGIN` (the first point `UnitClass` is guaranteed to answer). In-place mutation is the whole trick: all ~35 accent call sites copy `DR_COLORS.accent[1..3]` at widget-creation time, and every frame is built after login, so nothing else has to know the colour changed. The gold literal left in the table is only the fallback when the class can't be resolved. Don't replace those tables with new ones — that breaks the mutation.

Blizzard's `UIPanelScrollFrameTemplate` scrollbar isn't part of `DR_COLORS`; `SkinDRScrollBar(scrollFrame)` tints it and probes for both the modern (`.Track`/`.Thumb`) and legacy (`ThumbTexture` + up/down buttons) shapes, skipping whatever it doesn't find. The two breakdown-window scroll frames deliberately hide their scrollbars, so the settings panel's is the only one that needs it.

### Persistence model

`DPSReportDB` (SavedVariables) holds: `profiles` (account-wide, keyed by profile name, each holding a full settings table cloned from `DEFAULT_SETTINGS`), `charData` (per-character active profile pointer, keyed by `charKey` = "Name-Realm"), `nicknames` (account-wide), and `seenNames` (account-wide GUID → name cache). `LoadSettings()` also handles one-time migrations (legacy account-wide `activeProfile` → per-character, legacy `settings` → `profiles.Default`, `"raid"` channel → `"instance"`, and `autoReportType` from `TYPE_MAP` spellings to the `METER_MODE_MAP` ones the segment is keyed by).

**Since V1.25 (2026-09-26):**

- **Saved M+ segments are PER CHARACTER**, in `DPSReportCharDB.segments`
  (`## SavedVariablesPerCharacter: DPSReportCharDB`). In `charData[charKey].segments` every
  character loaded every other character's ten runs, per-spell breakdowns included — most of a
  2.6 MB file. Each character's runs move across on its first login after the update
  (`LoadAllMeters`). ⚠ **The move only happens once the client is proven to save that
  variable** (`DPSMeter.segmentsPerChar`): a new `SavedVariablesPerCharacter` line is read at
  client start, not on `/reload`, and until a restart `DPSReportCharDB` is an unsaved global —
  moving runs into it then would lose them at logout. Proof is either the TOC metadata naming it
  or a `DPSReportCharDB.saved` marker that survived a round trip to disk. `SaveAllMeters` writes to
  whichever store `segmentsPerChar` chose.
- **`seenNames` expires**: entries unseen for 30 days are dropped at login. Last-seen stamps live
  in `DPSReportDB.seenNamesAt`; the out-of-combat source pass (~L4945) re-stamps everyone in the
  current fight, so regulars never age out. Legacy integer keys are removed there too.
  `seenNameCache` now IS `DPSReportDB.seenNames` (the local is reassigned at load; every closure
  captures the variable) instead of a full copy of it.
- `mythicRuns` was written by an old version and read by nothing; it is deleted at load.

Note the shallow fill loop in `LoadSettings` (`if prof[k] == nil then prof[k] = v end`) copies by reference, so a nested table in `DEFAULT_SETTINGS` would be shared across every profile. That is why the summary line toggles are flat `autoSummary*` booleans rather than one table.

Meter window layout (position, size, mode, session, snap relationships) is stored per-profile in `settings.meterLayout` and reapplied via `ApplyMeterLayoutFromSettings`, separate from `DPSMeter:SaveAllMeters()/LoadAllMeters()` which persists the meter list itself.

These two stores update on very different schedules, and that is deliberate. `SaveAllMeters` writes `charData[charKey].meters` on every drag, resize, mode change and logout — it is the live position. `SaveMeterLayoutToSettings` writes `settings.meterLayout` **only** when the user clicks "Save Current" or creates a profile — the profile is a snapshot you explicitly take, and "Load Profile" restoring it is the user's recovery path when the live position goes wrong. Do not wire layout saving into the live events; that removes the recovery path.

`DPSMeter.metersLoaded` guards `SaveAllMeters` against writing before `LoadAllMeters` has run. `LoadAllMeters` is deferred ~2s after `PLAYER_LOGIN`, so between login and that call `DPSMeter.meters` is empty — and any save in that window persists an empty list, destroying every saved meter and position. The next login then takes the "first run" branch and rebuilds one default meter at the default position. `PLAYER_REGEN_ENABLED` → `DoCombatEnd` → `SnapshotSegment` → `SaveAllMeters` is the path that actually triggers it, which is why it presented as "reloading during combat loses my layout". Any new `SaveAllMeters` caller inherits the guard; do not bypass it.

### Addon inter-communication

Uses `C_ChatInfo.RegisterAddonMessagePrefix("DPSReport")` + `CHAT_MSG_ADDON` to broadcast/receive nicknames between group members running the addon (`BroadcastNickname`/`OnAddonMessage`), populating the shared `nicknameCache`.
