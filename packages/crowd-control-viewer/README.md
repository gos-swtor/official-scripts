# Crowd Control Viewer

[Back to all scripts](../../README.md)

Crowd Control Viewer draws recognized crowd control effects above the units they affect. Each effect is shown with its SWTOR icon and a live remaining-time label, so you can see who is stunned, mezzed, rooted, or otherwise locked down without changing targets.

The viewer is display only. It does not cast, select targets, or alter a combat routine.

## What it tracks

- Timed crowd control debuffs recognized by the script's effect and icon catalog
- Friendly, hostile, neutral, and self layers with separate switches
- Multiple effects on one unit, up to the configured icon limit
- Last-known effects while Core is refreshing that unit's effect snapshot

Last-known icons are drawn with reduced opacity. The remaining time continues to count down from the last completed observation and disappears when it is no longer useful.

## Preview mode

Enable **Preview - Test Mode** to cycle sample crowd control icons over scanned units. Core clips anything that is off screen. This is useful for checking icon size, spacing, and vertical placement without waiting for a live effect.

## Settings

| Setting | Purpose |
| --- | --- |
| CC Viewer - Enabled | Master switch for the viewer. |
| Preview - Test Mode | Draws rotating sample icons. |
| Awareness - Crowd Control | Enables recognized crowd control effects. |
| Targets - Friendly | Includes friendly units. |
| Targets - Hostile | Includes hostile units. |
| Targets - Neutral | Includes neutral units. |
| Targets - Self | Includes your own character. |
| Limits - Max Units | Bounds the number of units checked after distance sorting. |
| Limits - CC Icons per Unit | Sets the maximum icons drawn above one unit. |
| Limits - Max Distance | Sets the scan distance. Zero means unlimited. |
| CC - Icon Size | Changes icon size in screen pixels. |
| CC - Y Offset | Moves the icon row above or below its default position. |

## Package contents

The package owns `live/crowd_control_viewer.lua`. Its **gos-assets** dependency owns the SWTOR icons, installed into the shared sprite directory.

## Notes

- An effect needs a recognized name and icon mapping before it can be drawn.
- The current target remains eligible even when its normal friendly, hostile, or neutral layer is disabled.
- Hard limits on units, icons, and draw commands keep the viewer under control during large fights.
- Effects come from Core's completed snapshots. While a refresh is pending, the viewer keeps the last completed result.
