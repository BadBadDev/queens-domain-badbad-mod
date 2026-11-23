-- Exercises BBM's Lua feature logic using stand-ins for UE4SS and Unreal widgets.
-- Run from the repository root with Lua 5.4: lua tests\bbm.lua
local function module(name, api)
    assert(loadfile("Scripts\\" .. name .. ".lua"))(api)
end
local function obj(t)
    t = t or {}
    t.IsValid = function()
        return true
    end
    t.GetAddress = function(self)
        return self
    end
    return t
end
local function ref(x)
    return {
        get = function()
            return x
        end,
    }
end
local now, width = 0, 1920
os.clock = function()
    return now
end
FText = function(x)
    return x
end
local hooks = {}
local function bind(path, fn)
    hooks[path] = fn
    hooks[path:match(":([^:]+)$")] = fn
end
local B = {
    valid = function(x)
        return x and x:IsValid()
    end,
    hook = bind,
    reset = {},
    config = { damageSeconds = 0.85, damageNumbers = true, itemStats = true },
}
local function wing(x)
    return obj({
        RenderTransform = { Translation = { X = x, Y = 15 } },
        SetRenderTranslation = function(s, xy)
            s.RenderTransform.Translation = xy
        end,
    })
end
local hud = obj({ StatusCluster = wing(8), CompassWidget = wing(-30), ConsumableHUD = wing(5) })
local cam = obj({ bConstrainAspectRatio = true })
local pawn = obj({
    FirstPersonCamera = cam,
    ["Update Camera Aspect Ratio Options"] = function()
        cam.bConstrainAspectRatio = true
    end,
})
hud.GetOwningPlayerPawn = function()
    return pawn
end
B.lib = function()
    return {
        GetViewportSize = function()
            return { X = width, Y = 1080 }
        end,
        GetViewportScale = function()
            return 1
        end,
    }
end
module("widescreen", B)
hooks.Tick = hooks["/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick"]
hooks.Tick(ref(hud))
assert(hud.StatusCluster.RenderTransform.Translation.X == 8)
width = 2560
now = 1
hooks.Tick(ref(hud))
assert(
    hud.StatusCluster.RenderTransform.Translation.X == -312
        and hud.CompassWidget.RenderTransform.Translation.X == 290
)
assert(not cam.bConstrainAspectRatio)
assert(hud.ConsumableHUD.RenderTransform.Translation.X == -315)
cam.bConstrainAspectRatio = true
hooks["Update Camera Aspect Ratio Options"](ref(pawn))
assert(not cam.bConstrainAspectRatio)
now = 2
hooks.Tick(ref(hud))
assert(hud.CompassWidget.RenderTransform.Translation.X == 290)
assert(hud.ConsumableHUD.RenderTransform.Translation.X == -315)
hud.ConsumableHUD = wing(12)
now = now + 0.5
hooks.Tick(ref(hud))
assert(hud.ConsumableHUD.RenderTransform.Translation.X == -308)
width = 1920
now = 3
hooks.Tick(ref(hud))
assert(hud.CompassWidget.RenderTransform.Translation.X == -30)
assert(hud.ConsumableHUD.RenderTransform.Translation.X == 12)
assert(cam.bConstrainAspectRatio)

do
    local box = obj({ Stretch = 2 })
    local image = wing(0)
    image.RenderTransform.Scale = { X = 1, Y = 1 }
    image.Brush = { ImageSize = { X = 1920, Y = 1080 } }
    image.GetParent = function()
        return box
    end
    image.SetRenderScale = function(self, size)
        self.RenderTransform.Scale = size
    end
    local overlay = ref(obj({ OverlayLayer = image }))
    local fit = hooks["/Game/Player/StatusEffectVisualizers/StatusEffectOverlay.StatusEffectOverlay_C:Tick"]
    width = 2560
    fit(overlay)
    assert(math.abs(image.RenderTransform.Scale.X - 4 / 3) < 0.001 and image.RenderTransform.Scale.Y == 1)
    box.Stretch = 1 -- stock Fill must not be stretched twice
    fit(overlay)
    assert(image.RenderTransform.Scale.X == 1)
    box.Stretch = 2
    width = 1920
    fit(overlay)
    assert(image.RenderTransform.Scale.X == 1 and image.RenderTransform.Scale.Y == 1)
end

