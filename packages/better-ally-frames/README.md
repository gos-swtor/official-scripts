# Better Ally Frames

[Back to all scripts](../../README.md)

Better Ally Frames adds a compact panel for friendly players, companions, and NPCs. Each frame shows current health, can show the unit's resource and distance, and can be clicked to select that unit in game.

It is a display and targeting helper. It does not cast abilities or control a combat routine.

## What it shows

- Up to 32 friendly frames from the current world snapshot
- Health values, health percentage, and a clear dead state
- Optional resource bars with colors for Force, energy, rage, heat, and other resource types
- Optional distance in metres
- A cyan highlight for the current target
- Dimmed frames for units beyond your configured range
- Separate colors for companions and friendly NPCs

You can sort the list by group and name, distance, health percentage, or name.

## Using the frames

Click a frame to select that unit. The frame shows a short pending state while Core handles the selection request.

Drag the title bar to move the panel. The saved X and Y settings update after the drag ends. The button in the title bar minimizes the panel, and the show or hide hotkey defaults to `F6`.

## Settings

| Setting | Purpose |
| --- | --- |
| Visible | Shows or hides the full panel. |
| Show / Hide Hotkey | Toggles the panel without disabling the script. |
| Minimized | Leaves only the title bar visible. |
| Sort Frames | Chooses how friendly units are ordered. |
| Out-of-Range Opacity | Controls how much distant frames are dimmed. |
| Range (metres) | Sets the distance used for the dimmed state. |
| Position X / Position Y | Sets the panel position. Dragging updates these values. |
| Columns | Sets the number of frames per row. |
| Frame Width / Frame Height | Changes the size of each frame. |
| Show Self | Includes your own character. |
| Show Players | Includes other friendly players. |
| Show Companions | Includes friendly companions. |
| Show Ally NPCs | Includes other friendly NPCs. |
| Show Distance | Adds rounded distance beside the name. |
| Show Resource Bar | Adds the resource bar when Core has a resource snapshot. |

## Package contents

This package owns `live/better_ally_frames.lua`. It has no shared package dependency.

## Notes

- Missing health, resource, name, or distance data is shown as unavailable instead of being guessed.
- Units outside the configured range remain visible. They are dimmed rather than removed.
- Buff and debuff icons are not part of the current frame layout.
