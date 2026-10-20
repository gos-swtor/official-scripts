-- Sage/Sorcerer display-name boundary.
--
-- Routes keep one canonical Sage priority model. This module translates only
-- at loadout, ability, effect, cast, and combat-event boundaries. Every
-- Sorcerer entry below has direct client/official pairing evidence; an absent
-- entry stays unavailable instead of falling back to a Sage name.

local M = {}

local DISCIPLINES = {
    sage = {
        Telekinetics = "Telekinetics",
        Balance = "Balance",
        Seer = "Seer",
    },
    sorcerer = {
        Lightning = "Telekinetics",
        Madness = "Balance",
        Corruption = "Seer",
    },
}

local SORCERER_ABILITIES = {
    ["Disturbance"] = "Lightning Strike",
    ["Telekinetic Burst"] = "Lightning Bolt",
    ["Project"] = "Shock",
    ["Telekinetic Throw"] = "Force Lightning",
    ["Weaken Mind"] = "Affliction",
    ["Mind Crush"] = "Crushing Darkness",
    ["Telekinetic Gust"] = "Lightning Flash",
    ["Turbulence"] = "Thundering Blast",
    ["Telekinetic Wave"] = "Chain Lightning",
    ["Power of the Force"] = "Halted Offensive ",
    ["Forcequake"] = "Force Storm",
    ["Forceful Retribution"] = "Eye of the Storm",
    ["Force in Balance"] = "Death Field",
    ["Shifted Balance"] = "Death Brand",
    ["Sever Force"] = "Creeping Terror",
    ["Vanquish"] = "Demolish",
    ["Force Serenity"] = "Force Leech",
    ["Destructive Wave"] = "Overloaded Strike",
    ["Telekinetic Blitz"] = "Volt Rush",
    ["Force Speed"] = "Force Speed",
    ["Benevolence"] = "Dark Heal",
    ["Deliverance"] = "Dark Infusion",
    ["Keeper of Peace"] = "Rally",
    ["Healing Trance"] = "Innervate",
    ["Rejuvenate"] = "Resurgence",
    ["Preserved Force Armor"] = "Static Barrier",
    ["Mending Force Armor"] = "Static Barrier",
    ["Force Armor"] = "Static Barrier",
    ["Force Mend"] = "Unnatural Preservation",
    ["Salvation"] = "Revivification",
    ["Wandering Mend"] = "Roaming Mend",
    ["Vindicate"] = "Consuming Darkness",
    ["Mend Wounds"] = "Purity",
    ["Restoration"] = "Expunge",
    ["Mental Alacrity"] = "Polarity Shift",
    ["Force Potency"] = "Recklessness",
    ["Force Barrier"] = "Force Barrier",
}

local SORCERER_KNOWN = {
    ["Tidal Force"] = "Lightning Storm",
    ["Clamoring Force"] = "Convection",
    ["Dormant Tremors"] = "Suppressive Current",
    ["Power of the Force"] = "Halted Offensive ",
    ["Magnifying Vibrations"] = "Convulsing Currents",
    ["Incoming Turbulence"] = "Thunder and Lightning",
    ["Mysteries of the Force"] = "Forbidden Knowledge",
    ["Mental Disparity"] = "Dark Embrace",
    ["Off Balance"] = "Off Balance",
    ["Presence of Mind"] = "Wrath",
    ["Force Suppression"] = "Deathmark",
    ["Abundant Justice"] = "Pestilence",
    ["Teachings of Rajivari"] = "Plague Master",
    ["Conveyance"] = "Force Bending",
    ["Resplendence"] = "Force Surge",
    ["Amnesty"] = "Reverse Corruptions",
    ["Altruism"] = "Dark Concentration",
    ["Force Shelter"] = "Reconstruct",
    ["Renewal"] = "Renewal",
    ["Soothing Protection"] = "Sustaining Darkness",
    ["Rejuvenating Aura"] = "Dark Resurgence",
    ["Resurging Power"] = "Corrupted Bastion",
    ["Potent Resolve"] = "Polarizing",
    ["Force Mobility"] = "Force Mobility",
    ["Telekinetic Regeneration"] = "Lightning Efficacy",
}

-- Exact unlocalized names exported by Core's PrettyAbilityName for these FQNs.
local SORCERER_PROTOTYPE_KNOWN = {
    ["Dormant Tremors"] = "Suppresive Current",
    ["Incoming Turbulence"] = "Thunder Lightning",
    ["Teachings of Rajivari"] = "Finish Them Madness",
    ["Potent Resolve"] = "Polarized",
    ["Mend Wounds"] = "Sith Purity",
    ["Force Mobility"] = "Force Mobility Healer",
    ["Power of the Force"] = "Halted Offensive",
}

