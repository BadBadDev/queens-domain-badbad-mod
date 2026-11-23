# BadBad Mod (BBM) for Queen's Domain

**v1.0.0** · Tested with Queen's Domain **1.01.07** on Windows and [UE4SS v4.0.0](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) · [Installation](#install-or-remove)

## Features

| Feature | How it works |
| --- | --- |
| **Graphics** | Native resolution, temporal anti-aliasing and 16x anisotropic filtering, without retro pixel filtering or dithering. Your saved video preferences stay intact. |
| **Pickup shimmer** | **Low** gives nearby items a subtle pulse; **Medium** strengthens it; **High** adds a short, pale-gold beam. |
| **HP and damage numbers** | Bars show current/max HP. Above enemy and boss bars, the name stays on the left and the last hit flashes on the right of the same row. |
| **Drag to equip** | In **Status & Inventory**, drag a weapon, throwable or charm onto a compatible slot. Normal equip rules and click controls still apply. |
| **Item stats** | Beneath the lore, weapons list Attack and base stamina recovery time; throwables list Attack and Return time. Buffs show their effects and remedies say what they cure. |
| **Healing bonus** | The status screen shows your healing bonus as a percentage; herbs and potions show the extra HP they restore. |
| **Status effect names** | Active effects stack above the usable-item icon at the bottom left. Names disappear as each effect ends. |
| **Widescreen** | The camera, HP/stamina, compass and usable-item icon adapt to the viewport. Status borders such as Poison expand to the edges on ultrawide. |

### Reading the numbers (Examples)

- **Primary Attack `15 (+20%) = 18`**: the weapon's level adds 20% to its base Attack. This isn't a damage prediction for a particular enemy.
- **Heals: `20 (+4)`**: 20 base HP plus 4 from your healing bonus, capped at your missing HP.
- **Return `5 s`**: the throwable is ready again in five seconds.

## Changing settings

Open **Options > Video** and scroll to the rows labeled **BBM**.

Feature switches take effect after restarting the game; shimmer strength changes immediately.

To edit settings with the game closed:

- [features.ini](features.ini): `1` enables a feature; `0` disables it.
- `shimmer.txt`: `low` (default), `medium`, or `high`.
- [config.lua](Scripts/config.lua): `screenPercentage` sets internal render resolution (`100` is native); `damageSeconds` sets how long the last hit stays visible.

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

Pull requests run a Lua 5.4 syntax check, Luacheck, StyLua in check-only mode, and [automated Lua tests](tests/bbm.lua). Run all tests from the repository root with `lua5.4 tests/bbm.lua`, or run a single feature test, such as `lua5.4 tests/widescreen.lua`. No game or UE4SS installation is needed.

## TODO (not yet implemented)

- [ ] **Quick save:** verify what Alt+F4 saves and restores before reusing that routine without quitting.
- [ ] **Faster exploration:** check for a reliable combat flag before increasing out-of-combat running speed. Restore normal speed when combat starts.
