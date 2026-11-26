-- Read-only examples in the Video page's existing preview area. Nothing here opens a gameplay HUD or save.
local mod = ...
local itemStats = assert(loadfile(mod.dir .. "itemstats.lua"))(mod)
local state
local examples = {
    itemStats = true,
    statusNames = true,
    enemyHpBars = true,
    graphics = true,
    shimmer = true,
}
local explanations = {
    drag = {
        "Drag to equip",
        "In Status & Inventory, drag a weapon, throwable, or charm onto a compatible slot to equip it. You can still equip items by clicking.",
    },
    inventoryStats = {
        "Inventory healing stat",
        "Adds a Healing bonus row to your character's status screen. It shows how much more HP healing items restore. Turning the row off doesn't change how much they heal.",
    },
    travelStride = {
        "Travel Stride",
        ("After %s %s out of combat, gain +%s%% ground speed and +%s%% sword-dash recharge rate. Enemy aggro or a combat hit ends the boost. Jump distance stays the same."):format(
            mod.config.travelStrideDelaySeconds,
            mod.config.travelStrideDelaySeconds == 1 and "second" or "seconds",
            mod.config.travelStrideSpeedBonusPercent,
            mod.config.travelStrideSwordRechargeBonusPercent
        ),
    },
    quickSave = {
        "Quick Save / Load",
        "Save at a Crystal Monument once in this slot. During gameplay, F5 saves your progress and last safe position; F9 reloads them in the same map. Your monument save stays untouched. This does not rewind a fight.",
    },
}
local sampleItems = {
    "/Game/Items/Consumables/Herb/HealingHerb_03.HealingHerb_03",
    "/Game/Items/Weapons/FlyingSword/FlyingSword.FlyingSword",
    "/Game/Items/Weapons/Daggers/Chakram/Chakram.Chakram",
    "/Game/Items/Consumables/IronFruit/IronFruit.IronFruit",
    "/Game/Items/Consumables/PoisonCure/PoisonCure.PoisonCure",
}
local secondsPerItem = 3
local renderLib = "/Script/Engine.Default__KismetRenderingLibrary"
local statusEffects = {
    { "Poison", "PoisonOverlaymat.PoisonOverlaymat" },
    { "Weaken", "Weaken/WeakenOverlayMat.WeakenOverlayMat" },
    { "Burn", "MagicFire/MagicFireOverlayMat_Inst.MagicFireOverlayMat_Inst" },
}
local secondsPerEffect = 2
local identity = {
    Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
    Translation = { X = 0, Y = 0, Z = 0 },
    Scale3D = { X = 1, Y = 1, Z = 1 },
}

local function closePanel()
    if state and mod.valid(state.panel) then
        state.panel:RemoveFromParent()
    end
    if state and mod.valid(state.capture) then
        state.capture:K2_DestroyComponent(state.capture)
    end
    if state and mod.valid(state.target) then
        mod.lib(renderLib):ReleaseRenderTarget2D(state.target)
    end
    if state then
        state.panel, state.capture, state.target, state.itemCard = nil, nil, nil, nil
        state.updateEnemyBar, state.lastPhase, state.status = nil, nil, nil
    end
end

local function close()
    closePanel()
    if mod.clearPreviewHerb then
        mod.clearPreviewHerb()
    end
    state = nil
end

local function place(panel, child, x, y, width, height)
    child:SetVisibility(3) -- HitTestInvisible, including descendants.
    local slot = panel:AddChildToCanvas(child)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = width, Y = height })
    return child
end

local function label(page, text, x, y, width, height, style, align)
    local textBlock = StaticConstructObject(mod.lib("/Script/CommonUI.CommonTextBlock"), page.WidgetTree)
    assert(mod.valid(textBlock), "could not create native preview text")
    textBlock:SetStyle(style or page.Vsync.FieldLabel.Style)
    textBlock:SetText(FText(text))
    textBlock:SetJustification(align or 0)
    textBlock:SetAutoWrapText(true)
    return place(state.panel, textBlock, x, y, width, height)
end