local SORCERER_EFFECTS = {
    ["Tidal Force"] = "Lightning Storm",
    ["Tremors"] = "Suppressive Current",
    ["Dormant Tremors"] = "Suppressive Current",
    ["Clamoring Force"] = "Convection",
    ["Telekinetic Gust"] = "Force Flash",
    ["Mental Alacrity"] = "Polarity Shift",
    ["Reserved Light"] = "Reserved Darkness",
    ["Weaken Mind"] = "Affliction",
    ["Sever Force"] = "Creeping Terror",
    ["Presence of Mind"] = "Wrath",
    ["Crushed (Vanquish)"] = "Crushed (Demolish)",
    ["Mind Blast"] = "Crushed (Crushing Darkness)",
    ["Force Suppression"] = "Deathmark",
    ["Rejuvenate"] = "Resurgence",
    ["Wandering Mend"] = "Roaming Mend",
    ["Conveyance"] = "Force Bending",
    ["Resplendence"] = "Force Surge",
    ["Amnesty"] = "Reverse Corruptions",
    ["Altruism"] = "Dark Concentration",
    ["Force Shelter"] = "Reconstruct",
    ["Renewal"] = "Renewal",
    ["Soothing Protection"] = "Sustaining Darkness",
    ["Rejuvenating Aura"] = "Dark Resurgence",
    ["Resurging Power"] = "Corrupted Bastion",
    ["Potent Resolve"] = "Polarizing",
    ["Force Potency"] = "Recklessness",
    ["Weary"] = "Weary",
    ["Preserved Force Armor"] = "Static Barrier",
    ["Mending Force Armor"] = "Static Barrier",
    ["Force Armor"] = "Static Barrier",
    ["Static Barrier"] = "Static Barrier",
    ["Force-imbalanced"] = "Deionized",
    ["Deionized"] = "Deionized",
}

-- Exact components from the installed-client effect catalog. Parent-derived
-- names also describe slows, armor buffs and proc bookkeeping on these abilities.
local EFFECT_COMPONENTS = {
    ["Weaken Mind"] = { sage = "effectdef:F6BD202A3774E4E2", sorcerer = "effectdef:C5636220FF5FB2EB", kind = "debuff" },
    ["Sever Force"] = { sage = "effectdef:6A5A7C919131B525", sorcerer = "effectdef:CB35082B7FEC7D40", kind = "debuff" },
    ["Crushed (Vanquish)"] = { sage = "effectdef:136AA97EB9199B94", sorcerer = "effectdef:451BA2C39A0B1AA3", kind = "debuff" },
    ["Mind Blast"] = { sage = "effectdef:308746DA5F79CD6F", sorcerer = "effectdef:F5424BC50341AF19", kind = "debuff" },
    ["Presence of Mind"] = { sage = "effectdef:9DA08289EE847B3E", sorcerer = "effectdef:3A806A6D3A86611A", kind = "buff" },
    ["Tidal Force"] = { sage = "effectdef:92FE970F966C8425", sorcerer = "effectdef:2981D73AE1ED5F8F", kind = "buff" },
    ["Clamoring Force"] = { sage = "effectdef:7C22F9085FD52D6D", sorcerer = "effectdef:ED0BDEA3328B4DEF", kind = "buff" },
    ["Mental Alacrity"] = { sage = "effectdef:A88DC59A3FD16521", sorcerer = "effectdef:310E5DE77CE595CD", kind = "buff" },
    ["Reserved Light"] = { sage = "effectdef:8ECDF5D3431B2EC5", sorcerer = "effectdef:3D2A148AD833A3BF", kind = "buff" },
    ["Force Potency"] = { sage = "effectdef:794D058A8C9FAA14", sorcerer = "effectdef:10CB0432492EE9D0", kind = "buff" },
    ["Telekinetic Gust"] = { sage = "effectdef:BF1D7BBC24665B45", sorcerer = "effectdef:C43F66273450B4CD", kind = "buff" },
    ["Tremors"] = { sage = "effectdef:E3118D73EEE136C6", sorcerer = "effectdef:08C32FFA084439AB", kind = "debuff" },
    ["Rejuvenate"] = { sage = "effectdef:2D33F882AEFA90A3", sorcerer = "effectdef:EDA30ED338576D2D", kind = "buff" },
    ["Conveyance"] = { sage = "effectdef:C1E3F20FDD118834", sorcerer = "effectdef:70B776306A954F60", kind = "buff" },
    ["Resplendence"] = { sage = "effectdef:7A15144517622E29", sorcerer = "effectdef:7AA602F6743B3BA1", kind = "buff" },
    ["Amnesty"] = { sage = "effectdef:E6C375536A5A3DBA", sorcerer = "effectdef:23E727EB5AE47B80", kind = "buff" },
    ["Weary"] = { sage = "effectdef:6F0E47AFD40FE6C2", sorcerer = "effectdef:B37E65CB3969D3BF", kind = "debuff" },
    ["Altruism"] = { sage = "effectdef:45A379E0D7A66A38", sorcerer = "effectdef:A37E51F965BBB5EE", kind = "buff" },
    ["Resurging Power"] = { sage = "effectdef:F98E0F76DAB2BC82", sorcerer = "effectdef:A6DE17FAD28B1B9E", kind = "buff" },
    ["Wandering Mend"] = { sage = "effectdef:56887BA6C36CFACF", sorcerer = "effectdef:4A51BB051BB85918", kind = "buff" },
}

