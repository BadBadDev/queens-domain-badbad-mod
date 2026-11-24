-- Adds BBM controls to the Video menu and saves changes without touching the native system save.
local B = ...
local featuresPath = B.dir .. "..\\features.ini"
local features = {
    { "graphics", "High-resolution graphics" },
    { "shimmer", "Pickup shimmer" },
    { "damageNumbers", "Damage numbers" },
    { "drag", "Drag to equip" },
    { "itemStats", "Item description stats" },
    { "inventoryStats", "Inventory healing stat" },
    { "statusNames", "Status effect names" },
    { "travelStride", "Travel Stride", default = false },
    { "quickSave", "Quick Save / Load" },
}
local saved, known = {}, {}
for _, feature in ipairs(features) do
    known[feature[1]], saved[feature[1]] = true, feature.default ~= false
end

local function parseFeatureSwitches(data)
    local offset, values, positions = 0, {}, {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*[;#]") and not line:match("^%s*$") then
            local key, pos, digit = line:match("^%s*([%w_]+)%s*=%s*()([01])%s*$")
            if key and known[key] then
                if positions[key] then
                    B.warn("duplicate setting " .. key, "using last value")
                end
                values[key], positions[key] = digit == "1", offset + pos - 1
            else
                B.warn("features.ini: " .. line, "expected a known key and 0 or 1")
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
        for k, v in pairs(values) do
            saved[k] = v
        end
    else
        B.warn("reading features.ini", err)
    end
else
    B.warn("opening features.ini", why)
end
-- Keep the active feature set unchanged until restart, including during a drag.
for key, v in pairs(saved) do
    B.config[key] = v
end

local function saveFeatureSwitch(key, value)
    local f, err = io.open(featuresPath, "r+b")
    if not f then
        return nil, err
    end
    local data, readErr = f:read("*a")
    if not data then
        f:close()
        return nil, readErr
    end
    local _, positions = parseFeatureSwitches(data)
    -- Change just one byte, preserving other values, comments and CRLF.
    local pos = positions[key]
    local at, seekErr = f:seek("set", pos or #data)
    if not at then
        f:close()
        return nil, seekErr
    end
    local prefix = pos and "" or ((data:sub(-1) == "\n" and "" or "\n") .. key .. "=")
    local written, writeErr = f:write(prefix, value and "1" or "0", pos and "" or "\n")
    local closed, closeErr = f:close()
    if not written or not closed then
        return nil, writeErr or closeErr
    end
    saved[key] = value
    return true
end

local pages = {}
local choices = { "low", "medium", "high", "arrow" }
local choiceIndex = { low = 0, medium = 1, high = 2, arrow = 3 }

local function createNativeOptionWidget(page, className)
    local name = "OptionsMenu_" .. className
    local path = "/Game/UI/Menus/OptionsMenu/" .. name .. "." .. name .. "_C"
    local factory = B.lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    local widget = factory:Create(page, B.lib(path), page:GetOwningPlayer())
    assert(B.valid(widget), "Could not create " .. name)
    return widget
end

local function appendNativeOptionRow(page, list, caption, kind)
    local entry = createNativeOptionWidget(page, "Entry")
    local control = createNativeOptionWidget(page, kind)
    -- The native controls normally read/write FS_SystemSave. BBM owns these settings.
    control.SkipSavingOption = true
    if kind == "OptionSelect" then
        control.ApplyOptionSettings = false
        control.Options = { FText("Low"), FText("Medium"), FText("High"), FText("Over Here!") }
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

local function syncShimmerStrengthSelector(control)
    control.CurrentValue = assert(choiceIndex[B.shimmer], "Unknown shimmer strength")
    control:Refreshtext()
end

local function mountVideoOptionRows(page)
    local list = page.OptionsList
    if not B.valid(list) then
        return
    end
    local id = page:GetAddress()
    local rows = pages[id] or {}
    pages[id] = rows
    for _, feature in ipairs(features) do
        local key, name = feature[1], feature[2]
        if not rows[key] or not B.valid(rows[key].entry) or not list:HasChild(rows[key].entry) then
            rows[key] = appendNativeOptionRow(page, list, "BBM: " .. name .. " (restart)", "ToggleControl")
        end
        syncFeatureToggle(rows[key].control, saved[key])
    end
    if not rows.strength or not B.valid(rows.strength.entry) or not list:HasChild(rows.strength.entry) then
        rows.strength = appendNativeOptionRow(page, list, "BBM: Shimmer strength", "OptionSelect")
    end
    syncShimmerStrengthSelector(rows.strength.control)
    return rows
end

local function persistChangedOptions(rows)
    for _, feature in ipairs(features) do
        local key = feature[1]
        local row = rows[key]
        if row and B.valid(row.control) then
            local value = row.control.CurrentValue
            if value ~= saved[key] then
                local ok, err = saveFeatureSwitch(key, value)
                if not ok then
                    syncFeatureToggle(row.control, saved[key])
                    B.warn("saving " .. key, err)
                end
            end
        end
    end
    if rows.strength and B.valid(rows.strength.control) then
        local level =
            assert(choices[rows.strength.control.CurrentValue + 1], "Invalid native shimmer selection")
        if level ~= B.shimmer and not B.setShimmer(level) then
            syncShimmerStrengthSelector(rows.strength.control)
        end
    end
end
local menu = "/Game/UI/Menus/OptionsMenu/OptionLists/Video_OptionsList.Video_OptionsList_C:"

B.hook(menu .. "Open", function(ctx)
    mountVideoOptionRows(ctx:get())
end)
B.hook(menu .. "Tick", function(ctx)
    local page = ctx:get()
    if not page:IsVisible() then
        return
    end
    local rows = pages[page:GetAddress()]
    if not rows then
        rows = mountVideoOptionRows(page)
    end
    if rows and os.clock() >= (rows.nextPoll or 0) then
        rows.nextPoll = os.clock() + 0.1
        persistChangedOptions(rows)
    end
end)

B.hook(menu .. "Close", function(ctx)
    local rows = pages[ctx:get():GetAddress()]
    if rows then
        persistChangedOptions(rows)
    end
end)

table.insert(B.reset, function()
    pages = {}
end)
