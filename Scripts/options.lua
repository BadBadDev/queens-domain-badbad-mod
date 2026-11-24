-- Adds BBM controls to the Video menu and saves changes without touching the native system save.
local mod = ...
local featuresPath = mod.dir .. "..\\features.ini"
local features = {
    { "graphics", "High-resolution graphics" },
    {
        "shimmer",
        "Pickup shimmer",
        levels = { "Off", "Low", "Mid", "High", "Over Here!" },
        default = 2,
        live = true,
    },
    { "enemyHpBars", "Enemy HP bars", levels = { "Off", "HP bar", "HP bar + damage" }, default = 2 },
    { "itemStats", "Item description stats" },
    { "statusNames", "Status effect names" },
    { "drag", "Drag to equip" },
    { "inventoryStats", "Inventory healing stat" },
    { "travelStride", "Travel Stride", default = false },
    { "quickSave", "Quick Save / Load" },
}
local saved, known = {}, {}
for _, feature in ipairs(features) do
    known[feature[1]] = feature
    saved[feature[1]] = feature.levels and feature.default or feature.default ~= false
end

local function parseFeatureSwitches(data)
    local offset, values, positions = 0, {}, {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*[;#]") and not line:match("^%s*$") then
            local key, pos, digit = line:match("^%s*([%w_]+)%s*=%s*()(%d)%s*$")
            local feature = known[key]
            if
                feature
                and (digit == "0" or digit == "1" or (feature.levels and feature.levels[tonumber(digit) + 1]))
            then
                if positions[key] then
                    mod.warn("duplicate setting " .. key, "using last value")
                end
                values[key] = feature.levels and tonumber(digit) or digit == "1"
                positions[key] = offset + pos - 1
            else
                mod.warn("features.ini: " .. line, "unknown setting or invalid value")
            end
        end
        offset = offset + #line + 1
    end
    return values, positions
end
local file, why = io.open(featuresPath, "rb")
if file then
    local data, err = file:read("*a")
    file:close()
    if data then
        local values = parseFeatureSwitches(data)
        for key, value in pairs(values) do
            saved[key] = value
        end
    else
        mod.warn("reading features.ini", err)
    end
else
    mod.warn("opening features.ini", why)
end
for key, value in pairs(saved) do
    mod.config[key] = value
end

local function saveFeatureSwitch(key, value)
    local fileHandle, err = io.open(featuresPath, "r+b")
    if not fileHandle then
        return nil, err
    end
    local data, readErr = fileHandle:read("*a")
    if not data then
        fileHandle:close()
        return nil, readErr
    end
    local _, positions = parseFeatureSwitches(data)
    -- Change just one byte, preserving other values, comments and CRLF.
    local pos = positions[key]
    local at, seekErr = fileHandle:seek("set", pos or #data)
    if not at then
        fileHandle:close()
        return nil, seekErr
    end
    local prefix = pos and "" or ((data:sub(-1) == "\n" and "" or "\n") .. key .. "=")
    local digit = known[key].levels and tostring(value) or (value and "1" or "0")
    local written, writeErr = fileHandle:write(prefix, digit, pos and "" or "\n")
    local closed, closeErr = fileHandle:close()
    if not written or not closed then
        return nil, writeErr or closeErr
    end
    saved[key] = value
    if known[key].live then
        mod.config[key] = value
    end
    return true
end

local pages = {}
local sectionTitle = "BBM Settings"

local function createNativeOptionWidget(page, className)
    local name = "OptionsMenu_" .. className
    local path = "/Game/UI/Menus/OptionsMenu/" .. name .. "." .. name .. "_C"
    local factory = mod.lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    local widget = factory:Create(page, mod.lib(path), page:GetOwningPlayer())
    assert(mod.valid(widget), "Could not create " .. name)
    return widget
end

local function appendNativeOptionRow(page, list, caption, levels)
    local entry = createNativeOptionWidget(page, "Entry")
    local control = createNativeOptionWidget(page, levels and "OptionSelect" or "ToggleControl")
    -- The native controls normally read/write FS_SystemSave. BBM owns these settings.
    control.SkipSavingOption = true
    if levels then
        control.ApplyOptionSettings = false
        local labels = {}
        for i, name in ipairs(levels) do
            labels[i] = FText(name)
        end
        control.Options = labels
    end
    entry.DisableRevert = true
    entry.Name = FText(caption)
    entry.ControlWidget:SetContent(control)
    local slot = list:AddChild(entry)
    local template = page.Vsync.Slot
    slot:SetPadding(template.Padding)
    slot:SetHorizontalAlignment(template.HorizontalAlignment)
    entry:Init(page)
    return { entry = entry, control = control }
end

local function syncFeatureToggle(control, value)
    control.CurrentValue = value
    control:PlayRelevantToggleAnim()
end

local function mountVideoOptionRows(page)
    local list = page.OptionsList
    if not mod.valid(list) then
        return
    end
    local id = page:GetAddress()
    local rows = pages[id] or {}
    pages[id] = rows
    if not mod.valid(rows.heading) or not list:HasChild(rows.heading) then
        local heading = mod.widget(page, "TextBlock")
        heading:SetFont(page.Vsync.FieldLabel.Font)
        heading:SetText(FText(sectionTitle))
        heading:SetVisibility(3)
        list:AddChild(heading):SetPadding({ Left = 12, Top = 16, Right = 0, Bottom = 8 })
        rows.heading = heading
    end
    for _, feature in ipairs(features) do
        local key, name = feature[1], feature[2]
        if not rows[key] or not mod.valid(rows[key].entry) or not list:HasChild(rows[key].entry) then
            rows[key] = appendNativeOptionRow(page, list, name, feature.levels)
        end
        if feature.levels then
            rows[key].control.CurrentValue = saved[key]
            rows[key].control:Refreshtext()
        else
            syncFeatureToggle(rows[key].control, saved[key])
        end
    end
    return rows
end

local function persistChangedOptions(rows)
    for _, feature in ipairs(features) do
        local key = feature[1]
        local row = rows[key]
        if row and mod.valid(row.control) then
            local value = row.control.CurrentValue
            if value ~= saved[key] then
                if feature.levels then
                    assert(feature.levels[value + 1], "Invalid native selection for " .. key)
                end
                local ok, err = saveFeatureSwitch(key, value)
                if not ok then
                    if feature.levels then
                        row.control.CurrentValue = saved[key]
                        row.control:Refreshtext()
                    else
                        syncFeatureToggle(row.control, saved[key])
                    end
                    mod.warn("saving " .. key, err)
                end
            end
        end
    end
end
local menu = "/Game/UI/Menus/OptionsMenu/OptionLists/Video_OptionsList.Video_OptionsList_C:"

-- A stationary mouse must not hold the preview on an old row after gamepad navigation.
local function highlightedRow(page, rows)
    local owner = page:GetOuter():GetOuter()
    local selected = owner.LastSelectedWidget
    local focused, selectedKey, hovered
    for _, feature in ipairs(features) do
        local key = feature[1]
        local entry = rows[key].entry
        if entry:IsHovered() then
            hovered = key
        end
        if mod.valid(selected) and entry.FS_Button:GetAddress() == selected:GetAddress() then
            selectedKey = key
        end
        if entry:HasAnyUserFocus() or entry:HasFocusedDescendants() then
            focused = key
        end
    end
    focused = focused or selectedKey
    if hovered ~= rows.hovered then
        rows.highlight = hovered or focused
    elseif focused ~= rows.focused then
        rows.highlight = focused or hovered
    end
    rows.hovered, rows.focused = hovered, focused
    return rows.highlight
end

-- Keep the inline label in place. Only pin a copy if scrolling takes it out of view.
local function scrolledPastHeading(page, heading)
    local list = page.OptionsList
    if list:GetScrollOffset() <= 0 then
        return false
    end
    local slate = mod.lib("/Script/UMG.Default__SlateBlueprintLibrary")
    local geometry = heading:GetCachedGeometry()
    local size = slate:GetLocalSize(geometry)
    if size.Y <= 0 then
        return false -- no layout yet
    end
    local bottom = slate:LocalToAbsolute(geometry, { X = 0, Y = size.Y })
    return slate:AbsoluteToLocal(list:GetCachedGeometry(), bottom).Y <= 0
end

local function pinHeading(page, rows, pin)
    if pin == (rows.originalTitle ~= nil) then
        return
    end
    if not mod.valid(rows.title) then
        local canvas = page:GetOuter():GetOuter().VideoOptions
        for i = 0, canvas:GetChildrenCount() - 1 do
            local child = canvas:GetChildAt(i)
            if child:GetFName():ToString() == "VideoHeader" then
                rows.title = child
                break
            end
        end
    end
    local title = rows.title
    if not mod.valid(title) then
        mod.warn("Video section title", "Native header unavailable; using inline heading")
        return
    end
    if pin then
        rows.originalTitle = title:GetText():ToString()
        title:SetText(FText(sectionTitle))
    else
        title:SetText(FText(rows.originalTitle))
        rows.originalTitle = nil
    end
end

mod.hook(menu .. "Open", function(ctx)
    local rows = mountVideoOptionRows(ctx:get())
    if rows then
        rows.closed, rows.hovered, rows.focused, rows.highlight = false, nil, nil, nil
    end
end)
mod.hook(menu .. "Tick", function(ctx)
    local page = ctx:get()
    if not page:IsVisible() then
        return
    end
    local rows = pages[page:GetAddress()]
    if not rows then
        rows = mountVideoOptionRows(page)
    end
    if rows and not rows.closed and os.clock() >= (rows.nextPoll or 0) then
        rows.nextPoll = os.clock() + 0.1
        persistChangedOptions(rows)
        local key = highlightedRow(page, rows)
        pinHeading(page, rows, scrolledPastHeading(page, rows.heading))
        if mod.updateVideoPreview then
            mod.updateVideoPreview(page, key, saved)
        end
    end
end)

mod.hook(menu .. "Close", function(ctx)
    local rows = pages[ctx:get():GetAddress()]
    if rows then
        rows.closed = true
        pinHeading(ctx:get(), rows, false)
        if mod.closeVideoPreview then
            mod.closeVideoPreview(ctx:get())
        end
        persistChangedOptions(rows)
    end
end)

table.insert(mod.reset, function()
    pages = {}
end)
