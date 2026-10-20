-- Shared progressive Operative DPS route engine.
-- Capability-driven through level 80: gos.abilities.loadout().known is SSOT.
-- Spec wrappers provide discipline-specific priorities and tree choice names.

local Mirror = require("operative.mirror")
local CurrentLoadout
local M = {}

local READY_SLACK = 0.04
local FAILURE_BACKOFF = 0.40
local CONTENTION_BACKOFF = 0.12
local ACCEPTED_UNCONFIRMED_BACKOFF = 0.75
local METERS_PER_WORLD_UNIT = 10.0
local DOT_OBSERVATION_GRACE = 1.50
local VOLATILE_OBSERVATION_GRACE = 3.25
local TA_OBSERVATION_GRACE = 2.00
local TACTICAL_OPPORTUNITY_PREDICTION_GRACE = 0.75
local DOT_EFFECT = "Corrosive Dart"
local ACID_BLADE_EFFECT = "Poisoned (Acid Blade)"
local GRENADE_EFFECT = "Corrosive Grenade"
local FATALITY_EFFECT = "Fatality"
local VOLATILE_EFFECT = "Volatile Substance"
local CRIPPLING_WOUNDS_EFFECT = "Crippling Wounds"
local TACTICAL_ADVANTAGE_EFFECT = "Tactical Advantage"
local STIM_BOOST_EFFECT = "Stim Boost"
local STEALTH_EFFECT = "Stealth"
local ACTIVE_STEALTH_EFFECT = "Active Stealth"
local TOXIC_HAZE_RADIUS_METERS = 8.0
local NOXIOUS_KNIVES_RANGE_METERS = 10.0
local NOXIOUS_KNIVES_CONE_ANGLE_DEGREES = 45.0
local ACTIVE_STEALTH_DURATION_SECONDS = 6.0
local ACTIVE_STEALTH_OBSERVATION_SETTLE_SECONDS = 0.75
local CONCEALMENT_MIN_SETUP_LIFETIME_SECONDS = 6.0
local DOT_FILTER = { kind = "debuff", timed = true }
-- Exact current-client components from docs/research/pvp_cleanse_effects_20260907.csv.
-- Parent-derived display names collapse Substance, Assailable and Revealing
-- Weakness together. Query by component identity, not a parent display name.
-- Never substitute another component or a guessed duration when this is absent.
local CONCEALMENT_EFFECT_FILTERS = {
    [DOT_EFFECT] = { kind = "debuff", timed = true,
        definition_key = "effectdef:C1434E7686FF7AF0" }, -- corrosive_dart/29/2
    [ACID_BLADE_EFFECT] = { kind = "debuff", timed = true,
        definition_key = "effectdef:DB4E3C665EDF6BAF" }, -- acid_blade/31/2: poison
    [VOLATILE_EFFECT] = { kind = "debuff", timed = true,
        definition_key = "effectdef:BC848E032E53F3A6" }, -- volatile_substance/26/1: unexploded
    ["Revealing Weakness"] = { kind = "debuff", timed = true,
        definition_key = "effectdef:3435AE75B21468A0" }, -- volatile_substance/26/3
}
local BUFF_FILTER = { kind = "buff" }
local TIMED_BUFF_FILTER = { kind = "buff", timed = true }

local function clamp(value, minimum, maximum)
    if type(value) ~= "number" then return minimum end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function safe_method(unit, name, ...)
    if not unit or type(unit[name]) ~= "function" then return nil end
    local ok, a, b = pcall(unit[name], unit, ...)
    if not ok then return nil end
    return a, b
end

local function bool_text(value)
    return value and "on" or "off"
end
local function optional_number(value, format)
    if type(value) ~= "number" then return "nil" end
    return type(format) == "string" and string.format(format, value) or tostring(value)
end

local function loadout_has(loadout, name)
    return type(loadout) == "table" and type(loadout.known) == "table" and
        type(name) == "string" and loadout.known[name] == true
end

local function selected_choice(loadout, names)
    for _, name in ipairs(names or {}) do
        if loadout_has(loadout, name) then return name end
    end
    return nil
end

local function unit_hp(unit)
    local hp = safe_method(unit, "hp")
    if type(hp) ~= "table" then return nil end
    local current = type(hp.current) == "number" and hp.current or nil
    local maximum = type(hp.max) == "number" and hp.max or nil
    local percent = type(hp.percent) == "number" and hp.percent or nil
    if percent == nil and current and maximum and maximum > 0 then
        percent = current / maximum * 100.0
    end
    return { current = current, max = maximum, percent = percent }
end
local function unit_resource(unit)
    local resource = safe_method(unit, "resource")
    if type(resource) ~= "table" then return nil end
    local current = type(resource.current) == "number" and resource.current or nil
    local maximum = type(resource.max) == "number" and resource.max or nil
    local percent = type(resource.percent) == "number" and resource.percent or nil
    if percent == nil and current and maximum and maximum > 0 then
        percent = current / maximum * 100.0
    end
    return { current = current, max = maximum, percent = percent, kind = resource.kind }
end

local function unit_distance(unit)
    local value = safe_method(unit, "distance")
    return type(value) == "number" and value == value and math.abs(value) < math.huge and
        value >= 0 and value * METERS_PER_WORLD_UNIT or nil
end

local function unit_position(unit)
    local value = safe_method(unit, "position")
    if type(value) ~= "table" or type(value.x) ~= "number" or
        type(value.y) ~= "number" or type(value.z) ~= "number" then
        return nil
    end
    return value
end

local function position_distance(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz) * METERS_PER_WORLD_UNIT
end

local function unit_rotation(unit)
    local value = safe_method(unit, "rotation")
    return type(value) == "number" and value or nil
end

local function position_in_forward_cone(origin, rotation, position, range_meters,
        angle_degrees)
    if not origin or type(rotation) ~= "number" or not position then return false end
    local dx, dz = position.x - origin.x, position.z - origin.z
    local planar_world_units = math.sqrt(dx * dx + dz * dz)
    if planar_world_units <= 0.000001 then return true end
    if planar_world_units * METERS_PER_WORLD_UNIT > range_meters then return false end
    local forward_x, forward_z = math.sin(rotation), -math.cos(rotation)
    local dot = (dx * forward_x + dz * forward_z) / planar_world_units
    return dot >= math.cos(math.rad(angle_degrees * 0.5))
end

local function unit_toughness(unit)
    local label, value = safe_method(unit, "toughness")
    if type(label) ~= "string" and type(value) ~= "number" then return nil end
    return { label = label, value = value }
end

local function unit_effect(unit, name, options)
    local actual, filter = Mirror.effect(CurrentLoadout, name, options)
    if actual == nil then return nil end
    local value = safe_method(unit, "effect", actual, filter)
    return type(value) == "table" and value or nil
end

local function toughness_is_durable(toughness)
    if type(toughness) ~= "table" then return false end
    if type(toughness.value) == "number" and
        ((toughness.value >= 4 and toughness.value <= 6) or
            (toughness.value >= 9 and toughness.value <= 14)) then
        return true
    end
    local label = type(toughness.label) == "string" and
        string.lower(toughness.label) or ""
    return label:find("strong", 1, true) ~= nil or
        label:find("elite", 1, true) ~= nil or
        label:find("champion", 1, true) ~= nil or
        label:find("boss", 1, true) ~= nil or
        label:find("conqueror", 1, true) ~= nil
end

local function toughness_is_major_threat(toughness)
    if type(toughness) ~= "table" then return false end
    -- Current SWTOR rank values: 6 = Raid Boss; 9-14 = Champion through
    -- Legendary Conqueror. Strong (4) and Elite (5) stay excluded.
    if type(toughness.value) == "number" and
        (toughness.value == 6 or (toughness.value >= 9 and toughness.value <= 14)) then
        return true
    end
    local label = type(toughness.label) == "string" and
        string.lower(toughness.label) or ""
    return label:find("champion", 1, true) ~= nil or
        label:find("boss", 1, true) ~= nil or
        label:find("conqueror", 1, true) ~= nil
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Strict gameplay evidence. No guessed duration, charge, owner or proc is created.
-- In particular, command submission/activation is not proof that a poison landed.
local function observed_effect(now, raw, own, after_activation)
    local status = type(raw) == "table" and raw.status or "unavailable"
    if status ~= "ready" or (raw.truncated == true and raw.present ~= true) then
        return { status = status == "ready" and "truncated" or status,
            present = false, mine = false, source = "observation_unavailable" }
    end
    if after_activation and finite(raw.age_ms) and
        now - raw.age_ms / 1000.0 <= after_activation then
        return { status = "pending", present = false, mine = false,
            source = "pre_activation_sample" }
    end
    if own and raw.present == true and raw.mine ~= true and raw.has_ownership ~= true then
        return { status = "unavailable", present = false, mine = false,
            source = "ownership_unavailable" }
    end
    local remaining = finite(raw.remaining) and raw.remaining >= 0 and raw.remaining or nil
    local present = raw.present == true and (remaining == nil or remaining > 0)
    local stacks = raw.charge_conflicted ~= true and raw.has_charges ~= false and
        finite(raw.stacks) and raw.stacks >= 0 and math.floor(raw.stacks) or nil
    return { status = "ready", present = present, mine = raw.mine == true,
        remaining = remaining, stacks = stacks,
        source = present and "effect" or "effect_absent" }
end

