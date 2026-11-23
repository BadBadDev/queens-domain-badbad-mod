-- Applies BBM's rendering preset when a world loads or the game reapplies its video settings.
local B = ...
local systemLibraryPath = "/Script/Engine.Default__KismetSystemLibrary"
local screenPercentage = B.config.screenPercentage
assert(
    type(screenPercentage) == "number" and screenPercentage >= 50 and screenPercentage <= 200,
    "screenPercentage must be 50..200"
)
local updatingResolution = false

local function applyGraphicsPreset(world, force)
    if updatingResolution then
        return
    end
    if not B.valid(world) then
        return
    end
    local lib = B.lib(systemLibraryPath)
    local function setConsoleVariableIfChanged(key, value)
        if math.abs(lib:GetConsoleVariableFloatValue(key) - value) > 0.001 then
            lib:ExecuteConsoleCommand(world, key .. " " .. value, nil)
        end
    end
    local gameInstance = B.lib("/Script/Engine.Default__GameplayStatics"):GetGameInstance(world)
    if B.valid(gameInstance) and B.valid(gameInstance.ActiveSystemSave) then
        local options = gameInstance.ActiveSystemSave
        local savedRetroLock, savedResolutionScale = options.LockedResScale, options.ResScale
        if
            (savedRetroLock or savedResolutionScale ~= screenPercentage)
            and (
                force
                or math.abs(lib:GetConsoleVariableFloatValue("r.ScreenPercentage") - screenPercentage)
                    > 0.01
            )
        then
            -- Run the same resolution update as the Video menu (including render targets).
            -- Scope the override to this call; do not save changes to native preferences.
            updatingResolution = true
            local ok, err = pcall(function()
                options.LockedResScale, options.ResScale = false, screenPercentage
                gameInstance["UpdateScreen%"](gameInstance, true)
            end)
            options.LockedResScale, options.ResScale = savedRetroLock, savedResolutionScale
            updatingResolution = false
            if not ok then
                error(err)
            end
        end
    end
    setConsoleVariableIfChanged("r.ScreenPercentage", screenPercentage)
    setConsoleVariableIfChanged("r.MaxAnisotropy", 16)
    setConsoleVariableIfChanged("r.DefaultFeature.AntiAliasing", 2)
    setConsoleVariableIfChanged("r.PostProcessAAQuality", 4)
    local asset = StaticFindObject("/Game/BaseMaterials/Resources/PixelFilter_MPC.PixelFilter_MPC")
    if B.valid(asset) then
        local material = B.lib("/Script/Engine.Default__KismetMaterialLibrary")
        material:SetScalarParameterValue(world, asset, FName("EnableDither"), 0)
        material:SetScalarParameterValue(world, asset, FName("PixelFilter"), 0)
        -- Not all installed materials expose the smooth-colour parameter.
        asset.ScalarParameters:ForEach(function(_, p)
            if p:get().ParameterName:ToString() == "QD_SmoothColours" then
                material:SetScalarParameterValue(world, asset, FName("QD_SmoothColours"), 2)
            end
        end)
    end
end

B.hook("/Script/Engine.PlayerController:ClientRestart", function(ctx)
    applyGraphicsPreset(ctx:get(), true)
end)
for _, event in ipairs({ "UpdateScreen%", "ApplyOptions" }) do
    B.hook("/Game/Blueprints/FS_GameInstance.FS_GameInstance_C:" .. event, function(ctx)
        applyGraphicsPreset(ctx:get(), event == "ApplyOptions")
    end)
end
-- Also handles a late mod load; do not rewrite the player's SystemSave.
local needsInitialApply = true

B.hook("/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick", function(ctx)
    if needsInitialApply then
        applyGraphicsPreset(ctx:get(), true)
        needsInitialApply = false
    end
end)

table.insert(B.reset, function()
    needsInitialApply = true
end)
