# PvP Sense

[Back to all scripts](../../README.md)

PvP Sense puts known player cooldowns beside on-screen nameplates and shows a short response cue for the current hostile target. It is useful in warzones and other fights involving players, where seeing a defensive or burst window quickly matters.

It also has an objective-interaction window. When a player is using one of the supported objective casts, the window shows that player, the action, a cast bar, and, when Core provides timing, the time left.

## Screenshots

![PvP Sense showing cooldown icons and crowd control warnings](https://i.imgur.com/ne9vREr.png)

## Quick start

1. Install the package through the Script Library, then reload Lua from Core's Scripts page.
2. Enable **PvP Sense** in its settings.
3. Turn on **Preview - Cycle Icons** to place the nameplate icons and cues.
4. In a match, use the objective window to spot supported capture, plant, and disarm casts. Drag its title bar to move it.

The script starts enabled by default. Preview uses your own nameplate only and cycles through the built-in catalog.

## What you see

- Defensive and offensive cooldown icons next to player nameplates.
- Remaining time, stack count, category-colored border, and an optional duration sweep when that information is available.
- A response cue for the current hostile target, such as `DO NOT CC`, `LOS`, `DEFEND`, or `TEAM BURST`. The cue can include the ability name.
- A movable objective-interaction list for hostile and friendly players. Its reviewed catalog recognizes localized ability titles and explicit Core prototype-name aliases, with separate `CAPTURE`, `ORB`, `PLANT`, `DISARM`, `PICKUP`, and `INTERACT` labels.
- A movable hostile-player roster with abbreviated class, clickable name, observed spec, HP percentage/bar, iLvl, and distance in metres. It includes off-screen hostile players known to Core, nearest first; it is independent of the nameplate icon filters.

The objective list can show up to eight entries. Clicking a row requests that Core select that player. The request can fail or wait if targeting is busy, and the script reports that in the Lua log.

The hostile roster uses the Seer-style `[=]` drag handle and `X` close control. Move it with `[=]`; drag release saves its position. Reopen it with **Hostiles - Roster Window**. Clicking a name submits the same Core click-ticket contract as objective rows, bound to the displayed entity rather than the next sorted occupant. A newer click in either window replaces this script's older undispatched intent; hiding either window cancels only its own pending intent. No uncertain selection is replayed.

Unknown fields display `--`. The iLvl column means overall equipped **item rating**, using `unit:item_rating()` from the matching Core build and the same prepared source as native nameplates. It is not character level or an individual inventory item's level. An older Core without the getter shows `--` and logs that limitation once. Remote spec information is independently optional and is not guessed from effects or abilities.

## Objective awareness

Names are matched exactly after lower-casing and trimming surrounding spaces. The catalog is derived from installed ability/placeable definitions, not a fuzzy search of cast names.

| Family | Localized titles and explicit Core aliases | Defined cast/channel time |
| --- | --- | --- |
| Ancient Hypergate pylons | `Use Objective`, `Use Objective Purple` | 6 s; `CAPTURE` |
| Hypergate orbs | `Gathering Orbs`, `Gather Energy` | 5 s; `ORB` |
| Shared capture / Yavin extraction | `Capturing the Objective`; `Use Extraction` | Shared title is ambiguous (6 / 8 s); explicit extraction alias is 8 s |
| Alderaan / Yavin turret | `Controlling the Turret` | 8 s; `CAPTURE` |
| Voidstar bomb | `Planting the Bomb` / `Plant Bomb`; `Defusing the Bomb` / `Defuse Bomb` | Plant 6 s; disarm 3 s |
| Voidstar controls | `Extending the Bridge` / `Bridge Console`; `Deactivating the Forcefield` / `Forcefield Console` | 6 s; `INTERACT` |
| Voidstar data core | `Downloading the Data Core` / `Data Core` | 0.5 s; `INTERACT` |
| Voidstar generic interaction | `Interacting` / `Interact` | 3 s; `INTERACT` |
| Legacy ship bomb | `Placing Explosives` / `Plantbomb`; `Disarming Explosives` / `Defusebomb` | 3 s; `PLANT` / `DISARM` |
| Legacy ship terminals | `Slicing Terminal` / `Bridgecontrols` / `Bridgedoor`; `Retrieving Datacore` / `Datacore`; `Overriding Security Terminal` | 1.5 s; 5 s; 5 s |
| Shared turret alias | `Turretswitch` | Ambiguous action and total (8 s capture / 5 s terminal); neutral `INTERACT` |
| Novare Coast emplacements | `Accessing the Emplacement`, `Generator1`, `Generator2`, `Generator3` | 18 s channel; `CAPTURE` |
| Artifact pickup | `Picking up the Artifact` / `Use Vip` | 6 s; `PICKUP` |
| Huttball pickup | `Grabbing the Ball` / `Ballstand` | Instant; no invented duration or persistent row |
| Ilum landing zone | `Capture Landing Zone` / `Take Landing Area` | 4 s; `CAPTURE` |
| Ilum repairs / supplies | `Repairing the Turret` / `Repair Imp Turret` / `Repair Rep Turret`; `Opening Supply Crate` / `Supply Crate Use` | 10 s; 5 s; `INTERACT` |
| Ilum cannon mounting | `Mount Particle Cannon` / `Mount Turret` / `Mount Turret Imp` / `Mount Turret Rep` | 0.5 s; `INTERACT` |
| Generic observed interaction | `Accessing` | Unknown total; `INTERACT` |

Remaining seconds always come from Core's current cast snapshot. Bar fill uses the defined total only when the exact name is unambiguous; it represents cast/channel progress, not objective capture percentage. An active cast and a resolved friendly/hostile player are required. Instant pickups may never produce a visible active row. Taxis, bolster, grapples, explosions, rocket attacks, carrier buffs, and scoring/support effects are not objective casts.

## Settings

| Group | Settings |
| --- | --- |
| Master and preview | Enable the overlay, cycle the catalog on your own nameplate, and set the preview interval. |
| Objective window | Show or hide it, include friendly and hostile players, show time left, and set its X/Y position and width. The title bar is draggable. |
| Hostile roster | Show or hide it, set X/Y position and width, and choose visible rows (default 16, maximum 32, further limited by viewport height). It reads at most 64 prepared hostile players. |
| Cooldown display | Toggle defensive icons, offensive icons, action cues, ability names in cues, bold cue text, timers, stacks, borders, and the time sweep. |
| Targets and limits | Include friendly, hostile, neutral, or self; set the maximum players checked, icons per side, and scan distance. A zero distance means no distance limit. |
| Layout | Choose which side carries defensives, horizontal or vertical icon direction, icon size and gap, offsets, text sizes, border width, sweep opacity, and defensive/offensive colors. |
| Diagnostics | **Effect Observations** writes one short status summary per second to the Lua log. It is off by default. |

Nameplate icons shrink from full size at 30 m to half size at 60 m. Only on-screen player units are considered. Your current target remains eligible even when its normal relation filter is off.

## Package contents and dependencies

| Item | Purpose |
| --- | --- |
| `live/pvp_sense.lua` | The script entry point. |
| `gos-assets` | Provides the 106 DDS icons referenced by the built-in cooldown catalog. |

This package depends on **gos-assets**. Core installs the sprites into the shared `sprites/swtor` paths used by the overlay.

## Known limits

- The catalog is finite. It recognizes the cooldown names included in `pvp_sense.lua`; unknown buffs do not get an icon or cue.
- Cooldown rows require a timed buff with positive remaining time. If Core supplies a last-known effect row, the script may keep its icon dimmed for display continuity, but it never uses that row for an action cue.
- The cooldown/nameplate section checks at most 64 configured players and budgets at most 120 draw commands per frame. Lower limits can leave some visible units without icons. The separate objective and hostile windows have their own bounded row counts.
- Objective detection uses the exact supported cast names above. Unknown names are ignored. A row can appear without timing. Shared `Capturing the Objective`, `Turretswitch`, and generic `Accessing` names retain the observed countdown with zero bar fill because their total cannot be identified safely by name alone. Public ability handles are opaque and are not archive/global definition IDs.
- PvP Sense does not cast abilities or change rotations. Only explicit clicks on an objective row or hostile-roster name request target changes.
- The hostile roster reads Core snapshots, not a complete server roster. Players absent from the snapshot cannot be listed. Its new equipped-rating getter requires the rebuilt Core; source checks and disk synchronization do not prove native activation or Lua VM reload.