local function backdrop(page, x, y, width, height)
    local background = mod.widget(page, "Border")
    background:SetBrushColor({ R = 0.016, G = 0.022, B = 0.024, A = 0.94 })
    place(state.panel, background, x, y, width, height)
end

local function previewAsset(path)
    local asset = StaticFindObject(path)
    if not mod.valid(asset) then
        LoadAsset(path)
        asset = mod.lib(path)
    end
    return asset
end

local function updateStatusEffect(sample, elapsed)
    local index = math.floor(elapsed / secondsPerEffect) % #statusEffects + 1
    if index ~= sample.index then
        local name, asset = table.unpack(statusEffects[index])
        local material = sample.materials[index]
        if not material then
            sample.overlay:SetBrushFromMaterial(
                previewAsset("/Game/Player/StatusEffectVisualizers/" .. asset)
            )
            material = sample.overlay:GetDynamicMaterial()
            assert(mod.valid(material), "status preview material unavailable: " .. name)
            material:SetScalarParameterValue(FName("Scale"), 1)
            sample.materials[index] = material
        else
            sample.overlay:SetBrushFromMaterial(material)
        end
        sample.label:SetText(FText(name))
        sample.index = index
    end
    local material = sample.materials[index]
    local phase = elapsed % secondsPerEffect
    material:SetScalarParameterValue(
        FName("Opacity"),
        math.min(1, (phase + 0.05) * 4, (secondsPerEffect - phase) * 4)
    )
    material:SetScalarParameterValue(FName("Pulse"), 0.8 + 0.2 * math.cos(phase * math.pi))
end

local function updateItemCard(page, elapsed, enabled)
    local index = math.floor(elapsed / secondsPerItem) % #sampleItems + 1
    local card = state.itemCard
    if not card then
        card = {
            titleStyle = previewAsset("/Game/UI/UI_Style/FontStyles/BigTextStyle.BigTextStyle_C"),
            statStyle = previewAsset("/Game/UI/UI_Style/FontStyles/StatText.StatText_C"),
            loreClass = previewAsset("/Game/UI/Widgets/FS_DescriptionText.FS_DescriptionText_C"),
            stats = {},
        }
        state.itemCard = card
    end
    if card.index ~= index then
        local item = previewAsset(sampleItems[index])
        local rows = itemStats.buildItemStatRows(page, item, true)
        state.panel:ClearChildren()
        backdrop(page, 86, 135, 868, 610)
        local icon = mod.widget(page, "Image")
        icon:SetBrushFromTexture(item.ItemIcon, false)
        place(state.panel, icon, 126, 168, 108, 108)
        label(page, item.Name:ToString(), 254, 198, 648, 76, card.titleStyle)
        local statsTop = 709 - #rows * 48
        local lore = mod.lib("/Script/UMG.Default__WidgetBlueprintLibrary")
            :Create(page, card.loreClass, page:GetOwningPlayer())
        assert(mod.valid(lore), "could not create inventory description widget")
        lore:SetClipping(1)
        place(state.panel, lore, 126, 300, 788, statsTop - 316)
        -- Set the localized lore directly: the inspect screen's item binding expects its inventory context.
        lore.MainTextBlock:SetText(item["Item Description"])
        card.stats = {}
        for rowIndex, row in ipairs(rows) do
            local top = statsTop + (rowIndex - 1) * 48
            table.insert(card.stats, label(page, row[1], 126, top, 477, 47, card.statStyle))
            table.insert(card.stats, label(page, row[2], 612, top, 300, 47, card.statStyle, 2))
        end
        card.index, card.enabled = index, nil
    end
    if card.enabled ~= enabled then
        for _, textBlock in ipairs(card.stats) do
            textBlock:SetVisibility(enabled and 3 or 1)
        end
        card.enabled = enabled
    end
end

