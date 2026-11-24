-- Reads item and player balance data and formats the values displayed by iteminfo.lua.
local B = ...

local function formatNumber(v)
    return (("%.2f"):format(v):gsub("0+$", ""):gsub("%.$", ""))
end

local function formatSignedNumber(v)
    return (v >= 0 and "+" or "") .. formatNumber(v)
end

local function formatSignedPercent(v)
    return formatSignedNumber(v * 100) .. "%"
end

local function formatDuration(v)
    return v > 0 and v < 1 and formatNumber(v * 1000) .. " ms" or formatNumber(v) .. " s"
end
-- Fractions store the bonus directly; multipliers store the final factor (1 = unchanged).
local function formatMultiplierBonus(v)
    return formatSignedPercent(v - 1)
end
local modifierFormats = {
    HPIncreasePercent = { "HP", formatSignedPercent },
    HPStealPercent = { "Life steal", formatSignedPercent },
    HealingEffectIncrease = { "Healing", formatSignedPercent },
    AttackSpeedBonus = { "Attack speed", formatSignedPercent },
    DamageMultiplier = { "Attack", formatMultiplierBonus },
    BaseDamageIncrease = { "Base damage", formatSignedNumber },
    DamageReductionPercent = { "Damage reduction", formatSignedPercent },
    TakenDamageMultiplier = { "Damage taken", formatMultiplierBonus },
    AllResistances = { "All resistances", formatSignedPercent },
    BindingResistance = { "Binding resistance", formatSignedPercent },
    DiseaseResistance = { "Disease resistance", formatSignedPercent },
    HeavyResistance = { "Heavy resistance", formatSignedPercent },
    MagicPoisonResistance = { "Magic Rot resistance", formatSignedPercent },
    PoisonResistance = { "Poison resistance", formatSignedPercent },
    StickyResistance = { "Sticky resistance", formatSignedPercent },
    WeakenResistance = { "Weaken resistance", formatSignedPercent },
    MagicPoisonDegenMultiplier = { "Magic Rot drain", formatMultiplierBonus },
    DaggerChargeTimeMult = { "Throwable return time", formatMultiplierBonus },
    GunChargeRateIncrease = { "Gun charge rate", formatSignedPercent },
    UltraChargeRateIncrease = { "Ultra charge rate", formatSignedPercent },
    MagicRate = { "Magic rate", formatSignedPercent },
    WeaponXPIncrease = { "Weapon XP", formatSignedPercent },
    XPIncrease = { "XP", formatSignedPercent },
    Luck = { "Luck", formatSignedNumber },
    LightRadius = {
        "Light radius",
        function(v)
            return formatSignedNumber(v / 100) .. " m"
        end,
    },
    RegenPerSecond = {
        "Regeneration",
        function(v)
            return formatSignedNumber(v) .. " HP/s"
        end,
    },
    Duration = { "Duration", formatDuration },
    Cooldown = { "Cooldown", formatDuration },
    SecondaryHeavyDuration = { "Secondary Heavy duration", formatDuration },
}

local function toDisplayedAttackPower(power, scale)
    -- The native widget multiplies as a float before flooring to an integer.
    local result = string.unpack("f", string.pack("f", power * scale))
    return math.floor(result)
end

local function readHealingBonus(owner)
    local pawn = owner:GetOwningPlayerPawn()
    if B.valid(pawn) then
        return pawn:GetHealingEffectMult() - 1
    end
end
local healingFieldsByItem = {}
for tier = 1, 3 do
    for _, prefix in ipairs({ "HealingHerb", "HealingPotion" }) do
        healingFieldsByItem[prefix .. (tier == 1 and "" or ("_0" .. tier))] = prefix .. tier .. "HealAmount"
    end
end
local curedEffectsByItem = {
    PoisonCure = "Poison",
    DiseaseCure = "Disease",
    HeavyCure = "Heavy",
    BindingCure = "Binding",
    StickyCure = "Sticky",
    WeakenCure = "Weaken",
    Panacea = "Binding, Disease, Heavy, Poison, Sticky, Weaken",
}
local buffStatsByItem = {
    BerserkFruit = { "Attack", "BerserkFruitDamageIncrease" },
    BerserkPotion = { "Attack", "BerserkPotionDamageIncrease" },
    IronFruit = { "Damage reduction", "Iron Skin Fruit Damage Reduction" },
    IronPotion = { "Damage reduction", "Iron Skin Potion Damage Reduction" },
}

local function formatHealing(hp, bonus)
    return formatNumber(hp) .. (bonus and (" (" .. formatSignedNumber(hp * bonus) .. ")") or "")
end

