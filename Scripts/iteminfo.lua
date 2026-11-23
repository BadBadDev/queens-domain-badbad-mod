-- Builds native-style item description rows and the inventory's healing-bonus readout.
local bbm = ...
local itemStats = assert(loadfile(bbm.dir .. "itemstats.lua"))(bbm)
local descriptionPanels, healingRows = {}, {}

local function appendStatTextCell(owner, box, text, styleSource, rightAligned)
    local label = bbm.widget(owner, "TextBlock")
    label:SetFont(styleSource.Font)
    label:SetColorAndOpacity(styleSource.ColorAndOpacity)
    label:SetShadowOffset(styleSource.ShadowOffset)
    label:SetShadowColorAndOpacity(styleSource.ShadowColorAndOpacity)
    label:SetJustification(rightAligned and 2 or 0)
    label:SetAutoWrapText(true)
    label:SetVisibility(3)
    label:SetText(FText(text))

    local slot = box:AddChildToHorizontalBox(label)
    slot:SetSize({ SizeRule = 1, Value = 1 })
    slot:SetVerticalAlignment(2)
    return label
end

local function findNativeLabelStyle(valueStyle)
    local nativeRow = valueStyle:GetParent()
    local textClass = bbm.lib("/Script/UMG.TextBlock")
    for index = 0, nativeRow:GetChildrenCount() - 1 do
        local child = nativeRow:GetChildAt(index)
        if child:GetAddress() ~= valueStyle:GetAddress() and child:IsA(textClass) then
            return child
        end
    end
    return valueStyle
end

local function appendStatRow(owner, parent, statName, statValue, valueStyle)
    local box = bbm.widget(owner, "HorizontalBox")
    box:SetVisibility(3)
    appendStatTextCell(owner, box, statName, findNativeLabelStyle(valueStyle), false)
    local valueLabel = appendStatTextCell(owner, box, statValue, valueStyle, true)
    local slot = parent:AddChildToVerticalBox(box)
    slot:SetHorizontalAlignment(0) -- Fill, so right-aligned values share the stock right edge.
    return valueLabel
end

local function refreshItemDescription(owner, item, scrollField, weaponStatsField)
    local parent = owner[scrollField]
    if not bbm.valid(parent) then
        return
    end

    local id = owner:GetAddress()
    local panel = descriptionPanels[id]
    if bbm.valid(panel) then
        panel:SetVisibility(1)
    end
    if not bbm.valid(item) then
        return
    end

    local rows = itemStats.buildItemStatRows(owner, item)
    if #rows == 0 then
        return
    end
    if not bbm.valid(panel) or not parent:HasChild(panel) then
        panel = bbm.widget(owner, "VerticalBox")
        descriptionPanels[id] = panel
        parent:AddChild(panel):SetHorizontalAlignment(0)
    end

    panel:ClearChildren()
    local valueStyle = owner[weaponStatsField].Power
    for _, stat in ipairs(rows) do
        appendStatRow(owner, panel, stat[1], stat[2], valueStyle)
    end
    panel:SetVisibility(3)
end

local function refreshInventoryHealingBonus(context)
    local menu = context:get()
    local id = menu:GetAddress()
    local state = healingRows[id] or { nextUpdate = 0 }
    healingRows[id] = state
    if os.clock() < state.nextUpdate then
        return
    end
    state.nextUpdate = os.clock() + 0.5

    local panel = menu.PlayerAttributes
    if not bbm.valid(panel) then
        return
    end
    local valueStyle = panel.AttackPower
    if not bbm.valid(valueStyle) then
        return
    end
    local parent = valueStyle:GetParent():GetParent()
    if not bbm.valid(state.label) then
        state.label = appendStatRow(panel, parent, "Healing bonus", "", valueStyle)
        state.lastText = nil
    end

    local text = itemStats.healingBonusText(menu)
    if text ~= state.lastText then
        state.label:SetText(FText(text))
        state.lastText = text
    end
end

local gameMenu = "/Game/UI/Menus/GameMenu.GameMenu_C:"
if bbm.config.itemStats then
    bbm.hook(gameMenu .. "ItemSelectionChanged", function(context, item)
        refreshItemDescription(context:get(), item:get(), "DescriptionScrollbox", "WeaponStats")
    end)
    bbm.hook("/Game/UI/Widgets/FS_InspectItem.FS_InspectItem_C:OpenForItem", function(context, item)
        refreshItemDescription(
            context:get(),
            item:get(),
            "ItemInspect_DescriptionScrollbox",
            "ItemInspect_WeaponStats"
        )
    end)
end

if bbm.config.inventoryStats then
    bbm.hook(gameMenu .. "Tick", refreshInventoryHealingBonus)
end

table.insert(bbm.reset, function()
    descriptionPanels, healingRows = {}, {}
end)
