# Playtesting, packaging and release

## Local layout

From the **parent workspace** on the original Windows machine:

| Relative path | Purpose |
| --- | --- |
| `queens-domain-badbad-mod\` | Git checkout; edit source here, not only in the install |
| `.venv\Scripts\python.exe` | Existing test interpreter with `lupa.lua54` and Pillow; reuse it |
| `QueensDomain\QueensDomain\Binaries\Win64\` | `QueensDomain-Win64-Shipping.exe`, `dwmapi.dll`, `ue4ss\` |
| `...\Win64\ue4ss\Mods\BadBadMod\` | Installable folder; `ue4ss\UE4SS.log` is relative to Win64 |
| `QueensDomain\QueensDomain\Content\Paks\QueensDomain-WindowsNoEditor.pak` | Cooked assets, useful for read-only asset/path discovery |
| `BadBadMod-playtest.zip` | One current local playable ZIP. Other supplied archives are reference material |

Paths can differ on another machine. A source-only clone can run Lua tests without UE4SS or the game. Do not bundle game assets, an old shipping executable, the loader, `.venv`, QA probes, or this skill.

## Offline checks

From the checkout, run the test that covers the change; consult `tests/bbm.lua` for the suite. The Lua entry points are `lua5.4 tests/options.lua` (example) and `lua5.4 tests/bbm.lua` (full suite). Windows equivalents with the existing workspace interpreter:

```powershell
& '..\.venv\Scripts\python.exe' -c "from pathlib import Path; from lupa.lua54 import LuaRuntime; LuaRuntime().execute(Path(r'tests\options.lua').read_text())"
& '..\.venv\Scripts\python.exe' -c "from pathlib import Path; from lupa.lua54 import LuaRuntime; LuaRuntime().execute(Path(r'tests\bbm.lua').read_text())"
```

`tests/support.lua` provides isolated globals, mocked hooks, and a controllable clock. Assert player-visible behavior and persistence, not just function calls. Follow `.stylua.toml`, `.luacheckrc`, and `.github/workflows/pull-request.yml`. The **Lua quality gate** compiles Lua 5.4, rejects all Luacheck warnings/errors, checks StyLua, and runs the complete suite. Prior local tools: Luacheck 1.1.2 and `npm exec --offline --yes --package=@johnnymorganz/stylua-bin@2.6.0 -- stylua --check Scripts tests`.

## In-game verification

For a check that needs the running game, split the test harness into two parts:

- **`probe.lua` (inside the game):** Exercise one behavior on the game thread. Measure it or capture the relevant frames, and log a unique `DONE` or `FAIL` marker. The runner installs this file as the temporary mod's `Scripts\main.lua`.
- **`run.ps1` (outside the game):** Reuse the launcher across checks; normally only the probe changes. Wait for the current run's marker with a timeout. Treat a crash, timeout, or `FAIL` as a failed test, and restore settings and clean up in `finally`.

Neither file belongs in the mod ZIP. For checks covered by the offline Lua tests, skip the launcher entirely.

1. Check whether **that exact copy** of the executable is running. If the player is using it, don't close or reconfigure it. Use a disposable `-UserDir="<scratch>\profile"` and `-NoSteam -windowed` for a test you launch. Keep its PID. Native profile isolation does **not** isolate the installed mod's own `features.ini` or `Scripts\config.lua`: preserve them separately before a test that changes them.
2. If an automated probe is useful, use a uniquely named temporary UE4SS mod with `Scripts\main.lua` and an empty `enabled.txt`. Exercise real code from the local checkout with UE4SS on the game thread. Work on a returned live instance, **not a `Default__` object or a widget-tree template**. Templates are useful as style sources, not as menus to open.
3. For Video tests, create or obtain a live `OptionsMenu_C` for the local player, add the test instance to the viewport, call `SwapToVideoMenu()`, then wait for `Video_OptionsList.ConfigVisInst`. The right side is the parent menu's `VideoOptions` canvas. `ScrollWidgetIntoView` and `row.FS_Button:SetUserFocus(pc)` exercise navigation. Find rows by caption, not a hardcoded list index. Check mouse/focus changes, close/reopen, saved selection, and teardown on an unrelated row. Test without a gameplay pawn as well.
4. **Capture what the player sees.** `shot showui` writes viewport images to the test profile's `Saved\Screenshots\WindowsNoEditor`. A `SceneCaptureComponent2D` alone does not capture UMG. Compare the same crop on/off using Pillow. For motion, measure the center of the scene as well as its edges; for label-only toggles, verify the border stays. A burn border may appear mainly at the bottom. Check fonts, wrapping, long names, 16:9 and ultrawide. When claiming a real-time cycle, record distinct frames and elapsed time.
5. For isolated pickup tests, spawn a native coin with `BeginDeferredActorSpawnFromClass` / `FinishSpawningActor`. Use a capture with `PrimitiveRenderMode=2` and `ShowOnlyActorComponents(actor,false)`. Refresh that component list **after** a new beam/arrow is created. Compare several camera angles, two bob phases, Off and collection; verify actual color/contrast, ground contact, and no duplicate components. For gameplay and saves, measure the relevant state or file hashes instead of screenshots alone.
6. Restore user settings even on failure, shut down only the test PID, and remove only the named probe and disposable profile. Keep the shared `.venv` and any unrelated files. If the game or test tools aren't available, say which results are from Lua tests and what remains unverified.

## Playtest vs public release

- **Local:** Sync only intended runtime files into `BadBadMod` and refresh the existing playtest ZIP if requested. Preserve installed user choices, especially opt-in Travel Stride. Bundle the **source defaults**, not preferences copied from the game install. Verify the ZIP prefix `BadBadMod/`, scripts, README, `features.ini`, and empty `enabled.txt`. For a committed tree, the release workflow's `git archive` command is the reference. For uncommitted fixes, package the tested working files, not stale `HEAD`.
- **Public, only on request:** Inspect the working tree, remote, authenticated account and repo-local author identity. Use conventional commits and the required project co-author trailer. Open/update the intended PR, wait for the required check without bypassing it, then merge if authorized. Tag the **verified merge commit** with an independent mod version. The release workflow publishes `BadBadMod.zip` with a title such as `v1.3.0 — Queen's Domain 1.01.07`. Download it, verify its digest, extract or compare entries against the tag, and link the published asset. Don't infer publication merely from a local tag or updated README.
- **History, not live status:** v1.0.0 established the combined mod; v1.1.0 added status HUD and ultrawide improvements; v1.2.0 added Travel Stride, private quicksave/load and pickup previews; v1.3.0 added live settings previews and numeric selectors. The Travel Stride branch was already included in the quicksave PR. A squash merge changes commit identity: compare trees/content before proposing a redundant PR.
