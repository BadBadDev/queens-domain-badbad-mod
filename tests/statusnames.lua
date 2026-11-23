-- Checks active status labels, their height above the item slot and their expiry.
local support = require("tests.support")
local test = support.new()
local B, hooks = test.api, test.hooks
local obj, ref, wing, noop = support.object, support.ref, support.hudWidget, support.noop

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
test.loadModule("statusnames")
hooks.Tick(ref(effectsHud))
assert(effectsLabel.text == "Burn\nPoison\nSticky" and effectsLabel.visibility == 3)
assert(effectsLabel.Slot.anchors == anchor and effectsLabel.Slot.position.X == -150)
local itemTop = -20 - 100 + 15
assert(itemTop - effectsLabel.Slot.position.Y >= 15, "leave one line of clearance above the usable item")
icon.RenderTransform.Translation.X = 0
test.now = test.now + 1
hooks.Tick(ref(effectsHud))
assert(effectsLabel.Slot.position.X == 50) -- reflow even when the effect names haven't changed
component.Applied = false
player.MagicFireEffectLogic.CurrentMagicFireDamagePool = 0
test.now = test.now + 1
hooks.Tick(ref(effectsHud))
assert(effectsLabel.text == "Sticky")
player.StickyEffectApplied = false
test.now = test.now + 1
hooks.Tick(ref(effectsHud))
assert(effectsLabel.visibility == 1)
