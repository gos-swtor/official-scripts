# Combat Meter

[Back to all scripts](../../README.md)

Combat Meter is an in-game overlay for damage done, healing done, and damage taken by your character. It reads the GoS combat event stream while you play. It does not parse SWTOR's text combat log or control your character.

## Quick start

1. Install the package through the Script Library and reload Lua from Core's Scripts page.
2. Enable **Combat Meter**. Press `F5` to toggle it by default.
3. Drag the header to place the compact meter. Click a contributor for the full damage or healing breakdown.
4. Use **Reset** before a new pull when you do not want to keep the completed encounter.

The meter opens in **Damage Done**. Its three tabs are **Damage Done**, **Healing Done**, and **Taken to Me**.

## What the meter shows

The compact view lists up to five contributors with total amount, DPS or HPS, and their share of the current encounter. Hovering a damage or healing row shows a small ability and target summary. Clicking it opens the detail view, which includes:

- the selected contributor's damage or healing total and rate
- up to 12 ability rows with amount, share, hits, and critical-hit rate
- up to 6 target rows
- an ability inspector with casts when that ability activation was observed, normal and critical hit counts, and up to 3 targets

**Taken to Me** is a separate view for incoming damage. It shows total damage and DTPS, damage rows, zero-damage rows, criticals, observed crowd-control changes, interrupts, a rolling 60-second chart, the top five sources and abilities, and a paged history. The history filter cycles through Damage / CC / Interrupts, Damage, CC observed, Interrupts, Effect lifecycle, and All events.

## Controls and settings

| Control | What it does |
| --- | --- |
| `F5` by default | Toggle the meter. The hotkey is configurable through the script activation setting. |
| Header drag | Move the compact or detail window. Positions are saved in settings. |
| Tabs | Switch between damage, healing, and incoming damage. |
| Contributor row | Open a damage/healing detail view. |
| Reset | Clear the current encounter and return to waiting. |
| Taken to Me: Details | Open the incoming-damage detail view. |
| Taken detail controls | Select a source, return to all sources, change the history filter, and page through the history. |

The settings card also has **Visible**, compact and detail window positions, **Font Size** from 11 to 18 px, **Overlay Transparency**, and **Background Color**. Setting the background color alpha to zero leaves bars and text visible without the window surface.

## Package contents and dependencies

| Item | Purpose |
| --- | --- |
| `live/combat_meter.lua` | The overlay, encounter tracking, and outgoing damage/healing views. |
| `common/combat_meter/incoming.lua` | The incoming-damage model, CC observations, source and ability summaries, and history. |
| `gos-ui` | Required package dependency. It supplies the actor-label registry used by the meter. |

Keep the package contents together. Manual copies also need the required `gos-ui` modules in the approved common script location.

## Known limits

- Damage uses `effective_amount`. Healing uses the reported `amount`; Core does not currently provide a separate overheal value, so the meter does not make one up.
- Damage and healing contributors are limited to the local player, friendly players, and companions that resolve in the current world snapshot. The model caps contributors at 64 and breakdown rows at 64. The UI groups extra visible detail rows into **Other** where appropriate.
- Incoming damage retains a 2,048-row history and 24 buckets of 2.5 seconds. Older rows are overwritten.
- CC entries in **Taken to Me** are observed changes from the current debuff snapshot, using the module's known effect-definition catalog. They are not native combat events and do not claim an exact application or removal time.
- The header warns when the event stream dropped records, timestamps are missing, an internal row limit was reached, or capture and metadata sampling stopped. Treat a warning as an incomplete meter for that encounter.
- A player identity change resets the meter. An actor-session change marks an active encounter as complete, and that result stays visible until Reset or later qualifying activity starts a fresh encounter.
