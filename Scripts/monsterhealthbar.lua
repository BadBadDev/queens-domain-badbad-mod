-- Places HP labels on player, enemy and boss bars and displays the last hit on each monster bar.
--
-- Shows current / max HP as text on the player's life bar, the enemy health
-- bar and the boss health bar. Runtime only: nothing is written to saves or
-- game files.
--
-- How it works: a post-hook on FS_PlayerHUD_C:Tick finds the three bars in
-- the HUD (StatusCluster.PlayerLifeBar, EnemyStatusZone.EnemyHealthBar_base,
-- EnemyStatusZone.BossHealthBar), adds one centred TextBlock to each the
-- first time, and refreshes it when the value changes. Enemy and boss values
-- come from the bars' own CurrentHP / MaxHP; the player's from
-- FS_PlayerChar.Health and GetMaxHP. The labels sit inside the bars, so they
-- fade in and out with them.
--
local B = ...
local Config = {
    PlayerSize = 14, -- font sizes
    EnemySize = 15,
    BossSize = 16,
    PlayerNudgeDown = 2,
    -- The player bar's visible length follows max HP, so the number is
    -- centred on the visible part (see PlaceOnVisibleBar).
}

local HudTick = "/Game/UI/HUD/FS_PlayerHUD.FS_PlayerHUD_C:Tick"

local Labels = {} -- bar address -> { Text, Last }
local Hits = {}
local HitLabels = {}
local enemySamples = {}
local Frame = 0
local PlayerMax = nil

local function Log(Message)
    print("[BBM] Health: " .. tostring(Message) .. "\n")
end

local function Valid(Object)
    if Object == nil then
        return false
    end
    local Ok, Result = pcall(function()
        return Object:IsValid()
    end)
    return Ok and Result == true
end

local TextClass = nil

local function createHealthTextBlock(Owner, FontSource, Size)
    if not Valid(TextClass) then
        TextClass = StaticFindObject("/Script/UMG.TextBlock")
    end
    local Text = StaticConstructObject(TextClass, Owner.WidgetTree)
    if Valid(FontSource) then
        pcall(function()
            Text:SetFont(FontSource.Font) -- copy the game's font into our own widget first
            local Font = Text.Font
            Font.Size = Size
            Text:SetFont(Font)
        end)
    end
    Text:SetJustification(1) -- centre
    Text:SetShadowOffset({ X = 1.5, Y = 1.5 })
    Text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
    Text:SetColorAndOpacity({ SpecifiedColor = { R = 1, G = 0.97, B = 0.9, A = 1 }, ColorUseRule = 0 })
    Text:SetVisibility(3) -- HitTestInvisible
    return Text
end

local function formatCurrentAndMaxHp(Current, Max)
    local C = math.max(0, math.ceil(Current - 0.001))
    if Max ~= nil and Max > 0 then
        return string.format("%d / %d", C, math.floor(Max + 0.5))
    end
    return string.format("%d", C)
end

local function updateLabelText(Label, Value)
    if Label.Last == Value then
        return
    end
    Label.Last = Value
    Label.Text:SetText(FText(Value))
end

local function centerHpTextInFill(bar, layer, text)
    local fit = B.widget(bar, "ScaleBox")
    fit:SetStretch(2) -- ScaleToFit: fit the full font line, including ascent and descent.
    fit:SetStretchDirection(1) -- DownOnly
    local content = fit:AddChild(text)
    content:SetHorizontalAlignment(2)
    content:SetVerticalAlignment(2)
    local slot = layer:AddChildToOverlay(fit)
    slot:SetHorizontalAlignment(0)
    slot:SetVerticalAlignment(0)
end

-- A sibling of the native fill, not a child of the game's disposable damage segments.
local function getOrCreateMonsterReadout(Bar, FontSource, Size)
    local Key = Bar:GetAddress()
    local Label = Labels[Key]
    if Label ~= nil and Valid(Label.Text) then
        return Label
    end
    local layer = B.widget(Bar, "Overlay")
    layer:SetVisibility(3)
    local layerSlot = Bar.HealthBar:AddChildToCanvas(layer)
    layerSlot:SetLayout(Bar.Fill.Slot.LayoutData)
    layerSlot:SetZOrder(100)
    local Text = createHealthTextBlock(Bar, FontSource, Size)
    centerHpTextInFill(Bar, layer, Text)
    Label = { Text = Text }
    Labels[Key] = Label
    return Label
end

