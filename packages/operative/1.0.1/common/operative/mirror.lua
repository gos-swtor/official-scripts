-- Operative priorities use canonical names; Core always receives the selected
-- combat style's exact client names and effect component identities.
local M = {}

local DISCIPLINES = {
    scoundrel = { Scrapper = "Concealment", Ruffian = "Lethality", Sawbones = "Medic" },
}

-- Source: build/generated/swtor/classes/{agent/operative,smuggler/scoundrel}.
local SCOUNDREL_ABILITIES = {
    ["Rifle Shot"] = "Flurry of Bolts",
    ["Shiv"] = "Blaster Whip",
    ["Veiled Strike"] = "Bludgeon",
    ["Overload Shot"] = "Quick Shot",
    ["Fragmentation Grenade"] = "Thermal Grenade",
    ["Corrosive Dart"] = "Vital Shot",
    ["Backstab"] = "Back Blast",
    ["Laceration"] = "Sucker Punch",
    ["Crippling Slice"] = "Shank Shot",
    ["Crippling Throw"] = "Crippling Shot",
    ["Volatile Substance"] = "Blood Boiler",
    ["Corrosive Grenade"] = "Shrap Bomb",
    ["Corrosive Assault"] = "Brutal Shots",
    ["Toxic Blast"] = "Sanguinary Shot",
    ["Lethal Strike"] = "Point Blank Shot",
    ["Toxic Haze"] = "Bushwhack",
    ["Noxious Knives"] = "Lacerating Blast",
    ["Stim Boost"] = "Pugnacity",
    ["Adrenaline Probe"] = "Cool Head",
    ["Shield Probe"] = "Defense Screen",
    ["Tactical Overdrive"] = "Hot Streak",
    ["Tactical Superiority"] = "Stack the Deck",
    ["Holotraverse"] = "Trick Move",
    ["Stealth"] = "Stealth",
    ["Cloaking Screen"] = "Disappearing Act",
    ["Infiltrate"] = "Smuggle",
    ["Flash Bang"] = "Flash Grenade",
    ["Debilitate"] = "Dirty Kick",
    ["Evasion"] = "Dodge",
    ["Sleep Dart"] = "Tranquilizer",
    ["Distraction"] = "Distraction",
    ["Toxin Scan"] = "Triage",
    ["Diagnostic Scan"] = "Diagnostic Scan",
    ["Kolto Injection"] = "Underworld Medicine",
    ["Kolto Infusion"] = "Kolto Pack",
    ["Kolto Probe"] = "Slow-release Medpac",
    ["Recuperative Nanotech"] = "Kolto Cloud",
    ["Surgical Probe"] = "Emergency Medpac",
    ["Kolto Waves"] = "Kolto Waves",
    ["Resuscitation Probe"] = "Heartrigger Patch",
    ["Tactical Advantage"] = "Upper Hand",
    ["Acid Blade"] = "Flechette Round",
    ["Calculated Frenzy"] = "Rolling Punches",
    ["Collateral Strike"] = "Flying Fists",
    ["Tactical Opportunity"] = "Round Two",
    ["Culling"] = "Turn the Tables",
    ["Shadow Operative Elite"] = "Slippery Devil",
    ["Fatality"] = "Unfair Advantage",
    ["Quickening"] = "Scurry",
    ["Lethal Purpose"] = "Fighting Spirit",
    ["Combat Stims"] = "Pugnacious",
    ["Roll Knife"] = "Rolling Fists",
    ["Relentless Blades"] = "Relentless Fists",
    ["Defensive Stance"] = "Defensive Stance",
    ["Curbing Strategies"] = "Curbing Strategies",
    ["Quick Countermeasures"] = "Strategic Surrender",
    ["Sly Countermeasures"] = "Sly Surrender",
    ["Clever Countermeasures"] = "Clever Surrender",
    ["The Best Defense"] = "The Best Defense",
    ["Crippling Wounds"] = "Setup Shot",
    ["Tactical Critical"] = "Upper Critical",
    ["Advanced Stealth"] = "Advanced Stealth",
    ["Corrosive Return"] = "Brutal Return",
    ["Penetrating Strategies"] = "Penetrating Strategies",
    ["Corrosive Impair"] = "Brutal Impair",
    ["Critical Grenade"] = "Critical Bomb",
    ["Corrosive Refund"] = "Explosive Refund",
    ["Corrosive Defense"] = "Shrap Defense",
    ["Tactical Stims"] = "Artful Cunning",
    ["Tactical Offense"] = "Leveraged Offense",
    ["Infiltrator"] = "Sneaky",
    ["Advanced Cloaking"] = "Flee the Scene",
    ["Med Shield"] = "Med Screen",
    ["Endorphin Rush"] = "Keep Cool",
    ["Evasive Imperative"] = "Scramble",
    ["Medical Engineering"] = "Medpac Mastery",
    ["Surgical Precision"] = "Emergent Emergencies",
    ["Curative Jolt"] = "Bootlegged Remedy",
    ["Incisive Action"] = "Exploratory Surgery",
    ["Patient Studies"] = "Patient Studies",
    ["Tox Screen"] = "Psych Meds",
    ["Stim Burst"] = "In the Zone",
    ["Tactical Effectiveness"] = "Healer's Edge",
    ["Kolto Burst"] = "Medical Burst",
    ["Kolto Stim"] = "Underworld Tactics",
    ["Reactive Substance"] = "Reactive Substance",
    ["Enduring Kolto"] = "Prolonged Prescription",
    ["Tactical Medicine"] = "Bedside Manner",
    ["Nanotech Stim"] = "Nutrient Rich Technologies",
    ["Nano Mark"] = "Kolto Mark",
    ["Critical Nanotech"] = "Critical Cloud",
    ["Accomplished Doctor"] = "Accomplished Sawbones",
    ["Medical Consult"] = "Healing Hand",
    ["Surprise Surgery"] = "Smuggled Med Delivery",
    ["Acidic Compounds"] = "Sharpened Materials",
    ["Corrosive Microbes"] = "Mortal Wound",
    ["Devouring Microbes"] = "Cold Blooded",
    ["Augmented Toxins"] = "Cut To The Quick",
    ["Lethal Proliferation"] = "Black Market Mods",
    ["Prey on the Weak"] = "Pierce And Batter",
    ["Waylay"] = "Sawed Off",
    ["Revealing Weakness"] = "Hot And Ready",
    ["Elite Education"] = "Element Of Surprise",
    ["Chem-resistant Inlays"] = "Scar Tissue",
    ["Evasive Screen"] = "Skedaddle",
    ["Jarring Strike"] = "K.O.",
    ["Blow for Blow"] = "Back at Ya",
}

