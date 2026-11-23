std = "lua54"
-- StyLua owns line wrapping, including long Unreal object paths.
max_line_length = false

files["Scripts/**/*.lua"].read_globals = {
    "FName", "FText", "FindAllOf", "FindFirstOf", "LoadAsset",
    "LoopInGameThreadWithDelay", "RegisterBeginPlayPostHook", "RegisterHook",
    "RegisterInitGameStatePostHook", "RegisterLoadMapPreHook",
    "StaticConstructObject", "StaticFindObject",
}

files["tests/bbm.lua"].globals = { "FText", "StaticConstructObject", "StaticFindObject", "os.clock" }
