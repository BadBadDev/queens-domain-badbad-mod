# BadBad Mod (BBM) for Queen's Domain

I made BadBad Mod for the way I like to play Queen's Domain. It brings together my own quality-of-life tweaks and features I liked from other mods. I'm sharing it in case you like playing this way too. 🙂

**v1.2.0** · Tested with Queen's Domain **1.01.07** on Windows and [UE4SS v4.0.0](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) · [Installation](#install-or-remove)

## Features

| Feature | How it works |
| --- | --- |
| **Graphics** | Native resolution, temporal anti-aliasing and 16x anisotropic filtering, without retro pixel filtering or dithering. Your saved video preferences stay intact. |
| **Pickup shimmer** | **Low** gives nearby items a subtle pulse; **Medium** (default) strengthens it; **High** adds a short, pale-gold beam; **Over Here!** is just for the lols |
| **HP and damage numbers** | Bars show current/max HP. Above enemy and boss bars, the name stays on the left and the last hit flashes on the right of the same row. |
| **Drag to equip** | In **Status & Inventory**, drag a weapon, throwable or charm onto a compatible slot. Normal equip rules and click controls still apply. |
| **Item stats** | Beneath the lore, weapons list Attack and base stamina recovery time; throwables list Attack and Return time. Buffs show their effects and remedies say what they cure. |
| **Healing bonus** | The status screen shows your healing bonus as a percentage; herbs and potions show the extra HP they restore. |
| **Status effect names** | Active effects stack above the usable-item icon at the bottom left. Names disappear as each effect ends. |
| **Widescreen** | The camera, HP/stamina, compass and usable-item icon adapt to the viewport. Status borders such as Poison expand to the edges on ultrawide. |
| **[Quick Save / Load](#quick-save--load)** | **F5** saves your progress separately for the current slot. **F9** reloads it without quitting, even if the game has made a newer recovery save. |
| **Travel Stride** | **Off by default** for players who prefer the game's original pace. If you want faster exploration and backtracking, turn it on in **Options > Video** and restart. After 8 seconds out of combat, ground speed increases by 25% and sword dashes recharge twice as fast. Jumping or stepping off a ledge removes the extra speed while in the air (preventing sequence breaking by using longer jumps). Enemy aggro or a combat hit removes the buff and restarts the timer. |

### Reading the numbers (Examples)

- **Primary Attack `15 (+20%) = 18`**: the weapon's level adds 20% to its base Attack. This isn't a damage prediction for a particular enemy.
- **Heals: `20 (+4)`**: 20 base HP plus 4 from your healing bonus, capped at your missing HP.
- **Return `5 s`**: the throwable is ready again in five seconds.

## Changing settings

Open **Options > Video** and scroll to the rows labeled **BBM**.

Feature switches take effect after restarting the game; shimmer strength changes immediately.

## Quick Save / Load

Save at a **Crystal Monument** at least once in the current save slot. Then use these keys during gameplay:

| Key | Action |
| --- | --- |
| **F5** | Pin your current progression and the game's last safe, walkable position. Wait for **Quick saved** before moving on. |
| **F9** | Discard progress since F5 and reload the quick-save. |

This restores saved progress, **not a fight in motion**: enemies, projectiles and moving platforms can reset. Use F9 in the same persistent map, not from the title or death screen. Menus, cutscenes, pickups, teleports and the game's save restrictions can block a request; the on-screen message or `ue4ss\UE4SS.log` gives details on erros.

Quicksaves don't overwrite your monument or recovery files. Each slot keeps `BBM_Quick_World<N>.sav` and one previous copy (`.sav.prev`) beside `World<N>.sav`. If you delete a character and reuse its save slot number, delete both of its quicksave files too. Back up your saves before first use and disable any other mod bound to F5 or F9.

## Install or remove

1. Download [UE4SS v4.0.0](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) (`UE4SS_v4.0.0.zip`).
2. Extract `dwmapi.dll` and the `ue4ss` folder into `QueensDomain\Binaries\Win64`, beside `QueensDomain-Win64-Shipping.exe`. If v4.0.0 is already installed, skip this step.
3. Download [BadBadMod.zip from the latest release](https://github.com/BadBadDev/queens-domain-badbad-mod/releases/latest/download/BadBadMod.zip) and extract it into `ue4ss\Mods`. If updating, keep your `features.ini` to preserve your switches.
4. Keep the bundled `BadBadMod\enabled.txt` file, or add `BadBadMod : 1` in `ue4ss\Mods\mods.txt`. Either method enables the mod. Launch the game and look for the settings under **Options > Video**.

To uninstall, delete the `BadBadMod` folder.

## Finding the code

- [widescreen.lua](Scripts/widescreen.lua) handles the gameplay camera and HUD edges.
- [monsterhealthbar.lua](Scripts/monsterhealthbar.lua) draws player HP and the enemy/boss HP and damage readouts.
- [iteminfo.lua](Scripts/iteminfo.lua) builds inventory widgets; [itemstats.lua](Scripts/itemstats.lua) calculates and formats the values they display.

Pull requests into `main` must pass **Lua quality gate**: Lua 5.4 syntax, Luacheck (no warnings or errors), StyLua formatting, and [automated Lua tests](tests/bbm.lua). Run all tests from the repository root with `lua5.4 tests/bbm.lua`, or a single feature test with `lua5.4 tests/widescreen.lua`. No game or UE4SS installation is needed.
