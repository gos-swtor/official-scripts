# Sage / Sorcerer

[Back to all scripts](../../README.md)

This package provides one hold-to-run routine for both **Sage** and **Sorcerer**. It routes the current loadout to **Telekinetics / Lightning**, **Balance / Madness**, or **Seer / Corruption**.

`live/sage.lua` owns the shared settings and the package's single ability executor. The discipline files keep one canonical Sage priority model, while `common/sage/mirror.lua` translates confirmed Sorcerer discipline, ability, passive, effect, cast, and combat-event names at the Core boundary.

## Quick start

1. Install this package from the Script Library. Core installs the required `gos-common` and `gos-ui` versions with it.
2. Reload Lua in GoS:SWTOR Core and enable **Sage / Sorcerer**.
3. Select one of the six supported disciplines.
4. Hold the **Rotation Key**. Its default is Mouse 4.

The routine reads unlocked abilities from the current loadout instead of assuming them from character level. Core makes the final decision on range, line of sight, target state, cost, cast state, and the global cooldown.

## What each discipline does

### Telekinetics / Lightning

This route uses a selected hostile target and only takes proc branches when the matching effect has been observed. Telekinetic Wave / Chain Lightning is never hard-cast. The route has target-centered AoE counting for Forceful Retribution / Overloaded Strike and Forcequake / Force Storm, a movement bar, and an optional burst mode with its own toggle key, default `7`.

You can set manual target counts, turn on automatic target-centered counting, tune the AoE radii and thresholds, and choose whether to pool resources for burst. The target-count visual is off by default.

### Balance / Madness

This route maintains its own damage effects on the selected hostile and uses observed Presence of Mind / Wrath state before its linked actions. Max AoE Spread can use Force in Balance / Death Field where available, or apply missing Sever Force / Creeping Terror and Weaken Mind / Affliction to one nearby eligible target at a time without changing your selected target.

Max AoE Spread is on by default and can be toggled with its setting or the Max Spread Key, default Mouse 5. The route also has Forcequake / Force Storm count controls, optional moving Rejuvenate / Resurgence, optional self Force Armor / Static Barrier, and a movement advisory overlay.

### Seer / Corruption

This route picks an eligible friendly target and submits healing with that exact target. It does not replace your visible selection with a healing target. The route supports current-health ordering or Incoming Damage Formula ordering, healing styles, target-type filters, shields, group healing, Force recovery, and low-priority DPS only when healing and safe recovery have nothing to do.

Incoming Damage Formula also drives urgency. Fresh urgent forecasts can admit an injured patient before the ordinary HP cutoff and prioritize available emergency heals over routine Force recovery or unrelated group coverage. Failed urgent healing does not become idle DPS; when useful rescues are unaffordable, safe Force recovery remains available. Current HP mode keeps the ordinary thresholds.

The healing route starts only when the ready loadout contains Benevolence / Dark Heal, Rejuvenate / Resurgence, Healing Trance / Innervate, Salvation / Revivification, a supported Force Armor / Static Barrier choice, and Keeper of Peace / Rally or Deliverance / Dark Infusion.

The shared cleanse catalog is used only for effects it recognizes. Physical cleanses require Mend Wounds / Purity. The route can also show a recent-action feed and lines from hostile casts to their captured targets.

## Important settings

The settings card shows the controls that apply to the selected discipline. Existing setting names keep their Sage labels so one saved settings schema works for both combat styles.

| Discipline | Settings |
| --- | --- |
| All routes | Rotation Key, ability queue window for the damage routes, cast log, decision log |
| Telekinetics / Lightning | Relevant Targets, target-centered count, AoE radii and thresholds, target-count visual, mobility bar, Force fallback, burst pooling and key |
| Balance / Madness | Max AoE Spread and key, spread radius, Forcequake radius and target count, moving Rejuvenate, self armor, movement overlay position and width |
| Seer / Corruption | Heal priority, healing style, friendly target types, cleanse choices, action feed, shields, recovery, group-heal threshold, cast-target lines, and each idle-DPS action |

Seer / Corruption defaults to `Incoming Damage Formula`, `Balanced`, and `All Friendlies`. Automatic Force Mend / Unnatural Preservation is on by default at 75% HP. Idle DPS is enabled by default but remains behind healing and the configured Force reserve.

## Package contents

```text
live/sage.lua
common/sage/balance.lua
common/sage/force_optimizer.lua
common/sage/healing_scheduler.lua
common/sage/mirror.lua
common/sage/seer.lua
common/sage/telekinetics.lua
```

This package depends on **gos-common** for combat helpers and pressure calculations and **gos-ui** for the shared Seer/Corruption action feed. Sorcerer display and event names retain the canonical Sage ability identity. Keep the release folders together instead of copying only `live/sage.lua`.

## Limits

- It stays inactive when the current combat style, discipline, or required loadout data does not match.
- A Madness loadout that replaces Lightning Strike with the still-unconfirmed Sorcerer counterpart of Destructive Wave stays inactive until that exact live name is confirmed.
- Corruption recognizes the shared Force Mobility name. It does not assume an unconfirmed counterpart for Telekinetic Regeneration, so that optional downtime-recovery branch stays unavailable.
- Damage routes require a usable selected hostile target.
- Seer / Corruption healing and cleanse actions only use friendly units and effects that the route can identify from current data. Optional idle DPS uses the selected hostile target.
- Missing position, effect, cooldown, or combat-event data can leave a branch inactive instead of guessing.
- Core still has the final say on every cast request.