local BREAKABLE_CONTROL = {
    -- Mezzes/incapacitates only. Hard stuns deliberately remain attackable.
    ["sleep dart"] = true, ["tranquilizer"] = true,
    ["flash bang"] = true, ["flash grenade"] = true,
    ["whirlwind"] = true, ["force lift"] = true,
    ["mind maze"] = true, ["mind trap"] = true,
    ["slice droid"] = true, ["low slash"] = true,
    ["concussion missile"] = true,
    ["concussion round"] = true, ["concussive round"] = true,
    ["awe"] = true, ["intimidating roar"] = true,
    ["backlash"] = true, ["kinetic collapse"] = true,
    ["asleep"] = true, ["sleeping"] = true, ["incapacitated"] = true,
}
local function breakable_control(unit)
    local effects = safe_method(unit, "effects", DOT_FILTER)
    if type(effects) ~= "table" or effects.status ~= "ready" then return false, false end
    local items = type(effects.items) == "table" and effects.items or {}
    for i = 1, math.min(64, #items) do
        local effect = type(items[i]) == "table" and items[i] or {}
        local name = type(effect.name) == "string" and effect.name:lower() or ""
        -- Core can append an effect category such as " (Tech)" to the visible label.
        name = name:gsub(" %([^)]*%)$", "")
        if BREAKABLE_CONTROL[name] and (not finite(effect.remaining) or effect.remaining > 0) then
            return true, true
        end
    end
    return false, effects.truncated ~= true
end

function M.new(executor, spec)
    assert(type(executor) == "table", "operative route requires executor")
    assert(type(spec) == "table", "operative route requires spec config")
    assert(type(spec.discipline) == "string", "operative route discipline required")
    assert(type(spec.owner) == "string", "operative route owner required")
    local is_lethality = spec.discipline == "Lethality"
    local owner_prefix = spec.owner .. ":"
    local grenade_ttl = type(spec.grenadeDuration) == "number" and spec.grenadeDuration or 24.0
    local Ability = {
        RifleShot = { id = "Rifle Shot", range = 30.0, fallbackCost = 0.0 },
        Shiv = { id = "Shiv", range = 4.0, fallbackCost = 15.0 },
        VeiledStrike = { id = "Veiled Strike", range = 4.0, fallbackCost = 15.0 },
        OverloadShot = { id = "Overload Shot", range = 10.0, fallbackCost = 15.0 },
        FragmentationGrenade = {
            id = "Fragmentation Grenade", range = 30.0, fallbackCost = 20.0,
            aoeRadius = 5.0, maxTargets = 7,
        },
        CorrosiveDart = { id = "Corrosive Dart", range = 30.0, fallbackCost = 15.0 },
        Backstab = {
            id = "Backstab", range = 4.0, fallbackCost = 15.0,
            requiresOpenReady = true,
        },
        StimBoost = {
            id = "Stim Boost", targetless = true, offGcd = true, fallbackCost = 0.0,
        },
        AdrenalineProbe = {
            id = "Adrenaline Probe", targetless = true, offGcd = true, fallbackCost = 0.0,
        },
        ShieldProbe = {
            id = "Shield Probe", targetless = true, offGcd = true, fallbackCost = 0.0,
        },
        NoxiousKnives = {
            id = "Noxious Knives", targetless = true,
            fallbackCost = 15.0,
        },
        CripplingSlice = { id = "Crippling Slice", range = 4.0, fallbackCost = 0.0 },
        CripplingThrow = { id = "Crippling Throw", range = 10.0, fallbackCost = 0.0 },
        VolatileSubstance = {
            id = "Volatile Substance", range = 10.0, fallbackCost = 15.0,
        },
        CorrosiveGrenade = {
            id = "Corrosive Grenade", range = 30.0, fallbackCost = 10.0,
            aoeRadius = 5.0, maxTargets = 8,
        },
        ToxicHaze = {
            id = "Toxic Haze", targetless = true,
            fallbackCost = 15.0, requiresTacticalAdvantage = true,
        },
        ToxicBlast = { id = "Toxic Blast", range = 10.0, fallbackCost = 10.0 },
        TacticalOverdrive = {
            id = "Tactical Overdrive", targetless = true, offGcd = true,
            fallbackCost = 0.0,
        },
        Spender = {
            id = spec.spender, range = spec.spenderRange or 4.0,
            fallbackCost = spec.discipline == "Concealment" and 10.0 or 20.0,
            requiresTacticalAdvantage = true,
        },
    }
    local AbilityList = {
        Ability.RifleShot, Ability.Shiv, Ability.VeiledStrike, Ability.OverloadShot,
        Ability.FragmentationGrenade, Ability.CorrosiveDart, Ability.Backstab,
        Ability.StimBoost, Ability.AdrenalineProbe, Ability.NoxiousKnives,
        Ability.CripplingSlice, Ability.CripplingThrow, Ability.VolatileSubstance,
        Ability.CorrosiveGrenade, Ability.ToxicHaze, Ability.ToxicBlast,
        Ability.TacticalOverdrive, Ability.ShieldProbe, Ability.Spender,
    }

    local Runtime = {
        nativeAdmission = nil,
        pending = nil,
        cripplingVolatileTarget = nil,
        cripplingVolatileFiller = false,
        woundsConsumedTarget = nil,
        woundsConsumedAt = nil,
        taActivationAt = -math.huge,
        backstabActivationAt = -math.huge,
        fatalityActivationAt = -math.huge,
        lifetimeSamples = {},
        lifetimeTarget = nil,
        failureBackoff = {},
        contentionUntil = 0.0,
        dotAttemptTarget = nil,
        dotAttemptUntil = 0.0,
        dotKnownUntil = {},
        grenadeAttemptTarget = nil,
        grenadeAttemptUntil = 0.0,
        grenadeKnownUntil = {},
        grenadeGraceUntil = {},
        volatileAttemptTarget = nil,
        volatileAttemptUntil = 0.0,
        volatileGraceUntil = {},
        fatalityEvidenceUntil = 0.0,
        fatalityConsumedUntil = 0.0,
        fatalityReadyAt = 0.0,
        taEvidenceCount = 0,
        taEvidenceUntil = 0.0,
        corrosiveReturnReadyAt = 0.0,
        stimAttemptUntil = 0.0,
        probeAttemptUntil = 0.0,
        tacticalOverdriveAttemptUntil = 0.0,
        tacticalOpportunityReadyAt = 0.0,
        stealthConsumedUntil = 0.0,
        stealthAwaitingAbsent = false,
        stealthEventGap = false,
        stealthLatched = false,
        activeStealthArmedAt = -math.huge,
        activeStealthEvidenceUntil = 0.0,
        activeStealthConsumedUntil = 0.0,
        lastDecision = nil,
        lastProgression = nil,
        lastDiagnosticAt = -math.huge,
    }
    local function emit(options, level, message)
        local logger = type(options) == "table" and options.logLine or nil
        if type(logger) ~= "function" then return end
        if level == "warn" or message:find("timing retry:", 1, true) or
            message:find("submitted without activation proof:", 1, true) then
            Runtime.logTimes = Runtime.logTimes or {}
            local key = level .. ":" .. (message:match("reason=([^ ]+)") or message)
            local now = (gos.time_ms() or 0) / 1000.0
            if now - (Runtime.logTimes[key] or -math.huge) < 1.0 then return end
            Runtime.logTimes[key] = now
        end
        logger(level, message)
    end

    local function is_selected(loadout)
        loadout = Mirror.adapt_loadout(loadout)
        return type(loadout) == "table" and loadout.status == "ready" and
            loadout.combat_style == "operative" and
            loadout.discipline == spec.discipline and
            type(loadout.known) == "table"
    end

    local function owns_pending()
        if not executor:owns_command() then return false end
        local status = executor:status()
        local key = type(status) == "table" and status.idempotency_key or nil
        return type(key) == "string" and key:sub(1, #owner_prefix) == owner_prefix
    end

    local function progression(loadout)
        return {
            level23 = selected_choice(loadout, spec.level23Choices),
            level27 = selected_choice(loadout, spec.level27Choices),
            level39 = selected_choice(loadout, spec.level39Choices),
            level43 = selected_choice(loadout, spec.level43Choices),
            level51 = selected_choice(loadout, spec.level51Choices),
            level64 = selected_choice(loadout, spec.level64Choices),
            level68 = selected_choice(loadout, spec.level68Choices),
            level73 = selected_choice(loadout, spec.level73Choices),
            acidBlade = loadout_has(loadout, "Acid Blade"),
            preyOnTheWeak = loadout_has(loadout, "Prey on the Weak"),
            revealingWeakness = loadout_has(loadout, "Revealing Weakness"),
            calculatedFrenzy = loadout_has(loadout, "Calculated Frenzy"),
            tacticalOpportunity = loadout_has(loadout, "Tactical Opportunity"),
            culling = loadout_has(loadout, "Culling"),
            eliteEducation = loadout_has(loadout, "Elite Education"),
            fatality = loadout_has(loadout, "Fatality"),
            lethalProliferation = loadout_has(loadout, "Lethal Proliferation"),
        }
    end

    local function fallback_cost(loadout, ability)
        if ability == Ability.Backstab and loadout_has(loadout, "Waylay") then
            return 10.0
        end
        if ability == Ability.Spender then
            if spec.discipline == "Concealment" and
                loadout_has(loadout, "Relentless Blades") then
                return 0.0
            end
        end
        return ability.fallbackCost
    end

    local function ability_snapshot(loadout)
        local result = {}
        for _, ability in ipairs(AbilityList) do
            local known = loadout_has(loadout, ability.id)
            local info = known and Mirror.info(CurrentLoadout, ability.id) or nil
            local cooldown = known and Mirror.cooldown_remaining(CurrentLoadout, ability.id) or nil
            local runtime_cost = type(info) == "table" and
                info.has_resource_cost == true and
                type(info.resource_cost) == "number" and info.resource_cost or nil
            result[ability.id] = {
                known = known,
                abilityHandle = type(info) == "table" and info.ability_handle or nil,
                resolved = type(info) == "table" and info.ability_handle ~= nil or false,
                bound = type(info) == "table" and info.on_bar == true or false,
                ready = known and Mirror.is_ready(CurrentLoadout, ability.id) == true,
                cooldownKnown = type(cooldown) == "number",
                cooldown = type(cooldown) == "number" and math.max(0, cooldown) or nil,
                gcdDuration = type(info) == "table" and info.gcd_duration or nil,
                cost = runtime_cost ~= nil and runtime_cost or fallback_cost(loadout, ability),
                costSource = runtime_cost ~= nil and "runtime" or
                    (fallback_cost(loadout, ability) ~= nil and "verified_fallback" or "unavailable"),
            }
        end
        return result
    end

    local function current_cast()
        local cast = gos.abilities.current_cast()
        if type(cast) ~= "table" then return nil end
        return {
            name = Mirror.canonical(CurrentLoadout, cast.name),
            remaining = cast.has_timing == true and
                type(cast.remaining) == "number" and math.max(0, cast.remaining) or nil,
        }
    end

    local function target_is_durable(state)
        if state.targetType == "player" then return true end
        if type(state.targetToughness) == "table" then
            -- A successfully observed Standard/Weak rank is authoritative. The HP
            -- heuristic exists only for missing rank metadata; otherwise ordinary
            -- scaled trash can be misclassified merely for having more HP than us.
            return toughness_is_durable(state.targetToughness)
        end
        return type(state.targetHp) == "number" and
            type(state.playerHpMax) == "number" and state.playerHpMax > 0 and
            state.targetHp >= state.playerHpMax
    end

    local function target_is_stim_worthy(state)
        -- Do not spend long offensive cooldowns on a target already in cleanup
        -- range. Unknown HP remains eligible rather than fabricating a health gate.
        if state.targetType == "player" then
            return type(state.targetHpPercent) ~= "number" or
                state.targetHpPercent >= 25.0
        end
        if not toughness_is_major_threat(state.targetToughness) then return false end
        return type(state.targetHpPercent) ~= "number" or
            state.targetHpPercent >= 10.0
    end

    local function sync_dot_evidence(now, target_handle, observed)
        local status = observed and observed.status or nil
        if target_handle == nil then
            return { status = status, present = false, mine = false, remaining = nil,
                source = "missing_target" }
        end
        local known_until = Runtime.dotKnownUntil[target_handle]
        if status == "ready" then
            if observed.present == true and observed.mine == true then
                local remaining = type(observed.remaining) == "number" and
                    math.max(0, observed.remaining) or nil
                Runtime.dotKnownUntil[target_handle] = remaining and
                    (now + remaining) or nil
                return { status = status, present = true, mine = true,
                    remaining = remaining,
                    source = remaining and "effect" or "effect_timer_unavailable" }
            end
            Runtime.dotKnownUntil[target_handle] = nil
            return { status = status, present = false, mine = false,
                remaining = 0.0, source = "effect_absent" }
        end
        if type(known_until) == "number" and known_until > now then
            return { status = status, present = true, mine = true,
                remaining = known_until - now, source = "accepted_fallback" }
        end
        return { status = status, present = false, mine = false,
            remaining = nil, source = status or "unavailable" }
    end

    local function sync_grenade_evidence(now, target_handle, observed)
        local status = observed and observed.status or nil
        if target_handle == nil then
            return { status = status, present = false, mine = false, remaining = nil,
                source = "missing_target" }
        end
        local known_until = Runtime.grenadeKnownUntil[target_handle]
        local grace_until = Runtime.grenadeGraceUntil[target_handle] or 0.0
        if status == "ready" then
            if observed.present == true and observed.mine == true then
                local remaining = type(observed.remaining) == "number" and
                    math.max(0, observed.remaining) or grenade_ttl
                Runtime.grenadeKnownUntil[target_handle] = now + remaining
                Runtime.grenadeGraceUntil[target_handle] = nil
                return { status = status, present = true, mine = true,
                    remaining = remaining, source = "effect" }
            end
            if type(known_until) == "number" and known_until > now and grace_until > now then
                return { status = status, present = true, mine = true,
                    remaining = known_until - now, source = "accepted_grace" }
            end
            Runtime.grenadeKnownUntil[target_handle] = nil
            Runtime.grenadeGraceUntil[target_handle] = nil
            return { status = status, present = false, mine = false,
                remaining = 0.0, source = "effect_absent" }
        end
        if type(known_until) == "number" and known_until > now then
            return { status = status, present = true, mine = true,
                remaining = known_until - now, source = "accepted_fallback" }
        end
        return { status = status, present = false, mine = false,
            remaining = nil, source = status or "unavailable" }
    end

    local function sync_volatile_evidence(now, target_handle, observed)
        local status = observed and observed.status or nil
        if target_handle == nil then
            return { status = status, present = false, mine = false,
                source = "missing_target" }
        end
        local grace_until = Runtime.volatileGraceUntil[target_handle] or 0.0
        if status == "ready" then
            if observed.present == true and observed.mine == true then
                Runtime.volatileGraceUntil[target_handle] = nil
                return { status = status, present = true, mine = true,
                    source = "effect" }
            end
            if grace_until > now then
                return { status = status, present = true, mine = true,
                    source = "accepted_grace" }
            end
            Runtime.volatileGraceUntil[target_handle] = nil
            return { status = status, present = false, mine = false,
                source = "effect_absent" }
        end
        if grace_until > now then
            return { status = status, present = true, mine = true,
                source = "accepted_fallback" }
        end
        return { status = status, present = false, mine = false,
            source = status or "unavailable" }
    end
    local function sync_fatality_evidence(now, observed)
        local status = observed and observed.status or nil
        if now < Runtime.fatalityConsumedUntil then
            Runtime.fatalityEvidenceUntil = 0.0
            return { status = status, present = false, source = "spender_consumed" }
        end
        if status == "ready" and observed.present == true then
            Runtime.fatalityEvidenceUntil = now + TA_OBSERVATION_GRACE
            return { status = status, present = true, source = "effect" }
        end
        if Runtime.fatalityEvidenceUntil > now then
            return { status = status, present = true,
                source = status == "ready" and "accepted_grace" or "accepted_fallback" }
        end
        Runtime.fatalityEvidenceUntil = 0.0
        return { status = status, present = false,
            source = status == "ready" and "effect_absent" or (status or "unavailable") }
    end

    local function sync_ta_evidence(now, observed)
        -- Fresh effects supply charges. Activation never adds to a post-activation
        -- sample, and ready+absent never becomes a two-second imaginary stack.
        local row = observed_effect(now, observed, false, Runtime.taActivationAt)
        if row.status == "ready" then
            Runtime.taEvidenceCount = row.present and row.stacks or 0
            Runtime.taEvidenceUntil = 0.0
            return row
        end
        return {status=row.status, present=false, stacks=nil,
            source="tactical_advantage_observation_gap"}
    end

    local function sync_stealth_evidence(now, observed)
        local status = type(observed) == "table" and observed.status or "unavailable"
        local sample = type(observed) == "table" and finite(observed.age_ms) and
            now - observed.age_ms / 1000.0 or now
        if status == "ready" and observed.truncated == true and
            observed.present ~= true then status = "unavailable" end
        if sample <= (Runtime.stealthEvidenceAt or -math.huge) then
            status = "pending"
        end
        if now < Runtime.stealthConsumedUntil then
            if status == "ready" and observed.present ~= true then
                Runtime.stealthAwaitingAbsent = false
            elseif status == "ready" and observed.present == true and
                Runtime.stealthAwaitingAbsent ~= true then
                Runtime.stealthConsumedUntil = 0.0
                Runtime.stealthLastKnown = true
                Runtime.stealthLatched = true
                return {status=status, present=true, source="new_stealth_after_opener"}
            end
            Runtime.stealthLastKnown = false
            Runtime.stealthLatched = false
            return {status=status, present=false, source="opener_consumed"}
        end
        if status == "ready" then
            Runtime.stealthEventGap = false
            Runtime.stealthLastKnown = observed.present == true
            Runtime.stealthLatched = Runtime.stealthLastKnown
            Runtime.stealthEvidenceAt = sample
            return {status=status, present=Runtime.stealthLatched,
                source=Runtime.stealthLatched and "effect" or "effect_absent"}
        end
        if Runtime.stealthLastKnown ~= nil then
            return {status=status, present=Runtime.stealthLastKnown,
                source=Runtime.stealthLastKnown and "observed_stealth_continuity" or
                    "observed_absence_continuity"}
        end
        return {status=status, present=false, source="stealth_unknown",
            eventGap=Runtime.stealthEventGap == true}
    end

    local function sync_active_stealth_evidence(now, observed)
        local status = observed and observed.status or nil
        if now < Runtime.activeStealthConsumedUntil then
            Runtime.activeStealthArmedAt = -math.huge
            Runtime.activeStealthEvidenceUntil = 0.0
            return { status = status, present = false, source = "direct_damage_consumed" }
        end
        if status == "ready" and observed.present == true then
            local remaining = type(observed.remaining) == "number" and
                math.max(0.0, observed.remaining) or ACTIVE_STEALTH_DURATION_SECONDS
            Runtime.activeStealthArmedAt = now
            Runtime.activeStealthEvidenceUntil = now + remaining
            return { status = status, present = true, source = "effect" }
        end
        if status == "ready" then
            local settling = Runtime.activeStealthEvidenceUntil > now and
                now - Runtime.activeStealthArmedAt <=
                    ACTIVE_STEALTH_OBSERVATION_SETTLE_SECONDS
            if settling then
                return { status = status, present = true, source = "accepted_grace" }
            end
            Runtime.activeStealthArmedAt = -math.huge
            Runtime.activeStealthEvidenceUntil = 0.0
            return { status = status, present = false, source = "effect_absent" }
        end
        if Runtime.activeStealthEvidenceUntil > now then
            return { status = status, present = true, source = "accepted_fallback" }
        end
        Runtime.activeStealthArmedAt = -math.huge
        Runtime.activeStealthEvidenceUntil = 0.0
        return { status = status, present = false,
            source = tostring(status or "unavailable") }
    end

    local function target_effect(target, name, options)
        local exact = not is_lethality and CONCEALMENT_EFFECT_FILTERS[name] or nil
        -- An empty name is deliberate: combining the combat-log label with the
        -- exact key would still reject a correct row carrying a parent-derived name.
        return unit_effect(target, exact and "" or name, exact or options)
    end

    local function read_state(loadout, options)
        local now_ms = gos.time_ms()
        local now = type(now_ms) == "number" and now_ms / 1000.0 or 0.0
        local world = gos.world()
        local player = world and world.player or nil
        local target = world and world.current_target or nil
        local player_hp = unit_hp(player)
        local resource = unit_resource(player)
        local target_hp = unit_hp(target)
        local target_handle = safe_method(target, "handle")
        local dot_observed = target_effect(target, DOT_EFFECT, DOT_FILTER)
        local grenade_observed = unit_effect(target, GRENADE_EFFECT, DOT_FILTER)
        local fatality_observed = unit_effect(player, FATALITY_EFFECT, BUFF_FILTER)
        local ta_observed = unit_effect(player, TACTICAL_ADVANTAGE_EFFECT, BUFF_FILTER)
        local stim_boost = unit_effect(player, STIM_BOOST_EFFECT, TIMED_BUFF_FILTER)
        local stealth_observed = unit_effect(player, STEALTH_EFFECT, BUFF_FILTER)
        local active_stealth_observed = unit_effect(player, ACTIVE_STEALTH_EFFECT, BUFF_FILTER)
        local dot = is_lethality and observed_effect(now, dot_observed, true) or
            sync_dot_evidence(now, target_handle, dot_observed)
        local grenade = is_lethality and observed_effect(now, grenade_observed, true) or
            sync_grenade_evidence(now, target_handle, grenade_observed)
        local fatality = is_lethality and observed_effect(now, fatality_observed, false,
            Runtime.fatalityActivationAt) or sync_fatality_evidence(now, fatality_observed)
        local tactical_advantage = is_lethality and observed_effect(now, ta_observed, false,
            Runtime.taActivationAt) or sync_ta_evidence(now, ta_observed)
        if is_lethality and fatality.present and finite(fatality.remaining) then
            -- Fatality lasts 15 seconds; derive its 10s ICD from the engine timer.
            Runtime.fatalityReadyAt = now + math.max(0, fatality.remaining - 5.0)
        end
        local stealth = sync_stealth_evidence(now, stealth_observed)
        local active_stealth = sync_active_stealth_evidence(now,
            active_stealth_observed)
        -- These are actual positioning-clear effects, not inferred from owning
        -- a talent, pressing Stim Boost, or merely being in Stealth.
        local critical_stims = observed_effect(now,
            unit_effect(player, "Critical Stims", BUFF_FILTER), false,
            Runtime.backstabActivationAt)
        local revealing_weakness = observed_effect(now,
            target_effect(target, "Revealing Weakness", DOT_FILTER), true,
            Runtime.backstabActivationAt)
        local gcd = gos.abilities.gcd_remaining()
        local function lasts_to_start(effect)
            return not finite(effect.remaining) or
                effect.remaining > (finite(gcd) and gcd or 0)
        end
        local backstab_override = critical_stims.status == "ready" and
            critical_stims.present and lasts_to_start(critical_stims) and
            "critical_stims" or nil
        if not backstab_override and revealing_weakness.status == "ready" and
            revealing_weakness.present and revealing_weakness.mine and
            lasts_to_start(revealing_weakness) then
            backstab_override = "own_revealing_weakness"
        end
        -- The target poison is NOT the player's same-ability armor-penetration buff.
        -- Read only the published, locally-owned poison component; never create a DoT
        -- merely because Backstab was submitted or Acid Lash was selected in UI.
        local acid_blade = not is_lethality and observed_effect(now,
            target_effect(target, ACID_BLADE_EFFECT, DOT_FILTER), true) or nil
        local volatile_raw = target_effect(target, VOLATILE_EFFECT, DOT_FILTER)
        local volatile_observed = not is_lethality and
            observed_effect(now, volatile_raw, true) or nil
        local speed = safe_method(player, "speed")
        return {
            now = now, world = world, player = player, target = target,
            playerHandle = safe_method(player, "handle"),
            playerHpMax = player_hp and player_hp.max or nil,
            playerHpPercent = player_hp and player_hp.percent or nil,
            playerHp = player_hp and player_hp.current or nil,
            playerPosition = unit_position(player),
            playerRotation = safe_method(player, "rotation"),
            targetSpeed = safe_method(target, "speed"),
            energyCurrent = resource and resource.current or nil,
            energyMax = resource and resource.max or nil,
            energyPercent = resource and resource.percent or nil,
            resourceKind = resource and resource.kind or nil,
            targetHandle = target_handle,
            targetReaction = safe_method(target, "reaction"),
            targetType = safe_method(target, "type"),
            targetHp = target_hp and target_hp.current or nil,
            targetHpPercent = target_hp and target_hp.percent or nil,
            targetDistance = unit_distance(target),
            targetPosition = unit_position(target),
            targetRotation = unit_rotation(target),
            backstabPositionOverride = backstab_override,
            revealingWeakness = revealing_weakness,
            acidBlade = acid_blade,
            volatileObserved = volatile_observed,
            targetToughness = unit_toughness(target),
            moving = type(speed) == "number" and math.abs(speed) > 0.001 or false,
            movementKnown = type(speed) == "number",
            busy = gos.abilities.is_casting_or_channeling() == true,
            gcdRemaining = type(gcd) == "number" and math.max(0, gcd) or nil,
            currentAction = current_cast(),
            abilities = ability_snapshot(loadout),
            progression = progression(loadout),
            volatile = sync_volatile_evidence(now, target_handle, volatile_raw),
            dot = dot,
            grenade = grenade,
            fatality = fatality,
            tacticalAdvantage = tactical_advantage,
            stealth = stealth,
            activeStealth = active_stealth,
            shieldProbe = not is_lethality and options.concealmentAutoShieldProbe == true and
                loadout_has(loadout, "Shield Probe") and
                unit_effect(player, "Shield Probe", BUFF_FILTER) or nil,
            cripplingWounds = not is_lethality and observed_effect(now,
                unit_effect(target, CRIPPLING_WOUNDS_EFFECT, DOT_FILTER), true,
                Runtime.woundsConsumedTarget == target_handle and
                    Runtime.woundsConsumedAt or nil) or nil,
            stimBoost = {
                status = stim_boost and stim_boost.status or nil,
                present = stim_boost and stim_boost.status == "ready" and
                    stim_boost.present == true or false,
            },
            relevantTargets = 1,
            targetCountSource = "manual",
        }
    end

    local function valid_target(state)
        if state.playerHandle == nil then return false, "missing_player" end
        if finite(state.playerHp) and state.playerHp <= 0 then return false, "player_dead" end
        if state.targetControlled then return false, "target_breakable_control" end
        if state.targetHandle == nil then return false, "missing_current_target" end
        if state.targetReaction ~= "hostile" then return false, "target_not_hostile" end
        if type(state.targetHp) == "number" and state.targetHp <= 0 then
            return false, "target_dead"
        end
        return true, "target_ready"
    end
    local function refresh_target_count(state, options)
        state.targetControlled, state.targetControlObserved =
            breakable_control(state.target)
        -- Unknown effect state is a hard veto for player targets. For NPCs, only
        -- positively observed mezzes veto AoE; otherwise packs larger than Core's
        -- bounded arbitrary-unit effect-watch cache could suppress AoE forever.
        local target_control_unknown = state.targetType == "player" and
            state.targetControlObserved ~= true
        state.hazeUnsafe = state.targetControlled == true or target_control_unknown
        state.knivesUnsafe = state.targetControlled == true or target_control_unknown
        state.grenadeUnsafe = state.targetControlled == true or target_control_unknown
        local manual = math.max(1, options.manualRelevantTargets or 1)
        state.relevantTargets = manual
        state.fragmentationTargets = math.min(Ability.FragmentationGrenade.maxTargets, manual)
        state.hazeTargets = manual
        state.knivesTargets = manual
        state.targetCountSource = "manual"
        state.hazeCountSource = "manual"
        state.knivesCountSource = "manual"
        local units = {}
        if state.world and type(state.world.units) == "function" then
            local ok, observed = pcall(state.world.units, state.world,
                { reaction = "hostile" })
            if ok and type(observed) == "table" then units = observed end
        end
        local target_count, frag_count, haze_count, knives_count = 0, 0, 0, 0
        local seen = {}
        local function consider_unit(unit)
            local handle = safe_method(unit, "handle")
            local hp = unit_hp(unit)
            if handle == nil or seen[handle] or
                (hp and type(hp.current) == "number" and hp.current <= 0) then
                return
            end
            local position = unit_position(unit)
            if not position then return end
            seen[handle] = true
            local controlled, control_observed = breakable_control(unit)
            local unit_type = safe_method(unit, "type")
            local splash_unsafe = controlled == true or
                (unit_type == "player" and control_observed ~= true)

            if state.targetPosition then
                local target_distance = position_distance(state.targetPosition, position)
                if type(target_distance) == "number" then
                    if target_distance <= (options.aoeClusterRadius or 5.0) then
                        target_count = target_count + 1
                    end
                    if target_distance <= Ability.FragmentationGrenade.aoeRadius then
                        frag_count = frag_count + 1
                        state.grenadeUnsafe = state.grenadeUnsafe or splash_unsafe
                    end
                end
            end

            if state.playerPosition then
                local player_distance = position_distance(state.playerPosition, position)
                if type(player_distance) == "number" and
                    player_distance <= TOXIC_HAZE_RADIUS_METERS then
                    haze_count = haze_count + 1
                    state.hazeUnsafe = state.hazeUnsafe or splash_unsafe
                end
                if position_in_forward_cone(state.playerPosition, state.playerRotation,
                        position, NOXIOUS_KNIVES_RANGE_METERS,
                        NOXIOUS_KNIVES_CONE_ANGLE_DEGREES) then
                    knives_count = knives_count + 1
                    state.knivesUnsafe = state.knivesUnsafe or splash_unsafe
                end
            end
        end

        for index = 1, math.min(#units, 128) do
            consider_unit(units[index])
        end
        if state.target and state.targetHandle and not seen[state.targetHandle] then
            consider_unit(state.target)
        end

        if options.automaticTargetCount ~= true then
            -- Manual count may replace quantity, never range/facing. A selected
            -- target must still occupy the real footprint, and scanned nearby CC
            -- remains authoritative when world enumeration is available.
            state.relevantTargets = state.targetPosition and manual or 1
            state.fragmentationTargets = frag_count > 0 and
                math.min(Ability.FragmentationGrenade.maxTargets, manual) or 0
            state.hazeTargets = haze_count > 0 and math.min(8, manual) or 0
            state.knivesTargets = knives_count > 0 and math.min(8, manual) or 0
            state.targetCountSource = "manual_bounded_geometry"
            state.hazeCountSource = "manual_bounded_geometry"
            state.knivesCountSource = "manual_bounded_geometry"
            return
        end

        if state.targetPosition then
            state.relevantTargets = math.max(1, target_count)
            state.fragmentationTargets = math.min(
                Ability.FragmentationGrenade.maxTargets, math.max(1, frag_count))
            state.targetCountSource = "automatic"
        else
            state.relevantTargets = 1
            state.fragmentationTargets = 0
            state.targetCountSource = "automatic_target_geometry_unavailable"
        end
        if state.playerPosition then
            state.hazeTargets = math.min(8, haze_count)
            state.hazeCountSource = "automatic"
            if type(state.playerRotation) == "number" then
                state.knivesTargets = math.min(8, knives_count)
                state.knivesCountSource = "automatic_cone"
            else
                state.knivesTargets = 0
                state.knivesCountSource = "automatic_rotation_unavailable"
            end
        else
            state.hazeTargets = 0
            state.knivesTargets = 0
            state.hazeCountSource = "automatic_player_geometry_unavailable"
            state.knivesCountSource = "automatic_player_geometry_unavailable"
        end
    end

    -- Lethality-only geometry and lifetime policy. Never infer an 8m self AoE
    -- from a cluster centered on a target 7m away from the player.
    local function lethality_context(state, options)
        if not is_lethality then return end
        state.targetControlled, state.targetControlObserved =
            breakable_control(state.target)
        state.hazeTargets, state.knivesTargets, state.fragmentationTargets = 0, 0, 0
        local target_control_unknown = state.targetType == "player" and
            state.targetControlObserved ~= true
        state.hazeUnsafe = state.targetControlled == true or target_control_unknown
        state.knivesUnsafe = state.targetControlled == true or target_control_unknown
        state.grenadeUnsafe = state.targetControlled == true or target_control_unknown
        local seen = {}
        local function visit(unit)
            local handle = safe_method(unit, "handle")
            if not handle or seen[handle] or safe_method(unit, "reaction") ~= "hostile" then return end
            seen[handle] = true
            local hp, position = unit_hp(unit), unit_position(unit)
            if not hp or not finite(hp.current) or hp.current <= 0 then return end
            local dp = position_distance(state.playerPosition, position)
            local dt = position_distance(state.targetPosition, position)
            local in_haze = finite(dp) and dp <= 8.0
            local in_grenade = finite(dt) and dt <= 5.0
            local in_knives = false
            if finite(dp) and dp <= 10.0 and finite(state.playerRotation) and position then
                local dx, dz = position.x-state.playerPosition.x, position.z-state.playerPosition.z
                local planar = math.sqrt(dx*dx+dz*dz)
                -- Jedipedia's Cone Angle field is 45 degrees. Use its conservative
                -- inner cone (22.5 degrees either side), not a guessed 120-degree arc.
                in_knives = planar <= 0.000001 or
                    (dx*math.sin(state.playerRotation)-dz*math.cos(state.playerRotation))/planar >=
                        math.cos(math.rad(22.5))
            end
            local cc, cc_observed = false, true
            if in_haze or in_grenade or in_knives then
                cc, cc_observed = breakable_control(unit)
            end
            local unit_type = safe_method(unit, "type")
            local splash_unsafe = cc == true or
                (unit_type == "player" and cc_observed ~= true)
            if in_haze then
                state.hazeTargets=state.hazeTargets+1
                state.hazeUnsafe=state.hazeUnsafe or splash_unsafe
            end
            if in_grenade then
                state.fragmentationTargets=state.fragmentationTargets+1
                state.grenadeUnsafe=state.grenadeUnsafe or splash_unsafe
            end
            if in_knives then
                state.knivesTargets=state.knivesTargets+1
                state.knivesUnsafe=state.knivesUnsafe or splash_unsafe
            end
        end
        visit(state.target)
        local units = safe_method(state.world, "units", {reaction="hostile"})
        if type(units)=="table" then
            for i=1,math.min(#units,64) do visit(units[i]) end
        end
        state.relevantTargets = math.max(1, state.fragmentationTargets)
        state.targetCountSource = "bounded_geometry"
        state.hazeTargets=math.min(8,state.hazeTargets)
        state.knivesTargets=math.min(8,state.knivesTargets)
        state.fragmentationTargets=math.min(7,state.fragmentationTargets)
        if options.automaticTargetCount == false then
            -- Explicit manual counts do not override range/facing or known CC guards.
            local n=math.max(1,options.manualRelevantTargets or 1)
            if state.hazeTargets>0 then state.hazeTargets=math.min(n,8) end
            if state.knivesTargets>0 then state.knivesTargets=math.min(n,8) end
            if state.fragmentationTargets>0 then state.fragmentationTargets=math.min(n,7) end
        end

        if Runtime.lifetimeTarget ~= state.targetHandle then
            Runtime.lifetimeTarget, Runtime.lifetimeSamples = state.targetHandle, {}
        end
        local samples=Runtime.lifetimeSamples
        if finite(state.targetHp) and state.targetHp > 0 then
            local last=samples[#samples]
            if last and state.targetHp>last.hp then samples={}; Runtime.lifetimeSamples=samples; last=nil end
            if not last or state.now-last.t >= 0.25 then
                samples[#samples+1]={t=state.now,hp=state.targetHp}
                while #samples>12 or (#samples>1 and state.now-samples[1].t>3.0) do table.remove(samples,1) end
            end
            local first=samples[1]
            if first and state.now-first.t>=0.75 and first.hp>state.targetHp then
                state.targetLifetime = state.targetHp*(state.now-first.t)/(first.hp-state.targetHp)
                state.lifetimeSource = "recent_hp_loss_estimate"
            end
        end
    end

    local function concealment_lifetime_context(state)
        if is_lethality then return end
        if Runtime.lifetimeTarget ~= state.targetHandle then
            Runtime.lifetimeTarget, Runtime.lifetimeSamples = state.targetHandle, {}
        end
        local samples = Runtime.lifetimeSamples
        if not finite(state.targetHp) or state.targetHp <= 0 then return end
        local last = samples[#samples]
        if last and state.targetHp > last.hp then
            samples = {}
            Runtime.lifetimeSamples = samples
            last = nil
        end
        if not last or state.now - last.t >= 0.25 then
            samples[#samples + 1] = { t = state.now, hp = state.targetHp }
            while #samples > 12 or
                (#samples > 1 and state.now - samples[1].t > 3.0) do
                table.remove(samples, 1)
            end
        end
        local first = samples[1]
        if first and state.now - first.t >= 0.75 and first.hp > state.targetHp then
            state.targetLifetime = state.targetHp * (state.now - first.t) /
                (first.hp - state.targetHp)
            state.lifetimeSource = "recent_hp_loss_estimate"
        end
    end

    local function lifetime_allows(state, seconds)
        return not finite(state.targetLifetime) or state.targetLifetime >= seconds
    end

    local function ability_state(state, ability)
        return state.abilities[ability.id] or { known = false }
    end
    local function concealment_builder(state)
        -- A learned replacement is authoritative, even if the old name lingers
        -- in the loadout. Unbound Veiled Strike is not permission to cast Shiv.
        return ability_state(state, Ability.VeiledStrike).known == true and
            Ability.VeiledStrike or Ability.Shiv
    end

    local function action_lock(state)
        if type(state.gcdRemaining) ~= "number" then return nil, "gcd_unavailable" end
        if state.busy then
            if state.currentAction and type(state.currentAction.remaining) == "number" then
                return math.max(state.gcdRemaining, state.currentAction.remaining), "cast_or_channel"
            end
            return nil, "busy_without_timing"
        end
        return state.gcdRemaining, "gcd"
    end

    local function failure_key(ability, target_handle)
        if ability.targetless then return ability.id end
        return ability.id .. ":" .. tostring(target_handle or "none")
    end

    local function ability_ready(state, ability)
        local snapshot = ability_state(state, ability)
        if snapshot.known ~= true then return false, "not_owned" end
        if snapshot.resolved ~= true then return false, "unresolved" end
        if snapshot.bound ~= true then return false, "not_on_quickbar" end
        local backoff = Runtime.failureBackoff[failure_key(ability, state.targetHandle)]
        if type(backoff) == "number" and state.now < backoff then
            return false, "failure_backoff"
        end
        if ability.offGcd == true then
            if snapshot.cooldownKnown then
                return snapshot.cooldown <= READY_SLACK,
                    snapshot.cooldown <= READY_SLACK and "cooldown_ready" or "cooldown"
            end
            return snapshot.ready == true, snapshot.ready and "runtime_ready" or "not_ready"
        end
        local starts_in = action_lock(state)
        if type(starts_in) ~= "number" then return false, "start_time_unavailable" end
        if snapshot.cooldownKnown then
            if snapshot.cooldown <= starts_in + READY_SLACK then
                return true, "cooldown_ready_at_start"
            end
            return false, "cooldown"
        end
        return snapshot.ready == true, snapshot.ready and "runtime_ready" or "not_ready"
    end

    local function scaled_cost(state, ability)
        if not is_lethality and ability == Ability.Spender and
            state.progression.level23 == "Relentless Blades" then
            return 0.0 -- Selected talent explicitly removes Laceration's energy cost.
        end
        if spec.discipline == "Lethality" and ability == Ability.Spender and
            type(state.fatality) == "table" and state.fatality.present == true then
            return 0.0
        end
        local snapshot = ability_state(state, ability)
        local cost = snapshot.cost
        if type(cost) ~= "number" then return nil end
        if snapshot.costSource == "verified_fallback" and
            type(state.energyMax) == "number" and state.energyMax > 0 then
            return cost * state.energyMax / 100.0
        end
        return cost
    end

    local function resource_allows(state, ability, options)
        local cost = scaled_cost(state, ability)
        if is_lethality and (not finite(cost) or cost < 0) then
            return false, "invalid_resource_cost", cost
        end
        if is_lethality and cost > 0 and
            (not finite(state.energyCurrent) or not finite(state.energyMax) or state.energyMax <= 0) then
            return false, "energy_unavailable", cost
        end
        if ability.offGcd == true then return true, "off_gcd", 0 end
        if type(cost) ~= "number" then return false, "resource_cost_unavailable", nil end
        if cost <= 0 then return true, "free", 0 end
        local current, maximum = state.energyCurrent, state.energyMax
        if type(current) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
            return false, "energy_unavailable", cost
        end
        if current < cost then return false, "insufficient_energy", cost end
        local projected = current - cost
        if spec.discipline == "Concealment" and ability == Ability.Spender and
            state.progression.culling == true then
            -- Culling refunds 2 Energy only after Collateral Strike lands. Keep the
            -- real upfront affordability check above; use the refund for reserve
            -- projection so Laceration is not treated as more expensive than it is.
            projected = math.min(maximum, projected + 2.0 * maximum / 100.0)
        end
        local floor = clamp(options.energyFloorPercent or 60, 0, 95)
        if projected / maximum * 100.0 < floor then
            -- The reserve is a policy, not an engine resource requirement. An
            -- explicit opt-in may spend through it only to finish a real proc
            -- window. Upfront current >= cost was already checked above.
            if not is_lethality and options.concealmentSpendReserveForProcs ~= false then
                local effect, deadline
                if state.concealmentTactical == "Volatile Strike" then
                    if ability == Ability.VeiledStrike then effect = state.volatileObserved end
                    if ability == Ability.Backstab then effect = state.revealingWeakness end
                elseif state.concealmentTactical == "Acid Lash" and
                    (ability == Ability.Spender or ability == Ability.Backstab) then
                    effect = state.acidBlade
                    local duration = ability_state(state, Ability.Spender).gcdDuration
                    if finite(duration) and duration > 0 then deadline = duration + READY_SLACK end
                end
                local wait = action_lock(state)
                local observed = type(effect) == "table" and effect.status == "ready" and
                    effect.present == true and effect.mine == true and finite(wait)
                local active = observed and (not finite(effect.remaining) or effect.remaining > wait)
                local justified = state.concealmentTactical == "Volatile Strike" or
                    (finite(deadline) and observed and finite(effect.remaining) and
                        effect.remaining <= wait + deadline)
                if active and justified then return true, "observed_proc_spend_reserve", cost end
            end
            return false, "energy_floor", cost
        end
        return true, "energy_floor_ok", cost
    end

    local function policy_allows(state, ability, options)
        -- The selected replacement wins even if a stale loadout lists both names.
        if not is_lethality and ability == Ability.Shiv and
            ability_state(state, Ability.VeiledStrike).known == true then
            return false, "replaced_by_veiled_strike"
        end
        if ability == Ability.CripplingSlice and
            state.progression.level39 == "Crippling Throw" then
            return false, "replaced_by_crippling_throw"
        end
        if ability == Ability.CripplingThrow and
            state.progression.level39 ~= "Crippling Throw" then
            return false, "crippling_throw_not_selected"
        end
        local ready, reason = ability_ready(state, ability)
        if not ready then return false, reason end
        if ability.requiresTacticalAdvantage == true then
            local ta = state.tacticalAdvantage
            if not is_lethality and (type(ta) ~= "table" or ta.status ~= "ready") then
                -- Core can_cast/is_ready are timing/metadata observations, NOT
                -- proof of Tactical Advantage. Use non-TA fallback during gaps.
                return false, "tactical_advantage_observation_gap"
            elseif type(ta) == "table" and ta.status ~= "ready" then
                -- Legacy branch; production Lethality has its own runtime.
            elseif type(ta) ~= "table" or ta.present ~= true then
                return false, type(ta) == "table" and
                    ("tactical_advantage_" .. tostring(ta.source or "absent")) or
                    "tactical_advantage_unavailable"
            end
            if type(ta.stacks) == "number" and ta.stacks < 1 then
                return false, "tactical_advantage_zero"
            end
            if ta.status == "ready" and
                type(state.gcdRemaining) == "number" and
                state.gcdRemaining <= READY_SLACK and
                ability_state(state, ability).ready ~= true then
                return false, "tactical_advantage_condition_not_ready"
            end
        end
        if ability.requiresOpenReady == true and
            type(state.gcdRemaining) == "number" and
            state.gcdRemaining <= READY_SLACK and
            ability_state(state, ability).ready ~= true then
            return false, "ability_condition_not_ready"
        end
        if type(ability.coneRange) == "number" then
            local target_ok, target_reason = valid_target(state)
            if not target_ok then return false, target_reason end
            if type(state.targetDistance) ~= "number" then
                return false, "distance_unavailable"
            end
            if state.targetDistance > ability.coneRange then return false, "out_of_range" end
        elseif ability.targetless ~= true then
            local target_ok, target_reason = valid_target(state)
            if not target_ok then return false, target_reason end
            if type(ability.range) == "number" and
                type(state.targetDistance) == "number" and
                state.targetDistance > ability.range then
                return false, "out_of_range"
            end
            -- A transient missing distance sample is not proof of range failure.
            -- Submit targeted abilities and let Core's engine admission decide;
            -- player-centered cone/AoE actions above still fail closed.
        end
        if ability == Ability.Backstab and state.backstabPositionOverride == nil then
            -- Stealth reserves Backstab as the opener; it does not by itself
            -- remove the ability's positional requirement.
            -- Target yaw is a real Core CharacterNode observation, never velocity
            -- or camera heading. Keep the existing conservative rear-half-plane
            -- policy; unknown heading is not permission to assume we are behind.
            if not state.playerPosition or not state.targetPosition or
                not finite(state.targetRotation) then
                return false, "backstab_position_unavailable"
            end
            local dx = state.playerPosition.x - state.targetPosition.x
            local dz = state.playerPosition.z - state.targetPosition.z
            if not finite(dx) or not finite(dz) or (dx == 0 and dz == 0) then
                return false, "backstab_position_undefined"
            end
            local facing = dx * math.sin(state.targetRotation) - dz * math.cos(state.targetRotation)
            if not finite(facing) or facing >= 0 then
                return false, "not_behind_target"
            end
        end
        local resource_ok, resource_reason = resource_allows(state, ability, options)
        if not resource_ok then return false, resource_reason end
        -- Policy eligibility is not client admission. Submit checks the exact
        -- target through Core; do not require a different can_cast request
        -- before consuming live admission on the next worker tick.
        return true, reason
    end

    local function corrosive_dart_due(state, options)
        if ability_state(state, Ability.CorrosiveDart).known ~= true then
            return false, "not_owned"
        end
        if spec.dotPolicy == "durable" and not target_is_durable(state) then
            return false, "target_not_durable"
        end
        if not is_lethality and not lifetime_allows(state,
                CONCEALMENT_MIN_SETUP_LIFETIME_SECONDS) then
            return false, "short_lived_target"
        end
        if is_lethality and not lifetime_allows(state, options.lethalityMinDotLifetime or 6.0) then
            return false, "short_lived_target"
        end
        if state.dot.status ~= "ready" then
            return false, "dot_observation_unavailable"
        end
        if Runtime.dotAttemptTarget == state.targetHandle and
            state.now < Runtime.dotAttemptUntil then
            return false, "application_pending"
        end
        if not state.dot.present or not state.dot.mine then
            return true, state.dot.status == "ready" and "missing" or
                ("observation_" .. tostring(state.dot.source or "unavailable"))
        end
        if type(state.dot.remaining) ~= "number" then return false, "timer_unavailable" end
        if state.dot.remaining <= (options.corrosiveDartRefreshSeconds or 1.5) then
            return true, "refresh"
        end
        return false, "active_" .. tostring(state.dot.source or "known")
    end

    local function corrosive_grenade_due(state, options)
        if ability_state(state, Ability.CorrosiveGrenade).known ~= true then
            return false, "not_owned"
        end
        if is_lethality and (state.grenadeUnsafe or
            not lifetime_allows(state, options.lethalityMinDotLifetime or 6.0)) then
            return false, state.grenadeUnsafe and "nearby_breakable_control" or "short_lived_target"
        end
        if is_lethality and state.grenade.status ~= "ready" then
            return false, "grenade_observation_unavailable"
        end
        if Runtime.grenadeAttemptTarget == state.targetHandle and
            state.now < Runtime.grenadeAttemptUntil then
            return false, "application_pending"
        end
        if not state.grenade.present or not state.grenade.mine then
            return true, state.grenade.status == "ready" and "missing" or
                ("observation_" .. tostring(state.grenade.source or "unavailable"))
        end
        if type(state.grenade.remaining) ~= "number" then return false, "timer_unavailable" end
        if state.grenade.remaining <= (options.corrosiveGrenadeRefreshSeconds or 1.5) then
            return true, "refresh"
        end
        return false, "active_" .. tostring(state.grenade.source or "known")
    end

    local function tactical_advantage_stacks(state)
        local ta = state.tacticalAdvantage
        if type(ta) ~= "table" or ta.status ~= "ready" then return nil end
        if ta.present ~= true then return 0 end
        return finite(ta.stacks) and math.max(0, math.floor(ta.stacks)) or nil
    end

    local function authoritative_corrosive_dart(state)
        if type(state.dot) ~= "table" or state.dot.status ~= "ready" or
            state.dot.present ~= true or state.dot.mine ~= true then
            return false
        end
        return state.dot.source == "effect" or
            state.dot.source == "effect_timer_unavailable"
    end

    local function own_effect_at_start(state, effect)
        if type(effect) ~= "table" or effect.status ~= "ready" or
            effect.present ~= true or effect.mine ~= true then return false end
        local wait = action_lock(state)
        return not finite(effect.remaining) or
            (finite(wait) and effect.remaining > wait)
    end

    local function concealment_poison_ready(state)
        return own_effect_at_start(state, state.acidBlade) or
            (authoritative_corrosive_dart(state) and own_effect_at_start(state, state.dot))
    end

    local function concealment_gcd_duration(state)
        -- Use the published runtime duration. Missing timing cannot
        -- justify claiming that a poison will expire in a fabricated GCD window.
        local duration = ability_state(state, Ability.Spender).gcdDuration
        return finite(duration) and duration > 0 and duration or nil
    end

    local function poisons_ready(state)
        if not (state.dot.present == true and state.dot.mine == true) then return false end
        if ability_state(state, Ability.CorrosiveGrenade).known == true then
            return state.grenade.present == true and state.grenade.mine == true
        end
        return true
    end

    local function decision(ability, reason)
        return { ability = ability, reason = reason }
    end

    local function consider(state, ability, reason, options)
        local castable, blocked = policy_allows(state, ability, options)
        if ability == Ability.VolatileSubstance then
            state.volatileGate = castable and "ready" or blocked
        end
        if not castable and ability_state(state, ability).known == true then
            state.blockedReasons = state.blockedReasons or {}
            if #state.blockedReasons < 5 then
                state.blockedReasons[#state.blockedReasons + 1] =
                    ability.id .. "=" .. tostring(blocked)
            end
        end
        return castable and decision(ability, reason) or nil
    end

    local function stealth_opener_required(state, options)
        -- Match Lethality: proven Stealth owns Backstab; unknown out-of-combat
        -- state also preserves the opener. A missing combat snapshot alone
        -- must not hold every other attack after the opener has completed.
        local stealth = state.stealth
        return stealth.present == true or stealth.eventGap == true or
            (stealth.status ~= "ready" and stealth.source ~= "opener_consumed" and
                options.inCombat ~= true)
    end

    local function select_shield_probe(state, options)
        -- Reuse Lethality's self-only defensive policy, not its damage APL.
        -- Shield Probe may run during the GCD and without a hostile selection.
        if is_lethality or options.concealmentAutoShieldProbe ~= true or
            options.inCombat ~= true or state.busy or
            state.now < Runtime.contentionUntil or options.autoStealthPending == true or
            stealth_opener_required(state, options) or state.playerHandle == nil or
            not finite(state.playerHp) or state.playerHp <= 0 or
            not finite(state.playerHpPercent) or
            state.playerHpPercent > (options.concealmentShieldProbeBelow or 75.0) then
            return nil
        end
        local shield = state.shieldProbe
        if not shield or shield.status ~= "ready" or shield.truncated == true or
            shield.present ~= false then return nil end
        return consider(state, Ability.ShieldProbe, "shield_probe_low_self_health", options)
    end

    local function select_offgcd(state, options)
        -- Preserve the stealth opener. Even harmless off-GCD commands would occupy
        -- the shared executor and can delay Backstab by a command lifecycle tick.
        if stealth_opener_required(state, options) then return nil end
        if options.inCombat ~= true then return nil end
        if state.busy or state.now < Runtime.contentionUntil then return nil end
        if options.autoAdrenalineProbe == true and
            state.now >= Runtime.probeAttemptUntil and
            type(state.energyPercent) == "number" and
            state.energyPercent <= (options.adrenalineProbeThresholdPercent or 20) then
            local selected = consider(state, Ability.AdrenalineProbe,
                "energy_recovery_" .. optional_number(state.energyPercent, "%.0f"), options)
            if selected then return selected end
        end
        local lethal_burst_ready = not is_lethality or
            (finite(state.targetDistance) and state.targetDistance <= 10.0 and
                lifetime_allows(state, 6.0) and
                (state.dot.present and state.dot.mine or state.grenade.present and state.grenade.mine) and
                state.tacticalAdvantage.status == "ready" and
                finite(tactical_advantage_stacks(state)) and tactical_advantage_stacks(state) < 2)
        local concealment_burst_ready = is_lethality or
            (finite(state.targetDistance) and state.targetDistance <= 4.0 and
                tactical_advantage_stacks(state) ~= nil and
                lifetime_allows(state, CONCEALMENT_MIN_SETUP_LIFETIME_SECONDS))
        if lethal_burst_ready and concealment_burst_ready and
            options.autoStimBoost == true and target_is_stim_worthy(state) and
            state.now >= Runtime.stimAttemptUntil and
            not (state.stimBoost.status == "ready" and state.stimBoost.present) then
            local ta = state.tacticalAdvantage
            local ta_capped = type(ta) == "table" and ta.present == true and
                type(ta.stacks) == "number" and ta.stacks >= 2
            if not ta_capped then
                local selected = consider(state, Ability.StimBoost, "stim_boost", options)
                if selected then return selected end
            end
        end
        if is_lethality and options.lethalityAutoTacticalOverdrive == true and
            state.progression.level43 == "Tactical Overdrive" and
            state.now >= Runtime.tacticalOverdriveAttemptUntil and
            target_is_stim_worthy(state) and poisons_ready(state) and
            lifetime_allows(state, 6.0) and finite(state.targetDistance) and state.targetDistance <= 4.0 then
            local haze, backstab, stim = ability_state(state, Ability.ToxicHaze),
                ability_state(state, Ability.Backstab), ability_state(state, Ability.StimBoost)
            local reset_window = haze.bound and haze.cooldownKnown and haze.cooldown > READY_SLACK and
                backstab.bound and backstab.cooldownKnown and backstab.cooldown > READY_SLACK and
                (options.autoStimBoost ~= true or stim.cooldownKnown and stim.cooldown > READY_SLACK)
            if reset_window then
                local selected = consider(state, Ability.TacticalOverdrive,
                    "lethality_reset_used_haze_backstab", options)
                if selected then return selected end
            end
        end
        if spec.discipline == "Concealment" and
            options.concealmentAutoTacticalOverdrive ~= false and
            state.progression.level43 == "Tactical Overdrive" and
            state.now >= Runtime.tacticalOverdriveAttemptUntil and
            target_is_stim_worthy(state) and
            state.volatileObserved.status == "ready" and
            state.volatileObserved.present ~= true and
            not (state.volatile and state.volatile.present) and
            lifetime_allows(state, CONCEALMENT_MIN_SETUP_LIFETIME_SECONDS) and
            finite(state.targetDistance) and state.targetDistance <= 4.0 then
            local backstab = ability_state(state, Ability.Backstab)
            local volatile = ability_state(state, Ability.VolatileSubstance)
            local stim = ability_state(state, Ability.StimBoost)
            local reset_window = backstab.bound == true and volatile.bound == true and
                backstab.cooldownKnown == true and volatile.cooldownKnown == true and
                type(backstab.cooldown) == "number" and backstab.cooldown > READY_SLACK and
                type(volatile.cooldown) == "number" and volatile.cooldown > READY_SLACK and
                (options.autoStimBoost ~= true or stim.bound ~= true or
                    (stim.cooldownKnown and stim.cooldown > READY_SLACK))
            if reset_window then
                local selected = consider(state, Ability.TacticalOverdrive,
                    "concealment_reset_backstab_volatile", options)
                if selected then return selected end
            end
        end
        return nil
    end

    local function aoe_action(state, options)
        if options.aoeEnabled ~= true then return nil end
        -- Automatic splash is conservative in PvP by default because a single
        -- Haze/Knives/Grenade can break coordinated mezzes. The live dispatcher
        -- exposes an explicit opt-in for players who want aggressive PvP cleave.
        if spec.discipline == "Concealment" and state.targetType == "player" and
            options.concealmentPvPAoEEnabled ~= true then
            return nil
        end
        local minimum = options.aoeMinTargets or 3
        local haze_targets = state.hazeTargets or 1
        local knives_targets = state.knivesTargets or 1
        local frag_targets = state.fragmentationTargets or 1

        if spec.discipline == "Concealment" then
            if state.hazeUnsafe ~= true and
                haze_targets >= math.max(3, minimum) then
                local haze = consider(state, Ability.ToxicHaze,
                    "concealment_toxic_haze_self_8m_" .. tostring(haze_targets), options)
                if haze then return haze end
            end

            local knives_minimum = state.progression.level27 == "Curbing Strategies" and
                math.max(3, minimum) or math.max(4, minimum)
            if state.knivesUnsafe ~= true and knives_targets >= knives_minimum then
                local knives = consider(state, Ability.NoxiousKnives,
                    (state.progression.level27 == "Curbing Strategies" and
                        "aoe_knives_curbing_" or "aoe_knives_") ..
                        tostring(knives_targets), options)
                if knives then return knives end
            end

            local probe = ability_state(state, Ability.AdrenalineProbe)
            local probe_ready = probe.known == true and
                ((probe.cooldownKnown == true and
                    type(probe.cooldown) == "number" and probe.cooldown <= READY_SLACK) or
                    (probe.cooldownKnown ~= true and probe.ready == true))
            local fragmentation_safe =
                (type(state.energyPercent) == "number" and state.energyPercent >= 95.0) or
                state.progression.level23 == "Relentless Blades" or
                (options.autoAdrenalineProbe == true and probe_ready)
            if state.grenadeUnsafe ~= true and
                frag_targets >= minimum and fragmentation_safe then
                return consider(state, Ability.FragmentationGrenade,
                    "aoe_frag_safe_5m_" .. tostring(frag_targets), options)
            end
            return nil
        end

        if state.progression.level27 == "Curbing Strategies" and
            knives_targets >= minimum then
            local knives = consider(state, Ability.NoxiousKnives,
                "aoe_knives_curbing_" .. tostring(knives_targets), options)
            if knives then return knives end
        end
        if frag_targets >= minimum then
            local selected = consider(state, Ability.FragmentationGrenade,
                "aoe_frag_5m_" .. tostring(frag_targets), options)
            if selected then return selected end
        end
        if knives_targets >= minimum then
            return consider(state, Ability.NoxiousKnives,
                "aoe_knives_" .. tostring(knives_targets), options)
        end
        return nil
    end

    local function owned_crippling_wounds(state)
        local effect = state.cripplingWounds
        return effect and effect.status == "ready" and effect.present == true and
            effect.mine == true
    end

    local function crippling_wounds_followup(state, options)
        if options.concealmentWoundsFollowup == false or
            state.progression.level39 ~= "Crippling Wounds" or
            not owned_crippling_wounds(state) then return nil end
        -- The real target debuff works equally for manual and automatic Slice.
        -- Take the best legal direct hit now; never wait for a blocked combo.
        local selected = consider(state, Ability.Backstab,
            "crippling_wounds_backstab", options)
        if selected then return selected end
        selected = consider(state, Ability.Spender,
            "crippling_wounds_laceration", options)
        if selected then return selected end
        selected = consider(state, concealment_builder(state),
            "crippling_wounds_builder", options)
        if selected then return selected end
        selected = consider(state, Ability.OverloadShot,
            "crippling_wounds_ranged_hit", options)
        if selected then return selected end
        return consider(state, Ability.RifleShot,
            "crippling_wounds_legal_free_hit", options)
    end

    local function crippling_wounds_setup(state, options)
        if options.concealmentAutoCrippling == false or
            state.progression.level39 ~= "Crippling Wounds" or
            owned_crippling_wounds(state) or state.activeStealth.present == true then
            return nil
        end
        if Runtime.cripplingVolatileTarget ~= state.targetHandle then
            Runtime.cripplingVolatileTarget = nil
            Runtime.cripplingVolatileFiller = false
        end
        -- Confirmed VS -> one ordinary GCD -> Slice. This is a priority hint,
        -- not a forced sequence: blocked Slice never holds the route.
        if Runtime.cripplingVolatileTarget == state.targetHandle and
            state.volatile.source == "effect" and state.volatile.present and
            Runtime.cripplingVolatileFiller ~= true then return nil end
        if not target_is_durable(state) then return nil end
        local duration = ability_state(state, Ability.CripplingSlice).gcdDuration
        if finite(duration) and duration > 0 and
            not lifetime_allows(state, duration * 2) then return nil end
        local hit = consider(state, Ability.Backstab, "wounds_setup_probe", options) or
            consider(state, Ability.Spender, "wounds_setup_probe", options)
        local volatile_hit = Runtime.cripplingVolatileTarget == state.targetHandle and
            Runtime.cripplingVolatileFiller == true and state.volatile.source == "effect" and
            state.volatile.present and concealment_poison_ready(state)
        if not hit and not volatile_hit then return nil end
        return consider(state, Ability.CripplingSlice,
            "crippling_wounds_setup_for_" .. (volatile_hit and "Volatile Substance" or hit.ability.id), options)
    end

    local function crippling_throw_builder(state, options)
        if options.concealmentAutoCrippling == false or
            state.progression.level39 ~= "Crippling Throw" then return nil end
        local stacks = tactical_advantage_stacks(state)
        -- Missing observations are not permission to assume room under the cap.
        if stacks == nil or stacks >= 2 then return nil end
        return consider(state, Ability.CripplingThrow,
            "crippling_throw_free_ta_builder", options)
    end

    local function crippling_free_filler(state, options)
        if options.concealmentAutoCrippling == false or
            state.progression.level39 == "Crippling Throw" or
            owned_crippling_wounds(state) or state.activeStealth.present == true then
            return nil
        end
        -- The Best Defense is applied by the engine on selected Slice use.
        return consider(state, Ability.CripplingSlice,
            state.progression.level39 == "The Best Defense" and
                "crippling_slice_best_defense" or "crippling_slice_free_filler", options)
    end

    local function select_priority(state, options)
        if stealth_opener_required(state, options) then
            -- No fallthrough to Dart, Slice, spender, filler or self-heal while
            -- preserving the opener. Fire Backstab as soon as it is legal.
            return consider(state, Ability.Backstab, "stealth_backstab_only", options)
        end

        local dart_due, dart_reason = corrosive_dart_due(state, options)
        local grenade_due, grenade_reason = corrosive_grenade_due(state, options)
        local function dart()
            if not dart_due then return nil end
            return consider(state, Ability.CorrosiveDart,
                "corrosive_dart_" .. tostring(dart_reason), options)
        end
        local function grenade()
            if not grenade_due then return nil end
            return consider(state, Ability.CorrosiveGrenade,
                "corrosive_grenade_" .. tostring(grenade_reason), options)
        end

        if is_lethality then
            local selected = grenade()
            if selected then return selected end
            selected = dart()
            if selected then return selected end

            local ta = tactical_advantage_stacks(state)
            local any_poison = state.dot.present and state.dot.mine or state.grenade.present and state.grenade.mine
            local full_poison = poisons_ready(state)
            local fatality = state.fatality.present and
                (not finite(state.fatality.remaining) or state.fatality.remaining > (state.gcdRemaining or 0))
            local close = finite(state.targetDistance) and state.targetDistance <= 8.0
            local pack = (state.hazeTargets or 0) >= (options.aoeMinTargets or 3)
            local stationary_npc = state.targetType ~= "player" and state.targetSpeed == 0 and
                target_is_durable(state) and options.lethalitySingleTargetHaze ~= false
            local haze_worthy = options.aoeEnabled == true and not state.hazeUnsafe and close and
                (pack or stationary_npc) and lifetime_allows(state, 6.0)
            local function assault(reason)
                if not any_poison then return nil end
                return consider(state, Ability.Spender, reason, options)
            end
            -- Spend a proven proc even when the second poison is unbound/blocked.
            -- Unknown observations are not replaced with fictitious DoT/TA timers.
            if fatality then
                selected = assault("corrosive_assault_fatality")
                if selected then return selected end
            end
            local blast = full_poison and lifetime_allows(state, 3.0) and
                consider(state, Ability.ToxicBlast, "toxic_blast_poison_window", options) or nil
            if ta ~= nil and ta < 2 and blast then return blast end
            if ta == 2 and blast then
                if haze_worthy then
                    selected = consider(state, Ability.ToxicHaze, "haze_make_room_for_blast", options)
                    if selected then return selected end
                end
                selected = assault("assault_make_room_for_blast")
                if selected then return selected end
            end
            if haze_worthy and (full_poison or pack and state.dot.present and state.dot.mine) then
                selected = consider(state, Ability.ToxicHaze,
                    pack and "toxic_haze_player_centered_pack" or "toxic_haze_stationary_npc", options)
                if selected then return selected end
            end
            if any_poison and ta ~= nil and ta < 2 and state.progression.fatality and
                state.now >= Runtime.fatalityReadyAt then
                selected = consider(state, Ability.Shiv, "shiv_fatality_builder", options)
                if selected then return selected end
            end
            if ta == 2 or ta == 1 and state.progression.level23 == "Corrosive Return" and
                state.now >= Runtime.corrosiveReturnReadyAt then
                selected = assault("corrosive_assault_ta_spend")
                if selected then return selected end
            end
            if options.aoeEnabled == true then
                local minimum = options.aoeMinTargets or 3
                if not state.knivesUnsafe and (state.knivesTargets or 0) >= minimum and
                    state.progression.level27 == "Curbing Strategies" then
                    selected = consider(state, Ability.NoxiousKnives, "aoe_knives_forward_pack", options)
                    if selected then return selected end
                end
                if not state.grenadeUnsafe and (state.fragmentationTargets or 0) >= minimum then
                    selected = consider(state, Ability.FragmentationGrenade, "aoe_frag_actual_pack", options)
                    if selected then return selected end
                end
                if not state.knivesUnsafe and (state.knivesTargets or 0) >= minimum then
                    selected = consider(state, Ability.NoxiousKnives, "aoe_knives_forward_pack", options)
                    if selected then return selected end
                end
            end
            if ta ~= nil and ta < 2 then
                selected = consider(state, Ability.Shiv, "tactical_advantage_builder", options)
                if selected then return selected end
            end
            selected = assault("corrosive_assault_poisoned_target")
            if selected then return selected end
            selected = consider(state, Ability.Backstab, "backstab_legal_filler", options)
            if selected then return selected end
            -- A 15-Energy filler must not repeatedly consume the reserve needed
            -- for a 20-Energy Assault while a real Tactical Advantage is waiting.
            if any_poison and ta ~= nil and ta > 0 then
                return consider(state, Ability.RifleShot, "free_filler_preserve_assault_energy", options)
            end
        else
            local builder = concealment_builder(state)
            local stacks = tactical_advantage_stacks(state)
            local acid = own_effect_at_start(state, state.acidBlade)
            local poison = concealment_poison_ready(state)
            local volatile = own_effect_at_start(state, state.volatileObserved)
            local weakness = own_effect_at_start(state, state.revealingWeakness)
            local acid_lash = state.concealmentTactical == "Acid Lash"
            local volatile_strike = state.concealmentTactical == "Volatile Strike"
            local gcd = concealment_gcd_duration(state)
            local selected

            -- Acid Lash refreshes ONLY an existing Acid Blade poison. Do not
            -- confuse it with the armor buff, another Operative's poison, or Dart.
            if acid_lash and acid and finite(gcd) and
                finite(state.acidBlade.remaining) and
                state.acidBlade.remaining <= (action_lock(state) or 0) + gcd + READY_SLACK then
                selected = consider(state, Ability.Backstab, "acid_blade_reapply_now", options) or
                    consider(state, Ability.Spender, "acid_lash_refresh_before_expiry", options)
                if selected then return selected end
                if stacks == 0 then
                    selected = consider(state, builder, "acid_lash_build_missing_ta", options)
                    if selected then return selected end
                end
            end

            -- PvP tactical: a real unexploded VS is the trigger. No Dart is
            -- required for Veiled Strike to detonate it. Slice is optional setup,
            -- never a forced wait, and we do not invent the subsequent crit proc.
            if volatile_strike and volatile then
                if options.concealmentAutoCrippling ~= false and
                    state.progression.level39 == "Crippling Wounds" and
                    not owned_crippling_wounds(state) and not state.activeStealth.present and
                    Runtime.cripplingVolatileTarget == state.targetHandle and
                    Runtime.cripplingVolatileFiller ~= true and
                    (not finite(state.targetLifetime) or
                        (finite(gcd) and state.targetLifetime > gcd)) then
                    selected = consider(state, Ability.CripplingSlice,
                        "volatile_strike_crippling_setup", options)
                    if selected then return selected end
                end
                selected = consider(state, Ability.VeiledStrike,
                    "volatile_strike_detonate_observed_substance", options)
                if selected then return selected end
            end
            -- Once detonation actually publishes RW, consume it with Backstab
            -- before low-value setup/fillers. Merely owning RW is never permission
            -- to stab from the front or count an unobserved Tactical Advantage.
            if weakness and volatile_strike then
                selected = consider(state, Ability.Backstab, "revealing_weakness_backstab", options)
                if selected then return selected end
            end
            if owned_crippling_wounds(state) and volatile and not poison and not volatile_strike then
                selected = dart() -- Periodic poison does not spend Wounds' direct-hit crit.
                if selected then return selected end
            end
            local wounds_hit = crippling_wounds_followup(state, options)
            if wounds_hit then return wounds_hit end
            if state.progression.level43 == "Advanced Stealth" and state.activeStealth.present then
                selected = consider(state, Ability.Backstab, "active_stealth_backstab", options) or
                    consider(state, Ability.Spender, "active_stealth_laceration_autocrit", options) or
                    consider(state, builder, "active_stealth_builder_autocrit", options)
                if selected then return selected end
            end

            -- Natural poison-detonation mini-cycle: VS -> poison-preserving hit
            -- -> Slice. The hint is tied to confirmed activations and this target;
            -- every step is re-admitted and a blocked step always falls through.
            if volatile and not volatile_strike and
                state.progression.level39 == "Crippling Wounds" and
                Runtime.cripplingVolatileTarget == state.targetHandle then
                if Runtime.cripplingVolatileFiller ~= true then
                    selected = consider(state, Ability.Backstab, "volatile_cycle_backstab", options) or
                        consider(state, Ability.Spender, "volatile_cycle_laceration", options) or
                        consider(state, builder, "volatile_cycle_builder", options)
                else
                    selected = crippling_wounds_setup(state, options)
                end
                if selected then return selected end
            end
            selected = aoe_action(state, options)
            if selected then return selected end

            local volatile_ready, volatile_reason = ability_ready(state, Ability.VolatileSubstance)
            local minimum_lifetime = volatile_strike and gcd or
                CONCEALMENT_MIN_SETUP_LIFETIME_SECONDS
            state.volatileGate = not volatile_ready and volatile_reason or
                (not target_is_durable(state) and "target_not_durable") or
                (not lifetime_allows(state, minimum_lifetime) and "short_lived_target") or
                (state.volatile.present and "unexploded_substance_present") or
                (Runtime.volatileAttemptTarget == state.targetHandle and
                    state.now < Runtime.volatileAttemptUntil and "application_pending") or
                "checking_poison_trigger"
            if state.volatileGate == "checking_poison_trigger" then
                -- Do not overwrite an unused, real RW when Backstab is available.
                if weakness then
                    selected = consider(state, Ability.Backstab,
                        "revealing_weakness_before_next_substance", options)
                    if selected then return selected end
                end
                local detonate = volatile_strike and
                    consider(state, Ability.VeiledStrike, "volatile_strike_trigger_probe", options)
                state.volatileGate = (poison or detonate) and "trigger_ready" or "owned_poison_trigger_missing"
                if poison or detonate then
                    if acid_lash and acid and stacks == 0 then
                        local backstab = consider(state, Ability.Backstab, "volatile_cycle_refresh_probe", options)
                        if not backstab then
                            selected = consider(state, builder, "build_ta_before_volatile_cycle", options)
                            if selected then return selected end
                        end
                    end
                    selected = consider(state, Ability.VolatileSubstance,
                        detonate and "volatile_substance_veiled_trigger_ready" or
                            "volatile_substance_own_poison_observed", options)
                    if selected then return selected end
                end
            end

            -- At 51+ Backstab itself supplies the needed poison and Prey on the
            -- Weak benefit. Lower levels retain Dart setup, not a fictitious Acid Blade.
            if state.progression.acidBlade and not acid then
                selected = consider(state, Ability.Backstab,
                    weakness and "revealing_weakness_restore_acid_blade" or "restore_acid_blade", options)
                if selected then return selected end
            end
            if target_is_durable(state) and not poison and
                (state.progression.tacticalOpportunity or ability_state(state, Ability.VolatileSubstance).known) then
                selected = dart()
                if selected then return selected end
            end
            selected = crippling_wounds_setup(state, options)
            if selected then return selected end
            selected = consider(state, Ability.Backstab,
                weakness and "revealing_weakness_backstab" or "backstab", options)
            if selected then return selected end
            selected = crippling_throw_builder(state, options)
            if selected then return selected end
            -- Veiled Strike should generate TA before the regular spender while
            -- below the cap; do not leave its cooldown idle until completely empty.
            if stacks == nil or stacks < 2 then
                selected = consider(state, builder, "tactical_advantage_builder", options)
                if selected then return selected end
            end
            selected = consider(state, Ability.Spender, "laceration_spender", options)
            if selected then return selected end
            selected = dart() -- Optional sustained/ranged filler, not mandatory over Acid Blade.
            if selected then return selected end
            selected = crippling_free_filler(state, options)
            if selected then return selected end
        end
        local selected = consider(state, Ability.OverloadShot,
            "mobile_or_ranged_paid_filler", options)
        if selected then return selected end
        return consider(state, Ability.RifleShot, "free_filler", options)
    end

    local function can_queue(state, options)
        if state.now < Runtime.contentionUntil then return false, "command_contention" end
        local remaining, reason = action_lock(state)
        if type(remaining) ~= "number" then return false, reason end
        if remaining > (options.abilityQueueWindow or 0.20) then
            return false, "locked_for=" .. string.format("%.3f", remaining)
        end
        return true, "queue_open"
    end

    local function progression_log(state, options)
        local signature = table.concat({
            tostring(state.progression.level23 or "none"),
            tostring(state.progression.level27 or "none"),
            tostring(state.progression.level39 or "none"),
            tostring(state.progression.level43 or "none"),
            tostring(state.progression.level51 or "none"),
            tostring(state.progression.level64 or "none"),
            tostring(state.progression.level68 or "none"),
            tostring(state.progression.level73 or "none"),
            tostring(state.progression.acidBlade), tostring(state.progression.revealingWeakness),
            tostring(state.concealmentTactical),
            tostring(ability_state(state, Ability.VeiledStrike).known),
            tostring(state.progression.fatality == true),
            tostring(ability_state(state, Ability.CorrosiveDart).known == true),
            tostring(ability_state(state, Ability.CorrosiveGrenade).known == true),
            tostring(ability_state(state, Ability.ToxicHaze).known == true),
            tostring(ability_state(state, Ability.ToxicBlast).known == true),
            tostring(ability_state(state, Ability.Backstab).known == true),
            tostring(ability_state(state, Ability.Spender).known == true),
            tostring(ability_state(state, Ability.StimBoost).known == true),
        }, "|")
        if Runtime.lastProgression == signature then return end
        Runtime.lastProgression = signature
        emit(options, "info", "operative progression: route=" .. spec.owner ..
            " level23=" .. tostring(state.progression.level23 or "none") ..
            " level27=" .. tostring(state.progression.level27 or "none") ..
            " level39=" .. tostring(state.progression.level39 or "none") ..
            " level43=" .. tostring(state.progression.level43 or "none") ..
            " level51=" .. tostring(state.progression.level51 or "none") ..
            " level64=" .. tostring(state.progression.level64 or "none") ..
            " level68=" .. tostring(state.progression.level68 or "none") ..
            " level73=" .. tostring(state.progression.level73 or "none") ..
            " tactical_setting=" .. tostring(state.concealmentTactical) ..
            " builder=" .. concealment_builder(state).id ..
            " acid_blade=" .. bool_text(state.progression.acidBlade) ..
            " revealing_weakness=" .. bool_text(state.progression.revealingWeakness) ..
            " prey_on_the_weak=" .. bool_text(state.progression.preyOnTheWeak) ..
            " calculated_frenzy=" .. bool_text(state.progression.calculatedFrenzy) ..
            " fatality=" .. bool_text(state.progression.fatality == true) ..
            " known{shiv=" .. bool_text(ability_state(state, Ability.Shiv).known == true) ..
            ",dart=" .. bool_text(ability_state(state, Ability.CorrosiveDart).known == true) ..
            ",grenade=" .. bool_text(ability_state(state, Ability.CorrosiveGrenade).known == true) ..
            ",haze=" .. bool_text(ability_state(state, Ability.ToxicHaze).known == true) ..
            ",blast=" .. bool_text(ability_state(state, Ability.ToxicBlast).known == true) ..
            ",backstab=" .. bool_text(ability_state(state, Ability.Backstab).known == true) ..
            ",spender=" .. bool_text(ability_state(state, Ability.Spender).known == true) ..
            "} bound{shiv=" .. bool_text(ability_state(state, Ability.Shiv).bound == true) ..
            ",dart=" .. bool_text(ability_state(state, Ability.CorrosiveDart).bound == true) ..
            ",backstab=" .. bool_text(ability_state(state, Ability.Backstab).bound == true) ..
            ",spender=" .. bool_text(ability_state(state, Ability.Spender).bound == true) ..
            "} costs{shiv=" .. optional_number(ability_state(state, Ability.Shiv).cost, "%.0f") ..
            ",dart=" .. optional_number(ability_state(state, Ability.CorrosiveDart).cost, "%.0f") ..
            ",backstab=" .. optional_number(ability_state(state, Ability.Backstab).cost, "%.0f") ..
            ",spender=" .. optional_number(ability_state(state, Ability.Spender).cost, "%.0f") .. "}")
    end
    local function decision_log(state, options, kind, detail)
        if options.decisionLog ~= true then return end
        local normalized = tostring(detail):gsub("locked_for=[%d.]+", "action_lock")
        local signature = table.concat({kind, normalized, tostring(state.targetHandle)}, "|")
        if Runtime.lastDecision == signature then return end
        local quiet = kind ~= "selected" and kind ~= "selected_offgcd"
        if quiet and state.now < (Runtime.nextWaitLogAt or 0) then return end
        if quiet then Runtime.nextWaitLogAt = state.now + 0.50 end
        Runtime.lastDecision = signature
        emit(options, "debug", "operative decision: route=" .. spec.owner ..
            " kind=" .. tostring(kind) .. " detail=" .. tostring(detail) ..
            " energy=" .. optional_number(state.energyPercent, "%.0f") ..
            " distance=" .. optional_number(state.targetDistance, "%.1f") ..
            " targets=" .. tostring(state.relevantTargets) ..
            " dot=" .. bool_text(state.dot.present and state.dot.mine) ..
            "/" .. tostring(state.dot.source or state.dot.status or "-") ..
            " grenade=" .. bool_text(state.grenade.present and state.grenade.mine) ..
            "/" .. tostring(state.grenade.source or state.grenade.status or "-") ..
            " fatality=" .. bool_text(state.fatality.present == true) ..
            "/" .. tostring(state.fatality.source or state.fatality.status or "-") ..
            " ta=" .. bool_text(state.tacticalAdvantage.present == true) ..
            "/" .. tostring(state.tacticalAdvantage.stacks or 0) ..
            "/" .. tostring(state.tacticalAdvantage.source or
                state.tacticalAdvantage.status or "-") ..
            " stealth=" .. bool_text(state.stealth.present == true) ..
            "/" .. tostring(state.stealth.status or "-") ..
            " target_yaw=" .. optional_number(state.targetRotation, "%.3f") ..
            " backstab_override=" .. tostring(state.backstabPositionOverride or "none") ..
            " acid_blade=" .. bool_text(state.acidBlade and state.acidBlade.present and state.acidBlade.mine) ..
            "/" .. optional_number(state.acidBlade and state.acidBlade.remaining, "%.2f") ..
            "/" .. tostring(state.acidBlade and state.acidBlade.status or "unavailable") ..
            " volatile=" .. bool_text(state.volatile and state.volatile.present and state.volatile.mine) ..
            "/" .. tostring(state.volatile and state.volatile.source or "unavailable") ..
            " volatile_remaining=" .. optional_number(state.volatileObserved and
                state.volatileObserved.remaining, "%.2f") ..
            " volatile_cd=" .. optional_number(ability_state(state, Ability.VolatileSubstance).cooldown, "%.2f") ..
            " volatile_gate=" .. tostring(state.volatileGate or "priority_not_reached") ..
            " target_lifetime=" .. optional_number(state.targetLifetime, "%.2f") ..
            " target=" .. tostring(state.targetHandle or "none") ..
            " revealing_weakness=" .. bool_text(state.revealingWeakness and
                state.revealingWeakness.present and state.revealingWeakness.mine) ..
            " tactical_setting=" .. tostring(state.concealmentTactical))
    end

    local function ability_diagnostics(state, options)
        if options.abilityDiagnostics ~= true or state.now - Runtime.lastDiagnosticAt < 2.0 then
            return
        end
        Runtime.lastDiagnosticAt = state.now
        local parts = {}
        for _, ability in ipairs(AbilityList) do
            local snapshot = ability_state(state, ability)
            if snapshot.known then
                parts[#parts + 1] = ability.id .. "=" ..
                    (snapshot.bound and "bound" or "unbound") .. "/" ..
                    (snapshot.resolved and "resolved" or "unresolved") .. "/" ..
                    (snapshot.ready and "ready" or "blocked") .. "/cost:" ..
                    optional_number(snapshot.cost, "%.0f") ..
                    "(" .. tostring(snapshot.costSource or "-") .. ")"
            end
        end
        emit(options, "debug", "operative abilities: route=" .. spec.owner ..
            " " .. table.concat(parts, ", "))
    end

    local function grant_ta_evidence(state, grace_seconds)
        Runtime.taEvidenceCount = math.min(2, math.max(0, Runtime.taEvidenceCount) + 1)
        local grace = type(grace_seconds) == "number" and
            math.max(0.0, grace_seconds) or TA_OBSERVATION_GRACE
        Runtime.taEvidenceUntil = state.now + grace
    end

    local function consume_ta_evidence(state)
        Runtime.taEvidenceCount = math.max(0, Runtime.taEvidenceCount - 1)
        Runtime.taEvidenceUntil = Runtime.taEvidenceCount > 0 and
            state.now + TA_OBSERVATION_GRACE or 0.0
    end

    local function timing_admission_reason(reason)
        return reason == "gcd" or reason == "cooldown"
    end

    local function shared_admission_gate(reason)
        return reason == "castability_pending" or reason == "melee_prequeue_deferred" or timing_admission_reason(reason) or reason == "busy" or
            reason == "executor_command_pending" or
            reason == "ability_submission_pending" or
            reason == "explicit_target_sync_pending" or
            reason == "ability_command_busy" or reason == "command_busy" or
            reason == "bridge_busy" or reason == "session_suspended" or
            reason == "line_of_sight" or reason == "not_in_line_of_sight" or
            reason == "target_not_visible" or reason == "invalid_target" or
            reason == "target_dead"
    end

    local function defer_timing_admission(state, result, reason, options, ability_id)
        local ready_ms = type(result) == "table" and
            (result.ready_in_ms or result.wait_ms) or nil
        local delay
        if type(ready_ms) == "number" then
            delay = clamp(ready_ms / 1000.0 - 0.010, 0.010, 0.200)
        elseif type(state.gcdRemaining) == "number" then
            delay = clamp(state.gcdRemaining - 0.010, 0.010, 0.200)
        else
            delay = 0.015
        end
        Runtime.contentionUntil = math.max(Runtime.contentionUntil,
            state.now + delay)
        if options.decisionLog == true then
            emit(options, "debug", "operative timing retry: route=" .. spec.owner ..
                " ability=" .. tostring(ability_id) .. " reason=" .. tostring(reason) ..
                " retry_ms=" .. tostring(math.floor(delay * 1000 + 0.5)))
        end
    end

    local function command_started(status)
        local function positive_sequence(value)
            return type(value) == "number" and value > 0
        end
        return type(status) == "table" and (
            status.core.acknowledged == true or status.core.state == "acknowledged" or
            status.core.state == "started" or
            positive_sequence(status.ability_activate_event_sequence) or
            positive_sequence(status.activation_event_sequence) or
            positive_sequence(status.post_terminal_activation_sequence) or
            positive_sequence(status.post_terminal_replication_sequence))
    end

    local function consumes_active_stealth(ability)
        return ability == Ability.RifleShot or ability == Ability.Shiv or
            ability == Ability.VeiledStrike or ability == Ability.OverloadShot or ability == Ability.FragmentationGrenade or
            ability == Ability.Backstab or ability == Ability.NoxiousKnives or
            ability == Ability.CripplingSlice or ability == Ability.CripplingThrow or
            ability == Ability.Spender
    end

    local function apply_acceptance(state, pending)
        if pending.acceptanceApplied == true then return end
        pending.acceptanceApplied = true
        -- A terminal submitted receipt proves transport, not engine activation.
        -- Never fabricate TA, Stealth consumption, poison, proc, or forced sequence
        -- state until command_started() supplied actual lifecycle evidence.
        if pending.acknowledged ~= true then return end
        if is_lethality then
            -- Only a fresh engine effect sample supplies TA/poison/proc state.
            -- Do not count a generator twice when replication precedes acknowledgement.
            local a = pending.ability
            if a == Ability.Shiv or a == Ability.StimBoost or a == Ability.Backstab or
                a == Ability.ToxicBlast or a == Ability.ToxicHaze or a == Ability.Spender then
                Runtime.taActivationAt = state.now
            end
            if a == Ability.Shiv or a == Ability.Spender then
                Runtime.fatalityActivationAt = state.now
            end
            if a == Ability.Spender and pending.taBefore == 1 and pending.hadFatality ~= true and
                state.progression.level23 == "Corrosive Return" and
                state.now >= Runtime.corrosiveReturnReadyAt and state.tacticalAdvantage.status == "ready" and
                state.tacticalAdvantage.present then
                Runtime.corrosiveReturnReadyAt = state.now + 10.0
            end
            if a == Ability.Backstab and pending.fromStealth then
                Runtime.stealthLatched = false
                Runtime.stealthConsumedUntil = state.now + 1.0
            end
            return
        end
        local a = pending.ability
        if a == Ability.Shiv or a == Ability.VeiledStrike or
            a == Ability.StimBoost or a == Ability.Backstab or
            a == Ability.ToxicHaze or a == Ability.Spender or a == Ability.CripplingThrow then
            Runtime.taActivationAt = state.now
            Runtime.taEvidenceCount = 0
            Runtime.taEvidenceUntil = 0.0
        end
        if a == Ability.Backstab then
            Runtime.backstabActivationAt = math.max(Runtime.backstabActivationAt, state.now)
        end
        if a == Ability.CorrosiveDart and pending.targetHandle ~= nil then
            Runtime.dotKnownUntil[pending.targetHandle] = nil
            Runtime.dotAttemptTarget = pending.targetHandle
            Runtime.dotAttemptUntil = state.now + DOT_OBSERVATION_GRACE
        elseif a == Ability.VolatileSubstance and pending.targetHandle ~= nil then
            Runtime.volatileGraceUntil[pending.targetHandle] =
                state.now + VOLATILE_OBSERVATION_GRACE
            Runtime.volatileAttemptTarget = pending.targetHandle
            Runtime.volatileAttemptUntil = state.now + VOLATILE_OBSERVATION_GRACE
        end
        if a.offGcd ~= true then
            -- Confirmed hostile activation ends Stealth. Keep this fact through
            -- observation outages and Mouse4 taps; never infer it from submission.
            Runtime.stealthLastKnown = false
            Runtime.stealthLatched = false
            Runtime.stealthEvidenceAt = state.now
            Runtime.stealthEventGap = false
            if a == Ability.Backstab and pending.fromStealth then
                Runtime.stealthConsumedUntil = state.now + 3.0
                Runtime.stealthAwaitingAbsent = true
            end
        end
        if spec.discipline == "Concealment" and
            consumes_active_stealth(pending.ability) and
            not (pending.ability == Ability.Backstab and pending.fromStealth == true) then
            Runtime.activeStealthArmedAt = -math.huge
            Runtime.activeStealthEvidenceUntil = 0.0
            Runtime.activeStealthConsumedUntil = state.now + 1.0
        end

    end

    local function service_pending(state, options)
        local pending = Runtime.pending
        if type(pending) ~= "table" then return owns_pending() end
        local status = executor:status()
        local same = type(status) == "table" and status.idempotency_key == pending.key
        if same and command_started(status) and pending.acknowledged ~= true then
            pending.acknowledged = true
            apply_acceptance(state, pending)
        end
        if executor:owns_command() then return true end
        if not same then
            Runtime.pending = nil
            return false
        end

        local terminal_state = tostring(status.core.state or "unknown")
        if pending.acknowledged ~= true then
            if terminal_state == "submitted" then
                apply_acceptance(state, pending)
                Runtime.failureBackoff[failure_key(pending.ability, pending.targetHandle)] = math.max(
                    Runtime.failureBackoff[failure_key(pending.ability, pending.targetHandle)] or 0.0,
                    state.now + ACCEPTED_UNCONFIRMED_BACKOFF)
                emit(options, "debug", "operative submitted without activation proof: route=" ..
                    spec.owner .. " ability=" .. pending.ability.id)
            else
                local reason = tostring(status.reason or terminal_state or "terminal_without_start")
                if timing_admission_reason(reason) then
                    defer_timing_admission(state, status, reason, options, pending.ability.id)
                else
                    if not shared_admission_gate(reason) then
                    Runtime.failureBackoff[failure_key(pending.ability, pending.targetHandle)] = state.now + FAILURE_BACKOFF
                    end
                    if reason == "busy" or reason == "executor_command_pending" or
                        reason == "ability_command_busy" or reason == "command_busy" or
                        reason == "ability_submission_pending" or
                        reason == "explicit_target_sync_pending" or
                        reason == "bridge_busy" then
                        Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                            state.now + CONTENTION_BACKOFF)
                    elseif reason == "session_suspended" then
                        Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                            state.now + 0.75)
                    elseif reason == "line_of_sight" or
                        reason == "not_in_line_of_sight" or
                        reason == "target_not_visible" or
                        reason == "invalid_target" or reason == "target_dead" then
                        Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                            state.now + FAILURE_BACKOFF)
                    end
                    emit(options, "warn", "operative command terminal without start: route=" ..
                        spec.owner .. " ability=" .. pending.ability.id .. " reason=" .. reason)
                end
            end
        end
        Runtime.pending = nil
        -- Consume the terminal tick: state was sampled before lifecycle/effect evidence changed.
        return true
    end

    local function submit(state, selected, options, phase)
        local ability = selected.ability
        local target = nil
        if ability.targetless ~= true then
            target = state.target
        end
        if phase ~= "offgcd" and type(state.gcdRemaining) == "number" and
            state.gcdRemaining > READY_SLACK and
            (ability == Ability.Shiv or ability == Ability.VeiledStrike or
                ability == Ability.Backstab or ability == Ability.Spender or
                ability == Ability.CripplingSlice or ability == Ability.CripplingThrow) then
            Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                state.now + math.max(0.010, state.gcdRemaining - READY_SLACK))
            return false, "melee_prequeue_deferred"
        end
        local request_handle = ability.targetless == true and
            state.playerHandle or state.targetHandle
        local key = table.concat({ spec.owner, phase or "regular", ability.id,
            tostring(request_handle or "none") }, ":")
        Runtime.nativeAdmission = nil
        local result = Mirror.submit(executor, CurrentLoadout, ability.id, target, {
            idempotencyKey = key, target_fallback = target ~= nil and "none" or nil,
        })
        local core = type(result) == "table" and type(result.core) == "table" and result.core or {}
        local admission_pending = type(result) == "table" and
            result.admission_pending == true
        if type(result) == "table" and (result.accepted == true or admission_pending) then
            local contract_ok = core.fallback_used ~= true and core.target_fallback == "none" and
                ((ability.targetless == true and core.target_mode == "none") or
                 (ability.targetless ~= true and core.target_mode == "explicit" and
                  core.target_valid == true and core.requested_target_handle == state.targetHandle and
                  core.target_handle == state.targetHandle))
            if ability == Ability.ShieldProbe then
                -- Same omitted-target native-none contract as Lethality's shield.
                -- This self-only ability must never borrow the selected enemy or
                -- an explicit-target override. Other ability contracts are unchanged.
                contract_ok = core.target_mode == "none" and core.target_valid ~= true and
                    core.target_handle == nil and core.requested_target_handle == nil and
                    core.target_override ~= true and core.fallback_used ~= true
            end
            if not contract_ok then
                local status = executor:status()
                if executor:owns_command() and type(status) == "table" and status.idempotency_key == key then
                    executor:cancel("concealment_target_contract")
                end
                decision_log(state, options, "target_contract_mismatch", ability.id)
                Runtime.nativeAdmission = nil
                return false, "target_contract_mismatch"
            end
            if admission_pending then
                Runtime.nativeAdmission = {
                    selected = selected,
                    phase = phase,
                    key = key,
                    abilityHandle = ability_state(state, ability).abilityHandle,
                    playerHandle = state.playerHandle,
                    actorEpoch = state.world and state.world.actor_epoch or nil,
                    targetHandle = ability.targetless ~= true and
                        state.targetHandle or nil,
                }
                decision_log(state, options, "waiting_admission", ability.id .. ":castability_pending")
                return false, "castability_pending" -- No command, effect evidence or retry timer.
            end
        end
        Runtime.nativeAdmission = nil
        if type(result) ~= "table" or result.accepted ~= true then
            local reason = type(result) == "table" and
                tostring(result.reason or result.code or "cast_failed") or "invalid_result"
            if timing_admission_reason(reason) then
                defer_timing_admission(state, result.core, reason, options, ability.id)
                return false, reason
            end
            if not shared_admission_gate(reason) then
            Runtime.failureBackoff[failure_key(ability, state.targetHandle)] = state.now + FAILURE_BACKOFF
            end
            if reason == "busy" or reason == "executor_command_pending" or
                reason == "ability_command_busy" or reason == "command_busy" or
                reason == "ability_submission_pending" or
                reason == "explicit_target_sync_pending" or reason == "bridge_busy" then
                Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                    state.now + CONTENTION_BACKOFF)
            elseif reason == "session_suspended" then
                Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                    state.now + 0.75)
            elseif reason == "line_of_sight" or
                reason == "not_in_line_of_sight" or
                reason == "target_not_visible" or
                reason == "invalid_target" or reason == "target_dead" then
                Runtime.contentionUntil = math.max(Runtime.contentionUntil,
                    state.now + FAILURE_BACKOFF)
            end
            emit(options, "warn", "operative cast failed: route=" .. spec.owner ..
                " ability=" .. ability.id .. " reason=" .. reason)
            return false, reason
        end
        if ability == Ability.CorrosiveDart then
            Runtime.dotAttemptTarget = state.targetHandle
            Runtime.dotAttemptUntil = state.now + 1.25
        elseif ability == Ability.CorrosiveGrenade then
            Runtime.grenadeAttemptTarget = state.targetHandle
            Runtime.grenadeAttemptUntil = state.now + 1.25
        elseif ability == Ability.VolatileSubstance then
            Runtime.volatileAttemptTarget = state.targetHandle
            Runtime.volatileAttemptUntil = state.now + 1.25
        elseif ability == Ability.StimBoost then
            Runtime.stimAttemptUntil = state.now + 1.50
        elseif ability == Ability.AdrenalineProbe then
            Runtime.probeAttemptUntil = state.now + 1.50
        elseif ability == Ability.TacticalOverdrive then
            Runtime.tacticalOverdriveAttemptUntil = state.now + 1.50
        end
        Runtime.pending = {
            ability = ability, key = key, targetHandle = state.targetHandle,
            reason = selected.reason,
            submittedAt = state.now,
            taBefore = is_lethality and tactical_advantage_stacks(state) or nil,
            hadFatality = state.fatality.present == true,
            fromStealth = ability == Ability.Backstab and state.stealth.present == true,
            acknowledged = false, acceptanceApplied = false,
        }
        if options.castLog == true then
            emit(options, "info", "operative cast queued: route=" .. spec.owner ..
                " ability=" .. ability.id .. " reason=" .. tostring(selected.reason))
        end
        return true, "submitted"
    end

    local function service_native_admission(state, options)
        local intent = Runtime.nativeAdmission
        if not intent then return false end
        local snapshot = ability_state(state, intent.selected.ability)
        local actor_epoch = state.world and state.world.actor_epoch or nil
        local same_target = intent.selected.ability.targetless == true or
            state.targetHandle == intent.targetHandle
        if state.playerHandle ~= intent.playerHandle or
            intent.actorEpoch ~= nil and actor_epoch ~= nil and
                actor_epoch ~= intent.actorEpoch or
            snapshot.abilityHandle ~= intent.abilityHandle or not same_target then
            Runtime.nativeAdmission = nil
            return false
        end
        submit(state, intent.selected, options, intent.phase)
        return true
    end

    local function reset_transient(clear_backoff)
        Runtime.nativeAdmission = nil
        Runtime.pending = nil
        Runtime.cripplingVolatileTarget = nil
        Runtime.cripplingVolatileFiller = false
        Runtime.woundsConsumedTarget = nil
        Runtime.woundsConsumedAt = nil
        Runtime.dotAttemptTarget = nil
        Runtime.dotAttemptUntil = 0.0
        Runtime.grenadeAttemptTarget = nil
        Runtime.grenadeAttemptUntil = 0.0
        Runtime.volatileAttemptTarget = nil
        Runtime.volatileAttemptUntil = 0.0
        Runtime.volatileGraceUntil = {}
        Runtime.fatalityEvidenceUntil = 0.0
        Runtime.fatalityConsumedUntil = 0.0
        Runtime.stimAttemptUntil = 0.0
        Runtime.probeAttemptUntil = 0.0
        Runtime.tacticalOverdriveAttemptUntil = 0.0
        -- Tactical Opportunity is a real 10s internal cooldown. Do not make it
        -- appear ready merely because Mouse4 was released between two GCDs.
        Runtime.taEvidenceCount = 0
        Runtime.taEvidenceUntil = 0.0
        Runtime.backstabActivationAt = -math.huge
        Runtime.stealthConsumedUntil = 0.0
        Runtime.stealthLatched = false
        Runtime.stealthLastKnown = nil
        Runtime.stealthEvidenceAt = nil
        Runtime.stealthEventGap = false
        Runtime.activeStealthArmedAt = -math.huge
        Runtime.activeStealthEvidenceUntil = 0.0
        Runtime.activeStealthConsumedUntil = 0.0
        Runtime.lastDecision = nil
        if clear_backoff then
            Runtime.failureBackoff = {}
            Runtime.contentionUntil = 0.0
            Runtime.dotKnownUntil = {}
            Runtime.grenadeKnownUntil = {}
            Runtime.grenadeGraceUntil = {}
        end
    end

    local function stop(reason)
        Runtime.lastDecision = nil
        Runtime.nativeAdmission = nil
        if owns_pending() then
            executor:cancel(reason or (spec.owner .. "_route_inactive"))
            return owns_pending()
        end
        if reason ~= "rotation_inactive" then reset_transient(true) end
        return false
    end

    local function offer_idle_self_heal(state, options, reason)
        if is_lethality or stealth_opener_required(state, options) or
            type(options.selfHealFiller) ~= "function" then return false end
        local ok, handled = pcall(options.selfHealFiller, reason)
        if not ok then
            emit(options, "warn", "DPS idle self-heal callback failed: " .. tostring(handled))
        elseif handled == true then
            decision_log(state, options, "selected_self_heal_idle", reason)
            return true
        end
        return false
    end

    local function tick(loadout, active, options)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        options = type(options) == "table" and options or {}
        if not is_selected(loadout) then return false end
        local state = read_state(loadout, options)
        state.concealmentTactical = options.concealmentTactical or "Unknown / Other"
        if is_lethality then
            lethality_context(state, options)
        else
            refresh_target_count(state, options)
            concealment_lifetime_context(state)
        end
        -- Hold semantics are authoritative even while a route-owned command is
        -- queued. Releasing Mouse4 must cancel a cancellable pre-dispatch command
        -- immediately instead of silently allowing one more attack to start.
        if active ~= true then
            stop("rotation_inactive")
            return true
        end
        progression_log(state, options)
        ability_diagnostics(state, options)
        if service_pending(state, options) then
            decision_log(state, options, "command_pending", spec.owner)
            return true
        end
        if executor:owns_command() then
            decision_log(state, options, "foreign_pending", "executor")
            return true
        end
        if service_native_admission(state, options) then
            decision_log(state, options, "waiting_admission", spec.owner)
            return true
        end
        local shield = select_shield_probe(state, options)
        if shield then
            decision_log(state, options, "selected_offgcd", shield.ability.id .. ":" .. shield.reason)
            submit(state, shield, options, "offgcd")
            return true
        end
        local target_ok, target_reason = valid_target(state)
        if not target_ok then
            -- No damage target is a recovery opportunity, not a reason to omit
            -- the shared healer entirely. Do not offer work for a dead/missing player.
            if target_reason ~= "missing_player" and target_reason ~= "player_dead" and
                offer_idle_self_heal(state, options, target_reason) then return true end
            decision_log(state, options, "waiting_target", target_reason)
            return true
        end
        local offgcd = select_offgcd(state, options)
        if offgcd then
            decision_log(state, options, "selected_offgcd",
                offgcd.ability.id .. ":" .. offgcd.reason)
            submit(state, offgcd, options, "offgcd")
            return true -- Reselect from fresh state; never switch requests mid-tick.
        end
        local queueable, queue_reason = can_queue(state, options)
        if not queueable then
            decision_log(state, options, "waiting_lock", queue_reason)
            return true
        end
        do -- One live-admission attempt per decision tick.
            local selected = select_priority(state, options)
            if not selected then
                if offer_idle_self_heal(state, options, "no_castable_priority") then return true end
                decision_log(state, options, "no_decision",
                    "no_castable_priority " .. table.concat(state.blockedReasons or {}, ";"))
                return true
            end
            if type(options.selfHealFiller)=="function" and
                (selected.ability==Ability.RifleShot or selected.ability==Ability.OverloadShot) then
                local callback_ok,handled,pooling=pcall(options.selfHealFiller,selected.ability.id)
                if not callback_ok then
                    emit(options,"warn","DPS self-heal filler callback failed: "..tostring(handled))
                elseif handled==true then
                    decision_log(state,options,"selected_self_heal_filler",selected.ability.id)
                    return true
                elseif pooling==true and selected.ability~=Ability.RifleShot then
                    local free=consider(state,Ability.RifleShot,"self_heal_energy_pool",options)
                    if not free then return true end
                    selected=free
                end
            end
            decision_log(state, options, "selected",
                selected.ability.id .. ":" .. selected.reason)
            submit(state, selected, options, "regular")
            return true
        end
    end

    local function observe_events(batch, loadout, player_handle)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        if not is_selected(loadout) or type(batch) ~= "table" then return end
        if type(batch.dropped) == "number" and batch.dropped > 0 then
            -- A lost event could be a manual Stealth activation. Never retain
            -- absence as permission to attack across an explicitly lost stream.
            Runtime.stealthLastKnown = nil
            Runtime.stealthLatched = false
            Runtime.stealthConsumedUntil = 0.0
            Runtime.stealthEvidenceAt = nil
            Runtime.stealthEventGap = true
        end
        local now = (gos.time_ms() or 0) / 1000.0
        for _, event in ipairs(batch.events or {}) do
            local event_name = Mirror.canonical(CurrentLoadout, event.name)
            if not is_lethality and event.source_handle == player_handle then
                local target = event.target_handle
                if event.kind == "ability" and event.action == "ability_activate" then
                    if event_name == "Volatile Substance" then
                        Runtime.cripplingVolatileTarget = target
                        Runtime.cripplingVolatileFiller = false
                    elseif event_name == "Crippling Slice" then
                        Runtime.cripplingVolatileTarget = nil
                        Runtime.cripplingVolatileFiller = false
                    elseif target and target == Runtime.cripplingVolatileTarget and
                        (event_name == "Backstab" or event_name == "Laceration" or
                            event_name == "Shiv" or event_name == "Veiled Strike" or
                            event_name == "Overload Shot" or
                            event_name == "Rifle Shot" or event_name == "Toxic Haze") then
                        Runtime.cripplingVolatileFiller = true
                    end
                elseif event.kind == "damage" and target then
                    local damage_at = finite(event.timestamp) and event.timestamp / 1000.0 or now
                    if event_name == "Crippling Slice" then
                        Runtime.woundsConsumedTarget = nil
                        Runtime.woundsConsumedAt = nil
                    elseif event_name == "Backstab" or event_name == "Laceration" or
                        event_name == "Shiv" or event_name == "Veiled Strike" or
                        event_name == "Overload Shot" or
                        event_name == "Rifle Shot" or event_name == "Volatile Substance" or
                        event_name == "Fragmentation Grenade" or event_name == "Noxious Knives" then
                        Runtime.woundsConsumedTarget = target
                        Runtime.woundsConsumedAt = damage_at
                    end
                end
            end
            if event.source_handle == player_handle and event.kind == "ability" and
                event.action == "ability_activate" then
                local activated_at = finite(event.timestamp) and event.timestamp / 1000.0 or now
                if event_name == "Backstab" then
                    Runtime.backstabActivationAt = math.max(Runtime.backstabActivationAt, activated_at)
                end
                if not is_lethality and (event_name == "Backstab" or event_name == "Veiled Strike" or
                    event_name == "Shiv" or event_name == "Laceration" or event_name == "Toxic Haze" or
                    event_name == "Crippling Throw" or event_name == "Stim Boost") then
                    Runtime.taActivationAt = math.max(Runtime.taActivationAt, activated_at)
                end
                if event_name == "Stealth" or event_name == "Cloaking Screen" then
                    Runtime.stealthLastKnown = true
                    Runtime.stealthLatched = true
                    Runtime.stealthConsumedUntil = 0.0
                    Runtime.stealthAwaitingAbsent = false
                    Runtime.stealthEvidenceAt = now
                    Runtime.stealthEventGap = false
                else
                    for _, ability in ipairs(AbilityList) do
                        if event_name == ability.id and ability.offGcd ~= true then
                            Runtime.stealthLastKnown = false
                            Runtime.stealthLatched = false
                            Runtime.stealthEvidenceAt = now
                            Runtime.stealthEventGap = false
                            break
                        end
                    end
                end
            end
        end
    end

    -- Infusion is cast by the shared self-healing helper, not this damage route.
    -- Fence older charge samples; never subtract from an already updated sample.
    local function observe_self_heal_ta(activation_time)
        if not finite(activation_time) then return end
        Runtime.taActivationAt=math.max(Runtime.taActivationAt or -math.huge,activation_time)
        Runtime.taEvidenceCount,Runtime.taEvidenceUntil=0,0
    end
    return {
        build_id = "concealment80-r4-exact-admission-retry",
        observe_events = observe_events,
        observe_self_heal_ta = observe_self_heal_ta,
        is_selected = is_selected,
        has_local_pending = function()
            return Runtime.nativeAdmission ~= nil or owns_pending()
        end,
        owns_pending = owns_pending,
        stop = stop,
        tick = tick,
    }
end

return M
