# GoS UI

[Back to all scripts](../../README.md)

GoS UI is a shared presentation dependency. Core installs the exact version requested by a script. It has no entry script and does not appear as a separate Script Library card.

| Module | Purpose |
| --- | --- |
| `common/ui/actor_labels.lua` | Keeps bounded actor display labels from Core name metadata. |
| `common/ui/healer_action_window.lua` | Shows accepted actions, procs and observed healing/damage for Operative, Commando and Sage/Sorcerer. |

Each script owns its window and label-registry state. The module does not cast abilities or own an executor. Sorcerer action names are displayed and matched against events while canonical identities keep group-heal and protection rules intact.

Modules load with `require("ui.actor_labels")` and `require("ui.healer_action_window")`. Window settings and overlay IDs remain owned by their calling script.