local SCOUNDREL_EFFECTS = {
    ["Corrosive Dart"] = "Vital Shot",
    ["Corrosive Grenade"] = "Shrap Bomb",
    ["Poisoned (Acid Blade)"] = "Bleeding (Flechette Round)",
    ["Volatile Substance"] = "Blood Boiler",
    ["Revealing Weakness"] = "Hot and Ready",
    ["Crippling Wounds"] = "Crippling Wounds",
    ["Tactical Advantage"] = "Upper Hand",
    ["Stim Boost"] = "Pugnacity",
    ["Fatality"] = "Unfair Advantage",
    ["Quickening"] = "Scurry",
    ["Stealth"] = "Stealth",
    ["Active Stealth"] = "Active Stealth",
    ["Shield Probe"] = "Defense Screen",
    ["Kolto Probe"] = "Slow-release Medpac",
    ["Recuperative Nanotech"] = "Kolto Cloud",
    ["Reactive Substance"] = "Reactive Substance",
    ["Enduring Kolto"] = "Prolonged Prescription",
    ["Tactical Medicine"] = "Bedside Manner",
}
-- Critical Stims has no proven current-client counterpart component. Its
-- optional positioning-clear branch stays unavailable; do not guess a proc.

-- Talent pairings are additionally checked against the installed tal.* records
-- and https://swtorista.com/articles/scoundrel-mirror-abilities/.
-- Owned spell labels can be localized by the client; talent labels use
-- PrettyAbilityName's final FQN token (Ability.cpp/LuaHost.cpp).
local SCOUNDREL_KNOWN = {
    ["Rifle Shot"] = "Flurry Of Bolts Optimize",
    ["Tactical Superiority"] = "Stack The Deck",
    ["Kolto Probe"] = "Slow Release Medpac",
    ["Culling"] = "Turn The Tables",
    ["Advanced Cloaking"] = "Flee The Scene",
    ["The Best Defense"] = "Best Defense",
    ["Stim Burst"] = "In The Zone",
    ["Tactical Effectiveness"] = "Healers Edge",
    ["Nanotech Stim"] = "Nutrient Tech",
    ["Reactive Substance"] = "Defensive Medicine",
    ["Chem-resistant Inlays"] = "Scartissue",
    ["Jarring Strike"] = "Knockout",
    ["Blow for Blow"] = "Back At Ya",
}