do
    local effectName = {
        ToString = function()
            return "Poison"
        end,
    }
    local component = obj({ Applied = true, EffectName = effectName })
    local player = obj({
        StatusEffectComps = {
            ForEach = function(_, visit)
                visit(1, ref(component))
            end,
        },
        StickyEffectApplied = true,
        MagicFireEffectLogic = obj({ CurrentMagicFireDamagePool = 3 }),
    })
    local anchor = { Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } }
    local icon = wing(-200)
    icon.Slot = {
        GetPosition = function()
            return { X = 50, Y = -20 }
        end,
        GetSize = function()
            return { X = 200, Y = 100 }
        end,
        GetAutoSize = function()
            return false
        end,
        GetAlignment = function()
            return { X = 0, Y = 1 }
        end,
        GetAnchors = function()
            return anchor
        end,
    }
    local root = obj({
        HasChild = function(self, child)
            return self.child == child
        end,
        AddChildToCanvas = function(self, child)
            local noop = function() end
            self.child = child
            child.Slot = {
                SetAutoSize = noop,
                SetAnchors = function(slot, anchors)
                    slot.anchors = anchors
                end,
                SetAlignment = noop,
                SetPosition = function(slot, position)
                    slot.position = position
                end,
                SetZOrder = noop,
            }
            return child.Slot
        end,
    })
    icon.GetParent = function()
        return root
    end
    local effectsHud = obj({ ConsumableHUD = icon, CharRef = player })
    local effectsLabel
    B.widget = function()
        local noop = function() end
        effectsLabel = obj({
            Font = {},
            SetFont = noop,
            SetShadowOffset = noop,
            SetShadowColorAndOpacity = noop,
            SetText = function(self, text)
                self.text = text
            end,
            SetVisibility = function(self, visibility)
                self.visibility = visibility
            end,
        })
        return effectsLabel
    end
    module("statusnames", B)
    hooks.Tick(ref(effectsHud))
    assert(effectsLabel.text == "Burn\nPoison\nSticky" and effectsLabel.visibility == 3)
    assert(effectsLabel.Slot.anchors == anchor and effectsLabel.Slot.position.X == -150)
    local itemTop = -20 - 100 + 15
    assert(itemTop - effectsLabel.Slot.position.Y >= 15, "leave one line of clearance above the usable item")
    icon.RenderTransform.Translation.X = 0
    now = now + 1
    hooks.Tick(ref(effectsHud))
    assert(effectsLabel.Slot.position.X == 50) -- reflow even when the effect names haven't changed
    component.Applied = false
    player.MagicFireEffectLogic.CurrentMagicFireDamagePool = 0
    now = now + 1
    hooks.Tick(ref(effectsHud))
    assert(effectsLabel.text == "Sticky")
    player.StickyEffectApplied = false
    now = now + 1
    hooks.Tick(ref(effectsHud))
    assert(effectsLabel.visibility == 1)
end

local config = obj({ HealingHerb1HealAmount = 20, BerserkFruitDamageIncrease = 0.2, BaseDamage = 10 })
B.dir = "Scripts\\"
B.lib = function()
    return {
        GetPlayerConfig = function(_, w, out)
            out.Config = config
        end,
        GetWeaponStats = function()
            return obj({ PowerMeterTime = 0.75 })
        end,
        GetDaggerStats = function()
            return obj({ CooldownTime = 5, DamageMult = 0.7 })
        end,
        GetWeaponPrimaryAttackPower = function(_, i, o, b, p, t)
            b.BasePower = 1.5
            p.IncreaseFromLevel = 0.2
            t.TotalPower = 1.8
        end,
        GetWeaponSecondaryAttackPower = function(_, i, o, b, p, t)
            b.BasePower = 3
            p.IncreaseFromLevel = 0.2
            t.TotalPower = 3.6
        end,
    }
end
local stats = assert(loadfile(B.dir .. "itemstats.lua"))(B)
local inventory = obj({
    GetOwningPlayerPawn = function()
        return obj({
            GetHealingEffectMult = function()
                return 1.25
            end,
        })
    end,
})
local name = "HealingHerb"
local item = obj({
    GetFName = function()
        return {
            ToString = function()
                return name
            end,
        }
    end,
    DataTags = { ForEach = function() end },
})
local function rows()
    local out = {}
    for _, p in ipairs(stats.buildItemStatRows(inventory, item)) do
        out[p[1]] = p[2]
    end
    return out
end
assert(rows()["Heals:"] == "20 (+5)" and stats.healingBonusText(inventory) == "25%")
for mult, expected in pairs({ [1] = "0%", [0.9] = "-10%" }) do
    local menu = obj({
        GetOwningPlayerPawn = function()
            return obj({
                GetHealingEffectMult = function()
                    return mult
                end,
            })
        end,
    })
    assert(stats.healingBonusText(menu) == expected)
