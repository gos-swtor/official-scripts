# GoS Common

[Back to all scripts](../../README.md)

GoS Common is the shared Lua package used by the official combat routines. It is not a standalone script and has no entry file. Core installs the exact version requested by a routine.

Users normally do not install or enable this package themselves.

## Included modules

| Module | Purpose |
| --- | --- |
| `combat/ability_executor.lua` | Owns one submitted ability command, follows its Core lifecycle, avoids duplicate submissions, and handles allowed replacement or cancellation. |
| `combat/cleanse.lua` | Chooses known cleansable effects from the shared catalog and returns a cleanse decision to the calling routine. |
| `combat/cleanse_db.lua` | Stores exact effect identities, dispel categories, exclusions, and supporting catalog metadata. |
| `combat/combat_events.lua` | Polls `gos.events.combat` once and dispatches matching events for the player, current target, or friendly allies. |
| `combat/pressure_tracker.lua` | Builds short damage and healing histories for healer priorities and Telekinetics self-pressure decisions. |
| `combat/interrupt.lua` | Evaluates recognized hostile casts and returns an interrupt candidate to the calling routine. |
| `combat/interrupt_db.lua` | Stores the recognized cast names, priorities, class restrictions, and interrupt immunity rules. |
| `combat/pressure_formula.lua` | Provides class-neutral health and incoming-damage scoring for supported routines and offline checks. |

## Combat events

The `combat_events` module gives scripts a small target-scoped wrapper around `gos.events.combat`:

```lua
local Combat = require("combat.combat_events")

Combat.on_player("damage", function(event)
    gos.log.info("player took " .. tostring(event.effective_amount or 0))
end)

Combat.on_current_target("heal", function(event)
    gos.log.info("current target was healed")
end)

Combat.on_ally("ability", function(event)
    gos.log.info("friendly ability: " .. tostring(event.name or "unknown"))
end)
```

The module starts polling when the first handler is registered. It keeps one cursor, reports dropped events, and catches a handler error so one callback does not prevent the rest from running. It processes one Core batch per tick, so a busy stream can take several ticks to catch up. `on_ally` only dispatches to a resolved friendly unit other than the local player.

Handlers may subscribe to an event `kind`, such as `damage` or `heal`, or to a distinct event `action` reported by Core.

## Shared combat decisions

`cleanse` and `interrupt` inspect current snapshots and return a candidate to the calling routine. They do not own a top-level tick or a second ability executor. Their catalogs use exact effect identities or normalized cast names and stop when required observations are unavailable.

The pressure modules keep short histories of recent damage and known healing-over-time events. They support healer priorities and Telekinetics self-pressure decisions. They reset after dropped combat events instead of treating an incomplete history as current evidence.

Actor labels and action-feed presentation belong to [GoS UI](../gos-ui/). `combat.ability_executor` follows one submitted Core command through its lifecycle and prevents the calling route from stacking unrelated commands on top of it.

## Ownership rules

These modules do not create their own top-level combat routine. The calling script owns its tick flow and its single `AbilityExecutor`, then passes prepared state into the shared helper.

Each consumer pins one exact GoS Common version in its manifest. Core refuses a combination that asks for two different versions at the same time. This keeps one shared copy of each module in the active `common` folder.

## For contributors

A change here can affect several routines. Check every package that imports the changed module and publish compatible consumer versions with a new GoS Common version. Core can prepare their linked update as one transaction; incompatible published latest versions are rejected.

Do not copy these modules into each routine. Keeping one shared package prevents fixes from drifting between several slightly different copies.