-- Use the actual HoT/charge component even when Core has only a parent-derived
-- label; sibling heals, slows and shields must not satisfy these observations.
local SCOUNDREL_EFFECT_DEFINITIONS = {
    ["Corrosive Dart"] = "effectdef:6329492CC0B1E91E",
    ["Corrosive Grenade"] = "effectdef:056AB1A0C74FC4D1",
    ["Tactical Advantage"] = "effectdef:C4F8233EDD94EA8C",
    ["Stim Boost"] = "effectdef:3FBE9AE77F0BB7EC",
    ["Fatality"] = "effectdef:0BA54A1788308AC9",
    ["Quickening"] = "effectdef:B134660547CD21BE",
    ["Shield Probe"] = "effectdef:7B34B49CD19FF7DD",
    ["Kolto Probe"] = "effectdef:60EF152088C792A5",
    ["Recuperative Nanotech"] = "effectdef:D4CC496F1A5586A3",
    ["Reactive Substance"] = "effectdef:2B19F0BC5544D568",
    ["Active Stealth"] = "effectdef:BAEE0E2A4EFA3511",
    ["Crippling Wounds"] = "effectdef:0069E518B5D90E01",
    ["Enduring Kolto"] = "effectdef:B8B1F7388D47EC56",
    ["Tactical Medicine"] = "effectdef:7AFE2AEA6A53590B",
    ["Heal Sust 01"] = "effectdef:18AE4A87F9EC323F",
}

-- Exact matching components from docs/research/pvp_cleanse_effects_20260907.csv.
local SCOUNDREL_DEFINITIONS = {
    ["effectdef:C1434E7686FF7AF0"] = "effectdef:6329492CC0B1E91E", -- primary Vital Shot
    ["effectdef:69B5B6CAE4F828EA"] = "effectdef:056AB1A0C74FC4D1", -- primary Shrap Bomb
    ["effectdef:DB4E3C665EDF6BAF"] = "effectdef:C15FE23F05FE4FCC", -- Flechette bleed
    ["effectdef:BC848E032E53F3A6"] = "effectdef:5E72757A94E99DEB", -- unexploded Boiler
    ["effectdef:3435AE75B21468A0"] = "effectdef:F13B648D1CD996FF", -- Hot and Ready
    ["effectdef:3FBE51E189615C1F"] = "effectdef:B8B1F7388D47EC56", -- Prolonged Prescription
    ["effectdef:2C2FB11C3E3E360B"] = "effectdef:7AFE2AEA6A53590B", -- Bedside Manner
    ["effectdef:68FDE8E70BC1D422"] = "effectdef:F391B0CA046B3538", -- Bootlegged Remedy proc
    ["effectdef:6E36796A85C5C781"] = "effectdef:36ED7FCAC9E7A9BA", -- In the Zone
    ["effectdef:09B69CBB4A4A2B8C"] = "effectdef:8CF75CE01E17D77D", -- Hot Streak
    ["effectdef:6C19110FBB913720"] = "effectdef:18AE4A87F9EC323F", -- Underworld Medpac tactical
}

local REVERSE = {}
for canonical, actual in pairs(SCOUNDREL_ABILITIES) do REVERSE[actual] = canonical end
for canonical, actual in pairs(SCOUNDREL_EFFECTS) do
    if REVERSE[actual] == nil then REVERSE[actual] = canonical end
end
for canonical, actual in pairs(SCOUNDREL_KNOWN) do
    if REVERSE[actual] == nil then REVERSE[actual] = canonical end
end

