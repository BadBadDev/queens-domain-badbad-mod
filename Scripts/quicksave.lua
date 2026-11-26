-- F5 pins progression to a private file; F9 loads that object instead of selecting a native recovery.
local B = ...
local PLAYER = "/Game/Player/FS_PlayerChar.FS_PlayerChar_C"
local SLOT = "/Game/Blueprints/SaveSystem/FS_SaveSlot.FS_SaveSlot_C"
local GP = "/Script/Engine.Default__GameplayStatics"
local SLOT_MARKER = FName("BBM_ManualSnapshot_V1")
local pendingLoad
local message, messageUntil, notice, noticeHud, displayedMessage
local lastPress = -math.huge

local function notify(text)
    message, messageUntil = text, os.clock() + 4
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

local function slotName(path)
    return "FULLPATH:" .. path
end

local function readSnapshot(game, path)
    local file = assert(io.open(path, "rb"), "Missing or unreadable quicksave")
    local header = file:read(4)
    file:close()
    assert(header == "GVAS", "Invalid quicksave file")
    local save = game.gp:LoadGameFromSlot(slotName(path), 0)
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

local function pinProgress(game)
    -- This counter blocks creating a suspend save, not reading a previously verified pin.
    assert(game.gi.SuspendIsBlocked <= 0, "Saving is currently blocked")
    local gp, player = game.gp, game.player
    assert(not player.SafeLocationIsForcedMidair, "No safe grounded resume point yet")
    local location = player.LastSafeLocation.Translation
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
    local source, nextPin, previous = game.pin .. ".work", game.pin .. ".new", game.pin .. ".prev"
    -- Clone the progression object through Unreal's serializer. Patch only that copy,
    -- never the monument file or the two suspend files used by the game.
    player:WriteStatusToSave()
    assert(gp:SaveGameToSlot(game.active, slotName(source), 0), "Could not stage progression")
    local clone = gp:LoadGameFromSlot(slotName(source), 0)
    assert(B.valid(clone) and clone:IsA(B.lib(SLOT)), "Could not read back staged progression")
    local manager = B.lib("/Script/QueensDomain.Default__FS_LevelManager"):GetLevelManager(player)
    assert(B.valid(manager), "Level streaming is not ready")
    clone.SuspendLocation = player.LastSafeLocation
    clone.SuspendPositionIsForcedMidair = false
    clone.LevelLoadingSuspendState = manager:GetSafeLocationSuspendState()
    local music = {}
    if B.valid(game.gi.MusicController) then
        for i, entry in ipairs(game.gi.MusicController:GetSafeLocationSuspendState()) do
            music[i] = entry:get()
        end
    end
    clone.MusicAreaSuspendState = music
    clone.SaveLevel = FName(game.level)
    clone.IsSuspendSave = true
    clone.NamedSaveData:Add(SLOT_MARKER, game.index + 1)
    assert(gp:SaveGameToSlot(clone, slotName(nextPin), 0), "Could not write the new quicksave")
    local verified = readSnapshot(game, nextPin)
    local expected, actual = clone.SuspendLocation.Translation, verified.SuspendLocation.Translation
    assert(
        verified.CurrentPlayerHealth == clone.CurrentPlayerHealth
            and actual.X == expected.X
            and actual.Y == expected.Y
            and actual.Z == expected.Z,
        "Quicksave verification failed"
    )
    -- Windows cannot rename over a file. Retain one generation, including through
    -- an interruption between these two renames. Never stage into the current pin.
    local hasPin = gp:DoesSaveGameExist(slotName(game.pin), 0)
    if hasPin then
        if gp:DoesSaveGameExist(slotName(previous), 0) then
            assert(os.remove(previous))
        end
        assert(os.rename(game.pin, previous))
    end
    local ok, err = os.rename(nextPin, game.pin)
    if not ok then
        if hasPin then
            assert(os.rename(previous, game.pin), "Could not roll back; previous pin is in .prev")
        end
        error("Could not promote quicksave: " .. tostring(err))
    end
    if not gp:DeleteGameInSlot(slotName(source), 0) then
        B.log("Could not clean up private .work file")
    end
    notify(("Quick saved - slot %d"):format(game.index + 1))
end

local function loadPinnedProgress(game)
    local path = game.pin
    if not game.gp:DoesSaveGameExist(slotName(path), 0) then
        path = path .. ".prev"
        assert(game.gp:DoesSaveGameExist(slotName(path), 0), "No quicksave for this slot")
    end
    local pin = readSnapshot(game, path)
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

local function request(action)
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
            notify("Quick save/load: " .. (tostring(err):match(":%d+: (.*)") or tostring(err)))
        end
    end)
end

RegisterKeyBind(Key.F5, function()
    request(pinProgress)
end)
RegisterKeyBind(Key.F9, function()
    request(loadPinnedProgress)
end)

B.hook("/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick", function(ctx)
    if pendingLoad and os.clock() > pendingLoad.deadline then
        pendingLoad = nil
        notify("Quick load not confirmed by the game")
    end
    if not message then
        return
    end
    if os.clock() >= messageUntil then
        if B.valid(notice) then
            notice:SetVisibility(1)
        end
        message, displayedMessage = nil, nil
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
        noticeHud, displayedMessage = hud:GetAddress(), nil
    end
    if displayedMessage ~= message then
        notice:SetText(FText(message))
        notice:SetVisibility(3)
        displayedMessage = message
    end
end)
table.insert(B.reset, function()
    notice, noticeHud, displayedMessage = nil, nil, nil
end)