local function reverse(source)
    local out = {}
    for canonical, actual in pairs(source) do
        if out[actual] == nil then out[actual] = canonical end
    end
    return out
end

local SORCERER_REVERSE = reverse(SORCERER_ABILITIES)
for actual, canonical in pairs(reverse(SORCERER_EFFECTS)) do
    if SORCERER_REVERSE[actual] == nil then
        SORCERER_REVERSE[actual] = canonical
    end
end

local KNOWN_META = { __index = function(known, name)
    local raw = known._raw
    if name == "Destructive Wave" and known._discipline == "Telekinetics" then
        return nil
    end
    if name == "Forceful Retribution" and known._discipline == "Telekinetics" and
        raw["Overloaded Strike"] == true then return true end
    if raw[name] ~= nil then return raw[name] end
    local ability = SORCERER_ABILITIES[name]
    local passive = SORCERER_KNOWN[name]
    local prototype = SORCERER_PROTOTYPE_KNOWN[name]
    if ability and raw[ability] == true or passive and raw[passive] == true or
        prototype and raw[prototype] == true then return true end
end }

local function profile(loadout)
    if type(loadout) ~= "table" then return nil end
    local style = loadout._sage_mirror_style or loadout.combat_style
    local disciplines = DISCIPLINES[style]
    local canonical = disciplines and disciplines[loadout._sage_mirror_discipline or
        loadout.discipline] or nil
    if canonical == nil and loadout._sage_mirror_canonical_discipline then
        canonical = loadout._sage_mirror_canonical_discipline
    end
    if canonical == nil then return nil end
    return style, canonical
end

function M.adapt_loadout(loadout)
    if type(loadout) ~= "table" then return loadout end
    if loadout._sage_mirror_style ~= nil then return loadout end
    local style = loadout.combat_style
    local canonical = DISCIPLINES[style] and
        DISCIPLINES[style][loadout.discipline] or nil
    if canonical == nil then return loadout end
    if style == "sage" then return loadout end
    local out = {}
    for key, value in pairs(loadout) do out[key] = value end
    out._sage_mirror_style = style
    out._sage_mirror_discipline = loadout.discipline
    out._sage_mirror_canonical_discipline = canonical
    out.combat_style = "sage"
    out.discipline = canonical

    if type(loadout.known) == "table" then
        out.known = setmetatable({ _raw = loadout.known, _discipline = canonical, _style = style }, KNOWN_META)
    end
    return out
end

function M.is_sorcerer(loadout)
    local style = profile(loadout)
    return style == "sorcerer"
end

function M.ability(loadout, canonical)
    local style, discipline = profile(loadout)
    if style == nil or style == "sage" then return canonical end
    if style ~= "sorcerer" then return nil end
    -- These two current Lightning actions have different FQN-derived and
    -- localized labels. Submit the learned label actually exported by Core.
    local known = type(loadout.known) == "table" and loadout.known or nil
    known = known and (known._raw or known)
    if discipline == "Telekinetics" and known then
        if canonical == "Forceful Retribution" and known["Eye of the Storm"] ~= true and
            known["Overloaded Strike"] == true then return "Overloaded Strike" end
        if canonical == "Power of the Force" and known["Halted Offensive "] ~= true and
            known["Halted Offensive"] == true then return "Halted Offensive" end
    end
    return SORCERER_ABILITIES[canonical]
end

function M.effect(loadout, canonical)
    local style = profile(loadout)
    if style == nil or style == "sage" then return canonical end
    if style ~= "sorcerer" then return nil end
    return SORCERER_EFFECTS[canonical]
end

function M.effect_query(loadout, canonical, options)
    local style = profile(loadout)
    if style ~= "sorcerer" then return canonical, options end
    local component = EFFECT_COMPONENTS[canonical]
    if component and component[style] then
        if type(options) == "table" and options.kind ~= nil and options.kind ~= component.kind then
            return nil, options
        end
        local query = {}
        for key, value in pairs(options or {}) do query[key] = value end
        query.kind, query.definition_key = component.kind, component[style]
        return "", query
    end
    return M.effect(loadout, canonical), options
end

function M.canonical(loadout, actual)
    local style, discipline = profile(loadout)
    if style ~= "sorcerer" then return actual end
    if actual == "Static Barrier" then
        return discipline == "Seer" and "Preserved Force Armor" or "Mending Force Armor"
    end
    if actual == "Overloaded Strike" and discipline == "Telekinetics" then
        return "Forceful Retribution"
    end
    if actual == "Halted Offensive" then return "Power of the Force" end
    return SORCERER_REVERSE[actual]
end

function M.discipline(loadout)
    local _, canonical = profile(loadout)
    return canonical
end

return M
