# GoS Assets

[Back to all scripts](../../README.md)

GoS Assets owns the shared SWTOR sprites used by Operative, PvP Sense and Crowd Control Viewer. Core installs the exact version requested by a script. It has no Lua entry and does not appear as a separate Script Library card.

All 143 DDS paths live under `sprites/swtor`. Scripts continue to use `SPRITE_PATH .. "swtor\\"`; their runtime paths are unchanged. Each asset path has one package owner.

A changed asset needs a new immutable package version and compatible dependency versions in its consumers. Keeping assets separate lets icon releases remain independent of combat and presentation modules.
