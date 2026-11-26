-- Exercise refusal and rollback paths without reading or modifying any real save.
local support = require("tests.support")
local test = support.new()
local obj, ref = support.object, support.ref
local keys, notifications = {}, {}
local gameMap = "/Game/Maps/TestWorld"
local slot, opened, header, marker, rejectTravel = 1, 0, "GVAS", 2, false
local real = obj({
    HasEverSaved = true,
    SaveVersion = 3,
    IsA = function()
        return true
    end,
})
local pinned = obj({
    IsSuspendSave = true,
    LevelLoadingSuspendState = { SafeLocLevelListStack = {}, SafeLocTriggerLevelListStack = {} },
    SaveVersion = 3,
    IsA = function()
        return true
    end,
    SaveLevel = {
        ToString = function()
            return gameMap
        end,
    },
    NamedSaveData = {
        Contains = function()
            return true
        end,
        Find = function()
            return ref(marker)
        end,
        Remove = support.noop,
    },
})
local gi = obj({
    ActiveSaveSlot = real,
    BaseActiveSave = real,
    SuspendIsBlocked = 0,
    GetActiveSaveSlotIndex = function()
        return slot
    end,
    SetActiveSave = function(self, save)
        self.ActiveSaveSlot = save
    end,
})
local player = obj({
    IsA = function()
        return true
    end,
    IsLocallyControlled = function()
        return true
    end,
    GetWorld = function()
        return {
            GetFullName = function()
                return "World " .. gameMap .. ".TestWorld"
            end,
        }
    end,
})
local controller = obj({ Pawn = player })
player.LastSafeLocation = { Translation = { X = 1, Y = 2, Z = 3 } }
player.SafeZoneProject = function()
    return true
end
local deathScreenVisible = false
local deathScreen = obj({
    IsVisible = function()
        return deathScreenVisible
    end,
})
local function savePath(name)
    return "FULLPATH:C:\\TestSave\\" .. name
end
local primary = savePath("BBM_Quick_World1.sav")
local available = { [primary] = true, [primary .. ".prev"] = true }
local expectedLoad = primary
local gp = {
    GetGameInstance = function()
        return gi
    end,
    IsGamePaused = function()
        return false
    end,
    DoesSaveGameExist = function(_, name)
        return name == savePath("World" .. slot .. ".sav") or available[name] == true
    end,
    LoadGameFromSlot = function(_, name)
        assert(name == expectedLoad, "loaded the wrong quicksave generation")
        return pinned
    end,
    OpenLevel = function(_, _, level)
        assert(gi.ActiveSaveSlot == pinned and gi.BaseActiveSave == pinned and level == gameMap)
        assert(not rejectTravel, "test travel failure")
        opened = opened + 1
    end,
}
test.api.lib = function(path)
    if path:match("FS_LevelManager$") then
        return {
            GetLevelManager = function()
                return obj({
                    SafeLocLevelListStack = pinned.LevelLoadingSuspendState.SafeLocLevelListStack,
                    SafeLocTriggerLevelListStack = pinned.LevelLoadingSuspendState.SafeLocTriggerLevelListStack,
                })
            end,
        }
    end
    if path:match("WidgetBlueprintLibrary$") then
        return {
            GetAllWidgetsOfClass = function(_, owner, out, _, topOnly)
                assert(owner == player and topOnly)
                out[1] = ref(deathScreen)
            end,
        }
    end
    if path:match("GameplayStatics$") then
        return gp
    end
    if path:match("BlueprintUtils$") then
        return {
            GetSaveSlotName = function(_, n)
                return {
                    ToString = function()
                        return savePath("World" .. n .. ".sav")
                    end,
                }
            end,
        }
    end
    return obj()
end
local bind = test.api.hook
test.api.hook = function(path, callback)
    bind(path, callback)
    return function()
        return true
    end