-- A dedicated capture leaves the player's view target, video settings and native orbit untouched.
-- The graphics comparison demonstrates render resolution, not a global preset switch.
local function frameScene(page, visualizer, kind, enabled)
    local graphics, damage = kind == "graphics", kind == "enemyHpBars"
    local status = kind == "statusNames"
    local base = visualizer:K2_GetActorLocation()
    local eye = graphics and { -262, -231, 122 } or { 340, -515, 175 }
    local subject = graphics and { -12, -9, 58 } or (damage and { 58, -72, 76 } or { 123, -151, 53 })
    local dx, dy, dz = subject[1] - eye[1], subject[2] - eye[2], subject[3] - eye[3]
    local component = visualizer:AddComponentByClass(
        mod.lib("/Script/Engine.SceneCaptureComponent2D"),
        false,
        identity,
        true
    )
    assert(mod.valid(component), "scene capture unavailable")
    state.capture = component
    component.bCaptureEveryFrame, component.bCaptureOnMovement = false, false
    component.CaptureSource = 3 -- final LDR color
    component.FOVAngle = graphics and 59 or 49
    visualizer:FinishAddComponent(component, false, identity)
    if status then
        local camera = visualizer.Camera
        assert(
            mod.valid(camera) and component:K2_AttachToComponent(camera, FName("None"), 2, 2, 2, false),
            "could not follow the Video scene camera"
        )
        component.FOVAngle = camera.FieldOfView
    else
        component:SetAbsolute(true, true, true)
        component:K2_SetWorldLocation(
            { X = base.X + eye[1], Y = base.Y + eye[2], Z = base.Z + eye[3] },
            false,
            {},
            false
        )
        component:K2_SetWorldRotation({
            Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))),
            Yaw = math.deg(math.atan(dy, dx)),
            Roll = 0,
        }, false, {}, false)
    end
    local low = graphics and not enabled
    local width = state.previewWidth
    local rt = mod.lib(renderLib):CreateRenderTarget2D(
        page,
        math.floor(width * (low and 0.25 or 1) + 0.5),
        low and 220 or 880,
        2,
        { R = 0, G = 0, B = 0, A = 1 },
        false
    )
    assert(mod.valid(rt), "scene target unavailable")
    state.target = rt
    component.TextureTarget = rt
    component:CaptureScene()
    component.bCaptureEveryFrame = status
    local image = mod.widget(page, "Image")
    image:SetBrushResourceObject(rt)
    place(state.panel, image, 0, 0, width, 880)
    if status then
        local overlay = place(state.panel, mod.widget(page, "Image"), 0, 0, width, 880)
        local name = label(page, "", 30, 742, 260, 38)
        name:SetVisibility(enabled and 3 or 1)
        state.status = { label = name, overlay = overlay, materials = {} }
    elseif graphics then
        label(page, enabled and "Resolution sample: full" or "Resolution sample: retro", 35, 38, 950, 75)
    elseif damage and enabled ~= 0 then
        local zoneClass =
            previewAsset("/Game/UI/HUD/Widgets/EnemyHealthBar/EnemyStatusZone.EnemyStatusZone_C")
        local zone = mod.lib("/Script/UMG.Default__WidgetBlueprintLibrary")
            :Create(page, zoneClass, page:GetOwningPlayer())
        assert(
            mod.valid(zone) and mod.valid(zone.EnemyHealthBar_base),
            "native enemy bar preview unavailable"
        )
        local bar = zone.EnemyHealthBar_base
        bar:PreConstruct(false)
        bar.EnemyName:SetText(FText("Skeleton"))
        local frame = bar.BG
        local size = frame.Slot:GetSize()
        -- Mount only the art and name row, not the gameplay widget that binds combat events and fades with its target.
        frame:RemoveFromParent()
        place(state.panel, frame, (width - size.X) / 2, 202, size.X, size.Y)
        state.updateEnemyBar = mod.createEnemyBarSample(bar, enabled == 2)
    end
end

local function mountPanel(page)
    local host = page:GetOuter():GetOuter().VideoOptions
    state.panel = mod.widget(page, "CanvasPanel")
    -- Same 1920x1080 design canvas as the native Video page; never overlap its scroll box.
    local slot = host:AddChildToCanvas(state.panel)
    local card = explanations[state.kind] or state.kind == "itemStats"
    slot:SetPosition({ X = 818 + (card and (state.previewWidth - 1040) / 2 or 0), Y = 100 })
    slot:SetSize({ X = card and 1040 or state.previewWidth, Y = 880 })
    slot:SetZOrder(10)
    state.panel:SetClipping(1)
    state.panel:SetVisibility(3)
