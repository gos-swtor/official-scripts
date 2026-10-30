# Operative / Scoundrel

[Back to all scripts](../../README.md)

One GoS:SWTOR Core script for the three Operative disciplines and their Scoundrel counterparts. It reads the live loadout and uses only abilities and choices that the current character actually has.

## Supported disciplines

| Discipline | Coverage |
| --- | --- |
| Concealment / Scrapper | Damage route through level 47 |
| Lethality / Ruffian | Damage route through level 80 |
| Medicine / Sawbones | Healing route through level 80 |

The entry script recognizes both combat styles. Its mirror module resolves Scoundrel abilities, effects, procs and talents while retaining the original Operative detection paths. Ability names below use the Operative names; Scoundrel uses the matching counterpart abilities and Upper Hand.

## Quick start

1. Install the Operative package from the Script Library. Core installs its GoS Common, GoS UI, and GoS Assets dependencies.
2. Keep the package's `live`, `common`, and `sprites` paths intact.
3. Reload Lua in GoS:SWTOR Core, enable **Operative**, and choose the correct character discipline.
4. Hold the Rotation Key to run the combat route. Its default binding is Mouse 4.
5. Open the script settings card to adjust only the features you want enabled. Settings that need a particular ability appear after that ability is known.

The damage and healing routes need a ready Operative or Scoundrel loadout. If the class, discipline, or required live data does not match, the route waits instead of guessing.

## What it does

### Concealment and Lethality

Both damage routes work from the selected hostile target. They manage learned attacks, Energy, Tactical Advantage, DoTs, AoE decisions, and the selected discipline choices. Lethality has its own level 80 route. Concealment has a progressive route through level 47.

The shared DPS self-healing option can keep two Kolto Probe stacks on yourself and use Kolto Infusion when its rules allow it. By default it is limited to PvP context, keeps normal damage ahead of routine recovery, and does not use a regular Infusion while moving. Lethality can use an observed Quickening proc for its free instant heal.

Optional self Shield Probe is available for both DPS disciplines. Evasion, Cloaking Screen, and other major defensive or crowd-control choices stay in your hands.

### Medicine

Medicine chooses a friendly patient from the configured target group and sends friendly casts to that exact unit. It can prioritize current health or recent incoming damage, then uses the learned healing kit as it becomes available. This includes Kolto Probe maintenance, direct heals, Surgical Probe, Recuperative Nanotech, Kolto Waves, and group healing windows when enough injured allies are in range.

#### Medicine changes in 1.0.1

| Decision | Before | Now |
| --- | --- | --- |
| An isolated injured patient, including yourself | A patient around 71% could wait while Medicine built or refreshed HoTs on healthier teammates, or set up the patient's missing Probe stacks. | Direct healing takes priority within the selected style's rescue band, before missing Probe setup or healthier teammates' HoT upkeep. |
| Several injured allies | Starting new HoTs could delay Nanotech and Kolto Waves. | Established HoTs retain upkeep; Nanotech and Waves get an opportunity before fresh HoT seeding when their group conditions are met. |
| Group-healing Energy | Routine group healing could leave less Energy available for the next rescue. | Routine group heals preserve an Energy reserve, and Waves budgets its full channel. Emergency healing can still use the reserve. |
| A pending HoT request when another patient becomes endangered | An unaccepted maintenance request could be retried before checking the new patient's urgency. | Medicine checks current patients before retrying off-patient maintenance. Already accepted casts retain their command ownership. |

The rescue bands use the existing healing styles: Safe 82%, Balanced 80%, or Efficient 66%. An isolated quiet 71% patient therefore has direct-rescue priority in Balanced and Safe; Efficient keeps its lower rescue band.

Routine Waves use needs enough injured allies in range, a stationary healer, and enough Energy for its full channel. Standing still does not force a cast-time heal: movement, available Tactical Advantage, and observed procs still influence the choice between instant and cast-time healing.

You can limit healing to players, include companions, or include all friendlies. By default, it maintains two Kolto Probe stacks on eligible visible friendlies within 30m. Turn off **Medicine Probe Everyone** to use the smaller configurable roster instead.

