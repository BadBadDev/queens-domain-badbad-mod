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
local deathScreenVisible = false
local deathScreen = obj({
    IsVisible = function()
        return deathScreenVisible
    end,
})
local function savePath(name)
    return "FULLPATH:C:\\TestSave\\" .. name
end
local gp = {
    GetGameInstance = function()
        return gi
    end,
    IsGamePaused = function()
        return false
    end,
    DoesSaveGameExist = function(_, name)
        return name == savePath("World" .. slot .. ".sav") or name == savePath("BBM_Quick_World1.sav")
    end,
    LoadGameFromSlot = function(_, name)
        assert(name == savePath("BBM_Quick_World1.sav"), "never choose a native recovery for F9")
        return pinned
    end,
    OpenLevel = function(_, _, level)
        assert(gi.ActiveSaveSlot == pinned and gi.BaseActiveSave == pinned and level == gameMap)
        assert(not rejectTravel, "test travel failure")
        opened = opened + 1
    end,
}
test.api.lib = function(path)
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
header, marker = "GVAS", 1
press("F9", "Not a BBM quicksave for this slot")
assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)

marker, rejectTravel = 2, true
press("F9", "test travel failure")
assert(opened == 0 and gi.ActiveSaveSlot == real and gi.BaseActiveSave == real)
rejectTravel = false
press("F9", "Loading quicksave")
press("F9", "already pending")
assert(opened == 1)
test.hooks.RestoreSuspend(ref(player))
assert(notifications[#notifications] == "Quick loaded - slot 2")