end
test.api.log = function(text)
    notifications[#notifications + 1] = text
end
test.env.Key = { F5 = "F5", F9 = "F9" }
test.env.RegisterKeyBind = function(key, callback)
    keys[key] = callback
end
test.env.ExecuteInGameThread = function(callback)
    callback()
end
test.env.FindFirstOf = function()
    return controller
end
test.env.StaticFindObject = function(path)
    assert(path == "/Game/UI/Menus/DieUI.DieUI_C")
    return obj()
end
test.env.FName = function(name)
    return name
end
test.env.io = {
    open = function(_, mode)
        assert(mode == "rb")
        return {
            read = function()
                return header
            end,
            close = support.noop,
        }
    end,
}
test.loadModule("quicksave")
local function press(key, expected)
    test.now = test.now + 1
    keys[key]()
    assert(notifications[#notifications]:find(expected, 1, true), notifications[#notifications])
end

gi.SuspendIsBlocked = 1
press("F5", "blocked")
player.IsDead = true
press("F9", "death screen")
player.IsDead, deathScreenVisible = false, true
press("F9", "death screen")
deathScreenVisible = false
gi.SuspendSaveCurrentlyWriting = true
press("F9", "being written")
assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)
gi.SuspendSaveCurrentlyWriting = false
press("F9", "Loading quicksave")
assert(opened == 1 and gi.SuspendIsBlocked == 1)
test.hooks.RestoreSuspend(ref(player))
assert(notifications[#notifications] == "Quick loaded - slot 2")
opened, gi.ActiveSaveSlot, gi.BaseActiveSave = 0, real, real
gi.SuspendIsBlocked = 0
slot = 0
press("F9", "No quicksave")
slot = 1
header = "junk"
press("F9", "Invalid quicksave")
assert(opened == 0)
header, available[primary], expectedLoad = "GVAS", false, primary .. ".prev"
press("F9", "Loading quicksave")
test.hooks.RestoreSuspend(ref(player))
assert(opened == 1 and notifications[#notifications] == "Quick loaded - slot 2")
opened, gi.ActiveSaveSlot, gi.BaseActiveSave = 0, real, real
available[primary], expectedLoad = true, primary
header, marker = "GVAS", 1
press("F9", "Not a BBM quicksave for this slot")
assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)

marker = 2
gameMap = "/Game/RuinsLevel/Maps/Ruins_Level_00"
press("F5", "Quick save: No safe resume region yet; quicksave unchanged")
press("F9", "Quick load: Quicksave has no resume region; load cancelled")
assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)

-- F5 can receive a region from the manager but fail to read it back from its staged file.
do
    local normal = { List = obj(), Priority = -1, bTrigger = false }
    local trigger = { List = obj(), Priority = 2, bTrigger = true }
    local withRegion = { SafeLocLevelListStack = { normal }, SafeLocTriggerLevelListStack = { trigger } }
    local fromDisk = setmetatable({
        LevelLoadingSuspendState = { SafeLocLevelListStack = { normal }, SafeLocTriggerLevelListStack = {} },
    }, { __index = pinned })
    local staged =
        obj({ IsA = real.IsA, NamedSaveData = { Add = support.noop }, LevelLoadingSuspendState = {} })
    local load = gp.LoadGameFromSlot
    local stagedContents
    local current = primary:sub(#"FULLPATH:" + 1)
    local files = { [current] = "old", [current .. ".prev"] = "older" }
    local rejectPromotion = true
    test.env.os.remove = function(path)
        assert(path == current .. ".prev" and files[path])
        files[path], available[primary .. ".prev"] = nil, false
        return true
    end
    test.env.os.rename = function(src, dst)
        if rejectPromotion and src == current .. ".new" then
            return nil, "test rename failure"
        end
        assert(files[src] and not files[dst])
        files[dst], files[src] = files[src], nil
        available["FULLPATH:" .. dst], available["FULLPATH:" .. src] = true, false
        return true
    end
    player.WriteStatusToSave = support.noop
    pinned.LevelLoadingSuspendState = withRegion
    gp.SaveGameToSlot = function(_, save, path)
        assert(path == primary .. ".new" and (save == real or save == staged))
        stagedContents = save
        files[current .. ".new"] = save
        return true
    end
    gp.LoadGameFromSlot = function(_, path)
        assert(path == primary .. ".new")
        if stagedContents == real then
            return staged
        end
        local copy = staged.LevelLoadingSuspendState
        for field, entries in pairs(withRegion) do
            assert(copy[field] ~= entries and #copy[field] == #entries)
            for i, entry in ipairs(entries) do
                local cloned = copy[field][i]
                assert(
                    cloned ~= entry
                        and cloned.List == entry.List
                        and cloned.Priority == entry.Priority
                        and cloned.bTrigger == entry.bTrigger
                )
            end
        end
        return fromDisk
    end
    press("F5", "Quick save: Could not verify the region in the new save; quicksave unchanged")
    fromDisk.LevelLoadingSuspendState.SafeLocTriggerLevelListStack =
        { { List = trigger.List, Priority = -1, bTrigger = true } }
    press("F5", "Quick save: Could not verify the region in the new save; quicksave unchanged")
    assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)
    assert(files[current] == "old" and files[current .. ".prev"] == "older")
    fromDisk.LevelLoadingSuspendState = withRegion
    fromDisk.CurrentPlayerHealth, staged.CurrentPlayerHealth = 43, 43
    fromDisk.SuspendLocation = player.LastSafeLocation
    press("F5", "Could not promote quicksave")
    assert(files[current] == "old" and not files[current .. ".prev"])
    rejectPromotion = false
    press("F5", "Quick saved - slot 2")
    assert(files[current] == staged and files[current .. ".prev"] == "old" and not files[current .. ".new"])
    gp.LoadGameFromSlot = load
end
pinned.LevelLoadingSuspendState.SafeLocTriggerLevelListStack = { {} }
rejectTravel = true
press("F9", "test travel failure")
assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)
rejectTravel = false
pinned.LevelLoadingSuspendState = { SafeLocLevelListStack = { {} }, SafeLocTriggerLevelListStack = {} }
press("F9", "Loading quicksave")
press("F9", "already pending")
assert(opened == 1)
test.hooks.RestoreSuspend(ref(player))
assert(notifications[#notifications] == "Quick loaded - slot 2")