Medicine can also cleanse through the shared cleanse module, use Shield Probe on itself, use Resuscitation Probe when a proven-dead friendly player is eligible and no living ally needs urgent help, and fill quiet moments with optional DPS. Game and encounter restrictions still decide whether a battle rez is allowed.

The optional Medicine action feed shows accepted actions, observed proc labels, and reported healing or damage amounts. Use its `[=]` handle to move it and `X` to hide it; the settings can restore it and adjust its rows, text size, and message lifetime.

### Shared extras

- **Auto Stealth** can enter Stealth while out of combat, either always or only while the Rotation Key is held.
- **Stealth Detection Awareness** attaches observed hostile detector icons to the target's current world origin through Core's PointSpec API. **Stealth Icon Height (m)** defaults to 2 m; icon size stays in pixels. Camera projection keeps placement attached without nameplate-distance formulas or CC-row reservations. It can show an optional range ring on the selected detector when that catalog entry has a known radius. A detector with an unverified radius still gets its icon but no ring. This display works independently of the combat key and requires the matching Core spatial-drawing API.
- **Cursor Holotraverse** is a separate hotkey for all three disciplines, default Shift+V. Hold the configured chord, point near an eligible on-screen unit, and it attempts Holotraverse to that exact candidate. The preview marker does not prove line of sight.
- Shared interrupt and cleanse settings are included through GoS Common. They are optional and use their own settings groups.

## Settings worth checking

The settings card has the full list. These are the ones most people will want to set first.

| Area | Main controls |
| --- | --- |
| General | Rotation Key, Ability Queue Window, Auto Stim Boost, Auto Adrenaline Probe and its Energy threshold |
| DPS | Energy Floor, Automatic AoE, target-count method, AoE minimum targets, and cluster radius |
| DPS self-healing | Enable per discipline, PvP-only gate, health thresholds, Kolto Probe refresh, Energy reserves, and Lethality Quickening options |
| Concealment | Tactical selection, optional PvP AoE, Shield Probe threshold, Tactical Overdrive, and Crippling Slice/Throw options |
| Lethality | Tactical selection, poison refresh windows, Toxic Blast, single-target PvE Toxic Haze, Shield Probe, Tactical Superiority, and Tactical Overdrive |
| Medicine | Heal priority, Safe/Balanced/Efficient style, friendly target group, Probe roster, group-heal ally counts, Shield Probe, battle rez, idle DPS, and action feed |
| Movement and awareness | Auto Stealth, Cursor Holotraverse hotkey/filter/radius, and stealth-detector icon distance, size, ring, and vertical offset |
| Logs | Cast Log, Decision Log, and Ability Diagnostics are off by default. Enable them when you need to inspect behavior. |

## Package contents and dependency

The package entry point is `live/operative.lua`. Its class modules cover the mirrored disciplines, self-healing, cursor Holotraverse, route helpers, and detector awareness. `common/operative/mirror.lua` maps counterpart names. Its awareness overlay uses three icons provided by GoS Assets; it is independent of the excluded standalone Stealth Detector package.

It depends on **gos-common** for combat helpers and pressure calculations, **gos-ui** for the action feed and actor labels, and **gos-assets** for detector icons. Core installs the exact declared versions. Do not copy only `live/operative.lua` into a script folder.

## Limits and notes

- The route follows the selected live Operative or Scoundrel discipline.
- Concealment coverage currently ends at level 47. Lethality and Medicine are the level 80 routes.
- DPS actions use the selected hostile target. Medicine selects legal friendly patients within its configured group.
- A missing ability, effect, target, range, or loadout observation can make a branch wait until the needed data is available.
- Automatic PvP AoE for Concealment is off by default, since it can break crowd control.
- Cursor Holotraverse needs a learned Holotraverse ability and Core cursor support. Releasing its hotkey stops new attempts, though a command that was already submitted may finish.
- This README describes package behavior from the current Lua source. It is not a substitute for checking your own loadout, bindings, encounter rules, or game restrictions.
