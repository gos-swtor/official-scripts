# GoS:SWTOR Official Scripts

This repository contains the scripts shown in the GoS:SWTOR Official Script Library. Core reads the official catalog from this repository, downloads the files for the version you choose, checks every file, and installs the package into your active script folder.

Use the Script Library inside Core for installation and updates. The folders here are also useful when you want to read the code or review a change before installing it.

## Scripts

| Package | What it is for |
| --- | --- |
| [Operative / Scoundrel](packages/operative/) | Concealment / Scrapper, Lethality / Ruffian, and Medicine / Sawbones routines. |
| [Commando / Mercenary](packages/commando/) | Gunnery / Arsenal, Assault Specialist / Innovative Ordnance, and Combat Medic / Bodyguard routines. |
| [Sage / Sorcerer](packages/sage/) | Telekinetics / Lightning, Balance / Madness, and Seer / Corruption routines. |
| [PvP Sense](packages/pvp-sense/) | Player cooldowns, response cues, objective interactions, and a clickable hostile roster. |
| [Combat Meter](packages/combat-meter/) | Live damage, healing, DPS, HPS, and incoming damage tracking. |
| [Combat Events for Lua](packages/gos-common/#combat-events) | Target-scoped event handlers provided by the shared package. |
| [Crowd Control Viewer](packages/crowd-control-viewer/) | Crowd control icons and countdowns above affected units. |
| [Better Ally Frames](packages/better-ally-frames/) | Compact, clickable frames for friendly players, companions, and NPCs. |

Shared dependencies are [`gos-common`](packages/gos-common/) for combat helpers, [`gos-ui`](packages/gos-ui/) for actor labels and action feeds, and [`gos-assets`](packages/gos-assets/) for sprites. Core installs the exact versions a script requests. These packages have no entry script and do not appear as separate cards.

## Installing a script

1. Open the Official Script Library in GoS:SWTOR Core.
2. Press **Refresh**.
3. Pick a version and press **Install**.
4. Enable the script from the Scripts page.
5. Core reloads Lua automatically after a successful installation.

Use the current Core for automatic updates of enabled scripts. Core waits for the
current native command, pauses Lua and reloads all enabled scripts together.
Settings and enabled states are preserved; failed updates restore the previous
files and preferences. Locally edited official files block replacement.

## Versions

Each package has its own version history. Published version folders are never changed after release. A fix or behavior change is published as a new version, and older versions remain available from the version selector in Core.

Shared packages are versioned separately. A script manifest names the exact versions it uses, and Core installs those dependencies with the script. When a shared update also needs compatible versions of other installed scripts, Core shows the linked version plan in the same list. Review it and press **Apply plan** to install the group in one transaction. An incompatible latest consumer blocks the plan instead of silently selecting another version.

## Temporary Library QA

[`Library QA A`](packages/library-qa-a/) and [`Library QA B`](packages/library-qa-b/)
are inert release tests. Version 1.0.0 displays a version label and saved marker,
logs startup once, and has no dependencies or gameplay actions. Install and enable
both, set different markers, and inspect their changelogs before the next test wave.

## Contributing

Pull requests are welcome. User-facing behavior changes should update the package README and changelog alongside the Lua change. Official releases are exported from the GoS:SWTOR development repository, so an accepted change is carried back to that source before the next package version is published.

Please do not edit files inside an existing version folder and present them as the same release. Once a version is published, its files do not change.
