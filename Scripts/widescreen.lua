-- Adapts the player camera and HUD edge groups to the current viewport aspect ratio.
local B = ...
local nextViewportCheck, trackedHudId, appliedEdgeOffset = 0, nil, 0
local originalAspectConstraint, trackedCameraId, isWide = nil, nil, false

local function updateCameraAspectConstraint(pawn)
    if not B.valid(pawn) then
        return
    end
    local camera = pawn.FirstPersonCamera
    if not B.valid(camera) then
        return
    end
    if isWide then
        if camera:GetAddress() ~= trackedCameraId then
            originalAspectConstraint, trackedCameraId = camera.bConstrainAspectRatio, camera:GetAddress()
        end
        if camera.bConstrainAspectRatio then
            camera.bConstrainAspectRatio = false
        end
    elseif trackedCameraId == camera:GetAddress() then
        trackedCameraId = nil
        -- Reapply the game's current aspect mode, not a stale pre-resize value.
        camera.bConstrainAspectRatio = originalAspectConstraint
        pawn["Update Camera Aspect Ratio Options"](pawn)
    end
end

B.hook("/Game/Player/FS_PlayerChar.FS_PlayerChar_C:Update Camera Aspect Ratio Options", function(ctx)
    if isWide then
        updateCameraAspectConstraint(ctx:get())
    end
end)

local function updateWidescreenHud(ctx)
    if os.clock() < nextViewportCheck then
        return
    end
    nextViewportCheck = os.clock() + 0.5
    local hud = ctx:get()
    local layout = B.lib("/Script/UMG.Default__WidgetLayoutLibrary")
    local size = layout:GetViewportSize(hud)
    if size.Y <= 0 then
        return
    end
    local scale = layout:GetViewportScale(hud)
    if scale <= 0 then
        return
    end
    local requiredEdgeOffset = math.max(0, (size.X - size.Y * 16 / 9) / (2 * scale))
    if requiredEdgeOffset < 1 then
        requiredEdgeOffset = 0
    end
    isWide = requiredEdgeOffset > 0
    if isWide or trackedCameraId then
        updateCameraAspectConstraint(hud:GetOwningPlayerPawn())
    end
    if trackedHudId ~= hud:GetAddress() then
        trackedHudId, appliedEdgeOffset = hud:GetAddress(), 0
    end
    if math.abs(requiredEdgeOffset - appliedEdgeOffset) < 0.5 then
        return
    end
    local status, compass = hud.StatusCluster, hud.CompassWidget
    if not B.valid(status) or not B.valid(compass) then
        return
    end
    -- Translate only the two edge groups, preserving stock anchors, padding and scale.
    local function translateWidgetHorizontally(w, delta)
        local t = w.RenderTransform.Translation
        w:SetRenderTranslation({ X = t.X + delta, Y = t.Y })
    end
    translateWidgetHorizontally(status, appliedEdgeOffset - requiredEdgeOffset)
    translateWidgetHorizontally(compass, requiredEdgeOffset - appliedEdgeOffset)
    appliedEdgeOffset = requiredEdgeOffset
end

B.hook("/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick", updateWidescreenHud)
table.insert(B.reset, function()
    trackedHudId, appliedEdgeOffset, nextViewportCheck, trackedCameraId, isWide = nil, 0, 0, nil, false
end)