-- Label inside an overlay (player life bar), centred on the bar.
local function getOrCreatePlayerReadout(Bar, Overlay, FontSource, Size)
    local Key = Bar:GetAddress()
    local Label = Labels[Key]
    if Label ~= nil and Valid(Label.Text) then
        return Label
    end
    local Text = createHealthTextBlock(Bar, FontSource, Size)
    local Slot = Overlay:AddChildToOverlay(Text)
    Slot:SetHorizontalAlignment(2) -- centre, then shifted onto the visible bar
    Slot:SetVerticalAlignment(2)
    Slot:SetPadding({ Left = 0, Top = Config.PlayerNudgeDown, Right = 0, Bottom = 0 })
    Label = { Text = Text, Last = nil, Shown = true }
    Labels[Key] = Label
    return Label
end

local function setReadoutVisibility(Label, Show)
    if Label.Shown == Show then
        return
    end
    Label.Shown = Show
    Label.Text:SetVisibility(Show and 3 or 1) -- HitTestInvisible / Collapsed
end

local function updateMonsterHpText(Bar, FontSource, Size)
    if not Valid(Bar) then
        return
    end
    local Label = getOrCreateMonsterReadout(Bar, FontSource, Size)
    updateLabelText(Label, formatCurrentAndMaxHp(Bar.CurrentHP, Bar.MaxHP))
end

local function recordTargetDamage(id, target, amount)
    if target and type(amount) == "number" and amount > 0 then
        local now = os.clock()
        Hits[id] = {
            target = target,
            text = string.format("-%d", math.ceil(amount)),
            started = now,
            untilTime = now + B.config.damageSeconds,
        }
    elseif Hits[id] and Hits[id].target ~= target then
        Hits[id] = nil
    end
end

local function onEnemyBarTargetChanged(ctx, enemyParam, damageParam)
    local bar, enemy = ctx:get(), enemyParam:get()
    if not Valid(bar) then
        return
    end
    local id = bar:GetAddress()
    local target = Valid(enemy) and enemy:GetAddress() or nil
    enemySamples[id] = target and { target = target, hp = bar.CurrentHP } or nil
    recordTargetDamage(id, target, damageParam:get())
end

local function trackEnemyHpLoss(bar, hp)
    local id = bar:GetAddress()
    local enemy = bar.Enemy
    local target = Valid(enemy) and enemy:GetAddress() or nil
    local prior = enemySamples[id]
    if not target then
        enemySamples[id] = nil
        return
    end
    if not prior or prior.target ~= target then
        enemySamples[id] = { target = target, hp = hp }
        recordTargetDamage(id, target, 0)
    else
        if hp < prior.hp then
            recordTargetDamage(id, target, prior.hp - hp)
        end
        prior.hp = hp
    end
end

local function refreshLastHitReadout(bar, source, size)
    if not Valid(bar) then
        return
    end
    local id = bar:GetAddress()
    local hit, label = Hits[id], HitLabels[id]
    if not hit or os.clock() >= hit.untilTime then
        Hits[id] = nil
        if label and Valid(label.Text) then
            setReadoutVisibility(label, false)
        end
        return
    end
    if not label or not Valid(label.Text) then
        local t = createHealthTextBlock(bar, source, size)
        t:SetJustification(2) -- right
        local slot = bar.HealthBar:AddChildToCanvas(t)
        slot:SetAutoSize(true)
        slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        slot:SetAlignment({ X = 1, Y = 1 })
        slot:SetZOrder(101)
        bar.EnemyName:ForceLayoutPrepass()
        label = { Text = t, Slot = slot, Shown = true }
        HitLabels[id] = label
    end
    -- The name's measured line height can change after the first layout or a target switch.
    local clearance = bar.BarPadding.Top + bar.EnemyName:GetDesiredSize().Y
    if clearance ~= label.clearance then
        label.Slot:SetPosition({ X = 0, Y = -clearance - 3 })
        label.clearance = clearance
    end
    setReadoutVisibility(label, true)
    updateLabelText(label, hit.text)
    -- Give identical consecutive hits a visible restart without moving the baseline.
    local alpha = 0.65 + 0.35 * math.min(1, (os.clock() - hit.started) / 0.12)
    if label.alpha ~= alpha then
        label.Text:SetRenderOpacity(alpha)
        label.alpha = alpha
    end
end

local function readPlayerMaxHp(Player)
    if PlayerMax ~= nil and Frame % 15 ~= 0 then
        return PlayerMax
    end
    local Ok, Max = pcall(function()
        local Out, NoWounds = {}, {}
        Player:GetMaxHP(false, Out, NoWounds)
        return Out.HP
    end)
    if not Ok or type(Max) ~= "number" or Max <= 0 then
        local Cached = Player.CachedHP
        Max = (type(Cached) == "number" and Cached > 0) and Cached or nil
    end
    PlayerMax = Max
    return Max
end

