-- F5 pins progression to a private file; F9 loads that object instead of selecting a native recovery.
local B = ...
local PLAYER = "/Game/Player/FS_PlayerChar.FS_PlayerChar_C"
local SLOT = "/Game/Blueprints/SaveSystem/FS_SaveSlot.FS_SaveSlot_C"
local GP = "/Script/Engine.Default__GameplayStatics"
local SLOT_MARKER = FName("BBM_ManualSnapshot_V1")
local pendingLoad
local message, notice, noticeHud
local lastPress = -math.huge

local function notify(text)
    message = { text = text, expires = os.clock() + 4 }
    B.log(text)
end

local function isDeathScreenOpen(player)
    local class = StaticFindObject("/Game/UI/Menus/DieUI.DieUI_C")
    if not B.valid(class) then
        return false
    end
    local widgets = {}
    B.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):GetAllWidgetsOfClass(player, widgets, class, true)
    for _, entry in ipairs(widgets) do
        local widget = entry:get()
        if B.valid(widget) and widget:IsVisible() then
            return true
        end
    end
    return false
end

local function currentGame()
    local pc = FindFirstOf("PlayerController")
    assert(B.valid(pc), "Load a character slot first")
    local player = pc.Pawn
    assert(B.valid(player) and player:IsA(B.lib(PLAYER)) and player:IsLocallyControlled(), "Gameplay only")
    local gp = B.lib(GP)
    local gi = gp:GetGameInstance(player)
    assert(B.valid(gi), "Game instance unavailable")
    local active = gi.ActiveSaveSlot
    assert(
        B.valid(active) and active:IsA(B.lib(SLOT)) and active.HasEverSaved,
        "Save at a Crystal Monument first"
    )
    assert(
        not player.IsDead and not isDeathScreenOpen(player),
        "Unavailable on the death screen; continue first"
    )
    assert(
        not gi.InCutscene and not gi.InPickupAnim and not player.Teleporting,
        "Finish the current transition or pickup first"
    )
    assert(not gp:IsGamePaused(player), "Close the pause menu first")
    assert(not gi.SuspendSaveCurrentlyWriting, "A save is being written; wait for it to finish")

    local index = gi:GetActiveSaveSlotIndex()
    assert(index >= 0 and index < 5 and index == math.floor(index), "No valid player slot")
    local utils = B.lib("/Script/QueensDomain.Default__BlueprintUtils")
    local native = utils:GetSaveSlotName(index, false, false, false, 0, false):ToString()
    local folder = native:match("^FULLPATH:(.+[/\\])World" .. index .. "%.sav$")
    assert(folder, "Unknown save path; no files changed")
    assert(gp:DoesSaveGameExist(native, 0), "Save at a Crystal Monument in this slot first")
    local level = player:GetWorld():GetFullName():match("^World (/Game/[^.]+)%.")
    assert(level, "Unknown gameplay map")
    return {
        gp = gp,
        gi = gi,
        player = player,
        active = active,
        index = index,
        level = level,
        pin = folder .. "BBM_Quick_World" .. index .. ".sav",
    }
end

local function hasResumeRegion(level, streaming)
    -- The main ruins map can load its base scenery without loading the region that populates it.
    return level ~= "/Game/RuinsLevel/Maps/Ruins_Level_00"
        or #streaming.SafeLocLevelListStack > 0
        or #streaming.SafeLocTriggerLevelListStack > 0
end

-- Copy the two cached stacks that belong to LastSafeLocation. UE4SS's temporary
-- struct returned by GetSafeLocationSuspendState can lose its nested arrays.
local function copyRegionStack(stack)
    local copy = {}
    for i = 1, #stack do
        local entry = stack[i]
        assert(B.valid(entry.List), "Invalid safe resume region; quicksave unchanged")
        copy[i] = { List = entry.List, Priority = entry.Priority, bTrigger = entry.bTrigger }
    end
    return copy
end

