-- Adapts the gameplay camera, edge HUD groups and status borders to the viewport aspect ratio.
local B = ...
local nextViewportCheck = 0
local edgeOffsets = {}
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

local function applyWidgetEdgeOffset(key, widget, offset)
    if not B.valid(widget) then
        return
    end
    local id = widget:GetAddress()
    local last = edgeOffsets[key]
    local previous = last and last.id == id and last.offset or 0
    if math.abs(offset - previous) < 0.5 then
        return
    end
    local translation = widget.RenderTransform.Translation
    widget:SetRenderTranslation({ X = translation.X + offset - previous, Y = translation.Y })
    edgeOffsets[key] = { id = id, offset = offset }
end

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
    applyWidgetEdgeOffset("status", hud.StatusCluster, -requiredEdgeOffset)
    applyWidgetEdgeOffset("usableItem", hud.ConsumableHUD, -requiredEdgeOffset)
    applyWidgetEdgeOffset("compass", hud.CompassWidget, requiredEdgeOffset)
end

B.hook("/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick", updateWidescreenHud)

-- Poison, Heavy and other screen-space status effects reuse this widget. Leave
-- its material, pulse animation and native aspect-mode selection untouched.
local widgetLayoutLibrary

local function fitStatusEffectBorder(context)
    local overlay = context:get()
    local image = overlay.OverlayLayer
    if not B.valid(image) then
        return
    end

    if not widgetLayoutLibrary then
        widgetLayoutLibrary = B.lib("/Script/UMG.Default__WidgetLayoutLibrary")
    end
    local viewport = widgetLayoutLibrary:GetViewportSize(overlay)
    if viewport.Y <= 0 then
        return
    end
    local aspect = viewport.X / viewport.Y
    local scaleX, scaleY = 1, 1
    local scaleBox = image:GetParent()
    if aspect > 16 / 9 + 0.001 and B.valid(scaleBox) and scaleBox.Stretch == 2 then -- ScaleToFit
        local brushSize = image.Brush.ImageSize
        if brushSize.X > 0 and brushSize.Y > 0 then
            local ratio = aspect / (brushSize.X / brushSize.Y)
            scaleX, scaleY = math.max(1, ratio), math.max(1, 1 / ratio)
        end
    end

    local previous = image.RenderTransform.Scale
    if math.abs(previous.X - scaleX) > 0.001 or math.abs(previous.Y - scaleY) > 0.001 then
        image:SetRenderScale({ X = scaleX, Y = scaleY })
    end
end

B.hook(
    "/Game/Player/StatusEffectVisualizers/StatusEffectOverlay.StatusEffectOverlay_C:Tick",
    fitStatusEffectBorder
)
table.insert(B.reset, function()
    edgeOffsets, nextViewportCheck, trackedCameraId, isWide = {}, 0, nil, false
    widgetLayoutLibrary = nil
end)