local KNOWN_META = { __index = function(known, canonical)
    local actual, talent = SCOUNDREL_ABILITIES[canonical], SCOUNDREL_KNOWN[canonical]
    return actual ~= nil and known._raw[actual] == true or
        talent ~= nil and known._raw[talent] == true
end }

local function style(loadout)
    return type(loadout) == "table" and
        (loadout._operative_mirror_style or loadout.combat_style) or nil
end

function M.adapt_loadout(loadout)
    if type(loadout) ~= "table" or loadout._operative_mirror_style ~= nil then return loadout end
    if loadout.combat_style ~= "scoundrel" then return loadout end
    local disciplines = DISCIPLINES[loadout.combat_style]
    local discipline = disciplines and disciplines[loadout.discipline] or nil
    if not discipline then return loadout end
    local out = {}
    for key, value in pairs(loadout) do out[key] = value end
    out._operative_mirror_style = loadout.combat_style
    out._operative_mirror_raw = loadout
    out.combat_style, out.discipline = "operative", discipline
    if type(loadout.known) == "table" then
        out.known = setmetatable({ _raw = loadout.known, _style = style(loadout) }, KNOWN_META)
    end
    return out
end

function M.raw_loadout(loadout)
    return type(loadout) == "table" and loadout._operative_mirror_raw or loadout
end

function M.ability(loadout, canonical)
    if style(loadout) ~= "scoundrel" then return canonical end
    local actual, alias = SCOUNDREL_ABILITIES[canonical], SCOUNDREL_KNOWN[canonical]
    local raw = M.raw_loadout(loadout)
    local known = type(raw) == "table" and raw.known or nil
    -- Core can expose the FQN-derived title until the client supplies its label.
    -- Submit the exact learned identity; punctuation and Optimize are significant.
    if type(known) == "table" and alias and known[alias] == true and known[actual] ~= true then
        return alias
    end
    return actual
end

function M.canonical(loadout, actual)
    if style(loadout) ~= "scoundrel" then return actual end
    return REVERSE[actual]
end

function M.effect(loadout, canonical, filter)
    if style(loadout) ~= "scoundrel" then return canonical, filter end
    local key = SCOUNDREL_EFFECT_DEFINITIONS[canonical]
    if type(filter) == "table" and filter.definition_key ~= nil then
        key = SCOUNDREL_DEFINITIONS[filter.definition_key]
        if not key then return nil end
    end
    if key then
        local translated = {}
        for k, value in pairs(filter or {}) do translated[k] = value end
        translated.definition_key = key
        return "", translated
    end
    return SCOUNDREL_EFFECTS[canonical], filter
end

function M.info(loadout, canonical)
    local actual = M.ability(loadout, canonical)
    if actual then return gos.abilities.info(actual) end
end

function M.cooldown_remaining(loadout, canonical)
    local actual = M.ability(loadout, canonical)
    if actual then return gos.abilities.cooldown_remaining(actual) end
end

function M.is_ready(loadout, canonical)
    local actual = M.ability(loadout, canonical)
    return actual ~= nil and gos.abilities.is_ready(actual) == true
end

function M.can_cast(loadout, canonical, unit)
    local actual = M.ability(loadout, canonical)
    if actual then return gos.abilities.can_cast(actual, unit) end
end

function M.submit(executor, loadout, canonical, unit, options)
    local actual = M.ability(loadout, canonical)
    if not actual then return { accepted = false, reason = "mirror_name_unavailable" } end
    return executor:submit(actual, unit, options)
end

function M.settings(schema)
    local counterparts = { Concealment = "Scrapper", Lethality = "Ruffian", Medic = "Sawbones" }
    for _, field in ipairs(schema.fields) do
        if type(field.disciplines) == "table" then
            local disciplines = {}
            for _, name in ipairs(field.disciplines) do
                disciplines[#disciplines + 1] = name
                if counterparts[name] then disciplines[#disciplines + 1] = counterparts[name] end
            end
            field.disciplines = disciplines
        end
        -- Native settings accept one ability name. Runtime ownership still gates
        -- both factions; faction-specific names must not hide the mirror's field.
        if field.requires_ability and SCOUNDREL_ABILITIES[field.requires_ability] and
            SCOUNDREL_ABILITIES[field.requires_ability] ~= field.requires_ability then
            field.requires_ability = nil
        end
    end
    return schema
end

return M
