-- Loadout-aware Seer healing route for scripts/live/sage.lua.
--
-- The route scales from the early Seer kit into the level-80 healing surface
-- strictly through gos.abilities.loadout().known. Optional abilities/talents
-- are never inferred from character level. Every ally cast uses a current-
-- generation friendly GosUnit with selected-target fallback disabled.

local Cleanse = require("combat.cleanse")
assert(Cleanse.supports_tier_filter == true,
    "Seer requires the shared r4 tier-filter cleanse helper")
local PressureTracker = require("combat.pressure_tracker")
local PressureFormula = PressureTracker.Formula
local ForceOptimizer = require("sage.force_optimizer")
local HealingScheduler = require("sage.healing_scheduler")
local Mirror = require("sage.mirror")
local M = {}
local CurrentLoadout

local EXPECTED_STYLE = "sage"
local EXPECTED_DISCIPLINE = "Seer"
local OWNER_PREFIX = "seer:"
local MAX_FRIENDLIES = 512
local MAX_HOSTILES = 512
local MAX_EVENT_DRAIN_PASSES = 4
local SALVATION_RADIUS_METERS = 8.0
local WANDERING_MEND_RADIUS_METERS = 20.0
local HEAL_RANGE_METERS = 30.0
local FORCEQUAKE_RADIUS_METERS = 4.0
local FORCEQUAKE_COUNT_REFRESH_MS = 100
local DECISION_LOG_INTERVAL_MS = 250
local METERS_PER_WORLD_UNIT = 10.0
local DEFAULT_DPS_FORCE_RESERVE_PERCENT = 40
local ALTRUISM_REFRESH_WINDOW_SECONDS = 5.0
local AMNESTY_CASH_WINDOW_SECONDS = 2.0
local EMERGENCY_HEAL_RATIO = 0.60
local LIFE_SAVING_HEAL_RATIO = 0.20
local DEFAULT_CLEANSE_MIN_REMAINING_SECONDS = 0.8
local DEFAULT_CLEANSE_PRESSURE_HP_RATIO = 0.90
local DEFAULT_DPS_MIN_ALLY_HP_RATIO = 0.95

local HealingStyle = {
    Safe = {
        healStart = 0.98,
        healingTrance = 0.94,
        wanderingMend = 0.90,
        filler = 0.85,
    },
    Balanced = {
        healStart = 0.95,
        healingTrance = 0.90,
        wanderingMend = 0.85,
        filler = 0.80,
    },
    Efficient = {
        healStart = 0.90,
        healingTrance = 0.85,
        wanderingMend = 0.80,
        filler = 0.75,
    },
}

-- Seer's localized level-15 replacement of the base Force Armor node.
local FORCE_ARMOR_CANDIDATES = {
    "Preserved Force Armor",
    "Mending Force Armor",
    "Force Armor",
}
-- Republic/Imperial shields are mutually exclusive at the target. A Seer must
-- honor every observed shield/lockout mirror, not only the selected local
-- ability label, or SWTOR can reject the press before AbilityActivate.
local FORCE_ARMOR_BLOCKING_BUFFS = {
    "Preserved Force Armor",
    "Mending Force Armor",
    "Force Armor",
    "Static Barrier",
}
local FORCE_ARMOR_BLOCKING_DEBUFFS = {
    "Force-imbalanced",
    "Deionized",
    -- Core can expose the shield lockout as a same-name mine debuff rather
    -- than the historical Force-imbalanced label. Treat all armor labels as
    -- lockout debuffs so native B934 does not reject a repeated shield before
    -- the request reaches the wire.
    "Preserved Force Armor",
    "Mending Force Armor",
    "Force Armor",
    "Static Barrier",
}
local ALTRUISM = "Altruism"
local AMNESTY = "Amnesty"
local BENEVOLENCE = "Benevolence"
local CONVEYANCE = "Conveyance"
local FORCE_BARRIER = "Force Barrier"
local FORCE_MEND = "Force Mend"
local FORCE_MOBILITY = "Force Mobility"
local FORCE_POTENCY = "Force Potency"
local FORCE_SHELTER = "Force Shelter"
local HEALING_TRANCE = "Healing Trance"
local MENTAL_ALACRITY = "Mental Alacrity"
local REJUVENATE = "Rejuvenate"
local REJUVENATING_AURA = "Rejuvenating Aura"
local RENEWAL = "Renewal"
local RESPLENDENCE = "Resplendence"
local RESURGING_POWER = "Resurging Power"
local POTENT_RESOLVE = "Potent Resolve"
local SALVATION = "Salvation"
local SOOTHING_PROTECTION = "Soothing Protection"
local VINDICATE = "Vindicate"
local WANDERING_MEND = "Wandering Mend"
local WEAKEN_MIND = "Weaken Mind"
local FORCEQUAKE = "Forcequake"
local MIND_CRUSH = "Mind Crush"
local PROJECT = "Project"
local TELEKINETIC_REGENERATION = "Telekinetic Regeneration"
local TELEKINETIC_THROW = "Telekinetic Throw"
local DISTURBANCE = "Disturbance"
local WEARY = "Weary"

-- Eligibility and cross-class effect definitions live in the shared Cleanse catalog.

local DpsAbility = {
    [WEAKEN_MIND] = true,
    [FORCEQUAKE] = true,
    [MIND_CRUSH] = true,
    [PROJECT] = true,
    [TELEKINETIC_THROW] = true,
    [DISTURBANCE] = true,
}

