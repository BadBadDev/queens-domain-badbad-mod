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
    local ini = "; test\r\ngraphics=0\r\ndrag = 1\r\ninventoryStats=0\r\n"
    writeIni(ini)
    local function openTestIni(_, mode)
        return io.open(tmp, mode)
    end
    test.env.io = { open = openTestIni }
    local optionRows = {}
    local slot = { SetPadding = noop, SetHorizontalAlignment = noop }
    local page = obj({
        GetOwningPlayer = noop,
        Vsync = { Slot = { Padding = {}, HorizontalAlignment = 0 } },
        OptionsList = obj({
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
    B.shimmer = "low"
    B.setShimmer = function(l)
        B.shimmer = l
        return true
    end
    B.lib = function(path)
        if not path:find("WidgetBlueprintLibrary", 1, true) then
            return path
        end
        return {
            Create = function(_, _, class)
                if class:match("OptionsMenu_Entry_C$") then
                    return obj({
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
    hooks.Open(ref(page))
    hooks.Open(ref(page))
    assert(#optionRows == 10)
    local selector = optionRows[#optionRows].MyControl
    assert(selector.text == "Low" and selector.ApplyOptionSettings == false)
    selector.CurrentValue = 2
    selector:Refreshtext()
    hooks.Tick(ref(page))
    assert(B.shimmer == "high" and readIni() == ini)
    selector.CurrentValue = selector.CurrentValue + 1
    selector:Refreshtext()
    hooks.Close(ref(page))
    assert(B.shimmer == "arrow" and selector.text == "Over Here!" and readIni() == ini)
    hooks.Open(ref(page))
    assert(selector.CurrentValue == 3)
    local drag, damage, stride
    for _, row in ipairs(optionRows) do
        if row.Name:find("Drag to equip", 1, true) then
            drag = row.MyControl
        end
        if row.Name:find("Damage numbers", 1, true) then
            damage = row.MyControl
        end
        if row.Name:find("Travel Stride", 1, true) then
            stride = row.MyControl
        end
    end
    drag.CurrentValue = false
    test.now = test.now + 0.2
    hooks.Tick(ref(page))
    damage.CurrentValue = false
    hooks.Close(ref(page))
    assert(B.config.drag and B.config.damageNumbers and B.shimmer == "arrow")
    assert(readIni() == ini:gsub("drag = 1", "drag = 0") .. "damageNumbers=0\n")
    assert(stride.CurrentValue == false and B.config.travelStride == false)
    stride.CurrentValue = true
    hooks.Close(ref(page))
    assert(B.config.travelStride == false)
    test.loadModule("options")
    assert(B.config.travelStride == true)
    assert(not B.config.drag and not B.config.damageNumbers and not B.config.graphics)
end)
os.remove(tmp)
assert(testResult, testError)
