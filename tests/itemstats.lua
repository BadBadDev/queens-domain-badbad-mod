-- Checks item labels, units and stat calculations against representative game values.
local support = require("tests.support")
local test = support.new()
local B = test.api
local obj, ref = support.object, support.ref

local config = obj({ HealingHerb1HealAmount = 20, BerserkFruitDamageIncrease = 0.2, BaseDamage = 10 })
B.lib = function()
    return {
        GetPlayerConfig = function(_, _, out)
            out.Config = config
        end,
        GetWeaponStats = function()
            return obj({ PowerMeterTime = 0.75 })
        end,
        GetDaggerStats = function()
            return obj({ CooldownTime = 5, DamageMult = 0.7 })
        end,
        GetWeaponPrimaryAttackPower = function(_, _, _, b, p, t)
            b.BasePower = 1.5
            p.IncreaseFromLevel = 0.2
            t.TotalPower = 1.8
        end,
        GetWeaponSecondaryAttackPower = function(_, _, _, b, p, t)
            b.BasePower = 3
            p.IncreaseFromLevel = 0.2
            t.TotalPower = 3.6
        end,
    }
end
local stats = test.loadModule("itemstats")
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
