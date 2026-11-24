-- Tracks nearby pickups and manages their material pulses, optional markers and High-mode light shafts.
-- Works by animating the Color_Brightness and Emissive_Brightness parameters of each pickup's own material.
-- ColorBlind mode also adds a coloured light and a letter marker to near pickups. Pickup materials have no colour
-- setting that shows (GlowColor and LevelUpFXColor changed nothing on screen), so the colour comes from a light.
--
-- Safety rule: never keep a UObject between ticks. Levels unload and free their actors, and touching
-- a kept reference (even IsValid) can then crash the game. Only object paths are stored, and each one
-- is looked up fresh with StaticFindObject, which simply finds nothing once the object is gone.
--
-- Cost rules, measured on the game thread on official UE4SS v3.0.1 (newer builds take under 1 ms for all of these):
-- - FindFirstOf and FindAllOf walk every object: 70 ms each. They never run per tick. New pickups and the player
--   controller come from a BeginPlay hook. A whole-game search is only used if that hook never fires.
-- - StaticFindObject: 11-67 ms the first time it sees a path, then nothing. So paths are only looked up when a
--   pickup is near, and on a slow build only one new path per SlowLookupGap seconds.
-- - StaticFindObject on a path that no longer exists: 55 ms, every time. So a collected pickup is forgotten at once.
local B = ...
local cfg = {
    Enabled = true,
    Strength = 1.0,
    Rest = 0.15,
    ColorPeak = 4.0,
    EmissivePeak = 1.0,
    PulseSeconds = 2.0,
    Sharpness = 2.0,
    RangeUnits = 5000,
    Exclude = {},
    Debug = false,
    PulseTickMs = 50,
    MaxPulsing = 32,
    BudgetMs = 1.5,
    NearUnits = 2000,
    FarEvery = 4,
    SlowLookupGap = 1.0,
    SlowBuildFarPickups = false,
    RescanSeconds = 30,
    ColorBlind = "off",
    LightColor = false,
    LightStrength = 1.0,
    LightUnits = 1500,
    MaxLights = 8,
    Marker = true,
    MarkerText = "V",
    MarkerColor = false,
}
if not cfg.Enabled then
    return
end

local TAG = "[BBM] Shimmer: "
-- UE4SS 2.x crashes this game within about a minute of these mods running, even with no hooks and a long wait at
-- startup, while it runs fine with no mods. So the mods stay off there and the game keeps working.
-- RegisterLoadMapPreHook is only used as a version check: it appeared in v3.0.0. It must never be called, see below.
if RegisterLoadMapPreHook == nil then
    print(
        TAG
            .. "not running: this needs UE4SS v3.0.0 or newer. This UE4SS is too old and crashes the game with this mod.\n"
    )
    return
end