-- Where the visible red bar is, in the life bar's own units (the bar widget
-- is 1024 wide). The game sets the bar's length to
--   MapRangeClamped(max HP, 0, 500, PercentMin, PercentMax)
-- with PercentMin/Max from PlayerLifeBar_C:GetHealthBarAspectRatioTweak
-- (0..1 at 16:9 and wider; 0.1..0.7 on narrower screens such as 16:10 and
-- 4:3, or depending on the game's aspect ratio setting). Measured in game at
-- 16:9: the red starts ~8 units in and ends at ~15 + 923 * that fraction.
local Tweak = nil -- { Min, Max }

local function readPlayerBarRange(Bar)
    if Tweak ~= nil and Frame % 120 ~= 0 then
        return Tweak
    end
    local Min, Max = 0, 1
    pcall(function()
        local Offset, PMax, PMin = {}, {}, {}
        Bar:GetHealthBarAspectRatioTweak(Offset, PMax, PMin)
        if
            type(PMax.PercentMax) == "number"
            and type(PMin.PercentMin) == "number"
            and PMax.PercentMax > PMin.PercentMin
        then
            Min, Max = PMin.PercentMin, PMax.PercentMax
        end
    end)
    if Tweak == nil or Tweak.Min ~= Min or Tweak.Max ~= Max then
        Log(string.format("player bar length range %.2f..%.2f", Min, Max))
    end
    Tweak = { Min = Min, Max = Max }
    return Tweak
end

local function centerLabelOnVisiblePlayerBar(Bar, Label, MaxHP)
    local Range = readPlayerBarRange(Bar)
    local Clamped = math.max(0, math.min(500, MaxHP or 500))
    local Fraction = Range.Min + (Range.Max - Range.Min) * Clamped / 500
    local Left, Right = 8, 15 + 923 * Fraction
    local Shift = math.floor((Left + Right) / 2 - 512 + 0.5)
    if Label.Shift == Shift then
        return
    end
    Label.Shift = Shift
    Label.Text:SetRenderTranslation({ X = Shift, Y = 0 })
end

local function updatePlayerHpText(Bar, FontSource)
    if not Valid(Bar) then
        return
    end
    local Player = Bar.PlayerChar
    if not Valid(Player) then
        return
    end
    local Label = getOrCreatePlayerReadout(Bar, Bar.Container, FontSource, Config.PlayerSize)
    local Max = readPlayerMaxHp(Player)
    updateLabelText(Label, formatCurrentAndMaxHp(Player.Health, Max))
    centerLabelOnVisiblePlayerBar(Bar, Label, Max)
end

local function updateHealthReadouts(Context)
    Frame = Frame + 1
    local Hud = Context:get()
    if not Valid(Hud) then
        return
    end
    local Zone = Hud.EnemyStatusZone
    local Cluster = Hud.StatusCluster
    local EnemyBar = Valid(Zone) and Zone.EnemyHealthBar_base or nil
    local BossBar = Valid(Zone) and Zone.BossHealthBar or nil
    local FontSource = Valid(EnemyBar) and EnemyBar.EnemyName or nil
    if B.config.damageNumbers then
        if Valid(EnemyBar) then
            trackEnemyHpLoss(EnemyBar, EnemyBar.CurrentHP)
        end
        refreshLastHitReadout(EnemyBar, FontSource, Config.EnemySize)
        refreshLastHitReadout(BossBar, FontSource, Config.BossSize)
    end
    updateMonsterHpText(EnemyBar, FontSource, Config.EnemySize)
    updateMonsterHpText(BossBar, FontSource, Config.BossSize)
    if Valid(Cluster) then
        updatePlayerHpText(Cluster.PlayerLifeBar, FontSource)
    end
end

local Errors = 0

local function updateHealthReadoutsSafely(Context)
    local Ok, Error = pcall(updateHealthReadouts, Context)
    if not Ok and Errors < 5 then
        Errors = Errors + 1
        Log("tick error: " .. tostring(Error))
    end
end

B.hook(HudTick, updateHealthReadoutsSafely)
if B.config.damageNumbers then
    local base = "/Game/UI/HUD/Widgets/EnemyHealthBar/"
    B.hook(base .. "EnemyHealthBar_base.EnemyHealthBar_base_C:SetTarget", onEnemyBarTargetChanged)
    B.hook(base .. "EnemyHealthBar_base.EnemyHealthBar_base_C:Damaged", function(ctx, newHP)
        local bar = ctx:get()
        if Valid(bar) then
            trackEnemyHpLoss(bar, newHP:get())
        end
    end)
    B.hook(base .. "BossHealthBar.BossHealthBar_C:Took Damage", function(ctx, enemyParam, amount)
        local bar, enemy = ctx:get(), enemyParam:get()
        if Valid(bar) and Valid(enemy) then
            recordTargetDamage(bar:GetAddress(), enemy:GetAddress(), amount:get())
        end
    end)
end

table.insert(B.reset, function()
    Labels, Hits, HitLabels, enemySamples, PlayerMax, Tweak = {}, {}, {}, {}, nil, nil
end)

Log("loaded")