local Stationary = {
    [BENEVOLENCE] = true,
    [SALVATION] = true,
    ["Keeper of Peace"] = true,
    ["Deliverance"] = true,
    [FORCEQUAKE] = true,
    [MIND_CRUSH] = true,
    [TELEKINETIC_THROW] = true,
    [DISTURBANCE] = true,
}
local function finite_number(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function healing_policy(options)
    local configured = type(options) == "table" and options.healing or nil
    configured = type(configured) == "table" and configured or {}

    local style_name = type(configured.style) == "string" and configured.style or
        "Balanced"
    local style = HealingStyle[style_name] or HealingStyle.Balanced
    if HealingStyle[style_name] == nil then
        style_name = "Balanced"
    end

    local target_mode = type(configured.targets) == "string" and
        configured.targets or "All Friendlies"
    if target_mode ~= "Players only" and
        target_mode ~= "Players + Companions" and
        target_mode ~= "All Friendlies" then
        target_mode = "All Friendlies"
    end
    local triage_mode = type(configured.triageMode) == "string" and
        configured.triageMode or PressureFormula.MODE_PRESSURE
    if triage_mode ~= PressureFormula.MODE_PRESSURE then
        triage_mode = PressureFormula.MODE_HP
    end

    local force_mend_percent = finite_number(configured.forceMendHpPercent) and
        clamp(configured.forceMendHpPercent, 1, 100) or 90
    local salvation_minimum = finite_number(configured.salvationMinAllies) and
        math.floor(clamp(configured.salvationMinAllies, 2, 8) + 0.5) or 3
    local vindicate_percent = finite_number(configured.vindicateBelowPercent) and
        clamp(configured.vindicateBelowPercent, 1, 99) or 85
    local cleanse_min_remaining = finite_number(configured.cleanseMinRemaining) and
        clamp(configured.cleanseMinRemaining, 0, 3) or
        DEFAULT_CLEANSE_MIN_REMAINING_SECONDS
    local cleanse_pressure_hp = finite_number(configured.cleansePressureHpPercent) and
        clamp(configured.cleansePressureHpPercent, 1, 100) / 100 or
        DEFAULT_CLEANSE_PRESSURE_HP_RATIO

    return {
        triageMode = triage_mode,
        style = style_name,
        targets = target_mode,
        healStart = style.healStart,
        healingTrance = style.healingTrance,
        wanderingMend = style.wanderingMend,
        filler = style.filler,
        autoForceArmor = configured.autoForceArmor ~= false,
        preShieldIncoming = configured.preShieldIncoming ~= false,
        autoForceMend = configured.autoForceMend == true,
        forceMend = force_mend_percent / 100,
        autoCleanse = configured.autoCleanse ~= false,
        cleanseSelf = configured.cleanseSelf ~= false,
        cleanseAllies = configured.cleanseAllies ~= false,
        cleansePhysical = configured.cleansePhysical ~= false,
        cleansePressure = configured.cleansePressure ~= false,
        cleansePressureHp = cleanse_pressure_hp,
        cleanseMinRemaining = cleanse_min_remaining,
        autoMentalAlacrity = configured.autoMentalAlacrity ~= false,
        autoForcePotency = configured.autoForcePotency ~= false,
        salvationMinAllies = salvation_minimum,
        autoVindicate = configured.autoVindicate ~= false,
        vindicateBelow = vindicate_percent / 100,
    }
end

local function healable_type(unit_type, policy)
    if unit_type == "player" then
        return true
    end
    if unit_type == "companion" then
        return policy.targets ~= "Players only"
    end
    if unit_type == "npc" then
        return policy.targets == "All Friendlies"
    end
    return false
end

local function safe_method(unit, name, ...)
    if not unit or type(unit[name]) ~= "function" then
        return nil
    end
    local ok, value = pcall(unit[name], unit, ...)
    if not ok then
        return nil
    end
    return value
end

local function emit(options, level, message)
    local logger = type(options) == "table" and options.logLine or nil
    if type(logger) == "function" then
        logger(level, message)
    end
end

local function number_text(value, decimals)
    if type(value) ~= "number" then
        return "?"
    end
    return string.format("%." .. tostring(decimals or 0) .. "f", value)
end

local function is_selected(loadout)
    loadout = Mirror.adapt_loadout(loadout)
    return type(loadout) == "table" and loadout.status == "ready" and
        loadout.combat_style == EXPECTED_STYLE and
        loadout.discipline == EXPECTED_DISCIPLINE
end

local function selected_force_armor(known)
    if type(known) ~= "table" then
        return nil
    end
    for _, name in ipairs(FORCE_ARMOR_CANDIDATES) do
        if known[name] == true then
            return name
        end
    end
    return nil
end

local function selected_filler(known)
    if type(known) ~= "table" then
        return nil
    end
    if known["Keeper of Peace"] == true then
        return "Keeper of Peace"
    end
    if known["Deliverance"] == true then
        return "Deliverance"
    end
    return nil
end

local function requires_stationary(known, name, instant)
    if instant == true then
        return false
    end
    if name == HEALING_TRANCE then
        return known[FORCE_MOBILITY] ~= true
    end
    return Stationary[name] == true
end

local function validated_loadout(loadout)
    loadout = Mirror.adapt_loadout(loadout)
    if not is_selected(loadout) or type(loadout.known) ~= "table" then
        return nil
    end
    for _, name in ipairs({
        BENEVOLENCE,
        REJUVENATE,
        HEALING_TRANCE,
        SALVATION,
    }) do
        if loadout.known[name] ~= true then
            return nil
        end
    end
    local armor = selected_force_armor(loadout.known)
    local filler = selected_filler(loadout.known)
    if armor == nil or filler == nil then
        return nil
    end
    return {
        known = loadout.known,
        armor = armor,
        filler = filler,
    }
end

local function living_hp(hp)
    return type(hp) == "table" and finite_number(hp.current) and
        finite_number(hp.max) and hp.max > 0 and hp.current > 0 and
        hp.current <= hp.max
end

local function valid_hp(hp)
    return living_hp(hp) and hp.current < hp.max
end
-- Forecasts may promote only the shared v2 urgent bands. Routine
-- pressure (bands 2/3) never displaces a materially lower-HP patient.
local function pressure_band(row, policy, hp)
    local p = row and row.pressure
    if policy.triageMode ~= PressureFormula.MODE_PRESSURE or
        type(row) ~= "table" or type(p) ~= "table" or
        p.pressure_model ~= "idf_v2_persistence" or
        not finite_number(p.fast_pressure) or p.fast_pressure <= 0 or
        not finite_number(p.projected_hp_2s) or p.projected_hp_2s < 0 or
        p.projected_hp_2s > 1 or not finite_number(p.ttd) or p.ttd < 0 then
        return nil
    end
    if hp and (hp.current ~= row.current or hp.max ~= row.maximum) then
        return nil
    end
    if not finite_number(p.hp_percent) or
        p.hp_percent ~= row.current / row.maximum then
        return nil
    end
    local band = p.risk_band
    if band == 0 or band == 1 then return band end
    return nil
end

local function pressure_urgent(row, policy, hp)
    return pressure_band(row, policy, hp) ~= nil
end

local function triage_band(row, policy)
    if type(row) ~= "table" or not finite_number(row.current) or
        not finite_number(row.maximum) or row.maximum <= 0 then
        return 2
    end
    local ratio = row.current / row.maximum
    local actual = ratio <= LIFE_SAVING_HEAL_RATIO and 0 or
        (ratio <= EMERGENCY_HEAL_RATIO and 1 or 2)
    return math.min(actual, pressure_band(row, policy) or 2)
end

local function triage_less(lhs, rhs, policy)
    local left_band, right_band = triage_band(lhs, policy), triage_band(rhs, policy)
    if left_band ~= right_band then return left_band < right_band end
    if left_band < 2 then
        if lhs.current ~= rhs.current then return lhs.current < rhs.current end
        local left_ratio = lhs.current / lhs.maximum
        local right_ratio = rhs.current / rhs.maximum
        if left_ratio ~= right_ratio then return left_ratio < right_ratio end
    end
    local left_ratio = lhs.current / lhs.maximum
    local right_ratio = rhs.current / rhs.maximum
    if left_ratio ~= right_ratio then return left_ratio < right_ratio end
    local left_missing = lhs.maximum - lhs.current
    local right_missing = rhs.maximum - rhs.current
    if left_missing ~= right_missing then return left_missing > right_missing end
    return lhs.handle < rhs.handle
end

local function actionable_hp(hp, policy)
    return valid_hp(hp) and hp.current <= hp.max * policy.healStart
end

local function valid_position(position)
    return type(position) == "table" and finite_number(position.x) and
        finite_number(position.y) and finite_number(position.z)
end

local function within_heal_range(unit)
    local distance = safe_method(unit, "distance")
    return finite_number(distance) and distance >= 0 and
        distance * METERS_PER_WORLD_UNIT <= HEAL_RANGE_METERS
end

local function friendlier(current, maximum, handle, rhs)
    if rhs == nil then
        return true
    end
    local lhs_ratio = current * rhs.maximum
    local rhs_ratio = rhs.current * maximum
    if lhs_ratio ~= rhs_ratio then
        return lhs_ratio < rhs_ratio
    end
    local lhs_missing = maximum - current
    local rhs_missing = rhs.maximum - rhs.current
    if lhs_missing ~= rhs_missing then
        return lhs_missing > rhs_missing
    end
    return handle < rhs.handle
end

local function maintenance_friendlier(current, maximum, handle, player_handle, rhs)
    if rhs == nil then
        return true
    end
    local lhs_ratio = current * rhs.maximum
    local rhs_ratio = rhs.current * maximum
    if lhs_ratio ~= rhs_ratio then
        return lhs_ratio < rhs_ratio
    end
    local lhs_missing = maximum - current
    local rhs_missing = rhs.maximum - rhs.current
    if lhs_missing ~= rhs_missing then
        return lhs_missing > rhs_missing
    end
    local lhs_self = handle == player_handle
    local rhs_self = rhs.handle == player_handle
    if lhs_self ~= rhs_self then
        return not lhs_self
    end
    return handle < rhs.handle
end

local function collect_injured(world, policy, player_handle)
    local ok, units = pcall(world.units, world, { reaction = "friendly" })
    if not ok or type(units) ~= "table" or #units > MAX_FRIENDLIES then
        return nil
    end

    local lowest
    local maintenance
    local friendlies = {}
    local injured = {}
    local seen = {}
    local observation = { complete = true, minRatio = 1.0, eligible = 0 }
    local function add(unit)
        local handle = safe_method(unit, "handle")
        local unit_type = safe_method(unit, "type")
        local hp = safe_method(unit, "hp")
        if type(handle) == "string" and seen[handle] then return end
        if type(handle) == "string" then
            seen[handle] = true
            friendlies[#friendlies + 1] = unit
        end
        if type(handle) == "string" and healable_type(unit_type, policy) then
            if not living_hp(hp) then
                local dead = type(hp) == "table" and finite_number(hp.current) and
                    finite_number(hp.max) and hp.max > 0 and hp.current == 0
                if not dead then observation.complete = false end
            else
                local is_self = handle == player_handle
                local unit_distance = is_self and 0 or safe_method(unit, "distance")
                if not is_self and
                    (not finite_number(unit_distance) or unit_distance < 0) then
                    observation.complete = false
                elseif unit_distance * METERS_PER_WORLD_UNIT <= HEAL_RANGE_METERS then
                    local position = safe_method(unit, "position")
                    local positioned = valid_position(position)
                    local row = {
                        unit = unit,
                        handle = handle,
                        current = hp.current,
                        maximum = hp.max,
                        x = positioned and position.x or nil,
                        y = positioned and position.y or nil,
                        z = positioned and position.z or nil,
                    }
                    observation.eligible = observation.eligible + 1
                    observation.minRatio = math.min(observation.minRatio,
                        hp.current / hp.max)
                    if maintenance_friendlier(hp.current, hp.max, handle,
                            player_handle, maintenance) then
                        maintenance = row
                    end
                    -- Evaluate IDF before the HP cutoff. Only urgent v2 bands
                    -- may later bypass the ordinary healing-style threshold.
                    if actionable_hp(hp, policy) or
                        policy.triageMode == PressureFormula.MODE_PRESSURE and valid_hp(hp) then
                        injured[#injured + 1] = row
                        if actionable_hp(hp, policy) and
                            friendlier(hp.current, hp.max, handle, lowest) then
                            lowest = row
                        end
                    end
                end
            end
        end
    end
    -- Match Combat Medic's stable roster boundary: self is authoritative from
    -- world.player and must not disappear when a friendly scan omits it or its
    -- derived distance is temporarily unavailable.
    add(world.player)
    for index = 1, #units do
        add(units[index])
    end
    return friendlies, lowest, #injured, maintenance, injured, observation
end

local function resolve_friendly(world, handle, injured_only, policy, pressure_row)
    local player = world and world.player or nil
    local is_self = safe_method(player, "handle") == handle
    local ok, unit = true, player
    if not is_self then
        ok, unit = pcall(world.resolve, world, handle)
    end
    if not ok or not unit or safe_method(unit, "handle") ~= handle or
        not is_self and safe_method(unit, "reaction") ~= "friendly" or
        not healable_type(safe_method(unit, "type"), policy) then
        return nil
    end
    local hp = safe_method(unit, "hp")
    if not living_hp(hp) or
        injured_only == true and not actionable_hp(hp, policy) and
        not (valid_hp(hp) and pressure_row and pressure_row.handle == handle and
            pressure_urgent(pressure_row, policy, hp)) then
        return nil
    end
    if not is_self and not within_heal_range(unit) then
        return nil
    end
    return unit
end

local function resolve_injured(world, handle, policy, pressure_row)
    return resolve_friendly(world, handle, true, policy, pressure_row)
end

local function ability_state(known, name)
    if known[name] ~= true then
        return nil
    end
    local actual = Mirror.ability(CurrentLoadout, name)
    if actual == nil then return nil end
    local info = gos.abilities.info(actual)
    if type(info) ~= "table" or type(info.ability_handle) ~= "string" or
        info.has_resource_cost ~= true or not finite_number(info.resource_cost) or
        info.resource_cost < 0 then
        return nil
    end
    return {
        cost = info.resource_cost,
        ability_handle = info.ability_handle,
    }
end

local function minimum_positive_cost(...)
    local best
    for index = 1, select("#", ...) do
        local state = select(index, ...)
        if type(state) == "table" and finite_number(state.cost) and
            state.cost > 0 and (best == nil or state.cost < best) then
            best = state.cost
        end
    end
    return best
end

local function exact_advisory(name, unit, handle)
    local actual = Mirror.ability(CurrentLoadout, name)
    if actual == nil then return "blocked", "mirror_name_unavailable" end
    local result = gos.abilities.can_cast(actual, unit)
    if type(result) ~= "table" then
        return "blocked", "invalid_can_cast_result"
    end
    if result.target_mode ~= "explicit" or result.target_valid ~= true or
        result.requested_target_handle ~= handle or result.target_handle ~= handle or
        result.target_fallback ~= "none" or result.fallback_used == true then
        return "blocked", "explicit_target_contract"
    end
    if result.ok == true then
        return "ready", "ready"
    end
    local reason = tostring(result.reason or result.code or "blocked")
    local codes = gos.abilities.result_codes or {}
    if result.code == codes.cooldown then
        return "unavailable", reason
    end
    return "blocked", reason
end

local function exact_resource_blocked_state(known, name, unit, handle, force)
    local state = ability_state(known, name)
    if state == nil or state.cost <= force or state.cost <= 0 then
        return nil
    end
    local actual = Mirror.ability(CurrentLoadout, name)
    if actual == nil then return nil end
    local result = gos.abilities.can_cast(actual, unit)
    if type(result) ~= "table" or result.ok == true or
        result.target_mode ~= "explicit" or result.target_valid ~= true or
        result.requested_target_handle ~= handle or
        result.target_handle ~= handle or
        result.target_fallback ~= "none" or result.fallback_used == true then
        return nil
    end
    local codes = gos.abilities.result_codes or {}
    if result.code == codes.insufficient_resource then
        return state
    end
    -- The repository simulator deliberately keeps validation-only result codes
    -- outside Core's shipped range and calls this one "resource". Accept it
    -- only when the live insufficient_resource symbol does not exist.
    if codes.insufficient_resource == nil and codes.resource ~= nil and
        result.code == codes.resource then
        return state
    end
    return nil
end

local function untargeted_advisory(name)
    local actual = Mirror.ability(CurrentLoadout, name)
    if actual == nil then return "blocked", "mirror_name_unavailable" end
    local result = gos.abilities.can_cast(actual)
    if type(result) ~= "table" then
        return "blocked", "invalid_can_cast_result"
    end
    if result.target_mode ~= "none" or result.target_valid == true or
        result.requested_target_handle ~= nil or result.target_handle ~= nil or
        result.target_fallback ~= "none" or result.fallback_used == true then
        return "blocked", "no_external_target_contract"
    end
    if result.ok == true then
        return "ready", "ready"
    end
    local reason = tostring(result.reason or result.code or "blocked")
    local codes = gos.abilities.result_codes or {}
    if result.code == codes.cooldown then
        return "unavailable", reason
    end
    return "blocked", reason
end

local function selected_advisory(name, handle)
    local actual = Mirror.ability(CurrentLoadout, name)
    if actual == nil then return "blocked", "mirror_name_unavailable" end
    local result = gos.abilities.can_cast(actual)
    if type(result) ~= "table" then
        return "blocked", "invalid_can_cast_result"
    end
    if result.target_mode ~= "selected" or result.target_valid ~= true or
        result.target_handle ~= handle or result.fallback_used == true or
        result.target_override == true then
        return "blocked", "selected_target_contract"
    end
    if result.ok == true then
        return "ready", "ready"
    end
    local reason = tostring(result.reason or result.code or "blocked")
    local codes = gos.abilities.result_codes or {}
    if result.code == codes.cooldown then
        return "unavailable", reason
    end
    return "blocked", reason
end

local function submission_status(result, accepted)
    if accepted then return "submitted" end
    if type(result) == "table" then
        if result.blocks_submission == true then return "owned" end
        if result.admission_pending == true then return "admission_pending" end
    end
    return "blocked"
end

local function try_submit(executor, known, name, unit, handle, force, moving,
        instant, state, untargeted, selected, resume_native)
    if state == nil then
        return "blocked", false, nil, "ability_state_unavailable"
    end
    if state.cost > force then
        return "unavailable", false, nil, "insufficient_force"
    end
    if moving and requires_stationary(known, name, instant) then
        return "unavailable", false, nil, "requires_stationary"
    end

    local advisory, gate
    if resume_native then
        -- cast() revalidates admission. Requiring another advisory sample here
        -- can miss the pending live sample, which is visible for one tick.
        advisory, gate = "ready", "native_retry"
    elseif selected then
        advisory, gate = selected_advisory(name, handle)
    elseif untargeted then
        advisory, gate = untargeted_advisory(name)
    else
        advisory, gate = exact_advisory(name, unit, handle)
    end
    if advisory ~= "ready" then
        return advisory, false, nil, gate
    end

    local result
    local accepted
    if selected then
        result = executor:submit(name, nil, {
            idempotencyKey = "seer:" .. name .. ":" .. handle,
        })
        local core = type(result) == "table" and
            type(result.core) == "table" and result.core or {}
        accepted = type(result) == "table" and result.accepted == true and
            core.target_mode == "selected" and core.target_valid == true and
            core.target_handle == handle and core.fallback_used ~= true and
            core.target_override ~= true
    elseif untargeted then
        result = executor:submit(name, nil, {
            idempotencyKey = "seer:" .. name .. ":untargeted",
        })
        local core = type(result) == "table" and type(result.core) == "table" and result.core or {}
        accepted = type(result) == "table" and result.accepted == true and
            core.target_mode == "none" and core.target_valid ~= true and
            core.requested_target_handle == nil and core.target_handle == nil and
            core.target_fallback == "none" and core.fallback_used ~= true
    else
        result = executor:submit(name, unit, {
            idempotencyKey = "seer:" .. name .. ":" .. handle,
            target_fallback = "none",
        })
        local core = type(result) == "table" and type(result.core) == "table" and result.core or {}
        accepted = type(result) == "table" and result.accepted == true and
            core.target_mode == "explicit" and core.target_valid == true and
            core.requested_target_handle == handle and
            core.target_handle == handle and core.target_fallback == "none" and
            core.fallback_used ~= true
    end
    local submit_gate = type(result) == "table" and
        tostring(result.reason or result.code or (accepted and "submitted" or "blocked")) or
        "invalid_cast_result"
    return submission_status(result, accepted), accepted, result, submit_gate
end

local function observed_effect_state(unit, name, kind, literal_name)
    local actual, query = name, { kind = kind }
    if not literal_name then actual, query = Mirror.effect_query(CurrentLoadout, name, query) end
    if actual == nil then return nil end
    local effect = safe_method(unit, "effect", actual, query)
    if type(effect) ~= "table" or effect.status ~= "ready" then
        return nil
    end
    if effect.present ~= true then
        return false
    end
    return effect
end

local function observed_effect(unit, name, kind, literal_name)
    local effect = observed_effect_state(unit, name, kind, literal_name)
    if effect == nil then
        return nil
    end
    return effect ~= false
end

local function mine_effect_present(unit, name, kind)
    local effect = observed_effect_state(unit, name, kind)
    if effect == nil then
        return nil
    end
    return effect ~= false and effect.mine == true
end

local function observed_stacks(unit, name, kind)
    local effect = observed_effect_state(unit, name, kind)
    if type(effect) ~= "table" then
        return effect == false and 0 or nil
    end
    if effect.has_charges == true and type(effect.stacks) == "number" then
        return effect.stacks
    end
    return nil
end

local function action_proc_markers(known, name, unit)
    if type(known) ~= "table" or
        (name ~= BENEVOLENCE and name ~= "Deliverance" and
            name ~= "Keeper of Peace" and name ~= HEALING_TRANCE and
            name ~= SALVATION and name ~= WANDERING_MEND and
            name ~= FORCE_MEND and name ~= REJUVENATE and
            name ~= VINDICATE) then
        return nil
    end
    local world = gos.world()
    local player = world and world.player or nil
    if not player then
        return nil
    end
    local markers = {}
    local function add(label, detail)
        markers[#markers + 1] = { label = label, detail = detail }
    end

    if name == BENEVOLENCE and known[ALTRUISM] == true and
        observed_effect(player, ALTRUISM, "buff") == true then
        add("Altruism", "+60% heal / instant / free")
    end

    if known[CONVEYANCE] == true and
        observed_effect(player, CONVEYANCE, "buff") == true then
        if name == BENEVOLENCE then
            add("Conveyance", "+60% crit")
        elseif name == "Deliverance" or name == "Keeper of Peace" then
            add("Conveyance", "-0.5s cast")
        elseif name == HEALING_TRANCE then
            add("Conveyance", "+25% crit")
        elseif name == SALVATION then
            add("Conveyance", "instant cast")
        elseif name == WANDERING_MEND then
            add("Conveyance", "immediate jumps")
        end
    end

    if known[RESURGING_POWER] == true and
        (name == BENEVOLENCE or name == "Deliverance" or
            name == "Keeper of Peace") then
        local stacks = observed_stacks(player, RESURGING_POWER, "buff")
        if finite_number(stacks) and stacks > 0 then
            stacks = math.max(1, math.min(3, math.floor(stacks + 0.5)))
            add("Resurging Power x" .. tostring(stacks),
                "+" .. tostring(stacks * 5) .. "% heal")
        end
    end

    if known[FORCE_POTENCY] == true and
        observed_effect(player, FORCE_POTENCY, "buff") == true and
        (name == BENEVOLENCE or name == "Deliverance" or
            name == "Keeper of Peace" or name == HEALING_TRANCE or
            name == FORCE_MEND) then
        add("Force Potency", "+60% crit")
    end

    if name == HEALING_TRANCE and known[POTENT_RESOLVE] == true and
        observed_effect(player, MENTAL_ALACRITY, "buff") == true then
        add("Potent Resolve", "+3% heal")
    end

    if name == REJUVENATE and
        (known[RENEWAL] == true or known[FORCE_SHELTER] == true) and
        mine_effect_present(unit, REJUVENATE, "buff") == true then
        add("Renewal", "Force Shelter refresh burst")
    end

    if name == VINDICATE and known[RESPLENDENCE] == true then
        local stacks = observed_stacks(player, RESPLENDENCE, "buff")
        if finite_number(stacks) and stacks > 0 then
            stacks = math.max(1, math.min(3, math.floor(stacks + 0.5)))
            add("Resplendence x" .. tostring(stacks), "+5 Force / no Weary")
        end
    end

    return #markers > 0 and markers or nil
end

local function armor_allowed(unit, armor_name)
    local sorcerer = CurrentLoadout and CurrentLoadout._sage_mirror_style == "sorcerer"
    if sorcerer and (observed_effect(unit, "Imbued Force Armor", "buff", true) ~= false or
        observed_effect(unit, "Imbued Force Armor", "debuff", true) ~= false or
        observed_effect(unit, "Sustaining Darkness", "buff", true) ~= false) then return false end
    -- Query both factions literally so another healer's shield is never renamed.
    for _, name in ipairs(FORCE_ARMOR_BLOCKING_DEBUFFS) do
        if observed_effect(unit, name, "debuff", true) ~= false then
            return false
        end
    end
    local selected_seen = false
    for _, name in ipairs(FORCE_ARMOR_BLOCKING_BUFFS) do
        if name == armor_name then
            selected_seen = true
        end
        if observed_effect(unit, name, "buff", true) ~= false then
            return false
        end
    end
    if not selected_seen and
        observed_effect(unit, armor_name, "buff", true) ~= false then
        return false
    end
    return observed_effect(unit, SOOTHING_PROTECTION, "buff", true) == false
end

local function hp_ratio(current, maximum)
    if not finite_number(current) or not finite_number(maximum) or maximum <= 0 then
        return nil
    end
    return current / maximum
end

local function optimizer_presence(effect)
    if type(effect) == "table" then return true end
    if effect == false then return false end
    return nil
end

local function optimizer_remaining(effect)
    if type(effect) == "table" and effect.has_timer == true and
        finite_number(effect.remaining) then
        return math.max(0, effect.remaining)
    end
    return nil
end

local function force_optimizer_state(known, resource, policy, reserve_force,
        resplendence_state, resplendence_stacks,
        amnesty_state, weary_state, weary_stacks)
    return {
        enabled = policy.autoVindicate == true,
        vindicate_known = known[VINDICATE] == true,
        resplendence_known = known[RESPLENDENCE] == true,
        current = resource.current,
        maximum = resource.max,
        reserve = reserve_force,
        soft_fraction = policy.vindicateBelow,
        resplendence_present = optimizer_presence(resplendence_state),
        resplendence_stacks = resplendence_stacks,
        resplendence_remaining = optimizer_remaining(resplendence_state),
        amnesty_present = optimizer_presence(amnesty_state),
        amnesty_remaining = optimizer_remaining(amnesty_state),
        weary_present = optimizer_presence(weary_state),
        weary_stacks = weary_stacks,
        weary_remaining = optimizer_remaining(weary_state),
    }
end

local function configured_force_reserve(resource, options)
    local dps = type(options) == "table" and options.dps or nil
    local percent = type(dps) == "table" and finite_number(dps.forceReservePercent) and
        clamp(dps.forceReservePercent, 0, 100) or DEFAULT_DPS_FORCE_RESERVE_PERCENT
    if type(resource) ~= "table" or not finite_number(resource.max) or
        resource.max <= 0 then
        return math.huge
    end
    return resource.max * percent / 100
end

local function configured_dps_min_ally_ratio(options, heal_start)
    local dps = type(options) == "table" and options.dps or nil
    local percent = type(dps) == "table" and finite_number(dps.minAllyHpPercent) and
        clamp(dps.minAllyHpPercent, 50, 100) or
        DEFAULT_DPS_MIN_ALLY_HP_RATIO * 100
    local ratio = percent / 100
    -- A stale/saved high DPS all-clear value must not create downtime when the
    -- active Seer healing style says no heal is needed. Effective DPS safety is
    -- capped by healStart; below healStart, healing still preempts damage.
    if finite_number(heal_start) and heal_start > 0 and heal_start <= 1 then
        ratio = math.min(ratio, heal_start)
    end
    return ratio
end

local function distance_squared(lhs, rhs)
    local dx = lhs.x - rhs.x
    local dy = lhs.y - rhs.y
    local dz = lhs.z - rhs.z
    return dx * dx + dy * dy + dz * dz
end

local function forcequake_target_count(world, target, radius_meters)
    if not world or not target or safe_method(target, "reaction") ~= "hostile" then
        return nil, "hostile_target_unavailable"
    end
    local target_position = safe_method(target, "position")
    if not valid_position(target_position) then
        return nil, "target_position_unavailable"
    end
    local ok, units = pcall(world.units, world, { reaction = "hostile" })
    if not ok or type(units) ~= "table" or #units > MAX_HOSTILES then
        return nil, "hostile_unit_list_unavailable"
    end

    local radius_world = clamp(radius_meters, 1.0, 12.0) /
        METERS_PER_WORLD_UNIT
    local radius_squared = radius_world * radius_world
    local target_handle = safe_method(target, "handle")
    local counted_target = false
    local count = 0
    for index = 1, #units do
        local unit = units[index]
        local handle = safe_method(unit, "handle")
        local is_target = safe_method(unit, "is_current_target") == true or
            target_handle ~= nil and handle == target_handle
        local hp = safe_method(unit, "hp")
        local position = safe_method(unit, "position")
        if safe_method(unit, "reaction") == "hostile" and living_hp(hp) and
            valid_position(position) and
            distance_squared(position, target_position) <= radius_squared then
            count = count + 1
        end
        if is_target then
            counted_target = true
        end
    end
    if not counted_target then
        count = count + 1
    end
    return clamp(count, 1, 8), "target_centered"
end

local function injured_cluster_count(injured, center, radius_meters)
    if type(center) ~= "table" or center.x == nil then
        return 0
    end
    local radius_world = radius_meters / METERS_PER_WORLD_UNIT
    local radius_squared = radius_world * radius_world
    local count = 0
    for index = 1, #injured do
        local row = injured[index]
        if row.x ~= nil and distance_squared(center, row) <= radius_squared then
            count = count + 1
        end
    end
    return count
end

local function best_salvation_center(injured, minimum, player_handle)
    if #injured < minimum then
        return nil, 0
    end
    local best
    local best_count = 0
    for index = 1, #injured do
        local candidate = injured[index]
        if candidate.x ~= nil then
            local count = injured_cluster_count(injured, candidate,
                SALVATION_RADIUS_METERS)
            if count > best_count or
                count == best_count and count >= minimum and
                maintenance_friendlier(candidate.current, candidate.maximum,
                    candidate.handle, player_handle, best) then
                best = candidate
                best_count = count
            end
        end
    end
    if best_count < minimum then
        return nil, best_count
    end
    return best, best_count
end

local function best_wandering_center(injured, player_handle)
    if #injured < 2 then
        return nil, 0
    end
    local best
    local best_count = 0
    for index = 1, #injured do
        local candidate = injured[index]
        if candidate.x ~= nil then
            local count = injured_cluster_count(injured, candidate,
                WANDERING_MEND_RADIUS_METERS)
            if count > best_count or
                count == best_count and count >= 2 and
                maintenance_friendlier(candidate.current, candidate.maximum,
                    candidate.handle, player_handle, best) then
                best = candidate
                best_count = count
            end
        end
    end
    if best_count < 2 then
        return nil, best_count
    end
    return best, best_count
end

local function wandering_mend_active(units, policy)
    local saw_healable = false
    local saw_unknown = false
    for index = 1, #units do
        local unit = units[index]
        if healable_type(safe_method(unit, "type"), policy) then
            local hp = safe_method(unit, "hp")
            if living_hp(hp) then
                saw_healable = true
                local mine = mine_effect_present(unit, WANDERING_MEND, "buff")
                if mine == true then
                    return true
                end
                if mine == nil then
                    saw_unknown = true
                end
            end
        end
    end
    if not saw_healable or saw_unknown then
        return nil
    end
    return false
end

-- ponytail: predict only from the current exact targeted activation; add cast
-- timing or damage projection only when the public event contract proves it.
local function incoming_armor_target(world, events, policy)
    if type(events) ~= "table" then
        return nil
    end
    for index = 1, #events do
        local event = events[index]
        if type(event) == "table" and event.kind == "ability" and
            event.action == "ability_activate" and
            type(event.source_handle) == "string" and
            type(event.target_handle) == "string" then
            local source = safe_method(world, "resolve", event.source_handle)
            if source and safe_method(source, "reaction") == "hostile" then
                local target =
                    resolve_friendly(world, event.target_handle, false, policy)
                if target then
                    return target, event.target_handle
                end
            end
        end
    end
    return nil
end

function M.new(executor)
    assert(type(executor) == "table" and type(executor.submit) == "function" and
        type(executor.status) == "function",
        "sage.seer.new requires the top-level AbilityExecutor")

    local combat_cursor
    local pressure_hot_names = {
            -- Count only observed periodic healing identities. Rejuvenate also
            -- has an upfront heal, so treating every Rejuvenate heal event as
            -- future HoT carry would over-credit a patient after the initial hit.
            [RENEWAL] = true,
            [SALVATION] = true,
    }
    local pressure_tracker = PressureTracker.new({ hot_names = pressure_hot_names })
    local last_pressure_diagnostic_at = -math.huge
    local last_decision_by_route = {}
    local last_route_decision_log_at = -math.huge
    -- Cast failures are deduplicated per ability. A single global key lets an
    -- alternating priority list (Rejuvenate/Armor/Mend/Trance/Deliverance)
    -- re-log the same Core gate every tick and can flood the client log.
    local last_cast_failure_by_ability = {}
    local forcequake_count_cache
    local route_player_handle, route_actor_epoch
    local native_admission
    local admission_waiting = false

    local function resume_native_admission(name, handle, mode, state)
        return native_admission ~= nil and state ~= nil and
            native_admission.name == name and native_admission.handle == handle and
            native_admission.mode == mode and
            native_admission.ability_handle == state.ability_handle
    end

    local function record_native_admission(name, handle, mode, state, result, decision)
        if type(result) ~= "table" then return false end
        native_admission = nil
        if result.admission_pending == true and result.owns_command ~= true then
            admission_waiting = tostring(result.reason or "admission_pending")
            -- Core has one live-admission identity. Do not replace its request
            -- by submitting the next candidate before the next update.
            native_admission = { name = name, handle = handle, mode = mode, decision = decision,
                ability_handle = state.ability_handle }
        end
        return admission_waiting
    end

    local function action_in_progress(status)
        return status == "submitted" or status == "admission_pending" or status == "owned"
    end

    local function monotonic_ms()
        if type(gos.time_ms) ~= "function" then
            return nil
        end
        local value = gos.time_ms()
        return finite_number(value) and value or nil
    end

    local function cached_forcequake_target_count(world, target, handle)
        local now = monotonic_ms()
        local generation = world and world.generation or nil
        local cached = forcequake_count_cache
        if finite_number(now) and cached and cached.handle == handle and
            cached.generation == generation and now < cached.expires_ms then
            return cached.count
        end
        local count = forcequake_target_count(world, target,
            FORCEQUAKE_RADIUS_METERS)
        forcequake_count_cache = {
            handle = handle,
            generation = generation,
            count = count,
            expires_ms = finite_number(now) and
                now + FORCEQUAKE_COUNT_REFRESH_MS or 0,
        }
        return count
    end

    local function route_submit(options, decision, known, name, unit, handle,
            force, moving, instant, state, untargeted, action_meta, selected)
        if executor:owns_command() then
            return "owned", false, nil, "executor_command_pending"
        end
        if admission_waiting then
            return "admission_pending", false, nil, admission_waiting
        end
        state = state or ability_state(known, name)
        local mode = selected and "selected" or untargeted and "none" or "explicit"
        local resume_native = resume_native_admission(name, handle, mode, state)
        local target_type = untargeted == true and "none" or
            tostring(safe_method(unit, "type") or "unknown")
        local proc_markers = type(options) == "table" and
            type(options.onAction) == "function" and
            action_proc_markers(known, name, unit) or nil
        local status, accepted, result, gate = try_submit(executor, known, name, unit,
            handle, force, moving, instant, state, untargeted, selected, resume_native)
        if record_native_admission(name, handle, mode, state, result, decision) then
            status = "admission_pending"
        elseif resume_native then
            native_admission = nil
        end
        if type(options) == "table" and options.decisionLog == true then
            local route_key = table.concat({ tostring(name), tostring(decision),
                tostring(handle), target_type }, "|")
            local value_key = table.concat({
                tostring(status), tostring(gate or "-"),
                tostring(moving), tostring(instant == true),
            }, "|")
            local now = monotonic_ms()
            if last_decision_by_route[route_key] ~= value_key and
                (not finite_number(now) or
                    now - last_route_decision_log_at >= DECISION_LOG_INTERVAL_MS) then
                last_decision_by_route[route_key] = value_key
                if finite_number(now) then last_route_decision_log_at = now end
                emit(options, "debug",
                    "route=seer phase=decision" ..
                    " selected=" .. tostring(name) ..
                    " reason=" .. tostring(decision) ..
                    " status=" .. tostring(status) ..
                    " gate=" .. tostring(gate or "-") ..
                    " target=" .. tostring(handle) ..
                    " target_type=" .. target_type ..
                    " force=" .. number_text(force, 0) ..
                    " moving=" .. tostring(moving) ..
                    " instant=" .. tostring(instant == true))
            end
        end

        local new_command = accepted and result.new_command == true
        if new_command and untargeted ~= true and selected ~= true and
            type(result) == "table" and
            type(result.command_handle) == "string" and
            type(options) == "table" and
            type(options.onExplicitTargetCommand) == "function" then
            options.onExplicitTargetCommand(result.command_handle, name, handle)
        end

        if new_command and type(options) == "table" and
            type(options.onAction) == "function" then
            if type(proc_markers) == "table" and #proc_markers > 0 then
                action_meta = type(action_meta) == "table" and action_meta or {}
                action_meta.procs = proc_markers
            end
            options.onAction({
                ability = name,
                decision = decision,
                command_handle = type(result) == "table" and result.command_handle or nil,
                target_handle = handle,
                target_name = safe_method(unit, "name"),
                target_type = target_type,
                untargeted = untargeted == true,
                meta = action_meta,
            })
        end

        if type(options) == "table" and options.castLog == true and
            result ~= nil then
            if new_command then
                last_cast_failure_by_ability[name] = nil
                emit(options, "info",
                    "route=seer phase=cast queued=true" ..
                    " command=" .. tostring(result.command_handle or "-") ..
                    " command_state=" ..
                        tostring(result.core and result.core.command_state or "-") ..
                    " executor=" .. tostring(result.disposition or "-") ..
                    " ability=" .. tostring(name) ..
                    " reason=" .. tostring(decision) ..
                    " target=" .. tostring(handle) ..
                    " target_type=" .. target_type ..
                    " force=" .. number_text(force, 0))
            elseif not accepted then
                local failure_reason = type(result) == "table" and
                    (result.reason or result.code) or "invalid_cast_result"
                if last_cast_failure_by_ability[name] ~= failure_reason then
                    last_cast_failure_by_ability[name] = failure_reason
                    emit(options, "warn",
                        "route=seer phase=cast queued=false" ..
                        " ability=" .. tostring(name) ..
                        " decision=" .. tostring(decision) ..
                        " reason=" .. tostring(failure_reason))
                end
            end
        end
        return status, accepted, result, gate
    end

    local function route_submit_untargeted(options, decision, known, name,
            unit, handle, force, moving, instant, state)
        return route_submit(options, decision, known, name, unit, handle,
            force, moving, instant, state, true)
    end

    local function route_submit_selected(options, decision, known, name,
            unit, handle, force, moving, instant, state)
        return route_submit(options, decision, known, name, unit, handle,
            force, moving, instant, state, false, nil, true)
    end

    local function route_submit_force_potency_for_trance(
            options, decision, known, player, player_handle,
            target, target_handle, force, moving, force_potency_state)
        if not resume_native_admission(FORCE_POTENCY, player_handle, "none",
                force_potency_state) then
            local followup_status, followup_gate = exact_advisory(
                HEALING_TRANCE, target, target_handle)
            if followup_status ~= "ready" then
                return followup_status, false, nil, followup_gate
            end
        end

        -- Setup is admitted only for a currently usable follow-up. After it
        -- completes, the normal scheduler reads the actual Potency effect and
        -- chooses a fresh patient; no private reservation may block triage.
        return route_submit_untargeted(
            options, decision, known, FORCE_POTENCY,
            player, player_handle, force, moving, true,
            force_potency_state)
    end

    local function route_submit_ground(options, decision, known, name, handle,
            force, moving, state, reserve_force)
        if executor:owns_command() then
            return "owned", false, nil, "executor_command_pending"
        end
        if admission_waiting then return "admission_pending", false, nil, admission_waiting end
        state = state or ability_state(known, name)
        local resume_native = resume_native_admission(name, handle, "ground", state)
        local status = "blocked"
        local accepted = false
        local result
        reserve_force = finite_number(reserve_force) and reserve_force or 0
        if state ~= nil and not moving and state.cost <= force and
            (state.cost <= 0 or force - state.cost >= reserve_force) then
            local gcd = gos.abilities.gcd_remaining()
            local busy = gos.abilities.is_casting_or_channeling() == true
            local actual = Mirror.ability(CurrentLoadout, name)
            local advisory = not resume_native and actual and
                gos.abilities.can_cast(actual) or nil
            if type(gcd) == "number" and gcd <= 0.0 and not busy and
                (resume_native or type(advisory) == "table" and advisory.ok == true) then
                result = executor:submit(name, nil, {
                    idempotencyKey = "seer:" .. name .. ":" .. handle,
                })
                accepted = type(result) == "table" and result.accepted == true
                status = submission_status(result, accepted)
            elseif type(gcd) == "number" and gcd > 0.0 or busy then
                status = "blocked"
            else
                status = "unavailable"
            end
        else
            status = "unavailable"
        end
        if record_native_admission(name, handle, "ground", state, result, decision) then
            status = "admission_pending"
        elseif resume_native then
            native_admission = nil
        end

        if type(options) == "table" and options.decisionLog == true then
            local route_key = table.concat({ tostring(name), tostring(decision),
                tostring(handle), "ground" }, "|")
            local value_key = table.concat({ tostring(status),
                tostring(moving) }, "|")
            local now = monotonic_ms()
            if last_decision_by_route[route_key] ~= value_key and
                (not finite_number(now) or
                    now - last_route_decision_log_at >= DECISION_LOG_INTERVAL_MS) then
                last_decision_by_route[route_key] = value_key
                if finite_number(now) then last_route_decision_log_at = now end
                emit(options, "debug",
                    "route=seer phase=decision selected=" .. tostring(name) ..
                    " reason=" .. tostring(decision) ..
                    " status=" .. tostring(status) ..
                    " target=" .. tostring(handle) ..
                    " force=" .. number_text(force, 0) ..
                    " moving=" .. tostring(moving) .. " ground=true")
            end
        end
        local new_command = accepted and result.new_command == true
        if new_command and type(options) == "table" and
            type(options.onAction) == "function" then
            options.onAction({
                ability = name,
                decision = decision,
                command_handle = type(result) == "table" and result.command_handle or nil,
                target_handle = handle,
                target_name = nil,
                target_type = "ground",
                untargeted = false,
            })
        end

        if type(options) == "table" and options.castLog == true and result ~= nil then
            if new_command then
                last_cast_failure_by_ability[name] = nil
                emit(options, "info",
                    "route=seer phase=cast queued=true" ..
                    " command=" .. tostring(result.command_handle or "-") ..
                    " command_state=" .. tostring(result.core and result.core.command_state or "-") ..
                    " executor=" .. tostring(result.disposition or "-") ..
                    " ability=" .. tostring(name) ..
                    " reason=" .. tostring(decision) ..
                    " target=" .. tostring(handle) ..
                    " force=" .. number_text(force, 0) .. " ground=true")
            elseif not accepted then
                local failure_reason = type(result) == "table" and
                    (result.reason or result.code) or "invalid_cast_result"
                if last_cast_failure_by_ability[name] ~= failure_reason then
                    last_cast_failure_by_ability[name] = failure_reason
                    emit(options, "warn",
                        "route=seer phase=cast queued=false" ..
                        " ability=" .. tostring(name) ..
                        " decision=" .. tostring(decision) ..
                        " reason=" .. tostring(failure_reason))
                end
            end
        end
        return status, accepted, result,
            type(result) == "table" and result.reason or status
    end

    local function scheduler_gate_holds(status, gate)
        if status ~= "blocked" then return false end
        gate = tostring(gate or "blocked")
        return gate == "gcd" or gate == "busy" or
            gate == "ability_submission_pending" or
            gate == "explicit_target_sync_pending" or
            gate == "bridge_busy" or gate == "command_busy" or
            gate == "ability_command_busy" or
            gate == "executor_command_pending" or
            gate == "native_not_ready_gcd"
    end

    local function execute_healing_plan(plan, env)
        -- A stable fresh plan resumes its in-flight admission before retrying
        -- predecessors which already declined. A new patient, urgency, group
        -- target or earlier authored priority invalidates that preference.
        local prefixes, preferred = {}, nil
        local prefix = table.concat({ tostring(env.target_handle), tostring(env.severity),
            tostring(env.armor_name), tostring(env.filler_name),
            tostring(env.wandering_handle), tostring(env.salvation_handle) }, "|")
        for index, intent in ipairs(plan) do
            prefix = prefix .. "|" .. tostring(intent.id) .. ":" .. tostring(intent.reason)
            prefixes[index] = prefix
            if native_admission and native_admission.plan_prefix == prefix then preferred = index end
        end
        for step = 1, #plan do
            local index = step
            if preferred then
                if step == 1 then index = preferred
                elseif step <= preferred then index = step - 1 end
            end
            local intent = plan[index]
            local status, accepted, result, gate
            local id = intent.id
            local reason = intent.reason

            if id == "mental_alacrity" then
                status, accepted, result, gate = route_submit_untargeted(
                    env.options, reason, env.known, MENTAL_ALACRITY,
                    env.player, env.player_handle, env.force, env.moving, true,
                    env.mental_alacrity)
            elseif id == "force_potency" then
                status, accepted, result, gate = route_submit_force_potency_for_trance(
                    env.options, reason, env.known, env.player,
                    env.player_handle, env.target, env.target_handle,
                    env.force, env.moving, env.force_potency)
            elseif id == "force_mend" then
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, FORCE_MEND,
                    env.player, env.player_handle, env.force, env.moving, true,
                    env.force_mend)
            elseif id == "benevolence" then
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, BENEVOLENCE,
                    env.target, env.target_handle, env.force, env.moving, true,
                    env.benevolence)
            elseif id == "armor" then
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, env.armor_name,
                    env.target, env.target_handle, env.force, env.moving, true,
                    env.armor)
            elseif id == "rejuvenate" then
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, REJUVENATE,
                    env.target, env.target_handle, env.force, env.moving, true,
                    env.rejuvenate)
            elseif id == "trance" then
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, HEALING_TRANCE,
                    env.target, env.target_handle, env.force, env.moving, nil,
                    env.trance)
            elseif id == "wandering" then
                local unit = env.wandering_target or env.target
                local handle = env.wandering_handle or env.target_handle
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, WANDERING_MEND,
                    unit, handle, env.force, env.moving, true, env.wandering)
            elseif id == "salvation" then
                local unit = env.salvation_target or env.target
                local handle = env.salvation_handle or env.target_handle
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, SALVATION,
                    unit, handle, env.force, env.moving,
                    env.conveyance == true, env.salvation)
            elseif id == "filler" then
                status, accepted, result, gate = route_submit(
                    env.options, reason, env.known, env.filler_name,
                    env.target, env.target_handle, env.force, env.moving,
                    env.conveyance == true, env.filler)
            elseif id == "vindicate" then
                status, accepted, result, gate = route_submit_untargeted(
                    env.options, reason, env.known, VINDICATE,
                    env.player, env.player_handle, env.force, env.moving, true,
                    env.vindicate)
            end

            if status == "submitted" and accepted then
                -- Off-GCD is a game property, not permission to bypass the
                -- executor's single command owner. Re-plan after its tick.
                last_decision_by_route.scheduler_hold = nil
                return true, false
            end
            if status == "admission_pending" or status == "owned" then
                if result and native_admission and result.admission_pending == true then
                    native_admission.plan_prefix = prefixes[index]
                end
                return false, true
            end
            -- Only true timing/ownership gates may monopolize the tick.
            -- Structural unavailability (metadata/state loss, cooldown,
            -- movement, range/LOS/target rejection, resource) must fall through
            -- to the next authored action in the plan.
            if intent.hold ~= false and scheduler_gate_holds(status, gate) then
                local hold_key = table.concat({ tostring(id), tostring(reason),
                    tostring(gate or "blocked"), tostring(env.target_handle) }, "|")
                if type(env.options) == "table" and
                    env.options.decisionLog == true and
                    last_decision_by_route.scheduler_hold ~= hold_key then
                    last_decision_by_route.scheduler_hold = hold_key
                    emit(env.options, "debug",
                        "route=seer phase=scheduler_hold action=" ..
                        tostring(id) .. " reason=" .. tostring(reason) ..
                        " gate=" .. tostring(gate or "blocked"))
                end
                return false, true
            end
        end
        last_decision_by_route.scheduler_hold = nil
        return false, false
    end

    local function try_idle_dps(options, world, known, resource, moving)
        local dps = type(options) == "table" and options.dps or nil
        if type(dps) ~= "table" or dps.enabled ~= true then
            return false
        end

        local target = world and world.current_target or nil
        local handle = safe_method(target, "handle")
        local hp = safe_method(target, "hp")
        local reserve_force = configured_force_reserve(resource, options)
        if not target or type(handle) ~= "string" or
            safe_method(target, "reaction") ~= "hostile" or not living_hp(hp) then
            return false
        end

        local resumed_name
        local function submit_if_enabled(flag, name, effect_name)
            if name == resumed_name then return false end
            if flag ~= true or known[name] ~= true then
                return false
            end
            if effect_name ~= nil then
                local mine = mine_effect_present(target, effect_name, "debuff")
                if mine ~= false then
                    return false
                end
            end
            local state = ability_state(known, name)
            if state == nil or state.cost > 0 and
                resource.current - state.cost < reserve_force then
                return false
            end
            local status = route_submit_selected(options, "idle_dps", known, name,
                target, handle, resource.current, moving, nil, state)
            return action_in_progress(status)
        end

        local function submit_forcequake()
            if resumed_name == FORCEQUAKE or moving or dps.forcequake ~= true or
                known[FORCEQUAKE] ~= true then return false end
            local targets = cached_forcequake_target_count(world, target, handle)
            if type(targets) ~= "number" or targets < 2 then return false end
            local state = ability_state(known, FORCEQUAKE)
            if state == nil or state.cost > 0 and
                resource.current - state.cost < reserve_force then return false end
            return action_in_progress(route_submit_ground(options, "idle_dps_aoe", known,
                FORCEQUAKE, handle, resource.current, moving, state, reserve_force))
        end

        local pending = native_admission
        if pending and pending.handle == handle and
            (pending.mode == "ground" and pending.decision == "idle_dps_aoe" or
                pending.mode == "selected" and pending.decision == "idle_dps") then
            local consumed = false
            if pending.mode == "ground" and pending.decision == "idle_dps_aoe" then
                consumed = submit_forcequake()
            elseif pending.mode == "selected" and pending.decision == "idle_dps" then
                local name = pending.name
                local flag = name == WEAKEN_MIND and dps.weakenMind or
                    name == MIND_CRUSH and dps.mindCrush or name == PROJECT and dps.project or
                    name == TELEKINETIC_THROW and dps.telekineticThrow or
                    name == DISTURBANCE and dps.disturbance
                consumed = submit_if_enabled(flag, name, name == WEAKEN_MIND and WEAKEN_MIND or nil)
            end
            if consumed then return true end
            resumed_name = pending.name
        end

        -- Weaken Mind is maintenance, not a movement-only filler. Whenever the
        -- healer state admits idle DPS, establish our DoT first and keep it on
        -- the selected hostile. mine_effect_present() makes this fail closed on
        -- uncertain effect data and avoids overwriting our own active DoT.
        if submit_if_enabled(dps.weakenMind, WEAKEN_MIND, WEAKEN_MIND) then
            return true
        end
        if submit_forcequake() then return true end
        if moving then
            return submit_if_enabled(dps.project, PROJECT, nil)
        end
        if submit_if_enabled(dps.mindCrush, MIND_CRUSH, nil) then
            return true
        end
        if submit_if_enabled(dps.project, PROJECT, nil) then
            return true
        end
        if submit_if_enabled(dps.telekineticThrow, TELEKINETIC_THROW, nil) then
            return true
        end
        return submit_if_enabled(dps.disturbance, DISTURBANCE, nil)
    end

    local function telekinetic_regeneration_candidate(options, world, known,
            resource, moving)
        local dps = type(options) == "table" and options.dps or nil
        if type(dps) ~= "table" or dps.enabled ~= true or
            dps.telekineticThrow ~= true or moving or
            known[TELEKINETIC_THROW] ~= true or
            known[TELEKINETIC_REGENERATION] ~= true then
            return nil
        end
        local target = world and world.current_target or nil
        local handle = safe_method(target, "handle")
        local hp = safe_method(target, "hp")
        if not target or type(handle) ~= "string" or
            safe_method(target, "reaction") ~= "hostile" or not living_hp(hp) then
            return nil
        end
        local state = ability_state(known, TELEKINETIC_THROW)
        -- The passive refunds Force only after damaging hits. Admission may use
        -- it as a recovery lane only when the observed activation cost itself
        -- is free; never pre-credit future tick refunds to fund the cast.
        if state == nil or state.cost ~= 0 or resource.current < 0 then
            return nil
        end
        return target, handle, state
    end

    local function try_telekinetic_regeneration(options, world, known,
            resource, moving)
        local target, handle, state = telekinetic_regeneration_candidate(
            options, world, known, resource, moving)
        if target == nil then return false end
        local status = route_submit_selected(options,
            "force_recovery_telekinetic_regeneration", known,
            TELEKINETIC_THROW, target, handle, resource.current,
            moving, nil, state)
        return action_in_progress(status)
    end

    local function owns_pending()
        if not executor:owns_command() then
            return false
        end
        local status = executor:status()
        local key = type(status) == "table" and status.idempotency_key or nil
        return type(key) == "string" and
            key:sub(1, #OWNER_PREFIX) == OWNER_PREFIX
    end

    local function reset_prediction()
        native_admission = nil
        admission_waiting = false
        combat_cursor = nil
        pressure_tracker:reset()
        forcequake_count_cache = nil
        route_player_handle, route_actor_epoch = nil, nil
    end

    local function poll_incoming_events()
        local events, dropped = {}, 0
        for _ = 1, MAX_EVENT_DRAIN_PASSES do
            local batch = gos.events.combat(combat_cursor)
            if type(batch) ~= "table" or type(batch.cursor) ~= "number" or
                type(batch.events) ~= "table" then
                return nil, dropped
            end
            combat_cursor = batch.cursor
            if finite_number(batch.dropped) and batch.dropped > 0 then
                dropped = dropped + batch.dropped
                return nil, dropped
            end
            for index = 1, #batch.events do
                events[#events + 1] = batch.events[index]
            end
            if batch.more ~= true then
                break
            end
        end
        return events, dropped
    end

    local function stop(reason, cancel_pending)
        reset_prediction()
        last_decision_by_route = {}
        last_cast_failure_by_ability = {}
        -- Route/loadout changes stop NEW Seer decisions, but an already-owned
        -- Core command remains authoritative until Core reports a terminal state.
        -- Only explicit rotation deactivation may request cancellation here;
        -- transient loadout/metadata gaps must not manufacture one.
        if cancel_pending == true and owns_pending() then
            executor:cancel(reason or "seer_rotation_inactive")
        end
        return owns_pending()
    end

    local function tick(loadout, active, options)
        admission_waiting = false
        loadout = Mirror.adapt_loadout(loadout or gos.abilities.loadout())
        CurrentLoadout = loadout
        pressure_hot_names["Revivification"] = type(loadout) == "table" and loadout._sage_mirror_style == "sorcerer" or nil
        if active ~= true then
            reset_prediction()
            last_decision_by_route = {}
            last_cast_failure_by_ability = {}
            if owns_pending() then
                executor:cancel("seer_rotation_inactive")
            end
            return true
        end

        local kit = validated_loadout(loadout)
        if kit == nil then
            -- Incomplete/pending metadata is not evidence that the already-owned
            -- Core command became invalid. Freeze new decisions and let the
            -- executor poll that command to one exact terminal Core state.
            -- Preserve per-ability failure dedupe across the transient gap.
            reset_prediction()
            last_decision_by_route = {}
            return true
        end
        local world = gos.world()
        local player = world and world.player or nil
        local player_handle = safe_method(player, "handle")
        if type(player_handle) == "string" then
            local actor_epoch = world.actor_epoch
            if route_player_handle ~= nil and
                (route_player_handle ~= player_handle or
                    route_actor_epoch ~= nil and actor_epoch ~= nil and
                    route_actor_epoch ~= actor_epoch) then
                reset_prediction()
            end
            route_player_handle, route_actor_epoch = player_handle, actor_epoch
        end
        if executor:owns_command() then
            -- Match Combat Medic's safety model: a queued damage command loses
            -- ownership as soon as current friendly HP makes DPS unsafe.
            local status = executor:status()
            local pending_name = type(status) == "table" and status.ability or nil
            if owns_pending() and DpsAbility[pending_name] == true then
                local snapshot = world
                local snapshot_player = snapshot and snapshot.player or nil
                local snapshot_handle = safe_method(snapshot_player, "handle")
                if snapshot and type(snapshot_handle) == "string" then
                    local policy = healing_policy(options)
                    local _, _, _, _, _, observation =
                        collect_injured(snapshot, policy, snapshot_handle)
                    local floor = configured_dps_min_ally_ratio(options, policy.healStart)
                    if not observation or observation.complete ~= true or
                        observation.minRatio < floor then
                        executor:cancel("seer_healing_preempts_queued_dps")
                    end
                end
            end
            return true
        end
        local incoming_events, incoming_dropped = poll_incoming_events()

        local resource = safe_method(player, "resource")
        local speed = safe_method(player, "speed")
        if not world or type(resource) ~= "table" or
            not finite_number(resource.current) or resource.current < 0 or
            not finite_number(speed) or type(player_handle) ~= "string" then
            return true
        end
        local pressure_now = monotonic_ms()
        pressure_tracker:observe(incoming_events, player_handle,
            incoming_dropped or 0, pressure_now)
        local moving = speed ~= 0
        local policy = healing_policy(options)
        local reserve_force = configured_force_reserve(resource, options)
        local dps_min_ally_ratio = configured_dps_min_ally_ratio(options, policy.healStart)
        -- Lull Armor is protection, not a damage all-clear gate. Keep a small
        -- buffer above healStart so mildly chipped allies can be protected when
        -- Armor is legal, but never let an unavailable/locked-out Armor block
        -- idle DPS above dps_min_ally_ratio.
        local dps_lull_armor_ratio = math.max(
            configured_dps_min_ally_ratio(options),
            math.min(0.98, policy.healStart + 0.03))
        local below_force_reserve = resource.current <= reserve_force
        local altruism_state = observed_effect_state(player, ALTRUISM, "buff")
        local altruism = type(altruism_state) == "table"
        local conveyance = observed_effect(player, CONVEYANCE, "buff")
        local force_potency_present = observed_effect(player, FORCE_POTENCY, "buff")
        local mental_alacrity_present = observed_effect(player, MENTAL_ALACRITY, "buff")
        local resplendence_state =
            observed_effect_state(player, RESPLENDENCE, "buff")
        local resplendence_present = optimizer_presence(resplendence_state)
        local resplendence = observed_stacks(player, RESPLENDENCE, "buff")
        local amnesty_state = observed_effect_state(player, AMNESTY, "buff")
        local weary_state = observed_effect_state(player, WEARY, "debuff")
        local weary_present = optimizer_presence(weary_state)
        local weary_stacks = observed_stacks(player, WEARY, "debuff")
        local force_state = force_optimizer_state(kit.known, resource,
            policy, reserve_force, resplendence_state, resplendence,
            amnesty_state, weary_state, weary_stacks)

        local friendlies, lowest, injured_count, maintenance, injured,
            healing_observation = collect_injured(world, policy, player_handle)
        if friendlies == nil then
            return true
        end
        local hp_lowest = lowest
        local pressure_sorted = policy.triageMode == PressureFormula.MODE_PRESSURE and
            pressure_tracker:sort(injured, pressure_now, function(lhs, rhs)
                return friendlier(lhs.current, lhs.maximum, lhs.handle, rhs)
            end)
        -- The shared formula annotates every evidenced pressure level. Seer only
        -- allows bands 0/1 to change triage class; bands 2/3 fall back to actual
        -- health so small friendly NPC health pools cannot steal the tank.
        if policy.triageMode == PressureFormula.MODE_PRESSURE then
            table.sort(injured, function(lhs, rhs)
                return triage_less(lhs, rhs, policy)
            end)
        end
        -- Compact in place: no second world scan or combat-event cursor.
        local kept = 0
        for index = 1, #injured do
            local row = injured[index]
            if row.current <= row.maximum * policy.healStart or
                pressure_urgent(row, policy) then
                kept = kept + 1
                injured[kept] = row
            end
        end
        for index = #injured, kept + 1, -1 do injured[index] = nil end
        injured_count = kept
        if pressure_sorted and kept > 0 then
            lowest = injured[1]
            if options and options.decisionLog == true and
                (hp_lowest == nil or lowest.handle ~= hp_lowest.handle or
                    pressure_urgent(lowest, policy)) and finite_number(pressure_now) and
                pressure_now - last_pressure_diagnostic_at >= 500 then
                last_pressure_diagnostic_at = pressure_now
                local f = lowest.pressure
                emit(options, "debug", string.format(
                    "route=seer pressure_triage model=%s hp_target=%s selected=%s hp=%.1f%% p2=%.1f%% p4=%.1f%% ttd=%.2fs attackers=%d recent=%d persistent=%d band=%d",
                    tostring(f.pressure_model or "unknown"),
                    tostring(hp_lowest and hp_lowest.handle or "none"), tostring(lowest.handle),
                    lowest.current / lowest.maximum * 100,
                    f.projected_hp_2s * 100, f.projected_hp_4s * 100,
                    f.ttd, f.attackers_3s, f.recent_attackers or 0,
                    f.persistent_attackers or 0, f.risk_band))
            end
        end

        local player_hp = safe_method(player, "hp")
        local player_ratio = type(player_hp) == "table" and
            hp_ratio(player_hp.current, player_hp.max) or nil
        local force_mend_candidate = policy.autoForceMend and
            kit.known[FORCE_MEND] == true and player_ratio ~= nil and
            player_ratio <= policy.forceMend

        local incoming_target, incoming_handle
        if policy.preShieldIncoming then
            incoming_target, incoming_handle =
                incoming_armor_target(world, incoming_events, policy)
        end

        local trance = ability_state(kit.known, HEALING_TRANCE)
        local rejuvenate = ability_state(kit.known, REJUVENATE)
        local salvation = ability_state(kit.known, SALVATION)
        local wandering = ability_state(kit.known, WANDERING_MEND)
        local force_potency = ability_state(kit.known, FORCE_POTENCY)
        local mental_alacrity = ability_state(kit.known, MENTAL_ALACRITY)
        local armor_state = ability_state(kit.known, kit.armor)
        local benevolence_state = ability_state(kit.known, BENEVOLENCE)
        local filler_state = ability_state(kit.known, kit.filler)
        local force_mend_state = ability_state(kit.known, FORCE_MEND)
        local vindicate_state = ability_state(kit.known, VINDICATE)
        local cleanse_policy = Cleanse.seer_policy(policy, options and options.cleanse)
        local cleanse_attempted = {}
        local function try_cleanse(tier)
            if cleanse_attempted[tier] then return false end
            cleanse_attempted[tier] = true
            return Cleanse.attempt({
                active = true, pending = executor:owns_command(), loadout = loadout,
                admission_via_submit = true,
                ability_name = function(name)
                    return Mirror.ability(CurrentLoadout, name)
                end,
                world = world, friendlies = friendlies, tier = tier,
                policy = cleanse_policy, log = options and options.logLine,
                submit = function(candidate, unit)
                    local status, accepted, result = route_submit(options,
                        "pvp_cleanse_" .. candidate.key, kit.known, candidate.ability,
                        unit, candidate.handle, resource.current, moving, true, nil, false, {
                            category = "cleanse", effect = candidate.effect,
                            dispel = candidate.dispel, tier = candidate.tier,
                            priority = candidate.priority,
                        })
                    return { accepted = accepted, owned = executor:owns_command(),
                        admission_pending = status == "admission_pending",
                        reason = type(result) == "table" and result.reason or status,
                        code = type(result) == "table" and result.code or nil }
                end,
            })
        end

        -- Force Mend is self-only utility and must not depend on the
        -- selected patient being the Sage. Try it globally at its configured
        -- self-survival threshold, then continue normal triage if Core cannot
        -- admit it this tick.
        if force_mend_candidate and force_mend_state ~= nil then
            local status = route_submit(options, "force_mend_self_global",
                kit.known, FORCE_MEND, player, player_handle,
                resource.current, moving, true, force_mend_state)
            if action_in_progress(status) then return true end
        end

        if lowest == nil then
            -- With no healing crisis, controls still outrank routine protection
            -- and recovery. Pressure debuffs remain optional until maintenance
            -- has had its turn below.
            if try_cleanse("must") then return true end
            if try_cleanse("movement") then return true end
            if incoming_target and
                armor_allowed(incoming_target, kit.armor) then
                local status = route_submit(options, "incoming_hostile_target",
                    kit.known, kit.armor, incoming_target, incoming_handle,
                    resource.current, moving)
                if action_in_progress(status) then
                    return true
                end
            end
            -- Commando keeps Trauma Probe maintained before DPS. Seer mirrors
            -- that principle with Force Armor only on a partially injured
            -- lowest friendly, and never spends through the configured reserve.
            local maintenance_ratio = maintenance and
                hp_ratio(maintenance.current, maintenance.maximum) or nil
            if policy.autoForceArmor and maintenance and maintenance_ratio and
                maintenance_ratio < dps_lull_armor_ratio then
                local maintenance_target =
                    resolve_friendly(world, maintenance.handle, false, policy)
                local armor_state = ability_state(kit.known, kit.armor)
                if maintenance_target and armor_state and
                    resource.current >= armor_state.cost and
                    resource.current - armor_state.cost >= reserve_force and
                    armor_allowed(maintenance_target, kit.armor) then
                    local status = route_submit(options,
                        "healing_lull_force_armor", kit.known, kit.armor,
                        maintenance_target, maintenance.handle,
                        resource.current, moving, nil, armor_state)
                    if action_in_progress(status) then return true end
                end
            end
            local maintenance_target = maintenance and
                resolve_friendly(world, maintenance.handle, false, policy) or nil
            local maintenance_rejuvenate = maintenance_target and
                mine_effect_present(maintenance_target, REJUVENATE, "buff") or nil
            -- No patient needs healing here. Spending an earned token at the
            -- soft threshold is not permission to buy unbuffed proc attempts.
            -- Hard-reserve/Weary repair keeps its explicit recovery lane.
            local critical_recovery = below_force_reserve or weary_present == true
            local resplendence_capped = finite_number(resplendence) and
                resplendence >= ForceOptimizer.Mechanics.resplendence_max_stacks
            local can_build_resplendence = maintenance_target ~= nil and
                not resplendence_capped and
                (critical_recovery or conveyance == true or force_potency_present == true) and
                trance ~= nil and trance.cost <= resource.current and
                (critical_recovery or resource.current - trance.cost >= reserve_force) and
                not (moving and requires_stationary(kit.known,
                    HEALING_TRANCE, nil))
            local all_clear_for_damage = healing_observation and
                healing_observation.complete == true and
                healing_observation.minRatio >= dps_min_ally_ratio
            local tt_target = all_clear_for_damage and
                telekinetic_regeneration_candidate(options, world, kit.known,
                    resource, moving) or nil
            local force_pressure = all_clear_for_damage and
                ForceOptimizer.Pressure.IDLE or ForceOptimizer.Pressure.LIGHT
            local force_action, force_reason = ForceOptimizer.plan(force_state, {
                pressure = force_pressure,
                amnesty_cash_window = AMNESTY_CASH_WINDOW_SECONDS,
                can_build_resplendence = can_build_resplendence,
                can_telekinetic_regenerate = tt_target ~= nil,
                force_barrier_purge_available = kit.known[FORCE_BARRIER] == true,
            })

            if force_action == "vindicate" then
                local status = route_submit_untargeted(options,
                    "force_optimizer_" .. force_reason, kit.known, VINDICATE,
                    player, player_handle, resource.current, moving, true)
                if action_in_progress(status) then return true end
            elseif force_action == "telekinetic_regeneration" then
                if try_telekinetic_regeneration(options, world, kit.known,
                        resource, moving) then
                    return true
                end
                if can_build_resplendence then
                    force_action = "build_resplendence"
                    force_reason = "build_after_telekinetic_regeneration_blocked"
                end
            end

            if force_action == "build_resplendence" and
                can_build_resplendence then
                if conveyance == true then
                    local status = route_submit(options, "force_build_trance",
                        kit.known, HEALING_TRANCE, maintenance_target,
                        maintenance.handle, resource.current, moving, nil, trance)
                    if action_in_progress(status) then return true end
                end
                if force_potency_present == true then
                    local status = route_submit(options,
                        "force_potency_recovery_trance",
                        kit.known, HEALING_TRANCE, maintenance_target,
                        maintenance.handle, resource.current, moving, nil, trance)
                    if action_in_progress(status) then return true end
                end
                if critical_recovery and policy.autoForcePotency and force_potency ~= nil and
                    force_potency_present == false and
                    resplendence_present ~= true and
                    ForceOptimizer.potency_worth_spending_for_build(
                        force_reason) then
                    local status = route_submit_force_potency_for_trance(
                        options, "force_optimizer_potency_" .. force_reason,
                        kit.known, player, player_handle, maintenance_target,
                        maintenance.handle, resource.current, moving,
                        force_potency)
                    if action_in_progress(status) then return true end
                end
                if critical_recovery and rejuvenate ~= nil and maintenance_rejuvenate == false and
                    rejuvenate.cost + trance.cost <= resource.current then
                    local status = route_submit(options,
                        "force_build_rejuvenate", kit.known, REJUVENATE,
                        maintenance_target, maintenance.handle,
                        resource.current, moving, nil, rejuvenate)
                    if action_in_progress(status) then return true end
                end
                if critical_recovery then
                    local status = route_submit(options, "force_build_trance",
                        kit.known, HEALING_TRANCE, maintenance_target,
                        maintenance.handle, resource.current, moving, nil, trance)
                    if action_in_progress(status) then return true end
                end
            end
            -- Soft recovery is a preference, not an idle state. Optional
            -- pressure cleansing gets the last healer-utility GCD before damage.
            if try_cleanse("pressure") then return true end
            -- Commando requires an explicit all-clear before DPS. Seer now does
            -- the same: incomplete friendly data or a partially injured ally
            -- below the configured floor is healing downtime, not DPS time.
            if not healing_observation or
                healing_observation.complete ~= true or
                healing_observation.minRatio < dps_min_ally_ratio then
                return true
            end
            if try_idle_dps(options, world, kit.known, resource, moving) then
                return true
            end
            -- Safe DPS was desired but the selected hostile was not currently
            -- attackable. Spend the otherwise-dead GCD on useful light
            -- maintenance rather than repeatedly retrying an illegal target.
            local dps_options = type(options) == "table" and options.dps or nil
            if type(dps_options) == "table" and dps_options.enabled == true and
                maintenance_target and maintenance_ratio and
                maintenance_ratio < 1.0 and maintenance_rejuvenate ~= true and
                kit.known[REJUVENATE] == true and
                (rejuvenate == nil or rejuvenate.cost <= 0 or
                    resource.current - rejuvenate.cost >= reserve_force) then
                local status = route_submit(options,
                    "healing_lull_rejuvenate", kit.known, REJUVENATE,
                    maintenance_target, maintenance.handle,
                    resource.current, moving, true, rejuvenate)
                if action_in_progress(status) then return true end
            end
            return true
        end

        local target = resolve_injured(world, lowest.handle, policy, lowest)
        if not target then
            -- The chosen patient became invalid between observation and action.
            -- Do not invent a replacement target from stale data.
            if try_cleanse("must") then return true end
            if try_cleanse("movement") then return true end
            if try_cleanse("pressure") then return true end
            return true
        end

        local target_hp = safe_method(target, "hp")
        local target_ratio = type(target_hp) == "table" and
            hp_ratio(target_hp.current, target_hp.max) or nil
        if target_ratio == nil then return true end

        local target_rejuvenate =
            mine_effect_present(target, REJUVENATE, "buff")
        local urgent_forecast = pressure_urgent(lowest, policy, target_hp)
        local patient_band = triage_band(lowest, policy)
        local severity = HealingScheduler.severity(
            target_ratio, patient_band, policy.healStart)
        local emergency = severity == HealingScheduler.Severity.LIFE or
            severity == HealingScheduler.Severity.EMERGENCY
        local altruism_expiring = altruism == true and
            altruism_state.has_timer == true and
            finite_number(altruism_state.remaining) and
            altruism_state.remaining <= ALTRUISM_REFRESH_WINDOW_SECONDS

        local armor = policy.autoForceArmor and
            kit.known[kit.armor] == true and
            armor_allowed(target, kit.armor)
        local target_salvation_count = injured_cluster_count(
            injured, lowest, SALVATION_RADIUS_METERS)
        local wandering_target, wandering_count =
            best_wandering_center(injured, player_handle)
        local salvation_target, salvation_count =
            best_salvation_center(injured,
                policy.salvationMinAllies, player_handle)
        local salvation_radius =
            SALVATION_RADIUS_METERS / METERS_PER_WORLD_UNIT
        local salvation_covers_target = salvation_target ~= nil and
            lowest.x ~= nil and
            distance_squared(salvation_target, lowest) <=
                salvation_radius * salvation_radius

        local wandering_candidate = kit.known[WANDERING_MEND] == true and
            ((wandering_count or 0) >= 2 or
                target_ratio <= policy.wanderingMend)
        local wandering_active
        if wandering_candidate then
            wandering_active = wandering_mend_active(friendlies, policy)
        end
        local wandering_unit = wandering_target and
            resolve_injured(world, wandering_target.handle,
                policy, wandering_target) or nil
        local salvation_unit = salvation_target and
            resolve_friendly(world, salvation_target.handle,
                false, policy) or nil

        local aura_cluster =
            kit.known[REJUVENATING_AURA] == true and
            target_rejuvenate == true and
            target_salvation_count >= 2
        local heavy_pressure =
            (emergency and injured_count >= 2) or
            salvation_count >= 5
        local patient_pressure_active = type(lowest.pressure) == "table" and
            finite_number(lowest.pressure.fast_pressure) and
            lowest.pressure.fast_pressure > 0 and
            ((lowest.pressure.persistent_attackers or 0) >= 1 or
                (lowest.pressure.recent_attackers or 0) >= 2)
        local patient_pressure_shield = type(lowest.pressure) == "table" and
            finite_number(lowest.pressure.projected_hp_2s) and
            lowest.pressure.projected_hp_2s <= policy.healingTrance and
            lowest.pressure.projected_hp_2s <= target_ratio - 0.05 and
            ((lowest.pressure.persistent_attackers or 0) >= 1 or
                (lowest.pressure.recent_attackers or 0) >= 2)
        local renewal_refresh =
            kit.known[FORCE_SHELTER] == true or
            kit.known[RENEWAL] == true

        local force_pressure = emergency and
            ForceOptimizer.Pressure.EMERGENCY or
            (severity == HealingScheduler.Severity.ACTIVE or
                heavy_pressure or (wandering_count or 0) >= 2) and
                ForceOptimizer.Pressure.ACTIVE or
                ForceOptimizer.Pressure.LIGHT
        local trance_movable = kit.known[HEALING_TRANCE] == true and
            not (moving and requires_stationary(
                kit.known, HEALING_TRANCE, nil))
        local can_build_resplendence = trance_movable and
            type(trance) == "table" and trance.cost <= resource.current
        local force_action, force_reason =
            ForceOptimizer.plan(force_state, {
                pressure = force_pressure,
                allow_safe_emergency_recovery =
                    severity == HealingScheduler.Severity.EMERGENCY,
                amnesty_cash_window = AMNESTY_CASH_WINDOW_SECONDS,
                can_build_resplendence = can_build_resplendence,
                can_telekinetic_regenerate = false,
                force_barrier_purge_available =
                    kit.known[FORCE_BARRIER] == true,
            })

        -- The configured Force reserve protects downtime/routine play.
        -- It must not become a hard wall while an ally is actively being
        -- treated. ACTIVE may cross the reserve for a useful heal; the Force
        -- optimizer then gets the next safe recovery opportunity. Emergency/
        -- life-saving treatment already has unconditional first refusal.
        local reserve_relaxed = emergency or urgent_forecast or
            patient_pressure_active or
            (severity == HealingScheduler.Severity.ACTIVE and
                target_ratio <= policy.filler)
        local reserve_mode = emergency and "emergency" or
            reserve_relaxed and "active_soft" or "routine_hard"
        local function healing_spend_allowed(state)
            if type(state) ~= "table" then
                return nil
            end
            if state.cost <= 0 then
                return true
            end
            if state.cost > resource.current then
                return false
            end
            if reserve_relaxed then
                return true
            end
            return resource.current - state.cost >= reserve_force
        end
        local scheduler_context = {
            severity = severity,
            target_ratio = target_ratio,
            heal_start = policy.healStart,
            trance_threshold = policy.healingTrance,
            wandering_threshold = policy.wanderingMend,
            filler_threshold = policy.filler,
            salvation_min = policy.salvationMinAllies,
            patient_is_self = lowest.handle == player_handle,
            force_mend_candidate = force_mend_candidate,
            target_rejuvenate = target_rejuvenate,
            renewal_refresh = renewal_refresh,
            conveyance = conveyance,
            altruism = altruism,
            altruism_expiring = altruism_expiring,
            force_potency_active = force_potency_present,
            force_potency_enabled = policy.autoForcePotency and
                trance_movable,
            mental_alacrity_active = mental_alacrity_present,
            resplendence_known = kit.known[RESPLENDENCE] == true,
            resplendence_stacks = resplendence,
            force_soft_low =
                resource.current / resource.max <= policy.vindicateBelow,
            force_hard_low = below_force_reserve,
            force_action = force_action,
            force_reason = force_reason,
            idf_urgent = urgent_forecast,
            pressure_active = patient_pressure_active,
            pressure_shield = patient_pressure_shield,
            incoming_exact = incoming_handle == lowest.handle,
            armor_allowed = armor and
                (salvation_count < 4 or emergency),
            aura_cluster = aura_cluster,
            wandering_count = wandering_count,
            wandering_active = wandering_active,
            salvation_count = salvation_count,
            salvation_covers_patient = salvation_covers_target,
            heavy_pressure = heavy_pressure,
            spend_allowed = {
                force_mend = healing_spend_allowed(force_mend_state),
                benevolence = altruism == true or
                    healing_spend_allowed(benevolence_state),
                armor = healing_spend_allowed(armor_state),
                rejuvenate = healing_spend_allowed(rejuvenate),
                trance = healing_spend_allowed(trance),
                wandering = healing_spend_allowed(wandering),
                salvation = healing_spend_allowed(salvation),
                filler = healing_spend_allowed(filler_state),
                mental_alacrity = healing_spend_allowed(mental_alacrity),
                force_potency = healing_spend_allowed(force_potency),
            },
            abilities = {
                force_mend = kit.known[FORCE_MEND] == true,
                benevolence = kit.known[BENEVOLENCE] == true,
                armor = policy.autoForceArmor and kit.known[kit.armor] == true,
                rejuvenate = kit.known[REJUVENATE] == true,
                trance = kit.known[HEALING_TRANCE] == true,
                wandering = kit.known[WANDERING_MEND] == true and
                    (wandering_unit ~= nil or wandering_target == nil),
                salvation = kit.known[SALVATION] == true and
                    salvation_unit ~= nil,
                filler = kit.known[kit.filler] == true,
                mental_alacrity = policy.autoMentalAlacrity and
                    kit.known[MENTAL_ALACRITY] == true,
                force_potency = trance_movable and
                    kit.known[FORCE_POTENCY] == true,
            },
        }
        local healing_plan = HealingScheduler.plan(scheduler_context)

        if type(options) == "table" and
            options.decisionLog == true then
            local scheduler_key = table.concat({
                tostring(severity), tostring(lowest.handle),
                tostring(math.floor(target_ratio * 1000 + 0.5)),
                tostring(conveyance), tostring(altruism),
                tostring(resplendence), tostring(force_action),
                tostring(reserve_mode),
                tostring(math.floor(resource.current + 0.5)),
                HealingScheduler.describe(healing_plan),
            }, "|")
            if last_decision_by_route["scheduler"] ~= scheduler_key then
                last_decision_by_route["scheduler"] = scheduler_key
                emit(options, "debug",
                    "route=seer phase=scheduler severity=" ..
                    tostring(severity) ..
                    " target=" .. tostring(lowest.handle) ..
                    " hp=" .. number_text(target_ratio * 100, 1) ..
                    " band=" .. tostring(patient_band) ..
                    " idf_urgent=" .. tostring(urgent_forecast) ..
                    " conveyance=" .. tostring(conveyance) ..
                    " altruism=" .. tostring(altruism) ..
                    " resplendence=" .. tostring(resplendence) ..
                    " force=" .. number_text(resource.current, 0) ..
                    "/" .. number_text(resource.max, 0) ..
                    " reserve=" .. number_text(reserve_force, 0) ..
                    " reserve_mode=" .. tostring(reserve_mode) ..
                    " force_action=" .. tostring(force_action) ..
                    " plan=" .. HealingScheduler.describe(healing_plan))
            end
        end

        -- Hard CC only yields to true life-saving treatment. For every other
        -- patient state, restoring an ally's whole kit comes first.
        if severity ~= HealingScheduler.Severity.LIFE and
            try_cleanse("must") then
            return true
        end

        local submitted, held = execute_healing_plan(
            healing_plan, {
                options = options,
                known = kit.known,
                player = player,
                player_handle = player_handle,
                target = target,
                target_handle = lowest.handle,
                severity = severity,
                wandering_target = wandering_unit,
                wandering_handle =
                    wandering_target and wandering_target.handle or nil,
                salvation_target = salvation_unit,
                salvation_handle =
                    salvation_target and salvation_target.handle or nil,
                force = resource.current,
                moving = moving,
                conveyance = conveyance,
                armor_name = kit.armor,
                filler_name = kit.filler,
                mental_alacrity = mental_alacrity,
                force_potency = force_potency,
                force_mend = force_mend_state,
                benevolence = benevolence_state,
                armor = armor_state,
                rejuvenate = rejuvenate,
                trance = trance,
                wandering = wandering,
                salvation = salvation,
                filler = filler_state,
                vindicate = vindicate_state,
            })
        if submitted or held then return true end

        if severity == HealingScheduler.Severity.LIFE and
            try_cleanse("must") then
            return true
        end
        if try_cleanse("movement") then return true end

        -- Every useful heal above has already had first refusal. Ask the
        -- Force optimizer for a last resort instead of reviving the old
        -- unconditional Weary fallback. Debt is admitted only when Core proves
        -- a useful heal is resource-blocked and one +40 Vindicate unlocks it.
        local blocked_armor = armor and salvation_count < 4 and
            (not below_force_reserve or emergency) and
            exact_resource_blocked_state(kit.known, kit.armor,
                target, lowest.handle, resource.current) or nil
        local blocked_rejuvenate = force_potency_present ~= true and
            rejuvenate ~= nil and
            (target_rejuvenate ~= true or renewal_refresh) and
            exact_resource_blocked_state(kit.known, REJUVENATE,
                target, lowest.handle, resource.current) or nil
        local blocked_wandering = force_potency_present ~= true and
            wandering ~= nil and wandering_active ~= true and
            (wandering_count >= 2 or target_ratio <= policy.wanderingMend) and
            exact_resource_blocked_state(kit.known, WANDERING_MEND,
                target, lowest.handle, resource.current) or nil
        local blocked_trance = trance ~= nil and
            (emergency or target_ratio <= policy.healingTrance) and
            exact_resource_blocked_state(kit.known, HEALING_TRANCE,
                target, lowest.handle, resource.current) or nil
        local blocked_filler = target_ratio <= policy.filler and
            exact_resource_blocked_state(kit.known, kit.filler,
                target, lowest.handle, resource.current) or nil
        local blocked_salvation = salvation_target and salvation ~= nil and
            (not emergency or salvation_covers_target) and
            exact_resource_blocked_state(kit.known, SALVATION,
                salvation_target.unit, salvation_target.handle,
                resource.current) or nil
        local minimum_paid_cost = minimum_positive_cost(
            blocked_armor, blocked_rejuvenate, blocked_wandering,
            blocked_trance, blocked_filler, blocked_salvation)
        local last_action, last_reason = ForceOptimizer.last_resort(force_state, {
            pressure = force_pressure,
            urgent = urgent_forecast,
            allow_debt = emergency,
            minimum_useful_paid_cost = minimum_paid_cost,
        })
        if last_action == "vindicate" then
            local status = route_submit_untargeted(options,
                "force_optimizer_" .. last_reason, kit.known, VINDICATE,
                player, player_handle, resource.current, moving, true)
            if action_in_progress(status) then return true end
        end

        -- Failed urgent healing must not turn into opportunistic damage just
        -- because the endangered patient's observed HP remains relatively high.
        if urgent_forecast then return true end

        -- An ally may still be below the monitoring threshold while every
        -- worthwhile heal is already covered, on cooldown, or otherwise not
        -- usable. Optional pressure cleansing is the final healer utility.
        if try_cleanse("pressure") then return true end
        -- Never spend a damage GCD through unresolved healing pressure. This is
        -- deliberately stricter than the old "blocked heal -> DPS" behavior.
        if not healing_observation or healing_observation.complete ~= true or
            healing_observation.minRatio < dps_min_ally_ratio then
            return true
        end
        try_idle_dps(options, world, kit.known, resource, moving)
        return true
    end

    return {
        is_selected = is_selected,
        owns_pending = owns_pending,
        stop = stop,
        tick = tick,
    }
end

return M
