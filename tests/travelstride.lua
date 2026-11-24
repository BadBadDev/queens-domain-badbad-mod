-- Exercise the native speed, movement-mode, enemy alert and flying-sword hook boundaries.
local test = require("tests.support").new()
local support = require("tests.support")
local obj, ref = support.object, support.ref
local B, hooks = test.api, test.hooks
local world = obj()
local function getWorld()
    return world
end
local grounded = true
local move = obj({
    MaxWalkSpeed = 400,
    MovementMode = 1,
    Velocity = { X = 0, Y = 0, Z = 0 },
    IsMovingOnGround = function()
        return grounded
    end,
})
local player = obj({
    CharacterMovement = move,
    LastGroundedHSpeed = 0,
    GetFullName = function()
        return "Player /Test.Player"
    end,
    GetWorld = getWorld,
    IsLocallyControlled = function()
        return true
    end,
})
local enemy = obj({ bAggrod = true, bDead = false, GetWorld = getWorld })
local bindingsReady = false
local bind = B.hook
B.hook = function(path, fn)
    bind(path, fn)
    return function()
        return bindingsReady
    end
end
test.env.StaticFindObject = function(path)
    assert(path == "/Test.Player")
    return player
end
B.lib = function(path)
    if path == "/Script/QueensDomain.FS_EnemyCharacterBase" then
        return obj()
    end
    assert(path == "/Script/Engine.Default__GameplayStatics")
    return {
        GetTimeSeconds = function()
            return test.now
        end,
        GetAllActorsOfClass = function(_, _, _, result)
            result[1] = ref(enemy)
        end,
    }
end
test.loadModule("travelstride")
local function nativeSpeedUpdate(at, base)
    test.now = at
    move.MaxWalkSpeed = base or 400
    hooks.TickMoveSpeed(ref(player))
end
nativeSpeedUpdate(0)
nativeSpeedUpdate(10)
assert(not B.hasTravelStride(player) and move.MaxWalkSpeed == 400)
bindingsReady = true
nativeSpeedUpdate(11)
assert(not B.hasTravelStride(player), "an already-alert enemy must prevent activation")
enemy.bAggrod = false
hooks.UnAggrod(ref(enemy))
nativeSpeedUpdate(12)
nativeSpeedUpdate(19.99)
assert(not B.hasTravelStride(player))
nativeSpeedUpdate(20)
assert(B.hasTravelStride(player) and move.MaxWalkSpeed == 500)
nativeSpeedUpdate(20.1, 300)
assert(move.MaxWalkSpeed == 375, "use the current native cap, including debuffs")
move.Velocity = { X = 225, Y = 300, Z = 480 }
player.LastGroundedHSpeed = 375
hooks.Jump(ref(player))
assert(move.Velocity.X == 180 and move.Velocity.Y == 240 and move.Velocity.Z == 480)
assert(move.MaxWalkSpeed == 300 and player.LastGroundedHSpeed == 300 and B.hasTravelStride(player))
grounded = false
nativeSpeedUpdate(20.2, 300)
assert(move.MaxWalkSpeed == 300)

local progress = 0
local sword = obj({
    GetOwner = function()
        return player
    end,
    ReceiveTick = function(self, delta)
        progress = progress + delta
        hooks.ReceiveTick(ref(self), ref(delta))
    end,
})
sword:ReceiveTick(0.25)
assert(progress == 0.5, "airborne sword recharge continues at 2x, not recursively")
grounded = true
nativeSpeedUpdate(21)
assert(move.MaxWalkSpeed == 500, "landing must not start a new eight-second timer")
grounded = false
move.Velocity = { X = 500, Y = 0, Z = -15 }
hooks.K2_OnMovementModeChanged(ref(player))
assert(move.Velocity.X == 400 and move.Velocity.Z == -15, "stepping off a ledge also sheds the boost")
grounded = true
nativeSpeedUpdate(22)
enemy.bAggrod = true
hooks.Aggrod(ref(enemy))
assert(not B.hasTravelStride(player) and move.MaxWalkSpeed == 400)
sword:ReceiveTick(0.25)
assert(progress == 0.75, "combat must immediately restore ordinary recharge without losing progress")
nativeSpeedUpdate(40)
assert(not B.hasTravelStride(player), "waiting while an enemy is still alert is not out of combat")
enemy.bDead = true
nativeSpeedUpdate(41)
nativeSpeedUpdate(49)
assert(B.hasTravelStride(player), "death without an unaggro event must not leave combat stuck")
hooks.DamagedHitFX(ref(player))
assert(not B.hasTravelStride(player))
for _, reset in ipairs(B.reset) do
    reset()
end
nativeSpeedUpdate(100)
assert(not B.hasTravelStride(player), "a fresh world starts its own quiet period")