local function captureResumeState(game)
    local player = game.player
    assert(not player.SafeLocationIsForcedMidair, "No safe grounded resume point yet")
    local transform = player.LastSafeLocation
    local location = transform.Translation
    local function finite(n)
        return type(n) == "number" and math.abs(n) < math.huge
    end
    assert(
        finite(location.X)
            and finite(location.Y)
            and finite(location.Z)
            and (location.X ~= 0 or location.Y ~= 0 or location.Z ~= 0),
        "No valid safe position yet"
    )
    assert(player:SafeZoneProject(location, {}), "The game's safe position is not on loaded walkable ground")
    local manager = B.lib("/Script/QueensDomain.Default__FS_LevelManager"):GetLevelManager(player)
    assert(B.valid(manager), "Level streaming is not ready")
    local streaming = {
        SafeLocLevelListStack = copyRegionStack(manager.SafeLocLevelListStack),
        SafeLocTriggerLevelListStack = copyRegionStack(manager.SafeLocTriggerLevelListStack),
    }
    assert(hasResumeRegion(game.level, streaming), "No safe resume region yet; quicksave unchanged")
    local music = {}
    if B.valid(game.gi.MusicController) then
        for i, entry in ipairs(game.gi.MusicController:GetSafeLocationSuspendState()) do
            music[i] = entry:get()
        end
    end
    return { location = transform, streaming = streaming, music = music }
end

local function readSnapshot(game, path)
    local file = assert(io.open(path, "rb"), "Missing or unreadable quicksave")
    local header = file:read(4)
    file:close()
    assert(header == "GVAS", "Invalid quicksave file")
    local save = game.gp:LoadGameFromSlot("FULLPATH:" .. path, 0)
    assert(B.valid(save) and save:IsA(B.lib(SLOT)) and save.IsSuspendSave, "Missing or unreadable quicksave")
    assert(
        save.NamedSaveData:Contains(SLOT_MARKER)
            and save.NamedSaveData:Find(SLOT_MARKER):get() == game.index + 1,
        "Not a BBM quicksave for this slot"
    )
    assert(save.SaveVersion == game.active.SaveVersion, "Quicksave version mismatch")
    assert(save.SaveLevel:ToString() == game.level, "Quicksave belongs to another gameplay map")
    return save
end

local function stageSnapshot(game, path, resume)
    -- Only the detached copy gets suspend data. Both writes target the same private staging file.
    game.player:WriteStatusToSave()
    local gp, slot = game.gp, "FULLPATH:" .. path
    assert(gp:SaveGameToSlot(game.active, slot, 0), "Could not stage progression")
    local clone = gp:LoadGameFromSlot(slot, 0)
    assert(B.valid(clone) and clone:IsA(B.lib(SLOT)), "Could not read back staged progression")
    clone.SuspendLocation = resume.location
    clone.SuspendPositionIsForcedMidair = false
    local destination = clone.LevelLoadingSuspendState
    for field, stack in pairs(resume.streaming) do
        destination[field] = stack
    end
    clone.MusicAreaSuspendState = resume.music
    clone.SaveLevel = FName(game.level)
    clone.IsSuspendSave = true
    clone.NamedSaveData:Add(SLOT_MARKER, game.index + 1)
    assert(gp:SaveGameToSlot(clone, slot, 0), "Could not write the new quicksave")
    return clone.CurrentPlayerHealth
end

local function matchesRegionStack(expected, actual)
    if #expected ~= #actual then
        return false
    end
    for i, entry in ipairs(expected) do
        local stored = actual[i]
        if
            not B.valid(stored.List)
            or stored.List:GetAddress() ~= entry.List:GetAddress()
            or stored.Priority ~= entry.Priority
            or stored.bTrigger ~= entry.bTrigger
        then
            return false
        end
    end
    return true
end

local function verifySnapshot(save, resume, health)
    for field, stack in pairs(resume.streaming) do
        assert(
            matchesRegionStack(stack, save.LevelLoadingSuspendState[field]),
            "Could not verify the region in the new save; quicksave unchanged"
        )
    end
    local expected, actual = resume.location.Translation, save.SuspendLocation.Translation
    assert(
        save.CurrentPlayerHealth == health
            and actual.X == expected.X
            and actual.Y == expected.Y
            and actual.Z == expected.Z,
        "Quicksave verification failed"
    )
end

local function exists(game, path)
    return game.gp:DoesSaveGameExist("FULLPATH:" .. path, 0)
end

local function promoteSnapshot(game, staged)
    -- Windows can't rename over an existing file. Keep one generation for rollback.
    local pin, previous = game.pin, game.pin .. ".prev"
    local hasPin = exists(game, pin)
    if hasPin then
        if exists(game, previous) then
            assert(os.remove(previous))
        end
        assert(os.rename(pin, previous))
    end
    local ok, err = os.rename(staged, pin)
    if not ok then
        if hasPin then
            assert(os.rename(previous, pin), "Could not roll back; previous pin is in .prev")
        end
        error("Could not promote quicksave: " .. tostring(err))
    end