end

function mod.updateVideoPreview(page, key, saved)
    local vis = page.ConfigVisInst
    if not mod.valid(vis) then
        return
    end
    if not state or state.page ~= page:GetAddress() or state.scene ~= vis:GetAddress() then
        close()
        state = { page = page:GetAddress(), scene = vis:GetAddress() }
    end
    local kind = (examples[key] or explanations[key]) and key or nil
    local now = os.clock()
    if kind == "shimmer" and not state.herbFailed and now >= (state.retryAt or 0) then
        local ok, ready = pcall(mod.updatePreviewHerb, vis)
        if not ok then
            state.herbFailed = true
            mod.clearPreviewHerb()
            mod.warn("Video herb preview", ready)
        elseif not ready then
            state.retryAt = now + 0.5
            if state.start and state.kind == kind and now - state.start > 5 then
                state.herbFailed = true
                mod.warn("Video herb floor", "Preview floor collision is not ready")
            end
        end
    elseif kind ~= "shimmer" and state.kind == "shimmer" then
        mod.clearPreviewHerb()
        state.retryAt, state.herbFailed = nil, nil
    end
    local enabled = kind and saved[kind]
    if kind == "shimmer" then
        enabled = true -- the herb updates live without rebuilding its camera
    end
    if state.kind == kind and (kind == "itemStats" or explanations[kind]) then
        state.enabled = enabled -- keep the same sample (or help text) when toggled
    end
    if kind == "statusNames" and state.kind == kind and enabled ~= state.enabled and state.status then
        state.status.label:SetVisibility(enabled and 3 or 1)
        state.enabled = enabled
    end
    local viewport = mod.lib("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(page)
    local width = viewport.Y > 0 and math.max(1040, math.floor(1080 * viewport.X / viewport.Y + 0.5) - 880)
        or 1040
    if kind ~= state.kind or enabled ~= state.enabled or width ~= state.previewWidth then
        closePanel()
        state.kind, state.enabled, state.start, state.previewWidth = kind, enabled, now, width
        if not kind then
            return
        end
        local ok, err = pcall(function()
            mountPanel(page)
            local help = explanations[kind]
            if help then
                backdrop(page, 86, 244, 868, 392)
                label(
                    page,
                    help[1],
                    126,
                    284,
                    788,
                    64,
                    previewAsset("/Game/UI/UI_Style/FontStyles/BigTextStyle.BigTextStyle_C")
                )
                label(page, help[2], 126, 374, 788, 224)
            elseif kind ~= "itemStats" then
                frameScene(page, vis, kind, enabled)
            end
        end)
        if not ok then
            closePanel()
            mod.warn("Video preview " .. kind, err)
        end
    end
    if kind == "itemStats" and state.panel then
        local ok, err = pcall(updateItemCard, page, now - state.start, enabled)
        if not ok then
            closePanel()
            mod.warn("Video item description", err)
        end
    elseif kind == "statusNames" and state.status then
        local ok, err = pcall(updateStatusEffect, state.status, now - state.start)
        if not ok then
            closePanel()
            mod.warn("Video status effect", err)
        end
    elseif kind == "enemyHpBars" and state.updateEnemyBar then
        local phase = (now - state.start) % 3
        local step = phase < 1 and 0 or (phase < 1 + mod.config.damageSeconds and 1 or 2)
        if step ~= state.lastPhase then
            state.updateEnemyBar(step == 0 and 40 or 28, 40, step == 1 and 12 or nil)
            state.lastPhase = step
        end
    elseif kind == "shimmer" and state.capture then
        state.capture:CaptureScene()
    end
end

function mod.closeVideoPreview(page)
    if state and state.page == page:GetAddress() then
        close()
    end
end

table.insert(mod.reset, function()
    state = nil -- old world and its widgets are no longer safe to dereference
end)
