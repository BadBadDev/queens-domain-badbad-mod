-- Checks HP and last-hit readouts, repeated hits, target switching and disabled damage numbers.
local support = require("tests.support")
local test = support.new()
local B, hooks = test.api, test.hooks
local obj, ref, noop = support.object, support.ref, support.noop
B.config.damageNumbers = true
B.config.damageSeconds = 0.85

local damageLabels, hpLabels = {}, {}
local nameRow, nameFit
test.env.StaticFindObject = function()
    return obj()
end
B.widget = function(_, kind)
    if kind == "HorizontalBox" then
        nameRow = obj({
            children = {},
            AddChildToHorizontalBox = function(row, child)
                row.children[#row.children + 1] = child
                if #row.children == 2 then
                    damageLabels[#damageLabels + 1] = child
                end
                return { SetSize = noop, SetVerticalAlignment = noop, SetPadding = noop }
            end,
        })
        return nameRow
    end
    if kind == "ScaleBox" then
        return obj({
            SetStretch = noop,
            SetStretchDirection = noop,
            AddChild = function(box, t)
                box.text = t
                if t.GetParent then
                    nameFit = box
                end
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
            box.text.layer = layer
            hpLabels[#hpLabels + 1] = box.text
            return { SetHorizontalAlignment = noop, SetVerticalAlignment = noop }
        end,
    })
end
local headerSlot = {
    autoSize = true,
    anchors = { Minimum = { X = 0, Y = 0.5 }, Maximum = { X = 0, Y = 0.5 } },
    offsets = { Left = -12, Top = -43, Right = 96, Bottom = 29 },
    GetAutoSize = function(s)
        return s.autoSize
    end,
    SetAutoSize = function(s, v)
        s.autoSize = v
    end,
    GetAnchors = function(s)
        return s.anchors
    end,
    SetAnchors = function(s, v)
        s.anchors = v
    end,
    GetOffsets = function(s)
        return s.offsets
    end,
    SetOffsets = function(s, v)
        s.offsets = v
    end,
}
local header = obj({
    Slot = headerSlot,
    RenderTransform = { Translation = { X = 0, Y = 0 } },
    SetContent = function(s, v)
        s.content = v
    end,
    SetHorizontalAlignment = noop,
})
test.env.StaticConstructObject = function()
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
        GetParent = function()
            return header
        end,
    }),
    Fill = { Slot = { LayoutData = {} } },
    HealthBar = {
        AddChildToCanvas = function(_, layer)
            return {
                SetLayout = function(_, v)
                    layer.layout = v
                end,
                SetZOrder = noop,
            }
        end,
    },
})
test.loadModule("monsterhealthbar")
local target = obj()
bar.Enemy = target
local combat = ref(obj({ EnemyStatusZone = obj({ EnemyHealthBar_base = bar }) }))
hooks.SetTarget(ref(bar), ref(target), ref(12))
hooks.Tick(combat)
assert(#damageLabels == 1 and damageLabels[1].text == "-12")
local damageLabel = damageLabels[1]
assert(hpLabels[1].layer.layout == bar.Fill.Slot.LayoutData)
assert(header.content == nameRow and nameRow.children[1] == nameFit and nameFit.text == bar.EnemyName)
assert(nameRow.children[2] == damageLabel and headerSlot.anchors.Maximum.X == 1)
assert(headerSlot.offsets.Top == -43 and headerSlot.offsets.Bottom == 29)
test.now = test.now + 0.5
bar.CurrentHP = 58
hooks.Damaged(ref(bar), ref(58))
hooks.Tick(combat)
assert(damageLabels[1].text == "-12" and damageLabels[1].opacity == 0.65)
test.now = test.now + 0.5
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
test.now = test.now + 1
hooks.Tick(combat)
assert(damageLabels[1].vis == 1)
assert(headerSlot.autoSize and headerSlot.anchors.Maximum.X == 0 and headerSlot.offsets.Right == 96)

-- HP labels are unconditional; disabling damage skips both hit-event bindings.
B.config.damageNumbers = false
for path in pairs(hooks) do
    hooks[path] = nil
end
test.loadModule("monsterhealthbar")
hooks.Tick(combat)
assert(
    not hooks.SetTarget
        and not hooks.Damaged
        and not hooks["Took Damage"]
        and hpLabels[#hpLabels].text == "9 / 100"
)