end

local function pinProgress(game)
    assert(game.gi.SuspendIsBlocked <= 0, "Saving is currently blocked")
    local resume = captureResumeState(game)
    local staged = game.pin .. ".new"
    local health = stageSnapshot(game, staged, resume)
    verifySnapshot(readSnapshot(game, staged), resume, health)
    promoteSnapshot(game, staged)
    notify(("Quick saved - slot %d"):format(game.index + 1))
end

local function loadPinnedProgress(game)
    local path = game.pin
    if not exists(game, path) then
        path = path .. ".prev"
        assert(exists(game, path), "No quicksave for this slot")
    end
    local pin = readSnapshot(game, path)
    assert(
        hasResumeRegion(game.level, pin.LevelLoadingSuspendState),
        "Quicksave has no resume region; load cancelled"
    )
    pin.NamedSaveData:Remove(SLOT_MARKER)
    local address = pin:GetAddress()
    local previousBase = game.gi.BaseActiveSave
    local ok, err = pcall(function()
        -- OpenLevel keeps the GameInstance; ForceLoadNewSlot would reselect the
        -- newest native disk file instead. Both active references must name our pin.
        game.gi:SetActiveSave(pin)
        game.gi.BaseActiveSave = pin
        assert(
            game.gi.ActiveSaveSlot:GetAddress() == address and game.gi.BaseActiveSave:GetAddress() == address,
            "Game did not select the pinned snapshot"
        )
        pendingLoad = { index = game.index, address = address, deadline = os.clock() + 60 }
        game.gp:OpenLevel(game.gi, FName(game.level), true, "")
    end)
    if not ok then
        pendingLoad = nil
        game.gi:SetActiveSave(game.active)
        game.gi.BaseActiveSave = previousBase
        error(err)
    end
    notify("Loading quicksave...")
end

local restoreHookReady = B.hook(PLAYER .. ":RestoreSuspend", function(ctx)
    if not pendingLoad then
        return
    end
    local player = ctx:get()
    local gi = B.lib(GP):GetGameInstance(player)
    local wanted = pendingLoad
    pendingLoad = nil
    if
        B.valid(gi.ActiveSaveSlot)
        and gi.ActiveSaveSlot:GetAddress() == wanted.address
        and gi:GetActiveSaveSlotIndex() == wanted.index
    then
        notify(("Quick loaded - slot %d"):format(wanted.index + 1))
    else
        notify("Quick load failed: restored save did not match")
    end
end)

local function bindKey(key, prefix, action)
    RegisterKeyBind(key, function()
        ExecuteInGameThread(function()
            local now = os.clock()
            if now - lastPress < 0.4 then
                return
            end
            lastPress = now
            local ok, err = pcall(function()
                assert(not pendingLoad, "A quick load is already pending")
                assert(restoreHookReady(), "Save system not ready yet")
                action(currentGame())
            end)
            if not ok then
                notify(prefix .. (tostring(err):match(":%d+: (.*)") or tostring(err)))
            end
        end)
    end)
end

bindKey(Key.F5, "Quick save: ", pinProgress)
bindKey(Key.F9, "Quick load: ", loadPinnedProgress)

B.hook("/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick", function(ctx)
    if pendingLoad and os.clock() > pendingLoad.deadline then
        pendingLoad = nil
        notify("Quick load not confirmed by the game")
    end
    if not message then
        return
    end
    if os.clock() >= message.expires then
        if B.valid(notice) then
            notice:SetVisibility(1)
        end
        message = nil
        return
    end
    local hud = ctx:get()
    if not B.valid(hud.Root) then
        return
    end
    if noticeHud ~= hud:GetAddress() or not B.valid(notice) then
        notice = B.widget(hud, "TextBlock")
        if B.valid(hud.InteractText) then
            notice:SetFont(hud.InteractText.Font)
        end
        notice:SetShadowOffset({ X = 1, Y = 1 })
        local slot = hud.Root:AddChildToCanvas(notice)
        slot:SetAutoSize(true)
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } })
        slot:SetAlignment({ X = 0.5, Y = 0 })
        slot:SetPosition({ X = 0, Y = 26 })
        slot:SetZOrder(200)
        noticeHud = hud:GetAddress()
        message.shown = false
    end
    if not message.shown then
        notice:SetText(FText(message.text))
        notice:SetVisibility(3)
        message.shown = true
    end
end)
table.insert(B.reset, function()
    notice, noticeHud = nil, nil
end)
