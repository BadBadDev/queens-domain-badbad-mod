-- Shortens peaceful ground travel without extending a running jump or altering dash distance.
local B = ...
local QUIET_SECONDS, GROUND_FACTOR = 8, 1.25
local PLAYER = "/Game/Player/FS_PlayerChar.FS_PlayerChar_C:"
local ENEMY = "/Game/Enemies/EnemyBase.EnemyBase_C:"
local SWORD = "/Game/Player/Assets/Blueprints/FlyingSwordChargeLogic.FlyingSwordChargeLogic_C:"
local state = {}
local signals = {}
local bindingsReady = false
local statics, enemyClass
local replayingRecharge = false

local function gameTime(player)
    statics = statics or B.lib("/Script/Engine.Default__GameplayStatics")
    return statics:GetTimeSeconds(player)
end

local function activePlayer()
    local player = state.path and StaticFindObject(state.path)
    if B.valid(player) and player:GetAddress() == state.id then
        return player
    end
end

local function removeGroundBonus(player)
    local base = state.groundCap
    if not base then
        return
    end
    local move = player.CharacterMovement
    if B.valid(move) then
        local cap = math.min(base, move.MaxWalkSpeed)
        move.MaxWalkSpeed = cap
        -- The native leave-ground logic also uses its last horizontal-speed sample.
        player.LastGroundedHSpeed = math.min(player.LastGroundedHSpeed, cap)
        local v = move.Velocity
        local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        if speed > cap and speed > 0 then
            local ratio = cap / speed
            move.Velocity = { X = v.X * ratio, Y = v.Y * ratio, Z = v.Z }
        end
    end
    state.groundCap = nil
end

local function interruptTravel(player, now)
    state.readyAt = now + QUIET_SECONDS
    state.active = false
    removeGroundBonus(player)
end

local function onCombatEvent(context)
    local player = activePlayer()
    if not player then
        return
    end
    local actor = context:get()
    if
        not B.valid(actor)
        or not B.valid(actor:GetWorld())
        or actor:GetWorld():GetAddress() ~= player:GetWorld():GetAddress()
    then
        return
    end
    interruptTravel(player, gameTime(player))
end

local function hasAlertEnemy(player)
    enemyClass = enemyClass or B.lib("/Script/QueensDomain.FS_EnemyCharacterBase")
    local enemies = {}
    statics:GetAllActorsOfClass(player, enemyClass, enemies)
    for _, parameter in ipairs(enemies) do
        local enemy = parameter:get()
        if B.valid(enemy) and enemy.bAggrod and not enemy.bDead then
            return true
        end
    end
    return false
end

local function resetForPlayer(player, now)
    state = {
        id = player:GetAddress(),
        path = assert(player:GetFullName():match("^%S+ (.+)$"), "Missing player object path"),
        readyAt = now + QUIET_SECONDS,
        nextScan = now,
        active = false,
    }
end

local function updateStrideAfterNativeSpeed(context)
    local player = context:get()
    if not player:IsLocallyControlled() then
        return
    end
    local now = gameTime(player)
    if state.id ~= player:GetAddress() then
        resetForPlayer(player, now)
    end
    if not bindingsReady then
        for _, ready in ipairs(signals) do
            if not ready() then
                return
            end
        end
        bindingsReady = true
        state.readyAt = now + QUIET_SECONDS
    end
    local move = player.CharacterMovement
    if
        not B.valid(move)
        or player.IsDead
        or player.InIntroCutscene
        or player.Teleporting
        or move.MovementMode == 0
    then
        interruptTravel(player, now)
        return
    end
    if now >= state.nextScan then
        -- Events interrupt immediately; the world query covers late loads, deaths and despawns.
        state.active = false
        local hostile = hasAlertEnemy(player)
        if hostile or state.hostile then
            interruptTravel(player, now)
        end
        state.hostile = hostile
        state.nextScan = now + 0.5
    end
    state.active = not state.hostile and now >= state.readyAt
    if
        not state.active
        or not move:IsMovingOnGround()
        or player.Dashing
        or player.bPressedJump
        or player.RunningBlocked
        or player.NormalAttackCharging
    then
        removeGroundBonus(player)
        return
    end
    -- TickMoveSpeed has just recomputed the vanilla cap from equipment, run mode and debuffs.
    local base = move.MaxWalkSpeed
    if base > 0 then
        state.groundCap = base
        move.MaxWalkSpeed = base * GROUND_FACTOR
        player.LastGroundedHSpeed = math.min(player.LastGroundedHSpeed, base)
    end
end

local function suspendGroundSpeed(context)
    local player = context:get()
    if state.id == player:GetAddress() then
        removeGroundBonus(player)
    end
end

for _, path in ipairs({
    ENEMY .. "Aggrod",
    ENEMY .. "UnAggrod",
    PLAYER .. "DamagedHitFX",
    PLAYER .. "EnemyWasDamaged",
}) do
    signals[#signals + 1] = B.hook(path, onCombatEvent)
end
signals[#signals + 1] = B.hook("/Script/Engine.Character:Jump", suspendGroundSpeed)
signals[#signals + 1] = B.hook(PLAYER .. "OnJumped", suspendGroundSpeed)
signals[#signals + 1] = B.hook(PLAYER .. "K2_OnMovementModeChanged", function(context)
    local player = context:get()
    if state.id == player:GetAddress() and not player.CharacterMovement:IsMovingOnGround() then
        removeGroundBonus(player)
    end
end)
signals[#signals + 1] = B.hook(PLAYER .. "BeginWindDash", suspendGroundSpeed)
B.hook(PLAYER .. "TickMoveSpeed", updateStrideAfterNativeSpeed)

B.hook(SWORD .. "ReceiveTick", function(context, delta)
    if not state.active or replayingRecharge then
        return
    end
    local charge = context:get()
    local owner = charge:GetOwner()
    if
        not B.valid(owner)
        or owner:GetAddress() ~= state.id
        or owner.IsDead
        or owner.InIntroCutscene
        or owner.Teleporting
    then
        return
    end
    -- One additional native recharge step: preserve the game's magic-rate multiplier,
    -- capacity, airborne queue and charge-gained events, including partial charges.
    replayingRecharge = true
    local ok, err = pcall(function()
        charge:ReceiveTick(delta:get())
    end)
    replayingRecharge = false
    if not ok then
        error(err)
    end
end)

function B.hasTravelStride(player)
    return state.active and state.id == player:GetAddress()
end

table.insert(B.reset, function()
    state, statics, enemyClass = {}, nil, nil
end)
