---
name: queens-domain-mod
description: Resume work on BadBad Mod for Queen's Domain. Use for UE4SS Lua features, native Video menu previews, graphics and HUD changes, save mechanics, in-game verification, local playtest packaging, or a requested release.
argument-hint: "[feature, bug, playtest, or release task]"
---

# Working on BadBad Mod

If invoked without a task, orient the user: report the actual branch, latest local tag, uncommitted work, and where the relevant source lives. Do not make changes just to resume context. With a task, use the workflow below. No previous chat or global memory is required.

## Orient before editing

1. Find the checkout. The usual workspace is `gameproject`, **not** a Git repository; the checkout is its child `queens-domain-badbad-mod`. Sometimes the checkout itself is the workspace. Verify with `git rev-parse --show-toplevel` there.
2. Run `git --no-pager status --short --branch`, `git --no-pager log -3 --oneline --decorate`, and `git describe --tags --abbrev=0`. Read the current [README](../../../README.md), [feature settings](../../../features.ini), and relevant source/test pair. Preserve other edits, particularly the user's README wording. The current checkout and request take precedence over this historical handoff.
3. Baseline when this skill was written: mod **v1.3.0** (`fb704b1`, PR #3), Windows game **1.01.07**, Unreal **4.27**, official **UE4SS 4.0.0**, Lua **5.4**. Verify before claiming a newer patch works. The mod is Lua-only: no companion PAK, Python, or other runtime dependency.
4. Read [feature decisions and engine findings](references/feature-notes.md) for the feature being changed. Use [playtesting and releases](references/playtesting.md) before touching an install, verifying a visual, or packaging. Keep player documentation short; these references are for developers, not the mod ZIP.

## Where to work

| Task | Start here |
| --- | --- |
| Module loading, hooks, world resets | [main.lua](../../../Scripts/main.lua) |
| Settings, mode persistence, focus, section heading | [options.lua](../../../Scripts/options.lua), [features.ini](../../../features.ini), [options test](../../../tests/options.lua) |
| Right-hand Video previews and explanatory panels | [videopreview.lua](../../../Scripts/videopreview.lua) |
| Graphics preset, screen percentage, ultrawide | [graphics.lua](../../../Scripts/graphics.lua), [features.ini](../../../features.ini), [widescreen.lua](../../../Scripts/widescreen.lua) |
| Pickup effects and preview herb | [shimmer.lua](../../../Scripts/shimmer.lua) |
| HP bars, damage, status label positions | [monsterhealthbar.lua](../../../Scripts/monsterhealthbar.lua), [statusnames.lua](../../../Scripts/statusnames.lua) |
| Item calculations, native inventory rows, drag to equip | [itemstats.lua](../../../Scripts/itemstats.lua), [iteminfo.lua](../../../Scripts/iteminfo.lua), [drag.lua](../../../Scripts/drag.lua) |
| Travel Stride, private quick save/load | [travelstride.lua](../../../Scripts/travelstride.lua), [quicksave.lua](../../../Scripts/quicksave.lua) |

## Working agreement

- Prefer the game's own art, controls, fonts, balance data, and mechanics. Keep source readable: descriptive names and a short module-purpose comment. Use one player-facing README; avoid repeated branding and redundant instructions.
- Reproduce the specific problem. For UI and rendering, a successful hook, `IsValid()`, a visibility flag, or a mock test does **not** prove that the player can see it. Check rendered pixels, layout, or motion in the game.
- If a local playable change is requested, refresh the installed files and the existing playtest ZIP after validation. Keep the user's settings. If the game is in use, don't close it; use offline checks and report what still needs an in-game pass.
- No old instruction to push, manipulate saves, or bypass protections carries into a new session. Keep local experiments local unless the current request authorizes publication. Report what actually changed, what was verified, and where to try it.