end
name = "SwordKey"
assert(next(rows()) == nil)
name = "PoisonCure"
assert(rows().Cures == "Poison")
name = "BerserkFruit"
assert(rows().Attack == "+20%")
name = "Sword"
item.Equippable = true
item.EquipSlot = 3
assert(rows()["Primary Attack"] == "15 (+20%) = 18" and rows()["Secondary Attack"] == "30 (+20%) = 36")
assert(rows()["Stamina recovery (base)"] == "750 ms")
item.EquipSlot = 2
assert(rows().Return == "5 s" and rows().Attack == "7")
name = "Charm"
item.Equippable = false
local tagValues = {
    HPIncreasePercent = 0.1,
    HealingEffectIncrease = 1,
    DamageMultiplier = 1.1,
    DaggerChargeTimeMult = 0.75,
    Luck = 5,
    Duration = 30,
}
item.DataTags.ForEach = function(_, visit)
    for key, value in pairs(tagValues) do
        visit(
            ref({
                ToString = function()
                    return key
                end,
            }),
            ref(value)
        )
    end
end
local modifiers = rows()
assert(modifiers.HP == "+10%" and not modifiers["HPIncrease Percent"])
assert(modifiers.Healing == "+100%" and modifiers.Attack == "+10%")
assert(
    modifiers["Throwable return time"] == "-25%" and modifiers.Luck == "+5" and modifiers.Duration == "30 s"
)
print("PASS: item modifiers use player-facing labels, signed bonuses and correct units")

local damageLabels, hpLabels = {}, {}
StaticFindObject = function()
    return obj()
