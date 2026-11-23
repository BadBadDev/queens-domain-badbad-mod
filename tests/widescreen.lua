-- Checks camera constraints, viewport edge groups and status overlay resizing.
local support = require("tests.support")
local test = support.new()
local B, hooks = test.api, test.hooks
local obj, ref, wing = support.object, support.ref, support.hudWidget
local width = 1920

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
test.loadModule("widescreen")
hooks.Tick = hooks["/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick"]
hooks.Tick(ref(hud))
assert(hud.StatusCluster.RenderTransform.Translation.X == 8)
width = 2560
test.now = 1
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
test.now = 2
hooks.Tick(ref(hud))
assert(hud.CompassWidget.RenderTransform.Translation.X == 290)
assert(hud.ConsumableHUD.RenderTransform.Translation.X == -315)
hud.ConsumableHUD = wing(12)
test.now = test.now + 0.5
hooks.Tick(ref(hud))
assert(hud.ConsumableHUD.RenderTransform.Translation.X == -308)
width = 1920
test.now = 3
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
