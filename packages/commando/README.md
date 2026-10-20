# Commando / Mercenary

[Back to all scripts](../../README.md)

This package provides one hold-to-run routine for **Commando** and **Mercenary**. It selects a route from the current loadout, covering **Gunnery / Arsenal**, **Assault Specialist / Innovative Ordnance**, and **Combat Medic / Bodyguard**.

The mirror module resolves Mercenary abilities, effects, talents and procs, and converts Heat for the shared resource checks. Ability names below use Commando names. An unsupported style or incomplete loadout leaves the route idle.

## Quick start

1. Install this package from the Script Library. Core installs the required `gos-common` and `gos-ui` versions with it.
2. Reload Lua in GoS:SWTOR Core and enable **Commando**.
3. Select the matching Commando or Mercenary discipline.
4. Hold the **Rotation Key**. Its default is Mouse 4.

The routine only submits actions that are known in the current loadout. Core still decides whether a cast is legal at that moment, including target state, range, line of sight, cost, cast state, and the global cooldown.

## What each discipline does

### Gunnery

Gunnery works from the selected hostile target. It uses observed Gravity Vortex, Charged Barrel, Grav Primer, and other effects before taking the branches that need them. It has a target-centered AoE count, resource limits for paid attacks and channels, and configurable High Impact Bolt stack targets.

It can use Recharge Cells and High Velocity Supercharged Cell when their configured conditions are met. Personal recovery and defensive options are available, but several are off by default so you can keep control of their timing. Long control and movement tools use optional hotkeys instead of being fired automatically.

### Assault Specialist

Assault Specialist maintains its damage effects and spends only effects that the script has actually observed. The route has separate reserves for priority attacks and fillers, plus its own Recharge Cells, Supercharged Cell, Electro Net, Sticky Grenade, and self-heal controls.

Its self-heal path can use Bacta Infusion, an observed Tech Override for Medical Probe, and Med Shot. It does not hard-cast Medical Probe for this path.

### Combat Medic

Combat Medic chooses from eligible friendly players, companions, or friendly NPCs according to the healing-target setting. It handles focused healing, group healing, Trauma Probe maintenance, emergency self-protection, Recharge Cells, and Supercharged Kolto Cell.

Its optional action feed shows accepted actions, observed proc labels, and reported healing or damage amounts. Use `[=]` to move it and `X` to hide it; the settings can restore it and adjust its rows, text size, and message lifetime.

#### Incoming Damage Formula (IDF)

Combat Medic can use the shared **Incoming Damage Formula** instead of sorting only by current HP. IDF combines current health with recent incoming damage, short-term and sustained pressure, attacker persistence, observed HoT carry, projected HP over roughly two and four seconds, and estimated time-to-die. This lets the healer react to a target that is still relatively healthy but is collapsing faster than the current lowest-HP player.

IDF assigns a pressure band from routine to emergency. The most urgent bands can promote stronger rescue actions and relax the normal energy reserve before raw HP alone would have crossed the same threshold. Current HP, Energy, cooldowns, effects, and Supercharge stacks are still live observations; forecasts never replace missing game state or bypass Core cast admission.

A useful live stress test was recorded on **Cademimu 4-player Master** on September 21, 2026. In one approximately 64-second pull the group fought **22 distinct enemy instances** and had **zero player deaths**. Two teammates fell as low as **5.38%** and **6.22% HP** before recovering. The Combat Medic, running r21 with IDF in green gear around item rating 325, produced about **1.36 million effective healing** while the group took about **2.77 million logged damage**. The fight included repeated AMP, Successive Treatment, Kolto Bomb, Medical Probe, Bacta Infusion, Trauma Probe, and two Supercharged Kolto Cell windows. This is strong real-fight evidence that the current policy can recover severe multi-target pressure; it is not proof that IDF alone caused the survival, because teammate defensives, self-healing, avoidance, and encounter execution also contributed.

Healing downtime can be configured to allow selected-target damage, but healing needs, resource reserves, and pending commands come first. Free Attacks Only is on by default, so paid damage is blocked until you disable it. The Full Auto option is enabled, but it still obeys that free-attacks gate. Electro Net starts disabled to leave its timing with the player.

## Important settings

The settings card changes with the selected discipline. The useful groups are:

| Discipline | Settings |
| --- | --- |
| All routes | Rotation Key, Enable Diagnostics / Logging, cast log, and decision log |
| Gunnery | Ability queue window, Energy floor, Recharge Cells, AoE count and radius, High Impact Bolt stacks, emergency self-heals and optional defensive automation |
| Assault Specialist | Incendiary Round refresh, priority and filler reserves, Recharge Cells, Supercharged Cell, Hyper Assault Rounds, Sticky Grenade, Electro Net, self-heal thresholds |
| Combat Medic | Healing style and targets, heal and emergency thresholds, energy reserves, Trauma Probe, group healing, Supercharged Kolto Cell, self-survival, cleanse, safe-downtime DPS, and action feed |

**Enable Diagnostics / Logging** is off by default. Turn it on before enabling individual cast, decision, ability, healing, or cleanse diagnostics. The action feed is a separate display setting.

`Automatic AoE` counts hostiles around the selected target when position data is available. If it is not available, the script uses `Relevant Targets` instead.

This release does not include the standalone Stealth Detector package or its automatic reveal feature.

## Package contents

```text
live/commando.lua
common/commando/assault_specialist.lua
common/commando/cleanse.lua
common/commando/combat_medic.lua
common/commando/gunnery_kit.lua
common/commando/mirror.lua
```

This package depends on **gos-common** for combat helpers and pressure calculations and **gos-ui** for the healer action feed and actor labels. Keep the release folders together instead of copying only `live/commando.lua`.

## Limits

- The script supports Commando and Mercenary; other combat styles remain unsupported.
- It does nothing until the selected discipline and known abilities are available from the loadout.
- A hostile target is required for the damage routes. Personal defensive and healing actions may still run without one.
- Target counts, effect checks, and cast requests are skipped when the needed live data is unavailable.
- Core owns final cast admission. A queued action can still be rejected by the current game state.