end
local function noop() end
B.widget = function(_, kind)
    if kind == "ScaleBox" then
        return obj({
            SetStretch = noop,
            SetStretchDirection = noop,
            AddChild = function(box, t)
                box.text = t
                return {
                    SetHorizontalAlignment = function(_, v)
                        t.align = v
                    end,
                    SetVerticalAlignment = noop,
                }
            end,
        })
    end
    assert(kind == "Overlay")
    return obj({
        SetVisibility = noop,
        AddChildToOverlay = function(layer, box)
            local labels = box.text.align == 3 and damageLabels or hpLabels
            box.text.layer = layer
            labels[#labels + 1] = box.text
            return { SetHorizontalAlignment = noop, SetVerticalAlignment = noop }
        end,
    })
end
StaticConstructObject = function()
    return obj({
        SetJustification = noop,
        SetShadowOffset = noop,
        SetShadowColorAndOpacity = noop,
        SetColorAndOpacity = noop,
        SetVisibility = function(s, v)
            s.vis = v
        end,
        SetText = function(s, v)
            s.text = v
        end,
        SetRenderOpacity = function(s, v)
            s.opacity = v
        end,
    })
end
local bar = obj({
    CurrentHP = 70,
    MaxHP = 100,
    BarPadding = { Top = 8 },
    EnemyName = obj({
        ForceLayoutPrepass = noop,
        GetDesiredSize = function()
            return { X = 140, Y = 20 }
        end,
    }),
    Fill = { Slot = { LayoutData = {} } },
    HealthBar = {
        AddChildToCanvas = function(_, layer)
            return {
                SetAutoSize = noop,
                SetAnchors = function(_, a)
                    layer.anchors = a
                end,
                SetAlignment = function(_, a)
                    layer.alignment = a
                end,
                SetPosition = function(_, p)
                    layer.position = p
                end,
                SetLayout = function(_, v)
                    layer.layout = v
                end,
                SetZOrder = function()
                    if layer.anchors then
                        damageLabels[#damageLabels + 1] = layer
                    end
                end,
            }
        end,
    },
})
module("monsterhealthbar", B)
local target = obj()
bar.Enemy = target
local combat = ref(obj({ EnemyStatusZone = obj({ EnemyHealthBar_base = bar }) }))
hooks.SetTarget(ref(bar), ref(target), ref(12))
hooks.Tick(combat)
assert(#damageLabels == 1 and damageLabels[1].text == "-12")
local damageLabel = damageLabels[1]
assert(hpLabels[1].layer.layout == bar.Fill.Slot.LayoutData)
assert(damageLabel.anchors.Maximum.X == 1 and damageLabel.anchors.Maximum.Y == 0)
assert(damageLabel.alignment.X == 1 and damageLabel.alignment.Y == 1)
local nameLineTop = -bar.BarPadding.Top - bar.EnemyName:GetDesiredSize().Y
assert(damageLabel.position.Y == nameLineTop and damageLabel.position.X <= 0)
now = now + 0.5
bar.CurrentHP = 58
hooks.Damaged(ref(bar), ref(58))
hooks.Tick(combat)
assert(damageLabels[1].text == "-12" and damageLabels[1].opacity == 0.65)
now = now + 0.5
bar.CurrentHP = 55
hooks.Tick(combat)
assert(damageLabels[1].text == "-3" and damageLabels[1].vis == 3)
bar.Enemy = obj()
bar.CurrentHP = 9
hooks.SetTarget(ref(bar), ref(bar.Enemy), ref(0))
hooks.Tick(combat)
assert(damageLabels[1].vis == 1)
bar.Enemy = target
hooks.SetTarget(ref(bar), ref(target), ref(4))
hooks.Tick(combat)
assert(damageLabels[1].text == "-4" and damageLabels[1].vis == 3)
now = now + 1
hooks.Tick(combat)
assert(damageLabels[1].vis == 1)
print("PASS: ultrawide camera/HUD resize and restore; item stats and units; per-target damage and expiry")

-- HP labels are unconditional; disabling damage skips both hit-event bindings.
B.config.damageNumbers = false
hooks = {}
module("monsterhealthbar", B)
hooks.Tick(combat)
assert(
    not hooks.SetTarget
        and not hooks.Damaged
        and not hooks["Took Damage"]
        and hpLabels[#hpLabels].text == "9 / 100"
)
print("PASS: HP numbers with damage disabled and no keyboard API")

-- Run the entry point with a memory-backed preference file, not the installed profile.
local stored, captured
local env = setmetatable({
    LoopInGameThreadWithDelay = noop,
    RegisterInitGameStatePostHook = noop,
    print = noop,
    io = {
        open = function(_, mode)
            if mode == "r" and not stored then
                return nil
            end
            return {
                read = function()
                    return stored
                end,
                write = function(_, v)
                    stored = v
                    return true
                end,
                close = function()
                    return true
                end,
            }
        end,
    },
    loadfile = function(path)
        if path:match("config%.lua$") then
            return function()
                return {}
            end
        end
        return function(api)
            captured = api
        end
    end,
}, { __index = _G })
local function boot()
    assert(loadfile("Scripts\\main.lua", "t", env))()
end
boot()
assert(captured.shimmer == "low")
captured.setShimmer("medium")
assert(stored == "medium")
boot()
assert(captured.shimmer == "medium")
captured.setShimmer("high")
assert(stored == "high")
captured.setShimmer("low")
assert(stored == "low")
print("PASS: shimmer selection and persistence across restart")

-- Exercise real Lua file modes/offsets with a disposable file instead of the installed INI.
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
    local sandbox = setmetatable({ io = { open = openTestIni } }, { __index = _G })
    local features = assert(loadfile("Scripts\\options.lua", "t", sandbox))
    local rows = {}
    local slot = { SetPadding = noop, SetHorizontalAlignment = noop }
    local page = obj({
        GetOwningPlayer = noop,
        Vsync = { Slot = { Padding = {}, HorizontalAlignment = 0 } },
        OptionsList = obj({
            AddChild = function(_, child)
                rows[#rows + 1] = child
                return slot
            end,
            HasChild = function(_, child)
                for _, r in ipairs(rows) do
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
    features(B)
    assert(B.config.drag and not B.config.graphics and not B.config.inventoryStats)
    hooks.Open(ref(page))
    hooks.Open(ref(page))
    assert(#rows == 8)
    local selector = rows[#rows].MyControl
    assert(selector.text == "Low" and selector.ApplyOptionSettings == false)
    selector.CurrentValue = 2
    selector:Refreshtext()
    hooks.Tick(ref(page))
    assert(B.shimmer == "high" and readIni() == ini)
    local drag, damage
    for _, row in ipairs(rows) do
        if row.Name:find("Drag to equip", 1, true) then
            drag = row.MyControl
        end
        if row.Name:find("Damage numbers", 1, true) then
            damage = row.MyControl
        end
    end
    drag.CurrentValue = false
    now = now + 0.2
    hooks.Tick(ref(page))
    damage.CurrentValue = false
    hooks.Close(ref(page))
    assert(B.config.drag and B.config.damageNumbers and B.shimmer == "high")
    assert(readIni() == ini:gsub("drag = 1", "drag = 0") .. "damageNumbers=0\n")
    features(B)
    assert(not B.config.drag and not B.config.damageNumbers and not B.config.graphics)
end)
os.remove(tmp)
assert(testResult, testError)
print("PASS: Options switches survive restart, don't duplicate rows, preserve other INI settings")