local function buildItemStatRows(owner, item, baseValuesOnly)
    local rows, config = {}, nil
    local function appendStat(k, v)
        rows[#rows + 1] = { k, v }
    end
    local function getPlayerBalance()
        if not config then
            local out = {}
            B.lib("/Game/Blueprints/PlayerConfigGetter.Default__PlayerConfigGetter_C")
                :GetPlayerConfig(owner, out)
            assert(B.valid(out.Config), "player balance unavailable")
            config = out.Config
        end
        return config
    end
    local name = item:GetFName():ToString()
    if healingFieldsByItem[name] then
        local hp = getPlayerBalance()[healingFieldsByItem[name]]
        local bonus
        if not baseValuesOnly then
            bonus = readHealingBonus(owner)
        end
        appendStat("Heals:", formatHealing(hp, bonus))
    elseif name == "Pizza_Upgrade" then
        appendStat("Healing bonus", formatSignedPercent(getPlayerBalance().Pizza_HealingEffectIncrease))
    elseif buffStatsByItem[name] then
        local buff = buffStatsByItem[name]
        appendStat(buff[1], formatSignedPercent(getPlayerBalance()[buff[2]]))
    elseif name == "MPCure" then
        appendStat("Magic Rot resistance", formatSignedPercent(getPlayerBalance().MagicRotResistAmount))
        appendStat("Duration", formatDuration(getPlayerBalance().MagicRotResistDuration))
    elseif name == "RadiantFruit" then
        appendStat("Light radius", formatSignedNumber(getPlayerBalance().RadiantFruitRadiusAdd / 100) .. " m")
    elseif item.Equippable and item.EquipSlot == 3 then
        local stats = B.lib("/Script/QueensDomain.Default__BlueprintUtils"):GetWeaponStats(item)
        if B.valid(stats) then
            local lib = B.lib("/Game/Player/PlayerStatsAndUtils.Default__PlayerStatsAndUtils_C")
            local scale = getPlayerBalance().BaseDamage
            for _, attackType in ipairs({ "Primary", "Secondary" }) do
                if baseValuesOnly then
                    appendStat(
                        attackType .. " Attack",
                        tostring(toDisplayedAttackPower(stats[attackType .. "AttackPower"], scale))
                    )
                else
                    local baseResult, levelResult, totalResult = {}, {}, {}
                    lib["GetWeapon" .. attackType .. "AttackPower"](
                        lib,
                        item,
                        owner,
                        baseResult,
                        levelResult,
                        totalResult
                    )
                    -- Both native getters return level multiplier minus one, not a power delta.
                    appendStat(
                        attackType .. " Attack",
                        ("%d (%s) = %d"):format(
                            toDisplayedAttackPower(baseResult.BasePower, scale),
                            formatSignedPercent(levelResult.IncreaseFromLevel),
                            toDisplayedAttackPower(totalResult.TotalPower, scale)
                        )
                    )
                end
            end
            appendStat("Stamina recovery (base)", formatDuration(stats.PowerMeterTime))
        end
    elseif item.Equippable and item.EquipSlot == 2 then
        local stats = B.lib("/Script/QueensDomain.Default__BlueprintUtils"):GetDaggerStats(item)
        if B.valid(stats) then
            appendStat(
                "Attack",
                tostring(toDisplayedAttackPower(stats.DamageMult, getPlayerBalance().BaseDamage))
            )
            appendStat("Return", formatDuration(stats.CooldownTime))
        end
    end
    local tags = {}
    item.DataTags:ForEach(function(k, v)
        local key, value = k:get():ToString(), v:get()
        if type(value) == "number" then
            tags[#tags + 1] = { key, value }
        end
    end)
    table.sort(tags, function(a, b)
        return a[1] < b[1]
    end)
    for _, tag in ipairs(tags) do
        local k, v = tag[1], tag[2]
        local spec = modifierFormats[k]
        if spec then
            appendStat(spec[1], spec[2](v))
        elseif k ~= "None" then
            local amount = (math.abs(v) > 0 and math.abs(v) < 1) and formatNumber(v * 100) .. "%"
                or formatNumber(v)
            appendStat((k:gsub("(%l)(%u)", "%1 %2")), amount)
        end
    end
    if curedEffectsByItem[name] then
        appendStat("Cures", curedEffectsByItem[name])
    end
    return rows
end

local function healingBonusText(owner)
    local bonus = readHealingBonus(owner)
    return bonus and formatNumber(bonus * 100) .. "%" or "Unavailable"
end
return {
    buildItemStatRows = buildItemStatRows,
    healingBonusText = healingBonusText,
    formatHealing = formatHealing,
}