-- For xpcall: UE4SS errors have no message, so say where they happened. Only runs when something has failed.
local function formatShimmerError(err)
    local text = type(err) == "string" and err or ("a UE4SS call failed (" .. type(err) .. ")")
    local where = {}
    local tb = debug and debug.traceback and debug.traceback("", 2) or ""
    for line in tostring(tb):gmatch("main%.lua:(%d+)") do
        where[#where + 1] = line
        if #where == 4 then
            break
        end
    end
    return #where > 0 and (text .. " at line " .. table.concat(where, " < ")) or text
end

-- Every different error is logged once, however often it happens, so a repeating one can't slow the game down.
local errorsSeen, errorsLogged = {}, 0

local function logError(err)
    -- UE4SS sometimes raises a function instead of a message, with a new address each time.
    local text = type(err) == "string" and err or ("a UE4SS call failed (" .. type(err) .. ")")
    if errorsSeen[text] or errorsLogged >= 10 then
        return
    end
    errorsSeen[text], errorsLogged = true, errorsLogged + 1
    print(TAG .. "error: " .. text .. "\n")
end

pcall(collectgarbage, "generational") -- short collections, instead of a long pause every so often

local PICKUP_CLASS = "ItemPickup_Base_C"
local RANGE2, NEAR2 = cfg.RangeUnits * cfg.RangeUnits, cfg.NearUnits * cfg.NearUnits
local EMISSIVE, COLOR, UNUSED = FName("Emissive_Brightness"), FName("Color_Brightness"), FName("BBM_Unused")
local TWO_PI = math.pi * 2
local MAX_ACTIVATE_PER_TICK = 2 -- making a material copy is the priciest call, so a full room spreads out
local SCAN_PER_TICK = 40 -- mostly plain arithmetic on remembered positions
local SKIP_SECONDS = 4 -- how long a pickup that can't pulse right now is left alone
local SLOW_LOOKUP_MS = 4 -- a first-time lookup slower than this means this UE4SS has the slow path

-- ColorBlind presets. Light colours sit where each type still sees a clear difference from green and brown.
local PRESETS = {
    ["red-green"] = { light = { R = 0.1, G = 0.35, B = 1.0, A = 1 }, marker = { 255, 230, 60 } }, -- blue light, yellow marker
    ["blue-yellow"] = { light = { R = 1.0, G = 0.15, B = 0.5, A = 1 }, marker = { 255, 255, 255 } }, -- pink-red light
    ["no-color"] = { light = { R = 1.0, G = 1.0, B = 1.0, A = 1 }, marker = { 255, 255, 255 } }, -- white light
}
local CB = cfg.ColorBlind ~= "off" and cfg.ColorBlind ~= false and PRESETS[cfg.ColorBlind] or nil
if cfg.ColorBlind and cfg.ColorBlind ~= "off" and not CB then
    print(
        TAG
            .. 'ColorBlind = "'
            .. tostring(cfg.ColorBlind)
            .. '" isn\'t known. Use "red-green", "blue-yellow", "no-color" or "off".\n'
    )
end
local LIGHT2 = cfg.LightUnits * cfg.LightUnits
local LIGHT_RADIUS, LIGHT_PEAK = 220, 1600 * cfg.LightStrength
local NO_TRANSFORM = {
    Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
    Translation = { X = 0, Y = 0, Z = 0 },
    Scale3D = { X = 1, Y = 1, Z = 1 },
}
local partClass = {} -- found once, the first time a part is made

local function loadMarkerAsset(path)
    local obj = StaticFindObject(path)
    if not B.valid(obj) then
        LoadAsset(path)
        obj = StaticFindObject(path)
    end
    assert(B.valid(obj), "pickup marker asset missing: " .. path)
    return obj
end
-- GodRay_Cutout starts at its pivot and runs 100 cm along +X. Its shader
-- expands the strip toward the camera using the same data slots as BP_LightBeam.
local beamHeight = 140
local beamScale = { X = beamHeight / 100, Y = beamHeight / 100, Z = beamHeight / 100 }
local beamTransform = {
    Rotation = NO_TRANSFORM.Rotation,
    Translation = NO_TRANSFORM.Translation,
    Scale3D = beamScale,
}

local function setPickupBeamVisible(e, actor, visible)
    if visible == (e.beamOn == true) then
        return
    end
    local comp = e.beamPath and StaticFindObject(e.beamPath)
    if visible and not B.valid(comp) then
        local mesh = loadMarkerAsset("/Game/VFX/Meshes/GodRay_Cutout.GodRay_Cutout")
        local mat = loadMarkerAsset("/Game/VFX/Environment/Materials/M_GodRay_Animated.M_GodRay_Animated")
        comp =
            actor:AddComponentByClass(B.lib("/Script/Engine.StaticMeshComponent"), false, beamTransform, true)
        assert(B.valid(comp), "beam component unavailable")
        e.beamPath = comp:GetFullName():match("^%S+ (.+)$")
        comp:SetVisibility(false, false)
        comp:SetCollisionEnabled(0)
        comp:SetGenerateOverlapEvents(false)
        comp:SetCastShadow(false)
        comp:SetStaticMesh(mesh)
        comp:SetMaterial(0, mat)
        actor:FinishAddComponent(comp, false, beamTransform)
        comp:SetCustomPrimitiveDataFloat(0, 16) -- width in cm
        comp:SetCustomPrimitiveDataFloat(1, beamHeight)
        comp:SetCustomPrimitiveDataVector4(2, { X = 1, Y = 0.88, Z = 0.65, W = 1 })
        comp:SetCustomPrimitiveDataFloat(7, 5) -- the soft ray mask attenuates the emissive output
        comp:SetCustomPrimitiveDataFloat(8, 15) -- depth fade in cm
        comp:SetCustomPrimitiveDataFloat(11, 0.35 / 10)
        comp:SetCustomPrimitiveDataFloat(12, 0.35 / 3)
        comp:SetBoundsScale(5) -- include the shader-expanded width during culling
        comp:K2_SetWorldLocation(actor:K2_GetActorLocation(), false, {}, false)
        comp:K2_SetWorldRotation({ Pitch = 90, Yaw = 0, Roll = 0 }, false, {}, false)
        comp:SetWorldScale3D(beamScale)
    end
    if B.valid(comp) then
        comp:SetVisibility(visible, false)
    end
    e.beamOn = visible
end

local function createArrowMesh(actor, shape, scale, rotation)
    local mesh = loadMarkerAsset("/Engine/BasicShapes/" .. shape .. "." .. shape)
    local material = loadMarkerAsset("/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial")
    local part =
        actor:AddComponentByClass(B.lib("/Script/Engine.StaticMeshComponent"), false, NO_TRANSFORM, true)
    assert(B.valid(part), "could not create arrow " .. shape)
    part:SetVisibility(false, false)
    part:SetCollisionEnabled(0)
    part:SetGenerateOverlapEvents(false)
    part:SetCastShadow(false)
    part:SetStaticMesh(mesh)
    part:SetMaterial(0, material)
    actor:FinishAddComponent(part, false, NO_TRANSFORM)
    part:SetAbsolute(false, true, true)
    part:K2_SetWorldRotation(rotation, false, {}, false)
    part:SetWorldScale3D(scale)
    part:SetVectorParameterValueOnMaterials(FName("Color"), { X = 1.5, Y = 0.005, Z = 0.01 })
    local lower, upper = {}, {}
    part:GetLocalBounds(lower, upper)
    return part, lower.Z * scale.Z, upper.Z * scale.Z
end

local function updatePickupArrow(entry, actor, visible, now, graphics)
    if not visible and not entry.arrowOn then
        return
    end
    local shaft = entry.arrowPath and StaticFindObject(entry.arrowPath)
    if not visible then
        if B.valid(shaft) then
            shaft:SetVisibility(false, true)
        end
        entry.arrowOn = false
        return
    end

    local p = actor:K2_GetActorLocation()
    if not B.valid(shaft) then
        local center, extent = {}, {}
        B.lib("/Script/Engine.Default__KismetSystemLibrary"):GetComponentBounds(graphics, center, extent, {})
        local tipZ = p.Z + math.max(0, center.Z + extent.Z - p.Z) + 18
        local shaftBottom
        shaft, shaftBottom = createArrowMesh(
            actor,
            "Cylinder",
            { X = 0.12, Y = 0.12, Z = 0.28 },
            { Pitch = 0, Yaw = 0, Roll = 0 }
        )
        local head, headBottom, headTop = createArrowMesh(
            actor,
            "Cone",
            { X = 0.36, Y = 0.36, Z = 0.22 },
            { Pitch = 0, Yaw = 0, Roll = 180 }
        )
        entry.shaftOffset = tipZ - p.Z + headTop - headBottom - shaftBottom
        shaft:K2_SetWorldLocation({ X = p.X, Y = p.Y, Z = p.Z + entry.shaftOffset }, false, {}, false)
        -- Keep world transforms while parenting: both parts bob and hide as one,
        -- independently of the pickup's own scale or rotation.
        head:K2_SetWorldLocation({ X = p.X, Y = p.Y, Z = tipZ + headTop }, false, {}, false)
        assert(head:K2_AttachToComponent(shaft, FName("None"), 1, 1, 1, false), "could not attach arrowhead")
        entry.arrowPath = assert(shaft:GetFullName():match("^%S+ (.+)$"))
    end
    local bob = 6 * math.sin(TWO_PI * (now / 0.9 + entry.phase))
    shaft:K2_SetWorldLocation({ X = p.X, Y = p.Y, Z = p.Z + entry.shaftOffset + bob }, false, {}, false)
    if not entry.arrowOn then
        shaft:SetVisibility(true, true)
    end
    entry.arrowOn = true
end

local function hasWorldMarker()
    return B.shimmer == "high" or B.shimmer == "arrow"
end

local lightsOn = 0

local items, byPath, live = {}, {}, {} -- list of entries, path -> entry, entries now pulsing
local pending = {} -- from the BeginPlay hook, added on the next tick
local classOk = {} -- class name -> "pickup", "pc" or false
local cursor, liveStart, tickCount = 1, 1, 0
local hookFired, rescanAt = false, 2
local nextFreshAt, nextFarAt, slowBuild = 0, 0, false
local pcPath, pcRetryAt = nil, 0
local START_DELAY_SECONDS, START_FALLBACK_SECONDS = 3, 60
local stats = {
    ticks = 0,
    totalMs = 0,
    maxMs = 0,
    rescanMs = 0,
    over2 = 0,
    hookMs = 0,
    hookCalls = 0,
    freshMs = 0,
    fresh = 0,
}

local function findObjectByPath(path)
    local a = StaticFindObject(path)
    if a and a:IsValid() then
        return a
    end
    return nil
end

-- For a path this mod hasn't looked up yet. Returns found, object. found = false means not its turn, try again later.
-- On a slow build, far pickups aren't worth a visible hitch each, so only near ones start, unless SlowBuildFarPickups is on.
local function resolvePickupWithinLookupBudget(e, now)
    if e.seen then
        return true, findObjectByPath(e.path)
    end
    local far = (e.dist2 or 0) > NEAR2
    if slowBuild and far and not cfg.SlowBuildFarPickups then
        return false, nil
    end
    if now < nextFreshAt or (far and now < nextFarAt) then
        return false, nil
    end
    local s = os.clock()
    local a = findObjectByPath(e.path)
    local ms = (os.clock() - s) * 1000
    e.seen = true
    stats.fresh, stats.freshMs = stats.fresh + 1, stats.freshMs + ms
    if ms > SLOW_LOOKUP_MS then
        slowBuild = true
        nextFreshAt = s + cfg.SlowLookupGap
        nextFarAt = s + cfg.SlowLookupGap * 3
    end
    return true, a
end

local function objectPath(obj)
    local full = obj:GetFullName() -- "Class /Path.To:Object"
    return full:sub((full:find(" ", 1, true) or 0) + 1)
end

local function pulsePhaseFromPath(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 997
    end
    return h / 997
end

-- What kind of actor is this class: "pickup", "pc" or false. Remembered by name, so each class is only worked out once.
local function classifyActor(cls)
    local name = cls:GetFName():ToString()
    local known = classOk[name]
    if known ~= nil then
        return known
    end
    local result, c, depth = false, cls, 0
    while c and c:IsValid() and depth < 16 do
        local n = c:GetFName():ToString()
        if n == PICKUP_CLASS then
            result = "pickup"
            break
        end
        if n == "PlayerController" then
            result = "pc"
            break
        end
        c = c:GetSuperStruct()
        depth = depth + 1
    end
    if cfg.Exclude[name] then
        result = false
    end
    classOk[name] = result
    return result
end

local function trackPickup(path, x, y, z)
    if byPath[path] or path:find("Default__", 1, true) then
        return
    end
    local e = { path = path, phase = pulsePhaseFromPath(path), skipUntil = 0 }
    if x and (x ~= 0 or y ~= 0 or z ~= 0) then -- at the origin = template or not placed yet
        e.x, e.y, e.z = x, y, z
    end
    byPath[path] = e
    items[#items + 1] = e
end

local function removePickupAtIndex(i)
    local e = items[i]
    byPath[e.path] = nil
    items[i] = items[#items]
    items[#items] = nil
    e.live, e.gone = false, true -- removed from the active list on its next animation update
    if e.deco then
        e.deco, lightsOn = false, lightsOn - 1
    end -- its actor is gone, and its parts with it
end

local function forgetPickup(e)
    for i = 1, #items do
        if items[i] == e then
            removePickupAtIndex(i)
            return
        end
    end
    e.live, e.gone = false, true
    if e.deco then
        e.deco, lightsOn = false, lightsOn - 1
    end
end

-- ColorBlind parts: a point light and a text marker added to the pickup actor, made once and then shown or hidden.
-- They belong to the actor, so they go when it goes. Never stored: found again with GetComponentByClass.
-- Official v3.0.1 ignores AddComponentByClass's transform and doesn't finish the component, so this finishes,
-- attaches and places them itself. The marker still doesn't show there; the light does.
local function findMarkerComponent(a, which)
    local cls = partClass[which]
    if cls == nil then
        cls = StaticFindObject(
            which == "light" and "/Script/Engine.PointLightComponent" or "/Script/Engine.TextRenderComponent"
        )
        if not (cls and cls:IsValid()) then
            cls = false
        end
        partClass[which] = cls
    end
    if not cls then
        return nil
    end
    local c = a:GetComponentByClass(cls)
    if c and c:IsValid() then
        return c
    end
    return nil
end

local function attachMarkerComponent(a, which, z)
    if not findMarkerComponent(a, which) and partClass[which] then
        local c = a:AddComponentByClass(partClass[which], false, NO_TRANSFORM, true)
        if not (c and c:IsValid()) then
            return nil
        end
        c:SetMobility(2)
        a:FinishAddComponent(c, false, NO_TRANSFORM)
        c:K2_AttachToComponent(a:K2_GetRootComponent(), FName("None"), 0, 0, 0, false)
        local l = a:K2_GetActorLocation()
        c:K2_SetWorldLocation({ X = l.X, Y = l.Y, Z = l.Z + z }, false, {}, false)
        if which == "light" then
            c:SetCastShadows(false)
            c:SetAttenuationRadius(LIGHT_RADIUS)
            c:SetLightColor(cfg.LightColor or CB.light, true)
        else
            local m = cfg.MarkerColor or CB.marker
            c:K2_SetText(FText(tostring(cfg.MarkerText)))
            c:SetWorldSize(36)
            c:SetHorizontalAlignment(1)
            c:SetVerticalAlignment(2)
            c:SetTextRenderColor({ R = m[1], G = m[2], B = m[3], A = 255 })
        end
        return c
    end
    return nil
end

local function createAccessibilityMarkers(a)
    -- A pickup that came with its own light or text is left alone, so the mod never changes the game's own parts.
    if findMarkerComponent(a, "light") or (cfg.Marker and findMarkerComponent(a, "marker")) then
        return false
    end
    if not attachMarkerComponent(a, "light", 30) then
        return false
    end
    if cfg.Marker then
        attachMarkerComponent(a, "marker", 55)
    end
    return true
end

local function hideAccessibilityMarkers(e, a)
    if not e.deco then
        return
    end
    e.deco, lightsOn = false, lightsOn - 1
    if a then
        local l = findMarkerComponent(a, "light")
        if l then
            l:SetVisibility(false, false)
        end
        local t = cfg.Marker and findMarkerComponent(a, "marker")
        if t then
            t:SetVisibility(false, false)
        end
    end
end

local function updateAccessibilityMarkers(e, a, level, px, py)
    if e.dist2 > LIGHT2 then
        hideAccessibilityMarkers(e, a)
        return
    end
    if not e.deco then
        if e.noDeco or lightsOn >= cfg.MaxLights then
            return
        end
        if not e.made then
            if not createAccessibilityMarkers(a) then
                e.noDeco = true
                return
            end
            e.made = true
        end
        e.deco, lightsOn = true, lightsOn + 1
        local t = cfg.Marker and findMarkerComponent(a, "marker")
        if t then
            t:SetVisibility(true, false)
        end
        local l0 = findMarkerComponent(a, "light")
        if l0 then
            l0:SetVisibility(true, false)
        end
    end
    local l = findMarkerComponent(a, "light")
    if l then
        l:SetIntensity(LIGHT_PEAK * cfg.Strength * (0.3 + 0.7 * level))
    end
    local t = cfg.Marker and findMarkerComponent(a, "marker")
    if t then
        local q = t:K2_GetComponentLocation()
        t:K2_SetWorldRotation(
            { Pitch = 0, Yaw = math.deg(math.atan(py - q.Y, px - q.X)), Roll = 0 },
            false,
            {},
            false
        )
    end
end

-- The whole-game search. Only where the BeginPlay hook doesn't exist, and spaced out by what it costs.
local function discoverExistingPickups(now)
    local started = os.clock()
    local all = FindAllOf(PICKUP_CLASS)
    if all then
        for _, a in ipairs(all) do
            if a:IsValid() and not cfg.Exclude[a:GetClass():GetFName():ToString()] then
                local l = a:K2_GetActorLocation()
                trackPickup(objectPath(a), l.X, l.Y, l.Z)
            end
        end
    end
    local ms = (os.clock() - started) * 1000
    stats.rescanMs = ms
    rescanAt = now + math.max(cfg.RescanSeconds, ms * 0.5) -- at 70 ms that is at least 35 s, 0.2% of the time
end

local function isCollectable(a, gfx)
    return not a.bHidden and not a.Acquired and gfx.bVisible
end

local function restorePickupMaterial(e, gfx, a)
    e.live = false
    if e.beamOn and a then
        setPickupBeamVisible(e, a, false)
    end
    if e.arrowOn then
        updatePickupArrow(e, a, false)
    end
    if e.deco then
        if a then
            local ok, err = xpcall(hideAccessibilityMarkers, formatShimmerError, e, a)
            if not ok then
                logError(err)
            end
        end
        if e.deco then
            e.deco, lightsOn = false, lightsOn - 1
        end
    end
    if gfx and gfx:IsValid() and e.emissive ~= nil then
        gfx:SetScalarParameterValueOnMaterials(EMISSIVE, e.emissive)
        gfx:SetScalarParameterValueOnMaterials(COLOR, e.color)
    end
end

-- Some pickups have a mesh with no material (the meat pedestals), so there is nothing to light up.
local function hasPickupMaterial(e, gfx)
    if e.emissive ~= nil then
        return true
    end
    local m = gfx:GetMaterial(0)
    return m ~= nil and m:IsValid()
end

-- The item's own brightness, to pulse from and restore. Items differ: more than half have an emissive of 0, not 0.2.
-- Not CreateDynamicMaterialInstance: it fails on every pickup on official UE4SS v3.0.1.
local function readPickupBrightness(gfx)
    local m = gfx:GetMaterial(0)
    return m:K2_GetScalarParameterValue(EMISSIVE), m:K2_GetScalarParameterValue(COLOR)
end

local function activatePickupPulse(e, gfx)
    if e.emissive == nil then
        local ok, emissive, color = pcall(readPickupBrightness, gfx)
        if not ok then
            -- Not a dynamic material yet. Setting a parameter it doesn't have makes the copy and changes nothing.
            gfx:SetScalarParameterValueOnMaterials(UNUSED, 0)
            ok, emissive, color = xpcall(readPickupBrightness, formatShimmerError, gfx)
        end
        if not ok then
            logError(emissive)
            return false
        end
        e.emissive, e.color = emissive, color
    end
    e.live, e.last = true, -1
    live[#live + 1] = e
    return true
end

local function pulseLevel(now, phase)
    local wave = 0.5 + 0.5 * math.sin((now / cfg.PulseSeconds + phase) * TWO_PI)
    return cfg.Rest + (1 - cfg.Rest) * wave ^ cfg.Sharpness
end

local function applyPickupBrightness(e, gfx, level)
    local gain = B.shimmer == "medium" and 0.65 + 2.25 * level or cfg.Strength * level
    gfx:SetScalarParameterValueOnMaterials(EMISSIVE, e.emissive + cfg.EmissivePeak * gain)
    gfx:SetScalarParameterValueOnMaterials(COLOR, e.color + cfg.ColorPeak * gain)
end

-- A plain mesh in the preview's streamed level: no pickup interaction, inventory or save callbacks.
local function createPreviewHerb(entry, visualizer)
    local base = visualizer:K2_GetActorLocation()
    -- Bare stone just beyond the seated skeleton's toes in the stock preview.
    local x, y = base.X + 123, base.Y - 151
    local hit, color = {}, { R = 0, G = 0, B = 0, A = 1 }
    local found = B.lib("/Script/Engine.Default__KismetSystemLibrary"):LineTraceSingle(
        visualizer,
        { X = x, Y = y, Z = base.Z + 120 },
        { X = x, Y = y, Z = base.Z - 120 },
        0,
        true,
        {},
        0,
        hit,
        true,
        color,
        color,
        0
    )
    assert(found, "could not locate the stone floor in the Video preview")
    local floorZ = hit.ImpactPoint.Z
    local transform = {
        Rotation = NO_TRANSFORM.Rotation,
        Translation = { X = x, Y = y, Z = floorZ },
        Scale3D = NO_TRANSFORM.Scale3D,
    }
    local herb = "/Game/Items/Consumables/Herb/"
    local mesh = loadMarkerAsset(herb .. "HealingHerbs_00_SM.HealingHerbs_00_SM")
    local leaves = loadMarkerAsset(herb .. "HealingHerbs_02_MI.HealingHerbs_02_MI")
    local gameplay = B.lib("/Script/Engine.Default__GameplayStatics")
    local actor = gameplay:BeginDeferredActorSpawnFromClass(
        visualizer,
        B.lib("/Script/Engine.StaticMeshActor"),
        transform,
        1,
        visualizer
    )
    assert(B.valid(actor), "could not spawn the preview herb")
    entry.path = objectPath(actor)
    actor:SetActorEnableCollision(false)
    local gfx = actor.StaticMeshComponent
    gfx:SetMobility(2)
    gfx:SetCollisionEnabled(0)
    gfx:SetGenerateOverlapEvents(false)
    gfx:SetStaticMesh(mesh)
    gfx:SetMaterial(0, leaves)
    gameplay:FinishSpawningActor(actor, transform)
    local lower, upper = {}, {}
    gfx:GetLocalBounds(lower, upper)
    local scale = 1.65
    gfx:SetWorldScale3D({ X = scale, Y = scale, Z = scale })
    gfx:K2_SetWorldLocation({ X = x, Y = y, Z = floorZ - lower.Z * scale }, false, {}, false)
    gfx:SetScalarParameterValueOnMaterials(UNUSED, 0)
    entry.emissive, entry.color = readPickupBrightness(gfx)
    return actor
end

local preview, videoPagePath
local function clearPreview()
    local actor = preview and preview.path and findObjectByPath(preview.path)
    if actor then
        actor:K2_DestroyActor()
    end
    preview = nil
end

local videoMenu = "/Game/UI/Menus/OptionsMenu/OptionLists/Video_OptionsList.Video_OptionsList_C:"
B.hook(videoMenu .. "Open", function(ctx)
    clearPreview()
    videoPagePath = objectPath(ctx:get())
end)
B.hook(videoMenu .. "Close", function(ctx)
    if videoPagePath == objectPath(ctx:get()) then
        videoPagePath = nil
        clearPreview()
    end
end)
table.insert(B.reset, function()
    preview, videoPagePath = nil, nil
end)

local function updatePreview(now)
    local page = findObjectByPath(videoPagePath)
    if not page then
        videoPagePath = nil
        clearPreview()
        return
    end
    local visualizer = page.ConfigVisInst
    if not B.valid(visualizer) or not page:IsVisible() then
        return -- the native page streams its scene asynchronously
    end
    local ok, err = pcall(function()
        local actor = preview and findObjectByPath(preview.path)
        if not actor then
            preview = { phase = 0 }
            actor = createPreviewHerb(preview, visualizer)
        end
        local gfx = actor.StaticMeshComponent
        applyPickupBrightness(preview, gfx, pulseLevel(now, preview.phase))
        setPickupBeamVisible(preview, actor, B.shimmer == "high")
        updatePickupArrow(preview, actor, B.shimmer == "arrow", now, gfx)
    end)
    if not ok then
        videoPagePath = nil
        clearPreview()
        B.warn("video pickup preview", err)
    end
end

-- At the pulsing limit, a far pickup makes way for a near one, so the one in front of the player always shows.
local function evictDistantPulse(now)
    local far
    for i = 1, #live do
        local o = live[i]
        if o.live and (o.dist2 or 0) > NEAR2 and (not far or o.dist2 > far.dist2) then
            far = o
        end
    end
    if not far then
        return false
    end
    local a = findObjectByPath(far.path)
    restorePickupMaterial(far, a and a.PickupGraphics or nil, a)
    far.skipUntil = now + SKIP_SECONDS
    return true
end

-- Range check. Pickups stay put, so their position is remembered and most of this is plain arithmetic.
local function updatePickupsInRange(now, px, py, pz)
    if #items == 0 then
        return
    end
    local activated = 0
    for _ = 1, math.min(SCAN_PER_TICK, #items) do
        if cursor > #items then
            cursor = 1
        end
        local i = cursor
        local e = items[i]
        if not e then
            break
        end
        cursor = i + 1

        if e.x then
            local dx, dy, dz = e.x - px, e.y - py, e.z - pz
            e.dist2 = dx * dx + dy * dy + dz * dz
            if e.live then
                if e.dist2 > RANGE2 then
                    local a = findObjectByPath(e.path)
                    restorePickupMaterial(e, a and a.PickupGraphics or nil, a)
                end
            elseif
                e.dist2 <= RANGE2
                and now >= e.skipUntil
                and activated < MAX_ACTIVATE_PER_TICK
                and (#live < cfg.MaxPulsing or e.dist2 <= NEAR2)
            then
                local found, a = resolvePickupWithinLookupBudget(e, now)
                if found then
                    if not a then
                        removePickupAtIndex(i)
                        cursor = i
                    else
                        local gfx = a.PickupGraphics
                        if gfx and gfx:IsValid() and isCollectable(a, gfx) then
                            if not hasPickupMaterial(e, gfx) then
                                if hasWorldMarker() and #live < cfg.MaxPulsing then
                                    e.live, e.last = true, -1
                                    live[#live + 1] = e
                                    activated = activated + 1
                                else
                                    e.skipUntil = now + SKIP_SECONDS
                                end
                            elseif #live < cfg.MaxPulsing or evictDistantPulse(now) then
                                if activatePickupPulse(e, gfx) then
                                    activated = activated + 1
                                else
                                    removePickupAtIndex(i)
                                    cursor = i
                                end
                            else
                                e.skipUntil = now + SKIP_SECONDS
                            end
                        elseif a.Acquired then
                            removePickupAtIndex(i)
                            cursor = i
                        else
                            e.skipUntil = now + SKIP_SECONDS
                        end
                    end
                end
            end
        elseif now >= e.skipUntil then
            -- Not placed when it was found (usually an enemy drop), so the position has to be read now.
            local found, a = resolvePickupWithinLookupBudget(e, now)
            if found then
                if a then
                    local l = a:K2_GetActorLocation()
                    if l.X ~= 0 or l.Y ~= 0 or l.Z ~= 0 then
                        e.x, e.y, e.z = l.X, l.Y, l.Z
                    else
                        e.skipUntil = now + SKIP_SECONDS
                    end
                else
                    removePickupAtIndex(i)
                    cursor = i
                end
            end
        end
    end
end

local function animateActivePickups(now, deadline, px, py)
    local count = #live
    if count == 0 then
        return
    end
    if liveStart > count then
        liveStart = 1
    end
    local i, visited, removed = liveStart, 0, false
    while visited < count do
        local e = live[i]
        visited = visited + 1
        if e.live then
            local far = (e.dist2 or 0) > NEAR2
            if not far or (tickCount + i) % cfg.FarEvery == 0 then
                local level = pulseLevel(now, e.phase)
                if B.shimmer == "arrow" or math.abs(level - e.last) > 0.01 or e.mode ~= B.shimmer then
                    local a = findObjectByPath(e.path)
                    local gfx = a and a.PickupGraphics
                    if not (gfx and gfx:IsValid()) then
                        if e.arrowOn then
                            updatePickupArrow(e, a, false)
                        end
                        forgetPickup(e)
                        removed = true
                    elseif not isCollectable(a, gfx) then
                        restorePickupMaterial(e, gfx, a) -- collected or hidden: back to normal immediately
                        if a.Acquired then
                            forgetPickup(e)
                        else
                            e.skipUntil = now + SKIP_SECONDS
                        end
                        removed = true
                    else
                        if not e.beamFailed then
                            local ok, why = pcall(setPickupBeamVisible, e, a, B.shimmer == "high")
                            if not ok then
                                e.beamFailed = true
                                B.warn("high shimmer beam", why)
                            end
                        end
                        if not e.arrowFailed then
                            local ok, why = pcall(updatePickupArrow, e, a, B.shimmer == "arrow", now, gfx)
                            if not ok then
                                e.arrowFailed = true
                                B.warn("pickup arrow", why)
                            end
                        end
                        if e.emissive ~= nil then
                            applyPickupBrightness(e, gfx, level)
                        elseif not hasWorldMarker() then
                            e.live = false
                            removed = true
                        end
                        e.mode = B.shimmer
                        e.last = level
                        if CB and not e.noDeco then
                            local ok, err =
                                xpcall(updateAccessibilityMarkers, formatShimmerError, e, a, level, px, py)
                            if not ok then
                                e.noDeco = true
                                if e.deco then
                                    e.deco, lightsOn = false, lightsOn - 1
                                end
                                logError(err)
                            end
                        end
                    end
                end
            end
        else
            removed = true
        end
        i = i % count + 1
        if os.clock() > deadline then
            break
        end -- out of time: the rest get their turn first next tick
    end
    liveStart = i
    if removed then
        local j = 1
        for k = 1, count do
            local e = live[k]
            if e.live then
                live[j] = e
                j = j + 1
            end
        end
        for k = j, count do
            live[k] = nil
        end
    end
end

local function resolvePlayerPawn(now)
    local pc = pcPath and findObjectByPath(pcPath)
    if not pc then
        pcPath = nil
        -- Normally the hook supplies this. The search is a slow last resort, so it is rarely retried.
        if now < pcRetryAt then
            return nil
        end
        pcRetryAt = now + (hookFired and 20 or 5)
        pc = FindFirstOf("PlayerController")
        if not (pc and pc:IsValid()) then
            return nil
        end
        pcPath = objectPath(pc)
    end
    local pawn = pc.Pawn
    if pawn and pawn:IsValid() then
        return pawn
    end
    return nil
end

local function reportShimmerTimings(ms)
    stats.ticks, stats.totalMs = stats.ticks + 1, stats.totalMs + ms
    if ms > stats.maxMs then
        stats.maxMs = ms
    end
    if ms > 2 then
        stats.over2 = stats.over2 + 1
    end
    if stats.ticks >= 200 then
        print(
            string.format(
                "%savg %.3f ms, max %.3f ms, over2ms %d, new paths %d avg %.1f ms, rescan %.1f ms, hook %.3f ms over %d calls, pulsing %d of %d, lights %d, lua %.0f kb\n",
                TAG,
                stats.totalMs / stats.ticks,
                stats.maxMs,
                stats.over2,
                stats.fresh,
                stats.fresh > 0 and stats.freshMs / stats.fresh or 0,
                stats.rescanMs,
                stats.hookMs,
                stats.hookCalls,
                #live,
                #items,
                lightsOn,
                collectgarbage("count")
            )
        )
        stats.ticks, stats.totalMs, stats.maxMs, stats.over2, stats.hookMs, stats.hookCalls, stats.fresh, stats.freshMs =
            0, 0, 0, 0, 0, 0, 0, 0
    end
end

local function updateNearbyPickupEffects()
    local started = os.clock()
    if videoPagePath then
        updatePreview(started)
    end
    tickCount = tickCount + 1
    if #pending > 0 then
        local p = pending
        pending = {}
        for i = 1, #p do
            trackPickup(p[i].path, p[i].x, p[i].y, p[i].z)
        end
    end
    local pawn = resolvePlayerPawn(started)
    if pawn then
        if started >= rescanAt then
            discoverExistingPickups(started)
            if hookFired then
                rescanAt = math.huge
            end
        end
        local p = pawn:K2_GetActorLocation()
        updatePickupsInRange(started, p.X, p.Y, p.Z)
        animateActivePickups(started, started + cfg.BudgetMs / 1000, p.X, p.Y)
    end
    if cfg.Debug then
        local ms = (os.clock() - started) * 1000
        if ms > 8 then
            print(string.format("%sslow tick %.0f ms, pulsing %d of %d\n", TAG, ms, #live, #items))
        end
        reportShimmerTimings(ms)
    end
end

local bindFallbackPlayerTick -- set with the loop at the end of this file
local hookTryAt = 0 -- the character class may load after the controller, so actors spawning retry the hook now and then

-- New pickups, including enemy drops, as they appear. Not in every UE4SS, so the rescan above covers the rest.
pcall(function()
    RegisterBeginPlayPostHook(function(ctx)
        local s = cfg.Debug and os.clock()
        local ok, err = xpcall(function()
            hookFired = true -- any actor at all shows the hook works here
            local now = os.clock()
            if now >= hookTryAt then
                hookTryAt = now + 1
                bindFallbackPlayerTick()
            end
            local actor = ctx:get()
            if actor and actor:IsValid() then
                local kind = classifyActor(actor:GetClass())
                if kind == "pickup" then
                    local l = actor:K2_GetActorLocation()
                    pending[#pending + 1] = { path = objectPath(actor), x = l.X, y = l.Y, z = l.Z }
                elseif kind == "pc" then
                    pcPath = objectPath(actor)
                    bindFallbackPlayerTick()
                end
            end
        end, formatShimmerError)
        if not ok then
            logError(err)
        end
        if s then
            stats.hookMs = stats.hookMs + (os.clock() - s) * 1000
            stats.hookCalls = stats.hookCalls + 1
        end
    end)
end)

-- Touching the engine during game startup crashes official UE4SS releases, so nothing below runs until the game
-- reports its first world. If that hook never fires, a fixed wait takes over.
local openAt = START_FALLBACK_SECONDS
pcall(function()
    RegisterInitGameStatePostHook(function()
        openAt = math.min(openAt, os.clock() + START_DELAY_SECONDS)
        -- A new map frees everything, so drop all stored paths and search again shortly.
        -- Not RegisterLoadMapPreHook: on v3.0.0 and v3.0.1 it throws on the game thread and crashes the game.
        items, byPath, live, pending, cursor, liveStart, lightsOn = {}, {}, {}, {}, 1, 1, 0
        pcPath, pcRetryAt, rescanAt = nil, os.clock() + 5, 0
        pcall(bindFallbackPlayerTick)
    end)
end)

local function runShimmerUpdateWhenReady()
    if os.clock() < openAt then
        return
    end
    local ok, err = xpcall(updateNearbyPickupEffects, formatShimmerError)
    if not ok then
        logError(err)
    end
end
-- The loop. Every call runs on the game thread, so no second thread ever touches this mod's Lua state.
-- Newer UE4SS: LoopInGameThreadWithDelay. Official v3.0.0 and v3.0.1 don't have it, and LoopAsync, the only loop
-- they have, runs Lua on another thread while the game thread runs this mod's hooks. UE4SS has deprecated it as
-- unsafe, and players saw crashes from it. So there the mod rides one of the game's own per-frame Blueprint events
-- instead: the player character's tick. It is hooked again if the game reloads that class.
local TICK_FN = "/Game/Player/FS_PlayerChar.FS_PlayerChar_C:ReceiveTick"
local tickAddress, nextTickAt = nil, 0
bindFallbackPlayerTick = function()
    if LoopInGameThreadWithDelay then
        return
    end
    local f = StaticFindObject(TICK_FN)
    if not (f and f:IsValid()) then
        return
    end
    local address = f:GetAddress()
    if address == tickAddress then
        return
    end
    local ok, err = pcall(RegisterHook, TICK_FN, function()
        local now = os.clock()
        if now < nextTickAt then
            return
        end
        nextTickAt = now + cfg.PulseTickMs / 1000
        runShimmerUpdateWhenReady()
    end)
    if ok then
        tickAddress = address
    else
        logError(err)
    end
end
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(cfg.PulseTickMs, function()
        runShimmerUpdateWhenReady()
    end)
end
print(TAG .. "loaded" .. (CB and (", colour-blind mode " .. cfg.ColorBlind) or "") .. "\n")
