-- Lists active player effects in the gameplay HUD without changing their duration or visuals.
local B = ...
local ITEM_CLEARANCE = 18 -- HUD units above the usable-item slot

local displayNames = {
    BerserkFruit = "Berserk",
    BerserkPotion = "Berserk",
    IronSkinFruit = "Ironskin",
    IronSkinPotion = "Ironskin",
    MagicRotResist = "Magic Rot resistance",
    RadiantFruit = "Radiant",
    B33Punch = "B33 Punch",
    CaputRing = "Caput Ring",
    b33sment = "B33sment",
}

local function activeStatusText(player)
    local seen, names = {}, {}
    local function include(name)
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    player.StatusEffectComps:ForEach(function(_, element)
        local component = element:get()
        if B.valid(component) and component.Applied then
            local name = component.EffectName:ToString()
            include(displayNames[name] or name)
        end
    end)

    -- These effects are tracked separately by the game's status screen.
    if player.StickyEffectApplied then
        include("Sticky")
    end
    if player.MagicPoisonEffectApplied then
        include("Magic Rot")
    end
    local fire = player.MagicFireEffectLogic
    if B.valid(fire) and fire.CurrentMagicFireDamagePool > 0 then
        include("Burn")
    end
    local sword = player.FlyingSwordChargeLogic
    if B.valid(sword) and #sword.DebuffAppliers > 0 then
        include("Gem Curse")
    end
    if B.hasTravelStride and B.hasTravelStride(player) then
        include("Travel Stride")
    end

    table.sort(names)
    return table.concat(names, "\n")
end

local function createStatusLabel(hud, parent)
    local label = B.widget(hud, "TextBlock")
    local source = hud.InteractText
    if B.valid(source) then
        label:SetFont(source.Font)
    end
    local font = label.Font
    font.Size = 15
    label:SetFont(font)
    label:SetShadowOffset({ X = 1, Y = 1 })
    label:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 1 })
    local slot = parent:AddChildToCanvas(label)
    slot:SetAutoSize(true)
    slot:SetAlignment({ X = 0, Y = 1 })
    slot:SetZOrder(100)
    return label
end

local function alignAboveUsableItem(label, icon)
    -- Both slots share the native item's canvas. Leave its whole slot free, even
    -- when there is no item equipped; additional names grow upward, not over it.
    local iconSlot = icon.Slot
    local position, size = iconSlot:GetPosition(), iconSlot:GetSize()
    if iconSlot:GetAutoSize() then
        size = icon:GetDesiredSize()
    end
    local alignment = iconSlot:GetAlignment()
    local translation = icon.RenderTransform.Translation
    local slot = label.Slot
    slot:SetAnchors(iconSlot:GetAnchors())
    slot:SetPosition({
        X = position.X - size.X * alignment.X + translation.X,
        Y = position.Y - size.Y * alignment.Y + translation.Y - ITEM_CLEARANCE,
    })
end

local hudId, label, lastText
local nextRead = 0
B.hook("/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick", function(context)
    if os.clock() < nextRead then
        return
    end
    nextRead = os.clock() + 0.25
    local hud = context:get()
    if hudId ~= hud:GetAddress() then
        hudId, label, lastText = hud:GetAddress(), nil, nil
    end

    local player = hud.CharRef
    local text = B.valid(player) and activeStatusText(player) or ""
    if text ~= "" then
        local icon = hud.ConsumableHUD
        if not B.valid(icon) or not B.valid(icon:GetParent()) then
            if B.valid(label) then
                label:SetVisibility(1)
            end
            lastText = nil
            return
        end
        local parent = icon:GetParent()
        if not B.valid(label) or not parent:HasChild(label) then
            if B.valid(label) then
                label:RemoveFromParent()
            end
            label = createStatusLabel(hud, parent)
            lastText = nil
        end
        alignAboveUsableItem(label, icon)
        if text ~= lastText then
            label:SetText(FText(text))
            label:SetVisibility(3) -- HitTestInvisible
        end
    elseif text ~= lastText and B.valid(label) then
        label:SetVisibility(1) -- Collapsed
    end
    lastText = text
end)

table.insert(B.reset, function()
    hudId, label, lastText, nextRead = nil, nil, nil, 0
end)
