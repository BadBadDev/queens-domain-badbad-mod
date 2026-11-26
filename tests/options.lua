-- Checks native menu rows and saved settings using a disposable INI file.
local support = require("tests.support")
local test = support.new()
local B, hooks = test.api, test.hooks
local obj, ref, noop = support.object, support.ref, support.noop

local tmp = os.tmpname()
local function writeIni(s)
    local f = assert(io.open(tmp, "wb"))
    assert(f:write(s))
    assert(f:close())
end
local function readIni()
    local f = assert(io.open(tmp, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local testResult, testError = pcall(function()
    local ini =
        "; test\r\ngraphics=0\r\nscreenPercentage=125\r\ndamageSeconds=1.75\r\ntravelStrideDelaySeconds=0\r\ndrag = 1\r\ninventoryStats=0\r\n"
    writeIni(ini)
    local function openTestIni(_, mode)
        return io.open(tmp, mode)
    end
    test.env.io = { open = openTestIni }
    local optionRows = {}
    local hovered, focused
    local scroll = 0
    local title = obj({
        text = "Video Options",
        GetFName = function()
            return {
                ToString = function()
                    return "VideoHeader"
                end,
            }
        end,
    })
    function title:GetText()
        return {
            ToString = function()
                return self.text
            end,
        }
    end
    function title:SetText(value)
        self.text = value
    end
    local nativeMenu = obj({
        VideoOptions = {
            GetChildrenCount = function()
                return 1
            end,
            GetChildAt = function()
                return title
            end,
        },
    })
    local slot = { SetPadding = noop, SetHorizontalAlignment = noop }
    local page = obj({
        GetOwningPlayer = noop,
        Vsync = { FieldLabel = { Font = {} }, Slot = { Padding = {}, HorizontalAlignment = 0 } },
        GetOuter = function()
            return {
                GetOuter = function()
                    return nativeMenu
                end,
            }
        end,
        OptionsList = obj({
            GetScrollOffset = function()
                return scroll
            end,
            GetCachedGeometry = function()
                return { top = scroll }
            end,
            AddChild = function(_, child)
                optionRows[#optionRows + 1] = child
                return slot
            end,
            HasChild = function(_, child)
                for _, r in ipairs(optionRows) do
                    if child == r then
                        return true
                    end
                end
                return false
            end,
        }),
        IsVisible = function()
            return true
        end,
    })
    B.dir = ""
    B.warn = error
    B.widget = function()
        return obj({
            GetCachedGeometry = function()
                return { top = 100 }
            end,
            SetFont = noop,
            SetText = function(s, v)
                s.text = v
            end,
            SetVisibility = function(s, v)
                s.visibility = v
            end,
        })
    end
    B.lib = function(path)
        if path == "/Script/UMG.Default__SlateBlueprintLibrary" then
            return {
                GetLocalSize = function()
                    return { Y = 20 }
                end,
                LocalToAbsolute = function(_, g, point)
                    return { Y = g.top + point.Y }
                end,
                AbsoluteToLocal = function(_, g, point)
                    return { Y = point.Y - g.top }
                end,
            }
        end
        if not path:find("WidgetBlueprintLibrary", 1, true) then
            return path
        end
        return {
            Create = function(_, _, class)
                if class:match("OptionsMenu_Entry_C$") then
                    return obj({
                        FS_Button = obj(),
                        IsHovered = function(s)
                            return s == hovered
                        end,
                        HasAnyUserFocus = function()
                            return false
                        end,
                        HasFocusedDescendants = function(s)
                            return s == focused
                        end,
                        ControlWidget = {
                            SetContent = function(s, v)
                                s.child = v
                            end,
                        },
                        Init = function(s)
                            s.MyControl = s.ControlWidget.child
                            assert(s.DisableRevert and s.MyControl.SkipSavingOption)
                        end,
                    })
                end
                return obj({
                    PlayRelevantToggleAnim = noop,
                    Refreshtext = function(s)
                        s.text = s.Options[s.CurrentValue + 1]
                    end,
                })
            end,
        }
    end
    test.loadModule("options")
    assert(B.config.drag and not B.config.graphics and not B.config.inventoryStats)
    assert(
        B.config.screenPercentage == 125
            and B.config.damageSeconds == 1.75
            and B.config.travelStrideDelaySeconds == 0
    )
    hooks.Open(ref(page))
    hooks.Open(ref(page))
    assert(#optionRows == 10)
    assert(optionRows[1].text == "BBM Settings")
    local expected = {
        "High-resolution graphics",
        "Pickup shimmer",
        "Enemy HP bars",
        "Item description stats",
        "Status effect names",
        "Drag to equip",
        "Inventory healing stat",
        "Travel Stride",
        "Quick Save / Load",
    }
    for i, name in ipairs(expected) do
        assert(optionRows[i + 1].Name == name)
    end
    local selector = optionRows[3].MyControl
    assert(selector.text == "Mid" and selector.ApplyOptionSettings == false)
    selector.CurrentValue = 3
    selector:Refreshtext()
    hooks.Tick(ref(page))
    assert(B.config.shimmer == 3 and readIni() == ini .. "shimmer=3\n")
    selector.CurrentValue = selector.CurrentValue + 1
    selector:Refreshtext()
    hooks.Close(ref(page))
    assert(B.config.shimmer == 4 and selector.text == "Over Here!" and readIni() == ini .. "shimmer=4\n")
    hooks.Open(ref(page))
    assert(selector.CurrentValue == 4)
    local drag, enemyBars, stride
    for i = 2, #optionRows do
        local row = optionRows[i]
        assert(not row.Name:find("(restart)", 1, true))
        if row.Name:find("Drag to equip", 1, true) then
            drag = row.MyControl
        end
        if row.Name == "Enemy HP bars" then
            enemyBars = row.MyControl
        end
        if row.Name:find("Travel Stride", 1, true) then
            stride = row.MyControl
        end
    end
    drag.CurrentValue = false
    test.now = test.now + 0.2
    hooks.Tick(ref(page))
    assert(enemyBars.text == "HP bar + damage")
    enemyBars.CurrentValue = 1
    hooks.Close(ref(page))
    assert(B.config.drag and B.config.enemyHpBars == 2 and B.config.shimmer == 4)
    assert(readIni() == ini:gsub("drag = 1", "drag = 0") .. "shimmer=4\nenemyHpBars=1\n")
    assert(stride.CurrentValue == false and B.config.travelStride == false)
    stride.CurrentValue = true
    hooks.Close(ref(page))
    assert(B.config.travelStride == false)
    test.loadModule("options")
    assert(B.config.travelStride == true)
    assert(not B.config.drag and B.config.enemyHpBars == 1 and not B.config.graphics)

    -- A stationary pointer shouldn't trap the preview when navigating with a controller.
    optionRows = {}
    local shown, closes = nil, 0
    B.updateVideoPreview = function(_, key)
        shown = key
    end
    B.closeVideoPreview = function()
        closes = closes + 1
    end
    hooks.Open(ref(page))
    local entries = {}
    for i = 2, #optionRows do
        local row = optionRows[i]
        entries[row.Name] = row
    end
    enemyBars = entries["Enemy HP bars"].MyControl
    assert(enemyBars.text == "HP bar")
    local function poll()
        test.now = test.now + 0.2
        hooks.Tick(ref(page))
    end
    local before = readIni()
    local heading = optionRows[1]
    scroll = 90
    hovered = entries["Pickup shimmer"]
    poll()
    assert(shown == "shimmer" and heading.visibility == 3 and title.text == "Video Options")
    focused = entries["Item description stats"]
    poll()
    assert(shown == "itemStats" and heading.visibility == 3 and title.text == "Video Options")
    scroll = 125
    poll()
    assert(title.text == "BBM Settings" and heading.visibility == 3)
    scroll = 90
    poll()
    assert(title.text == "Video Options" and heading.visibility == 3)
    hovered = entries["Status effect names"]
    poll()
    assert(shown == "statusNames" and readIni() == before)
    enemyBars.CurrentValue = 0
    hooks.Close(ref(page))
    assert(readIni() == before:gsub("enemyHpBars=1", "enemyHpBars=0"))
    shown = nil
    poll()
    assert(shown == nil and closes == 1 and title.text == "Video Options")
    test.loadModule("options")
    assert(B.config.enemyHpBars == 0)

    writeIni("shimmer=0\n")
    optionRows = {}
    test.loadModule("options")
    hooks.Open(ref(page))
    selector = optionRows[3].MyControl
    assert(selector.CurrentValue == 0 and selector.text == "Off")
    selector.CurrentValue = 2
    hooks.Close(ref(page))
    assert(B.config.shimmer == 2 and readIni() == "shimmer=2\n")
    hooks.Open(ref(page))
    assert(selector.text == "Mid")
    selector.CurrentValue = 0
    hooks.Close(ref(page))
    assert(B.config.shimmer == 0 and readIni() == "shimmer=0\n")

    writeIni("screenPercentage=201\ndamageSeconds=-1\ntravelStrideDelaySeconds=1e999\n")
    local warnings = {}
    B.warn = function(key)
        warnings[key] = true
    end
    test.loadModule("options")
    assert(
        B.config.screenPercentage == 100
            and B.config.damageSeconds == 0.85
            and B.config.travelStrideDelaySeconds == 12
    )
    assert(
        warnings["features.ini: screenPercentage=201"]
            and warnings["features.ini: damageSeconds=-1"]
            and warnings["features.ini: travelStrideDelaySeconds=1e999"]
    )
end)
os.remove(tmp)
assert(testResult, testError)
