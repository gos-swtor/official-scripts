-- Loadout-aware Medicine healing route for scripts/live/operative.lua.
-- Progressive Medicine route through level 80: early direct heals, level-31
-- Kolto Probe, level-35 Recuperative Nanotech/Medical Engineering, level-47
-- Surgical Probe, level-51 Surgical Precision, level-60 Kolto Waves /
-- Accomplished Doctor, and the remaining 64/68/73/78 tree/passive mechanics.
-- Friendly casts keep the strict explicit-target/no-fallback contract as Seer;
-- spare GCDs are filled with DPS when HoTs can safely carry chip damage.

local Cleanse = require("combat.cleanse")
local PressureFormula = require("combat.pressure_formula")
local Mirror = require("operative.mirror")
local CurrentLoadout
local M = {}

local EXPECTED_STYLE = "operative"
local EXPECTED_DISCIPLINE = "Medic"
local OWNER_PREFIX = "medicine:"
local MAX_FRIENDLIES = 512
local HEAL_RANGE_METERS = 30.0
local KOLTO_BURST_RADIUS_METERS = 8.0
local RECUPERATIVE_NANOTECH_RADIUS_METERS = 10.0
local RECUPERATIVE_NANOTECH_MAX_TARGETS = 4
local KOLTO_WAVES_RADIUS_METERS = 8.0
local KOLTO_WAVES_MIN_ALLIES = 3
local KOLTO_WAVES_CHANNEL_ENERGY = 28.0 -- Four observed seven-Energy ticks.
local METERS_PER_WORLD_UNIT = 10.0
local EMERGENCY_HEAL_RATIO = 0.60
local LIFE_SAVING_HEAL_RATIO = 0.20
local SELF_EMERGENCY_TRIAGE_BIAS = 0.12
local SELF_ROUTINE_TRIAGE_BIAS = 0.06
local KOLTO_PROBE_MAX_STACKS = 2
local DEFAULT_KOLTO_PROBE_REFRESH_SECONDS = 4.5
local ROUTINE_HEAL_ENERGY_RESERVE_PERCENT = 60.0
local BURST_HEAL_ENERGY_RESERVE = 20.0
-- A confirmed Kolto Probe cast can become visible in the effect scanner a few
-- ticks later. This is observation-settle grace only; it is not a fabricated
-- HoT duration or cooldown timer.
local PROBE_OBSERVATION_SETTLE_SECONDS = 8.0
local HOT_COVERED_DIRECT_HEAL_DISCOUNT = 0.04
local COMPANION_HOT_COVERED_DISCOUNT = 0.02
local PRESSURE_HISTORY_MS = 8000
local PRESSURE_HOT_WINDOW_MS = 4000
local PRESSURE_MAX_EVENTS = 4096

local DIAGNOSTIC_SCAN = "Diagnostic Scan"
local KOLTO_INJECTION = "Kolto Injection"
local KOLTO_INFUSION = "Kolto Infusion"
local KOLTO_PROBE = "Kolto Probe"
local RECUPERATIVE_NANOTECH = "Recuperative Nanotech"
local SURGICAL_PROBE = "Surgical Probe"
local SURGICAL_PRECISION = "Surgical Precision"
local KOLTO_WAVES = "Kolto Waves"
local ACCOMPLISHED_DOCTOR = "Accomplished Doctor"
local MED_SHIELD = "Med Shield"
local ENDORPHIN_RUSH = "Endorphin Rush"
local EVASIVE_SCREEN = "Evasive Screen"
local INFILTRATOR = "Infiltrator"
local ADVANCED_CLOAKING = "Advanced Cloaking"
local CHEM_RESISTANT_INLAYS = "Chem-resistant Inlays"
local INFILTRATE = "Infiltrate"
local FLASH_BANG = "Flash Bang"
local HOLOTRAVERSE = "Holotraverse"
local MEDICAL_CONSULT = "Medical Consult"
local TACTICAL_SUPERIORITY = "Tactical Superiority"
local EVASIVE_IMPERATIVE = "Evasive Imperative"
local JARRING_STRIKE = "Jarring Strike"
local BLOW_FOR_BLOW = "Blow for Blow"
local TACTICAL_MEDICINE = "Tactical Medicine"
local CURATIVE_JOLT = "Curative Jolt"
local REACTIVE_SUBSTANCE = "Reactive Substance"
local SHIELD_PROBE = "Shield Probe"
local RESUSCITATION_PROBE = "Resuscitation Probe"

local FRIENDLY_HEAL = {
    [DIAGNOSTIC_SCAN] = true,
    [KOLTO_INJECTION] = true,
    [KOLTO_INFUSION] = true,
    [KOLTO_PROBE] = true,
    [RECUPERATIVE_NANOTECH] = true,
    [SURGICAL_PROBE] = true,
}
-- Presentation-only coverage. Kolto Waves is omitted from FRIENDLY_HEAL because
-- its ground/channel admission uses different targeting semantics, but active
-- healing buffs still enhance it and should be visible in the action feed.
local MEDICINE_PROC_HEALS = {
    [DIAGNOSTIC_SCAN] = true,
    [KOLTO_INJECTION] = true,
    [KOLTO_INFUSION] = true,
    [KOLTO_PROBE] = true,
    [RECUPERATIVE_NANOTECH] = true,
    [SURGICAL_PROBE] = true,
    [KOLTO_WAVES] = true,
}
local SURPRISE_SURGERY = "Surprise Surgery"
local ENDURING_KOLTO = "Enduring Kolto"
local STIM_BOOST = "Stim Boost"
local KOLTO_STIM = "Kolto Stim"
local KOLTO_BURST = "Kolto Burst"
local STIM_BURST = "Stim Burst"
local TACTICAL_OVERDRIVE = "Tactical Overdrive"
local TACTICAL_EFFECTIVENESS = "Tactical Effectiveness"
local CURBING_STRATEGIES = "Curbing Strategies"
local CLEVER_COUNTERMEASURES = "Clever Countermeasures"
local DEBILITATE = "Debilitate"
local EVASION = "Evasion"
local NOXIOUS_KNIVES = "Noxious Knives"
local MEDICAL_ENGINEERING = "Medical Engineering"
local NANOTECH_STIM = "Nanotech Stim"
local NANO_MARK = "Nano Mark"
local CRITICAL_NANOTECH = "Critical Nanotech"
local ADRENALINE_PROBE = "Adrenaline Probe"
local TACTICAL_ADVANTAGE = "Tactical Advantage"
-- Diagnostics Probe's live 7.x stack effect is surfaced by Core as
-- "Heal Sust 01" (verified from the effect inspector). "Tactical Probe" is
-- retained as the source-facing alias used by game data / 8.0.
local DIAGNOSTICS_PROBE_EFFECTS = { "Heal Sust 01", "Tactical Probe" }
local DIAGNOSTICS_PROBE_MAX_STACKS = 3

-- Exact transient proc/buff identities from the installed client catalog.
-- These are presentation evidence only; route permission still comes from the
-- existing authoritative observations/Core admission.
local PROC_EFFECT = {
    EnduringKolto = "effectdef:3FBE51E189615C1F",
    TacticalMedicine = "effectdef:2C2FB11C3E3E360B",
    CurativeJolt = "effectdef:68FDE8E70BC1D422",
    StimBurst = "effectdef:6E36796A85C5C781",
    TacticalOverdrive = "effectdef:09B69CBB4A4A2B8C",
    TacticalProbe = "effectdef:6C19110FBB913720",
}

local STEALTH = "Stealth"
local BACKSTAB = "Backstab"
local SHIV = "Shiv"
local CORROSIVE_DART = "Corrosive Dart"
local OVERLOAD_SHOT = "Overload Shot"
local RIFLE_SHOT = "Rifle Shot"

-- Verified game costs are fallbacks only while Core's current metadata observation
-- is temporarily absent. Core runtime observations remain authoritative when present.
local FALLBACK_COST = {
    [DIAGNOSTIC_SCAN] = 0,
    [KOLTO_INJECTION] = 20,
    [KOLTO_INFUSION] = 20,
    [KOLTO_PROBE] = 10,
    -- Medical Therapy is a built-in Medicine passive in the current tree and
    -- reduces Recuperative Nanotech from its 20 Energy base cost to 15.
    [RECUPERATIVE_NANOTECH] = 15,
    [SURGICAL_PROBE] = 5,
    [KOLTO_WAVES] = KOLTO_WAVES_CHANNEL_ENERGY,
    [STIM_BOOST] = 0,
    [TACTICAL_OVERDRIVE] = 0,
    [SHIELD_PROBE] = 0,
    [RESUSCITATION_PROBE] = 0,
    [EVASION] = 0,
    [DEBILITATE] = 5,
    [NOXIOUS_KNIVES] = 15,
    [ADRENALINE_PROBE] = 0,
    [BACKSTAB] = 15,
    [SHIV] = 15,
    [CORROSIVE_DART] = 15,
    [OVERLOAD_SHOT] = 15,
    [RIFLE_SHOT] = 0,
}

local DPS_RANGE = {
    [BACKSTAB] = 4.0,
    [SHIV] = 4.0,
    [DEBILITATE] = 4.0,
    [OVERLOAD_SHOT] = 10.0,
    [NOXIOUS_KNIVES] = 10.0,
    [CORROSIVE_DART] = 30.0,
    [RIFLE_SHOT] = 30.0,
}

local CastRejectUntil = {}
local TargetSkipUntil = {}
local SubmittedReceiptGuard = {}
local LastCastRejectLog = {}
local LastHealUnavailableLog = {}
local CAST_REJECT_BACKOFF_SECONDS = 0.08
local TARGET_FAILOVER_BACKOFF_SECONDS = 0.35
local CAST_REJECT_LOG_INTERVAL_SECONDS = 0.50
local HEAL_UNAVAILABLE_LOG_INTERVAL_SECONDS = 0.50
local REPEAT_LOG_INTERVAL_SECONDS = 2.0
local BATTLE_REZ_REJECTION_BACKOFF_SECONDS = 5.0
local REPEATED_DECISIONS = {
    wait = true, probe_stack2_reserved = true, probe_degraded = true,
    idle_dps_wait = true, idle_dps_skip = true, idle_dps_degraded = true,
}

local HealingStyle = {
    Safe = { healStart = 0.98, injection = 0.94, infusion = 0.82, infusionBuild = 0.82 },
    Balanced = { healStart = 0.95, injection = 0.88, infusion = 0.80, infusionBuild = 0.74 },
    Efficient = { healStart = 0.90, injection = 0.82, infusion = 0.66, infusionBuild = 0.66 },
}

local function finite_number(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function now_seconds()
    local value = gos.time_ms()
    return finite_number(value) and value / 1000.0 or 0.0
end

local function safe_method(unit, name, ...)
    if not unit or type(unit[name]) ~= "function" then return nil end
    local ok, value = pcall(unit[name], unit, ...)
    return ok and value or nil
end

local function emit(options, level, message)
    local logger = type(options) == "table" and options.logLine or nil
    if type(logger) == "function" then logger(level, message) end
end

local function is_selected(loadout)
    loadout = Mirror.adapt_loadout(loadout)
    return type(loadout) == "table" and loadout.status == "ready" and
        loadout.combat_style == EXPECTED_STYLE and
        loadout.discipline == EXPECTED_DISCIPLINE
end

local function healing_policy(options)
    local configured = type(options) == "table" and options.healing or nil
    configured = type(configured) == "table" and configured or {}
    local style_name = type(configured.style) == "string" and configured.style or "Balanced"
    local style = HealingStyle[style_name] or HealingStyle.Balanced
    local targets = type(configured.targets) == "string" and
        configured.targets or "All Friendlies"
    if targets ~= "Players only" and targets ~= "Players + Companions" and
        targets ~= "All Friendlies" then
        targets = "All Friendlies"
    end
    local burst_min = finite_number(configured.koltoBurstMinAllies) and
        math.floor(clamp(configured.koltoBurstMinAllies, 2, 8) + 0.5) or 3
    local probe_everyone = configured.koltoProbeEveryone ~= false
    local probe_targets = finite_number(configured.koltoProbeTargets) and
        math.floor(clamp(configured.koltoProbeTargets, 1, 32) + 0.5) or 4
    local probe_refresh = finite_number(configured.koltoProbeRefreshSeconds) and
        clamp(configured.koltoProbeRefreshSeconds, 0.5, 6.0) or
        DEFAULT_KOLTO_PROBE_REFRESH_SECONDS
    local nanotech_min = finite_number(configured.nanotechMinAllies) and
        math.floor(clamp(configured.nanotechMinAllies, 1, 4) + 0.5) or 2
    local waves_min = finite_number(configured.koltoWavesMinAllies) and
        math.floor(clamp(configured.koltoWavesMinAllies, 2, 8) + 0.5) or
        KOLTO_WAVES_MIN_ALLIES
    local triage_mode = type(configured.triageMode) == "string" and
        configured.triageMode or PressureFormula.MODE_PRESSURE
    if triage_mode ~= PressureFormula.MODE_PRESSURE then
        triage_mode = PressureFormula.MODE_HP
    end
    return {
        triageMode = triage_mode,
        style = style_name,
        targets = targets,
        healStart = style.healStart,
        injection = style.injection,
        infusion = style.infusion,
        infusionBuild = style.infusionBuild or style.infusion,
        koltoBurstMinAllies = burst_min,
        koltoProbeEveryone = probe_everyone,
        koltoProbeTargets = probe_targets,
        koltoProbeRefreshSeconds = probe_refresh,
        nanotechMinAllies = nanotech_min,
        koltoWavesMinAllies = waves_min,
    }
end

local function burst_ceiling(policy)
    return math.max(EMERGENCY_HEAL_RATIO, policy.infusion, policy.infusionBuild)
end

local function direct_heal_threshold(policy, unit_type, hot_covered)
    local threshold = policy.injection
    if hot_covered == true then
        local discount = HOT_COVERED_DIRECT_HEAL_DISCOUNT +
            (unit_type == "companion" and COMPANION_HOT_COVERED_DISCOUNT or 0.0)
        threshold = math.max(policy.infusion, (threshold * 100.0 - discount * 100.0) / 100.0)
    end
    return threshold
end

local function healable_type(unit_type, policy)
    if unit_type == "player" then return true end
    if unit_type == "companion" then return policy.targets ~= "Players only" end
    if unit_type == "npc" then return policy.targets == "All Friendlies" end
    return false
end

local function living_hp(hp)
    return type(hp) == "table" and finite_number(hp.current) and
        finite_number(hp.max) and hp.max > 0 and hp.current > 0 and hp.current <= hp.max
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

local function unit_priority(unit_type)
    if unit_type == "player" then return 1 end
    if unit_type == "companion" then return 2 end
    return 3
end

local function triage_ratio(row)
    if type(row) ~= "table" or not finite_number(row.current) or
        not finite_number(row.maximum) or row.maximum <= 0 then
        return math.huge
    end
    local ratio = row.current / row.maximum
    if row.isSelf == true then
        local bias = ratio <= EMERGENCY_HEAL_RATIO and
            SELF_EMERGENCY_TRIAGE_BIAS or SELF_ROUTINE_TRIAGE_BIAS
        ratio = math.max(0.0, ratio - bias)
    end
    return ratio
end

local function better_heal_target(row, best)
    if best == nil then return true end
    local lhs_ratio = triage_ratio(row)
    local rhs_ratio = triage_ratio(best)
    if lhs_ratio ~= rhs_ratio then return lhs_ratio < rhs_ratio end
    local lhs_missing = row.maximum - row.current
    local rhs_missing = best.maximum - best.current
    if lhs_missing ~= rhs_missing then return lhs_missing > rhs_missing end
    if row.isSelf ~= best.isSelf then return row.isSelf == true end
    if row.priority ~= best.priority then return row.priority < best.priority end
    return row.handle < best.handle
end

local function actionable_hp(hp, policy)
    return living_hp(hp) and hp.current < hp.max and
        hp.current <= hp.max * policy.healStart
end

local function collect_injured(world, player, policy)
    local lowest, injured, probe_candidates, nanotech_candidates, seen = nil, {}, {}, {}, {}
    local function consider(unit, is_self)
        local handle = safe_method(unit, "handle")
        if type(handle) ~= "string" or seen[handle] then return end
        seen[handle] = true
        local unit_type = safe_method(unit, "type")
        local hp = safe_method(unit, "hp")
        if not healable_type(unit_type, policy) or not living_hp(hp) or
            (is_self ~= true and not within_heal_range(unit)) then return end
        local position = safe_method(unit, "position")
        local positioned = valid_position(position)
        local row = {
            unit = unit, handle = handle, current = hp.current, maximum = hp.max,
            priority = unit_priority(unit_type), unitType = unit_type,
            isSelf = is_self == true,
            x = positioned and position.x or nil,
            y = positioned and position.y or nil,
            z = positioned and position.z or nil,
        }
        -- Recuperative Nanotech can affect living friendlies even when they are
        -- currently full HP. Keep that complete coverage set so Nanotech Stim can
        -- maximize the exact number of targets affected (and therefore the exact
        -- Stim Boost cooldown reduction) without making a healthy unit the cast target.
        nanotech_candidates[#nanotech_candidates + 1] = row
        -- Keep living players/companions visible to Probe roster recovery so an
        -- existing owned HoT can remain sticky after they return to full HP.
        -- New roster slots are seeded only from damaged units below.
        if unit_type == "player" or unit_type == "companion" then
            probe_candidates[#probe_candidates + 1] = row
        end
        if actionable_hp(hp, policy) then
            injured[#injured + 1] = row
            if better_heal_target(row, lowest) then lowest = row end
        end
    end
    consider(player, true)
    if not world or type(world.units) ~= "function" then
        return lowest, injured, false, probe_candidates, nanotech_candidates
    end
    local ok, units = pcall(world.units, world, { reaction = "friendly" })
    if not ok or type(units) ~= "table" or #units > MAX_FRIENDLIES then
        return lowest, injured, false, probe_candidates, nanotech_candidates
    end
    for index = 1, #units do consider(units[index], false) end
    table.sort(injured, function(lhs, rhs)
        return better_heal_target(lhs, rhs)
    end)
    table.sort(probe_candidates, function(lhs, rhs)
        return better_heal_target(lhs, rhs)
    end)
    return lowest, injured, true, probe_candidates, nanotech_candidates
end

local function proven_dead_player(unit)
    if safe_method(unit, "type") ~= "player" or
        safe_method(unit, "reaction") ~= "friendly" then return false end
    local hp = safe_method(unit, "hp")
    return type(hp) == "table" and finite_number(hp.current) and
        finite_number(hp.max) and hp.max > 0 and hp.current <= 0
end

local function collect_dead_friendlies(world, player_handle)
    if not world or type(world.units) ~= "function" then return {}, false end
    local ok, units = pcall(world.units, world, {
        type = "player", reaction = "friendly", local_player = false,
    })
    if not ok or type(units) ~= "table" or #units > MAX_FRIENDLIES then
        return {}, false
    end
    local dead, seen = {}, {}
    local function consider(unit)
        local handle = safe_method(unit, "handle")
        if type(handle) ~= "string" or handle == player_handle or seen[handle] or
            not proven_dead_player(unit) or not within_heal_range(unit) then return end
        seen[handle] = true
        local distance = safe_method(unit, "distance")
        dead[#dead + 1] = {
            unit = unit, handle = handle,
            selected = safe_method(unit, "is_current_target") == true,
            distance = finite_number(distance) and distance or math.huge,
        }
    end
    consider(world.current_target)
    for _, unit in ipairs(units) do consider(unit) end
    table.sort(dead, function(lhs, rhs)
        if lhs.selected ~= rhs.selected then return lhs.selected end
        if lhs.distance ~= rhs.distance then return lhs.distance < rhs.distance end
        return lhs.handle < rhs.handle
    end)
    return dead, true
end

local function resolve_dead_friendly(world, handle)
    local ok, unit = pcall(world.resolve, world, handle)
    if not ok or not unit or safe_method(unit, "handle") ~= handle or
        not proven_dead_player(unit) or not within_heal_range(unit) then return nil end
    return unit
end

local function resolve_friendly(world, handle, policy)
    local ok, unit = pcall(world.resolve, world, handle)
    if not ok or not unit or safe_method(unit, "handle") ~= handle or
        safe_method(unit, "reaction") ~= "friendly" then return nil end
    local hp = safe_method(unit, "hp")
    if not healable_type(safe_method(unit, "type"), policy) or
        not living_hp(hp) or not within_heal_range(unit) then return nil end
    return unit
end

local function ability_state(known, name)
    if type(known) ~= "table" or known[name] ~= true then return nil end
    local info = Mirror.info(CurrentLoadout, name)
    if type(info) ~= "table" or info.ability_handle == nil then return nil end
    if info.has_resource_cost == true and finite_number(info.resource_cost) and
        info.resource_cost >= 0 then
        return { cost = info.resource_cost, costSource = "runtime",
            ready = info.ready == true, onBar = info.on_bar == true,
            abilityHandle = info.ability_handle }
    end
    local fallback = FALLBACK_COST[name]
    if not finite_number(fallback) or fallback < 0 then return nil end
    return { cost = fallback, costSource = "verified_fallback",
        ready = info.ready == true, onBar = info.on_bar == true,
        abilityHandle = info.ability_handle }
end

local function within_dps_range(target, name)
    local maximum = DPS_RANGE[name]
    if not finite_number(maximum) then return true end
    local distance = safe_method(target, "distance")
    return finite_number(distance) and distance >= 0 and
        distance * METERS_PER_WORLD_UNIT <= maximum
end

local function timing_gate(reason)
    return reason == "gcd" or reason == "busy" or reason == "cooldown"
end

local function admission_pending(reason)
    return reason == "castability_pending"
end

local function transient_gate(reason)
    return admission_pending(reason) or timing_gate(reason) or reason == "ability_metadata_unavailable" or
        reason == "ability_submission_pending" or
        reason == "explicit_target_sync_pending" or reason == "bridge_busy" or
        reason == "ability_command_busy" or reason == "command_busy"
end

local function target_specific_gate(reason)
    reason = tostring(reason or ""):lower()
    if reason == "retry_backoff" or reason == "explicit_target_contract" or
        reason == "explicit_target_sync_pending" or
        reason == "explicit_target_sync_suspended" or
        reason == "submitted_receipt_unresolved" then
        return true
    end
    return reason == "target_not_visible" or reason == "not_visible" or
        reason == "target_out_of_range" or reason == "out_of_range" or
        reason == "target_invalid" or reason == "invalid_target" or
        reason == "target_unavailable" or reason == "target_not_resolved" or
        reason == "target_not_in_world" or reason == "line_of_sight" or
        reason == "not_in_line_of_sight" or reason == "target_not_in_line_of_sight" or
        reason == "target_view_blocked" or reason == "too_far" or reason == "too_close" or
        reason == "not_facing" or reason == "target_dead" or reason == "target_untargetable" or
        reason == "missing_target" or reason == "stale_unit"
end

local function target_backoff_gate(reason)
    reason = tostring(reason or ""):lower()
    return reason == "target_not_visible" or reason == "not_visible" or
        reason == "target_out_of_range" or reason == "out_of_range" or
        reason == "target_invalid" or reason == "invalid_target" or
        reason == "target_unavailable" or reason == "target_not_resolved" or
        reason == "target_not_in_world" or reason == "line_of_sight" or
        reason == "not_in_line_of_sight" or reason == "target_not_in_line_of_sight" or
        reason == "target_view_blocked" or reason == "too_far" or reason == "too_close" or
        reason == "not_facing" or reason == "target_dead" or reason == "target_untargetable" or
        reason == "missing_target" or reason == "stale_unit"
end

local function target_skip_active(handle)
    local until_time = TargetSkipUntil[tostring(handle or "")]
    return finite_number(until_time) and now_seconds() < until_time
end

local function remember_target_skip(handle)
    if type(handle) == "string" then
        TargetSkipUntil[handle] = now_seconds() + TARGET_FAILOVER_BACKOFF_SECONDS
    end
end

local function exact_target_result(result, handle)
    return type(result) == "table" and result.target_mode == "explicit" and
        result.target_valid == true and result.requested_target_handle == handle and
        result.target_handle == handle and result.target_fallback == "none" and
        result.fallback_used ~= true
end

local function untargeted_result(result)
    return type(result) == "table" and result.target_mode == "none" and
        result.target_valid ~= true and result.requested_target_handle == nil and
        result.target_handle == nil and result.target_fallback == "none" and
        result.fallback_used ~= true and result.target_override ~= true
end

local function observed_effect(unit, name, kind)
    local actual, filter = Mirror.effect(CurrentLoadout, name, { kind = kind })
    if actual == nil then return nil end
    local effect = safe_method(unit, "effect", actual, filter)
    if type(effect) ~= "table" or effect.status ~= "ready" then return nil end
    if effect.present ~= true then return false end
    return effect
end

local function observed_definition_effect(unit, definition_key, kind)
    local actual, filter = Mirror.effect(CurrentLoadout, "", {
        kind = kind or "buff", definition_key = definition_key,
    })
    if actual == nil then return nil end
    local effect = safe_method(unit, "effect", actual, filter)
    if type(effect) ~= "table" or effect.status ~= "ready" or
        effect.truncated == true or effect.charge_conflicted == true then
        return nil
    end
    if effect.present ~= true then return false end
    if effect.has_timer == true and
        (not finite_number(effect.remaining) or effect.remaining <= 0) then
        return nil
    end
    if effect.has_charges == true and
        (not finite_number(effect.stacks) or effect.stacks <= 0 or
            effect.stacks % 1 ~= 0) then
        return nil
    end
    return effect
end

local function diagnostics_probe_snapshot(player)
    local observed = false
    for _, effect_name in ipairs(DIAGNOSTICS_PROBE_EFFECTS) do
        local effect = observed_effect(player, effect_name, "buff")
        if effect ~= nil then
            observed = true
        end
        if type(effect) == "table" and effect.mine == true then
            local stacks = 1
            if effect.has_charges == true and finite_number(effect.stacks) then
                stacks = math.floor(effect.stacks + 0.5)
            end
            stacks = clamp(stacks, 1, DIAGNOSTICS_PROBE_MAX_STACKS)
            local remaining = effect.has_timer == true and finite_number(effect.remaining) and
                math.max(0.0, effect.remaining) or nil
            return {
                known = true, present = true, stacks = stacks,
                remaining = remaining, source = effect_name,
            }
        end
    end
    if observed then
        return { known = true, present = false, stacks = 0, remaining = 0.0, source = "absent" }
    end
    return { known = false, present = false, stacks = nil, remaining = nil, source = "unavailable" }
end

local function action_proc_markers(known, name)
    if type(known)~="table" or MEDICINE_PROC_HEALS[name]~=true then return nil end
    local world=gos.world()
    local player=world and world.player or nil
    if not player then return nil end

    local markers={}
    local function add(label,detail)
        markers[#markers+1]={label=label,detail=detail}
    end
    local function present(key)
        return type(observed_definition_effect(player,key,"buff"))=="table"
    end

    -- Consumed/ability-specific procs first so the compact feed shows them
    -- before broad throughput buffs when more than three modifiers overlap.
    if (name==KOLTO_INJECTION or name==KOLTO_INFUSION) and
        known[ENDURING_KOLTO]==true and present(PROC_EFFECT.EnduringKolto) then
        add("Enduring Kolto","instant cast")
    end

    if name==KOLTO_INJECTION then
        local tactical=observed_definition_effect(player,PROC_EFFECT.TacticalProbe,"buff")
        if type(tactical)=="table" then
            local stacks=tactical.has_charges==true and tactical.stacks or nil
            if finite_number(stacks) and stacks>=1 and stacks<=DIAGNOSTICS_PROBE_MAX_STACKS and
                stacks%1==0 then
                stacks=math.floor(stacks)
                add("Tactical Probe x"..tostring(stacks),
                    stacks>=3 and "instant cast" or
                    string.format("-%.2fs cast",stacks*0.25))
            else
                add("Tactical Probe","faster Kolto Injection")
            end
        end
    end

    if name==SURGICAL_PROBE and known[CURATIVE_JOLT]==true and
        present(PROC_EFFECT.CurativeJolt) then
        add("Curative Jolt","+100% crit")
    end

    -- Broad active throughput buffs are still shown only when their exact
    -- transient effect is present before the accepted heal.
    if known[TACTICAL_MEDICINE]==true and present(PROC_EFFECT.TacticalMedicine) then
        add("Tactical Medicine","+3% heal")
    end
    if known[STIM_BURST]==true and present(PROC_EFFECT.StimBurst) then
        add("Stim Burst","+15% heal")
    end
    if known[TACTICAL_OVERDRIVE]==true and present(PROC_EFFECT.TacticalOverdrive) then
        add("Tactical Overdrive","+20% Mastery")
    end

    return #markers>0 and markers or nil
end

local function player_moving(player)
    local speed = safe_method(player, "speed")
    if not finite_number(speed) then return nil end
    return math.abs(speed) > 0.001
end

local function heal_usable_while_moving(known, player, name)
    if name == DIAGNOSTIC_SCAN then
        return known[SURPRISE_SURGERY] == true
    end
    if name == KOLTO_INJECTION then
        local diagnostic = diagnostics_probe_snapshot(player)
        if diagnostic.known == true and finite_number(diagnostic.stacks) and
            diagnostic.stacks >= DIAGNOSTICS_PROBE_MAX_STACKS then
            return true
        end
        return type(observed_effect(player, ENDURING_KOLTO, "buff")) == "table"
    end
    if name == KOLTO_INFUSION then
        return type(observed_effect(player, ENDURING_KOLTO, "buff")) == "table"
    end
    return true
end

-- Budget until direct support can resume AFTER the missing Probe casts.
-- Applying the final stack still consumes a GCD; it is not an immediate heal.
-- Missing timing remains unknown and never disables raw-HP/IDF rescue rails.
local function probe_setup_seconds(unit, missing_stacks)
    if not finite_number(missing_stacks) or missing_stacks <= 0 then return 0.0 end
    local advisory
    if gos and gos.abilities and type(gos.abilities.can_cast) == "function" then
        local ok, value = pcall(Mirror.can_cast, CurrentLoadout, KOLTO_PROBE, unit)
        if ok and type(value) == "table" then advisory = value end
    end
    local gcd_remaining = gos and gos.abilities and
        type(gos.abilities.gcd_remaining) == "function" and
        gos.abilities.gcd_remaining() or nil
    if not finite_number(gcd_remaining) and type(advisory) == "table" and
        finite_number(advisory.gcd_remaining) then
        gcd_remaining = advisory.gcd_remaining
    end
    if not finite_number(gcd_remaining) then
        if type(advisory) == "table" and advisory.ok == true then
            gcd_remaining = 0.0
        else
            return nil
        end
    end
    gcd_remaining = math.max(0.0, gcd_remaining)
    local gcd_duration = type(advisory) == "table" and advisory.gcd_duration or nil
    if not finite_number(gcd_duration) or gcd_duration <= 0 then return nil end
    return gcd_remaining + missing_stacks * gcd_duration
end

local function ta_max_stacks(known)
    return type(known) == "table" and known[SURGICAL_PRECISION] == true and 3 or 2
end

local function tactical_state(player, known)
    local effect = observed_effect(player, TACTICAL_ADVANTAGE, "buff")
    local cap = ta_max_stacks(known)
    if effect == false then
        return { known = true, present = false, stacks = 0, max = cap, source = "effect_absent" }
    end
    -- TA gains, consumption and Surgical Precision refunds belong to the game.
    -- Missing/invalid observations must not reuse old stacks or invent one.
    if effect == nil or effect.has_charges ~= true or effect.charge_conflicted == true or
        not finite_number(effect.stacks) or effect.stacks % 1 ~= 0 or
        effect.stacks < 1 or effect.stacks > cap then
        return { known = false, present = false, stacks = nil, max = cap, source = "unavailable" }
    end
    return { known = true, present = true, stacks = effect.stacks, max = cap, source = "effect" }
end

local function effect_absent_mine(unit, name, kind)
    local effect = observed_effect(unit, name, kind)
    if effect == nil then return nil end
    if effect == false then return true end
    return effect.mine ~= true
end

local function mine_effect_stacks(unit, name, kind)
    local effect = observed_effect(unit, name, kind)
    if effect == nil then return nil end
    if effect == false or effect.mine ~= true then return 0 end
    if effect.has_charges == true and finite_number(effect.stacks) then
        return math.max(1, math.floor(effect.stacks + 0.5))
    end
    return 1
end

local function mine_effect_snapshot(unit, name, kind)
    local effect = observed_effect(unit, name, kind)
    if effect == nil then return nil end
    if effect == false or effect.mine ~= true then
        return { stacks = 0, remaining = 0.0 }
    end
    local stacks = effect.has_charges == true and finite_number(effect.stacks) and
        math.max(1, math.floor(effect.stacks + 0.5)) or 1
    local remaining = effect.has_timer == true and finite_number(effect.remaining) and
        math.max(0.0, effect.remaining) or nil
    return { stacks = stacks, remaining = remaining }
end

local function kolto_probe_needs_refresh(unit, policy)
    local state = mine_effect_snapshot(unit, KOLTO_PROBE, "buff")
    -- Unknown observation is not evidence that the HoT is missing; fail closed
    -- so the route cannot spam Kolto Probe while Core catches up.
    if state == nil then return false, "observation_unknown" end
    if state.stacks < KOLTO_PROBE_MAX_STACKS then
        return true, "build_" .. tostring(state.stacks + 1)
    end
    if finite_number(state.remaining) and
        state.remaining <= policy.koltoProbeRefreshSeconds then
        return true, "refresh_expiring"
    end
    return false, "healthy"
end

local function distance_squared(lhs, rhs)
    if lhs.x == nil or rhs.x == nil then return nil end
    local dx, dy, dz = lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z
    return dx * dx + dy * dy + dz * dz
end

local function cluster_count(center, rows, radius_meters)
    local radius = radius_meters / METERS_PER_WORLD_UNIT
    local radius_sq, count = radius * radius, 0
    for _, row in ipairs(rows or {}) do
        local d2 = distance_squared(center, row)
        if d2 ~= nil and d2 <= radius_sq then count = count + 1 end
    end
    return count
end

local function best_cluster_center(lowest, injured, radius_meters)
    if lowest == nil then return nil, 0 end
    local best, best_count = lowest, cluster_count(lowest, injured, radius_meters)
    for _, candidate in ipairs(injured or {}) do
        local count = cluster_count(candidate, injured, radius_meters)
        if count > best_count or
            (count == best_count and better_heal_target(candidate, best)) then
            best, best_count = candidate, count
        end
    end
    return best, best_count
end

local function best_nanotech_center(known, lowest, injured, coverage, min_injured)
    if lowest == nil then return nil, 0, 0, "none" end
    coverage = coverage or injured
    local required_injured = finite_number(min_injured) and
        math.max(1, math.floor(min_injured + 0.5)) or 1
    local function counts(candidate)
        local injured_count = math.min(RECUPERATIVE_NANOTECH_MAX_TARGETS,
            cluster_count(candidate, injured, RECUPERATIVE_NANOTECH_RADIUS_METERS))
        local affected_count = math.min(RECUPERATIVE_NANOTECH_MAX_TARGETS,
            cluster_count(candidate, coverage, RECUPERATIVE_NANOTECH_RADIUS_METERS))
        return injured_count, affected_count
    end

    local lowest_injured, lowest_affected = counts(lowest)
    -- Nano Mark buffs healing received from us on the initial target, so center
    -- the cast on the current triage target rather than sacrificing that bonus.
    if known[NANO_MARK] == true then
        return lowest, lowest_injured, lowest_affected, "nano_mark_focus"
    end
    if known[NANOTECH_STIM] ~= true and known[CRITICAL_NANOTECH] ~= true then
        return lowest, lowest_injured, lowest_affected, "base"
    end

    if known[NANOTECH_STIM] == true then
        -- Do not trade away the configured amount of meaningful healing merely to
        -- touch healthy bodies. Among centers that cover enough injured allies,
        -- maximize total affected targets first (2s Stim Boost CD each, max 8s),
        -- then injured coverage, then the normal lowest/pressure triage target.
        local best, best_injured, best_affected = nil, 0, 0
        for _, candidate in ipairs(injured or {}) do
            local injured_count, affected_count = counts(candidate)
            if injured_count >= required_injured and
                (best == nil or affected_count > best_affected or
                    (affected_count == best_affected and injured_count > best_injured)) then
                -- Exact ties keep the earlier candidate. `injured` is already in
                -- the active triage order (pressure formula or HP ordering), so
                -- this preserves the currently more endangered primary target.
                best, best_injured, best_affected = candidate, injured_count, affected_count
            end
        end
        if best ~= nil then
            return best, best_injured, best_affected, "nanotech_stim_cluster"
        end
        return lowest, lowest_injured, lowest_affected, "nanotech_stim_focus"
    end

    -- Preserve Critical Nanotech's existing healing-first center choice.
    local best, best_injured, best_affected = lowest, lowest_injured, lowest_affected
    for _, candidate in ipairs(injured or {}) do
        local injured_count, affected_count = counts(candidate)
        if injured_count > best_injured or
            (injured_count == best_injured and better_heal_target(candidate, best)) then
            best, best_injured, best_affected = candidate, injured_count, affected_count
        end
    end
    return best, best_injured, best_affected, "critical_nanotech_cluster"
end

local function kolto_burst_count(player, injured)
    local position = safe_method(player, "position")
    if not valid_position(position) then return 0 end
    local center = { x = position.x, y = position.y, z = position.z }
    local radius = KOLTO_BURST_RADIUS_METERS / METERS_PER_WORLD_UNIT
    local radius_sq, count = radius * radius, 0
    for _, row in ipairs(injured or {}) do
        local d2 = distance_squared(center, row)
        if d2 ~= nil and d2 <= radius_sq then count = count + 1 end
    end
    return count
end

local function toughness_is_durable(toughness)
    if type(toughness) ~= "table" then return false end
    if finite_number(toughness.value) and
        (toughness.value == 6 or (toughness.value >= 9 and toughness.value <= 14)) then
        return true
    end
    local label = type(toughness.label) == "string" and toughness.label:lower() or ""
    return label:find("champion", 1, true) ~= nil or
        label:find("boss", 1, true) ~= nil or
        label:find("conqueror", 1, true) ~= nil
end

local function durable_hostile(target, player)
    if safe_method(target, "type") == "player" then return true end
    if toughness_is_durable(safe_method(target, "toughness")) then return true end
    local target_hp, player_hp = safe_method(target, "hp"), safe_method(player, "hp")
    return living_hp(target_hp) and living_hp(player_hp) and target_hp.max >= player_hp.max
end

local function dps_policy(options)
    local configured = type(options) == "table" and options.dps or nil
    configured = type(configured) == "table" and configured or {}
    local reserve = finite_number(configured.energyReservePercent) and
        clamp(configured.energyReservePercent, 0, 100) or 70
    return {
        enabled = configured.enabled ~= false,
        energyReservePercent = reserve,
        buildTactical = configured.buildTactical ~= false,
        backstab = configured.backstab ~= false,
        corrosiveDart = configured.corrosiveDart ~= false,
        overloadShot = configured.overloadShot ~= false,
        rifleShot = configured.rifleShot ~= false,
    }
end

local function reserve_energy(resource, policy)
    if type(resource) ~= "table" or not finite_number(resource.max) or resource.max <= 0 then
        return math.huge
    end
    return resource.max * policy.energyReservePercent / 100.0
end

local function routine_heal_reserve(resource)
    if type(resource) ~= "table" or not finite_number(resource.max) or resource.max <= 0 then
        return math.huge
    end
    return resource.max * ROUTINE_HEAL_ENERGY_RESERVE_PERCENT / 100.0
end

local function can_afford(state, resource, reserve)
    return state ~= nil and finite_number(resource.current) and
        state.cost <= resource.current and resource.current - state.cost >= reserve
end

local function action_target(world)
    local target = world and world.current_target or nil
    if not target then return nil, nil, "missing_current_target" end
    local handle = safe_method(target, "handle")
    if type(handle) ~= "string" then
        return nil, nil, "target_handle_unavailable"
    end
    if safe_method(target, "reaction") ~= "hostile" then
        return nil, nil, "target_not_hostile"
    end
    local hp = safe_method(target, "hp")
    -- Offensive targeting must not treat an unavailable vitals snapshot as a
    -- dead unit. Current-target identity/reaction are authoritative here; only
    -- positively observed zero HP proves death. Core submit remains the final
    -- engine admission check for every submitted attack.
    if type(hp) == "table" and finite_number(hp.current) and hp.current <= 0 then
        return nil, nil, "target_dead"
    end
    return target, handle, type(hp) == "table" and "target_ready" or
        "target_ready_hp_unavailable"
end

local function hostile_count_within(world, meters)
    if not world or type(world.units) ~= "function" then return nil end
    local ok, units = pcall(world.units, world, { reaction = "hostile" })
    if not ok or type(units) ~= "table" or #units > MAX_FRIENDLIES then return nil end
    local count = 0
    for _, unit in ipairs(units) do
        local distance = safe_method(unit, "distance")
        local hp = safe_method(unit, "hp")
        local known_dead = type(hp) == "table" and finite_number(hp.current) and hp.current <= 0
        if not known_dead and finite_number(distance) and distance >= 0 and
            distance * METERS_PER_WORLD_UNIT <= meters then
            count = count + 1
        end
    end
    return count
end

local function can_stun_for_peel(target)
    if safe_method(target, "type") == "player" then return true end
    local toughness = safe_method(target, "toughness")
    local label = type(toughness) == "string" and toughness:lower() or ""
    if label:find("boss", 1, true) or label:find("champion", 1, true) or
        label:find("conqueror", 1, true) or label:find("legendary", 1, true) then
        return false
    end
    return true
end

local function cooldown_remaining(name)
    local api = gos and gos.abilities or nil
    if not api or type(api.cooldown_remaining) ~= "function" then return nil end
    local ok, value = pcall(Mirror.cooldown_remaining, CurrentLoadout, name)
    return ok and finite_number(value) and math.max(0.0, value) or nil
end

local function retry_key(name, handle)
    return tostring(name) .. ":" .. tostring(handle or "none")
end

local function reject_backoff_active(name, handle)
    local until_time = CastRejectUntil[retry_key(name, handle)]
    return finite_number(until_time) and now_seconds() < until_time
end

local function remember_cast_reject(options, name, handle, reason)
    local now = now_seconds()
    CastRejectUntil[retry_key(name, handle)] = now + CAST_REJECT_BACKOFF_SECONDS
    if options.decisionLog ~= true then return end
    local key = retry_key(name, handle) .. ":" .. tostring(reason)
    local last = LastCastRejectLog[key]
    if not finite_number(last) or now - last >= CAST_REJECT_LOG_INTERVAL_SECONDS then
        LastCastRejectLog[key] = now
        emit(options, "debug", "operative medicine cast rejected: ability=" ..
            tostring(name) .. " reason=" .. tostring(reason))
    end
end

local function log_heal_unavailable(options, name, handle, stage, reason,
        resource, target_ratio, ta)
    if options.decisionLog ~= true then return end
    local now = now_seconds()
    local key = table.concat({ tostring(name), tostring(handle), tostring(stage),
        tostring(reason) }, "|")
    local last = LastHealUnavailableLog[key]
    if finite_number(last) and
        now - last < HEAL_UNAVAILABLE_LOG_INTERVAL_SECONDS then
        return
    end
    LastHealUnavailableLog[key] = now
    local energy = type(resource) == "table" and
        (tostring(resource.current) .. "/" .. tostring(resource.max)) or "?"
    local ta_detail = type(ta) == "table" and
        (tostring(ta.known) .. "/" .. tostring(ta.stacks or 0) .. "/" ..
            tostring(ta.max or "?")) or "?"
    emit(options, "debug", "operative medicine heal unavailable: ability=" ..
        tostring(name) .. " stage=" .. tostring(stage) ..
        " reason=" .. tostring(reason) .. " target=" .. tostring(handle) ..
        " hp=" .. tostring(finite_number(target_ratio) and
            string.format("%.1f%%", target_ratio * 100.0) or "?") ..
        " energy=" .. energy .. " ta=" .. ta_detail)
end

local function submitted_receipt_key(name, handle)
    return tostring(name) .. "|" .. tostring(handle or "none")
end

local function positive_sequence(value)
    return finite_number(value) and value > 0
end

local function submitted_receipt_status_resolved(command)
    if type(command) ~= "string" then return true end
    local status = gos.abilities.command_status(command)
    if type(status) ~= "table" or status.known ~= true then return true end
    return positive_sequence(status.post_terminal_activation_sequence) or
        positive_sequence(status.post_terminal_replication_sequence) or
        positive_sequence(status.post_terminal_rejection_sequence) or
        positive_sequence(status.competing_activation_event_sequence)
end

local function submitted_receipt_guard_active(name, unit, handle)
    local key = submitted_receipt_key(name, handle)
    local guard = SubmittedReceiptGuard[key]
    if type(guard) ~= "table" or type(guard.command) ~= "string" then
        return false
    end

    local status = gos.abilities.command_status(guard.command)
    if type(status) ~= "table" or status.known ~= true or
        submitted_receipt_status_resolved(guard.command) then
        SubmittedReceiptGuard[key] = nil
        return false
    end

    -- Do not invent a delay after request_submission_completed. Hold only while
    -- Core still reports the same cast as apparently ready despite the unresolved
    -- native receipt. Once engine readiness catches up and reports GCD/busy/
    -- submission ownership, drop the guard and let the normal exact advisory
    -- enforce that authoritative gate.
    local readiness = Mirror.can_cast(CurrentLoadout, name, unit)
    if type(readiness) == "table" and readiness.ok ~= true then
        local reason = tostring(readiness.reason or readiness.code or "blocked")
        if timing_gate(reason) or reason == "ability_submission_pending" or
            reason == "bridge_busy" or reason == "ability_command_busy" or
            reason == "command_busy" then
            SubmittedReceiptGuard[key] = nil
            return false
        end
    end
    return true
end

-- Core submit is the only admission producer used by Medicine decisions.
-- A pending response is neither an accepted command nor a failed ability.
local function submit_admitted(executor, options, known, name, unit, handle, decision, mode, reserve)
    local key = OWNER_PREFIX .. name .. ":" .. handle .. (mode == "ground" and ":ground" or "")
    -- Snapshot proc evidence before the command, matching Seer's action-feed
    -- semantics. The cast may consume or replace these effects immediately.
    local proc_markers = type(options.onAction)=="function" and
        action_proc_markers(known,name) or nil
    if type(options.clearMedicineAdmission) == "function" then
        options.clearMedicineAdmission()
    end
    local result = Mirror.submit(executor, CurrentLoadout, name, unit, {
        idempotencyKey = key, target_fallback = unit ~= nil and "none" or nil,
    })
    local reason = type(result) == "table" and
        tostring(result.reason or result.code or "cast_failed") or "invalid_cast_result"
    local accepted = type(result) == "table" and result.accepted == true
    local pending = type(result) == "table" and result.admission_pending == true
    local core = type(result) == "table" and type(result.core) == "table" and result.core or {}
    if accepted or pending then
        local contract_ok
        if mode == "explicit" then contract_ok = exact_target_result(core, handle)
        elseif mode == "none" then contract_ok = untargeted_result(core)
        else
            -- Preserve Core's existing two-stage/omitted-target ground path.
            contract_ok = core.target_fallback == "none" and core.fallback_used ~= true and
                core.target_override ~= true and
                (core.target_mode == "none" or core.target_mode == "selected")
        end
        if not contract_ok then
            local status = executor:status()
            if executor:owns_command() and type(status) == "table" and
                status.idempotency_key == key and status.command_handle == result.command_handle then
                executor:cancel("medicine_target_contract")
            end
            local failure = mode == "explicit" and "explicit_target_contract" or "no_external_target_contract"
            remember_cast_reject(options, name, handle, failure)
            return false, failure, result
        end
    end
    if pending then
        if type(options.recordMedicineAdmission) == "function" then
            local state = ability_state(known, name)
            options.recordMedicineAdmission({
                name = name, unit = unit, handle = handle, decision = decision,
                mode = mode, reserve = reserve, key = key,
                abilityHandle = state and state.abilityHandle or nil,
                cleanseCandidate = options.medicineAdmissionCandidate,
            })
        end
        if options.decisionLog == true then
            local now = now_seconds()
            local log_key = "admission:" .. retry_key(name, handle)
            if now - (LastCastRejectLog[log_key] or -math.huge) >= CAST_REJECT_LOG_INTERVAL_SECONDS then
                LastCastRejectLog[log_key] = now
                emit(options, "debug", "operative medicine admission pending: ability=" .. name ..
                    " target=" .. handle .. " policy=next_tick_live_admission")
            end
        end
        return false, reason, result -- No retry backoff or speculative HoT/TA evidence.
    end
    if not accepted then
        if not transient_gate(reason) then remember_cast_reject(options, name, handle, reason) end
        return false, reason, result
    end
    CastRejectUntil[retry_key(name, handle)] = nil
    if type(options.onAction) == "function" then
        local action_meta={}
        if type(proc_markers)=="table" and #proc_markers>0 then
            action_meta.procs=proc_markers
        end
        options.onAction({
            ability = name,
            decision = decision,
            command_handle = type(result) == "table" and result.command_handle or nil,
            target_handle = handle,
            target_name = safe_method(unit, "name"),
            target_type = mode == "none" and "none" or
                tostring(safe_method(unit, "type") or "unknown"),
            untargeted = mode == "none",
            meta = action_meta,
        })
    end
    if options.castLog == true then
        emit(options, "info", "operative medicine cast queued: ability=" .. name ..
            " reason=" .. tostring(decision) .. " target=" .. handle .. " mode=" .. mode)
    end
    return true, "submitted", result
end

local function submit_explicit(executor, options, known, name, unit, handle,
        resource, decision, reserve)
    if submitted_receipt_guard_active(name, unit, handle) then
        return false, "submitted_receipt_unresolved"
    end
    if reject_backoff_active(name, handle) then return false, "retry_backoff" end
    local state = ability_state(known, name)
    if state == nil or state.cost > resource.current then return false, "ability_state" end
    if finite_number(reserve) and resource.current - state.cost < reserve then
        return false, "energy_reserve"
    end
    if type(handle) ~= "string" or safe_method(unit, "handle") ~= handle then
        return false, "target_unavailable"
    end
    -- Friendly rows are snapshots. Re-check the live unit immediately before
    -- admission so a death between triage/cluster selection and submission can
    -- never consume a heal (notably Recuperative Nanotech) on a corpse.
    if FRIENDLY_HEAL[name] == true then
        local live_hp = safe_method(unit, "hp")
        if not living_hp(live_hp) then
            if type(live_hp) == "table" and finite_number(live_hp.current) and
                live_hp.current <= 0 then
                return false, "target_dead"
            end
            return false, "target_unavailable"
        end
    end
    return submit_admitted(executor, options, known, name, unit, handle, decision,
        "explicit", reserve)
end

local function submit_untargeted(executor, options, known, name, resource, decision)
    local handle = "untargeted"
    if reject_backoff_active(name, handle) then return false, "retry_backoff" end
    local state = ability_state(known, name)
    if state == nil or state.cost > resource.current then return false, "ability_state" end
    -- Current Core readiness includes cooldown/charges/GCD without a query.
    -- Implicit casts do not have the explicit-target pre-admission timing check.
    if not state.onBar then return false, "not_on_quickbar" end
    if not state.ready then return false, "not_ready" end
    return submit_admitted(executor, options, known, name, nil, handle, decision,
        "none", nil)
end

local function submit_ground(executor, options, known, name, center_handle,
        resource, moving, decision, reserve)
    local handle = tostring(center_handle or "ground")
    if reject_backoff_active(name, handle) then return false, "retry_backoff" end
    local state = ability_state(known, name)
    if state == nil or state.cost > resource.current then return false, "ability_state" end
    if finite_number(reserve) and resource.current - state.cost < reserve then
        return false, "energy_reserve"
    end
    if moving == true then return false, "moving" end
    local gcd = gos.abilities.gcd_remaining()
    if finite_number(gcd) and gcd > 0.04 then return false, "ground_start_locked" end
    if gos.abilities.is_casting_or_channeling() == true then return false, "busy" end
    if not state.onBar then return false, "not_on_quickbar" end
    if not state.ready then return false, "not_ready" end
    return submit_admitted(executor, options, known, name, nil, handle, decision,
        "ground", reserve)
end

local function diagnostics(options, known, resource, ta, lowest)
    if options.abilityDiagnostics ~= true then return end
    local pieces = {}
    for _, name in ipairs({
        DIAGNOSTIC_SCAN, KOLTO_INJECTION, KOLTO_INFUSION, KOLTO_PROBE,
        RECUPERATIVE_NANOTECH, SURGICAL_PROBE, KOLTO_WAVES,
        BACKSTAB, SHIV, CORROSIVE_DART, NOXIOUS_KNIVES, OVERLOAD_SHOT, RIFLE_SHOT,
        STIM_BOOST, TACTICAL_OVERDRIVE, SHIELD_PROBE, RESUSCITATION_PROBE,
        EVASION, DEBILITATE, ADRENALINE_PROBE,
    }) do
        local state = ability_state(known, name)
        pieces[#pieces + 1] = name .. "=" ..
            (state and (tostring(state.cost) .. "(" ..
                tostring(state.costSource or "-") .. ")") or "-")
    end
    local lowest_text = "none"
    if lowest then
        local ratio = finite_number(lowest.current) and finite_number(lowest.maximum) and
            lowest.maximum > 0 and lowest.current / lowest.maximum * 100.0 or nil
        lowest_text = tostring(lowest.handle) .. "/" .. tostring(lowest.unitType or "?") ..
            "/self=" .. tostring(lowest.isSelf == true) ..
            "/hp=" .. (finite_number(ratio) and string.format("%.1f%%", ratio) or "?")
    end
    emit(options, "debug", "operative medicine state: energy=" ..
        tostring(math.floor(resource.current + 0.5)) .. "/" ..
        tostring(math.floor(resource.max + 0.5)) .. " ta=" ..
        tostring(ta.present) .. "/" .. tostring(ta.stacks or "?") ..
        "/max=" .. tostring(ta.max or "?") ..
        "/known=" .. tostring(ta.known) .. "/source=" .. tostring(ta.source or "-") ..
        " lowest=" .. lowest_text ..
        " kit=" .. table.concat(pieces, ","))
end

function M.new(executor)
    assert(type(executor) == "table" and type(executor.status) == "function",
        "operative_medicine.new requires the shared AbilityExecutor")

    CastRejectUntil = {}
    TargetSkipUntil = {}
    SubmittedReceiptGuard = {}
    LastCastRejectLog = {}
    LastHealUnavailableLog = {}

    local runtime = {
        nativeAdmission = nil,
        groupRecovery = false,
        triagePlayerHandle = nil,
        triageActorEpoch = nil,
        repeatLogs = {},
        repeatLogOptions = nil,
        nextRepeatFlushAt = 0.0,
        lastDiagnosticAt = -math.huge,
        lastProbeDiagnosticAt = -math.huge,
        lastKitSignature = nil,
        backstabCommand = nil,
        stealthConsumedUntil = 0.0,
        stealthUnknownSince = nil,
        probeRoster = {},
        probeCommand = nil,
        probeEvidence = {},
        lastHealLifecycleCommand = nil,
        lastSubmittedReceiptCommand = nil,
        receiptAvoidTarget = nil,
        curativeJoltReadyAt = 0.0,
        curativeJoltAvailable = false,
        pressureDamage = {},
        pressureHotHealing = {},
        pressureDamageByTarget = {},
        pressureHotHealingByTarget = {},
        pressureDamageSeq = 0,
        pressureHotHealingSeq = 0,
        pressureDamageMinSeq = 1,
        pressureHotHealingMinSeq = 1,
        pressureDegradedUntil = 0.0,
        pressureFocusHandle = nil,
        lastPressureDiagnosticAt = -math.huge,
        lastPrereqGate = nil,
        lastPrereqGateAt = -math.huge,
        battleRezCommand = nil,
        battleRezBlockedUntil = 0.0,
        battleRezTargetBlockedUntil = {},
    }

    local function index_pressure_by_target(rows)
        local indexed = {}
        for _, row in ipairs(rows) do
            local target = type(row) == "table" and row.target or nil
            if type(target) == "string" then
                local bucket = indexed[target]
                if bucket == nil then
                    bucket = {}
                    indexed[target] = bucket
                end
                bucket[#bucket + 1] = row
            end
        end
        return indexed
    end

    local function append_pressure_indexed(kind, row)
        local rows_key = kind == "damage" and "pressureDamage" or "pressureHotHealing"
        local index_key = kind == "damage" and "pressureDamageByTarget" or "pressureHotHealingByTarget"
        local seq_key = kind == "damage" and "pressureDamageSeq" or "pressureHotHealingSeq"
        local min_key = kind == "damage" and "pressureDamageMinSeq" or "pressureHotHealingMinSeq"
        runtime[seq_key] = runtime[seq_key] + 1
        row.seq = runtime[seq_key]
        local rows = runtime[rows_key]
        rows[#rows + 1] = row
        local bucket = runtime[index_key][row.target]
        if bucket == nil then
            bucket = {}
            runtime[index_key][row.target] = bucket
        end
        bucket[#bucket + 1] = row
        runtime[min_key] = math.max(1, runtime[seq_key] - PRESSURE_MAX_EVENTS + 1)

        if #rows > PRESSURE_MAX_EVENTS * 2 then
            local kept = {}
            for _, event in ipairs(rows) do
                if event.seq >= runtime[min_key] then
                    kept[#kept + 1] = event
                end
            end
            runtime[rows_key] = kept
            runtime[index_key] = index_pressure_by_target(kept)
        end
    end

    local function observe_pressure_events(options, player_handle)
        local now_ms = gos.time_ms()
        if not finite_number(now_ms) then return end
        local batch = type(options) == "table" and options.combatBatch or nil
        if type(batch) ~= "table" then return end
        if finite_number(batch.dropped) and batch.dropped > 0 then
            runtime.pressureDamage = {}
            runtime.pressureHotHealing = {}
            runtime.pressureDamageByTarget = {}
            runtime.pressureHotHealingByTarget = {}
            runtime.pressureDamageSeq = 0
            runtime.pressureHotHealingSeq = 0
            runtime.pressureDamageMinSeq = 1
            runtime.pressureHotHealingMinSeq = 1
            runtime.pressureDegradedUntil = now_ms / 1000.0 + PRESSURE_HISTORY_MS / 1000.0
        end
        for _, event in ipairs(batch.events or {}) do
            if type(event) == "table" then
                local at = finite_number(event.timestamp) and event.timestamp or now_ms
                if event.kind == "damage" and type(event.target_handle) == "string" and
                    finite_number(event.effective_amount) and event.effective_amount >= 0 then
                    append_pressure_indexed("damage", {
                        t = at, target = event.target_handle,
                        source = event.source_handle or "unknown",
                        amount = event.effective_amount,
                    })
                elseif event.kind == "heal" and type(player_handle) == "string" and
                    event.source_handle == player_handle and type(event.target_handle) == "string" and
                    (Mirror.canonical(CurrentLoadout, event.name) == KOLTO_PROBE or Mirror.canonical(CurrentLoadout, event.name) == RECUPERATIVE_NANOTECH) and
                    finite_number(event.amount) and event.amount > 0 then
                    append_pressure_indexed("hot", {
                        t = at, target = event.target_handle, amount = event.amount,
                    })
                end
            end
        end
    end

    local function pressure_features(row, now_ms)
        now_ms = finite_number(now_ms) and now_ms or gos.time_ms()
        if not finite_number(now_ms) or now_ms / 1000.0 < runtime.pressureDegradedUntil then
            return nil
        end
        local d075, d075_2, d2_4 = 0, 0, 0
        local attackers3, recent_sources, older_sources = {}, {}, {}
        for _, event in ipairs(runtime.pressureDamageByTarget[row.handle] or {}) do
            if event.seq >= runtime.pressureDamageMinSeq then
                local age = now_ms - event.t
                if age >= 0 and age <= 4000 then
                    local amount = math.max(0, event.amount or 0)
                    local source = event.source or "unknown"
                    if age <= 3000 then attackers3[source] = true end
                    if age <= 750 then
                        d075 = d075 + amount
                        recent_sources[source] = true
                    elseif age <= 2000 then
                        d075_2 = d075_2 + amount
                        older_sources[source] = true
                    else
                        d2_4 = d2_4 + amount
                        older_sources[source] = true
                    end
                end
            end
        end
        local attacker_count, recent_count, persistent_count = 0, 0, 0
        for _ in pairs(attackers3) do attacker_count = attacker_count + 1 end
        for source in pairs(recent_sources) do
            recent_count = recent_count + 1
            if older_sources[source] then persistent_count = persistent_count + 1 end
        end
        local recent_hot = 0
        for _, event in ipairs(runtime.pressureHotHealingByTarget[row.handle] or {}) do
            if event.seq >= runtime.pressureHotHealingMinSeq and
                now_ms - event.t >= 0 and now_ms - event.t <= PRESSURE_HOT_WINDOW_MS then
                recent_hot = recent_hot + math.max(0, event.amount or 0)
            end
        end
        local hot_hps = recent_hot / (PRESSURE_HOT_WINDOW_MS / 1000.0)
        return PressureFormula.evaluate({
            hp = row.current, max_hp = row.maximum,
            damage_075s = d075,
            damage_075_2s = d075_2,
            damage_2_4s = d2_4,
            attackers_3s = attacker_count,
            recent_attackers = recent_count,
            persistent_attackers = persistent_count,
            hot_healing_2s = hot_hps * 2.0,
            hot_healing_4s = hot_hps * 4.0,
        })
    end

    local function apply_pressure_triage(injured, policy)
        if policy.triageMode ~= PressureFormula.MODE_PRESSURE or
            now_seconds() < runtime.pressureDegradedUntil then
            runtime.pressureFocusHandle = nil
            return false
        end
        -- IDF adds value only when it has pressure evidence. With no recent
        -- damage/HoT observations preserve Medicine's established HP/self-bias
        -- ordering instead of manufacturing a zero-pressure formula ranking.
        local now_ms = gos.time_ms()
        local handles, evidence = {}, false
        for _, row in ipairs(injured or {}) do handles[row.handle] = true end
        if finite_number(now_ms) then
            for handle in pairs(handles) do
                for _, event in ipairs(runtime.pressureDamageByTarget[handle] or {}) do
                    if event.seq >= runtime.pressureDamageMinSeq then
                        local age = now_ms - event.t
                        if age >= 0 and age <= 4000 then
                            evidence = true
                            break
                        end
                    end
                end
                if evidence then break end
            end
            if not evidence then
                for handle in pairs(handles) do
                    for _, event in ipairs(runtime.pressureHotHealingByTarget[handle] or {}) do
                        if event.seq >= runtime.pressureHotHealingMinSeq then
                            local age = now_ms - event.t
                            if age >= 0 and age <= PRESSURE_HOT_WINDOW_MS then
                                evidence = true
                                break
                            end
                        end
                    end
                    if evidence then break end
                end
            end
        end
        if not evidence then
            runtime.pressureFocusHandle = nil
            return false
        end
        for _, row in ipairs(injured or {}) do
            row.pressure = pressure_features(row, now_ms)
        end
        table.sort(injured, function(lhs, rhs)
            if lhs.pressure and rhs.pressure then
                local compared = PressureFormula.compare(lhs.pressure, rhs.pressure)
                if compared ~= 0 then return compared < 0 end
            elseif lhs.pressure ~= nil then
                return true
            elseif rhs.pressure ~= nil then
                return false
            end
            return better_heal_target(lhs, rhs)
        end)

        -- Pressure sorting is allowed to pick a new focus, but once a patient is
        -- already in the configured burst band keep that patient sticky until it
        -- leaves the band, another patient is actually lower HP, or a new band-0
        -- life-saving emergency appears. This prevents higher-HP pressure-score
        -- jitter from donating a GCD away from an established tunnel target.
        local ceiling = burst_ceiling(policy)
        local focus_index, focus_row
        if type(runtime.pressureFocusHandle) == "string" then
            for index, row in ipairs(injured or {}) do
                if row.handle == runtime.pressureFocusHandle then
                    focus_index, focus_row = index, row
                    break
                end
            end
        end
        local selected = injured and injured[1] or nil
        if focus_row and focus_row.maximum > 0 and
            focus_row.current / focus_row.maximum <= ceiling and selected and
            selected.maximum > 0 and selected.handle ~= focus_row.handle then
            local focus_band = focus_row.pressure and focus_row.pressure.risk_band or nil
            local selected_band = selected.pressure and selected.pressure.risk_band or nil
            local focus_ratio = focus_row.current / focus_row.maximum
            local selected_ratio = selected.current / selected.maximum
            local life_saving_preempt = selected_band == 0 and focus_band ~= 0
            local lower_hp_preempt = selected_ratio < focus_ratio
            if not life_saving_preempt and not lower_hp_preempt then
                table.remove(injured, focus_index)
                table.insert(injured, 1, focus_row)
                selected = focus_row
            end
        end
        if selected and selected.maximum > 0 and
            selected.current / selected.maximum <= ceiling then
            runtime.pressureFocusHandle = selected.handle
        else
            runtime.pressureFocusHandle = nil
        end
        return true
    end

    local function owns_pending()
        if not executor:owns_command() then return false end
        local status = executor:status()
        local key = type(status) == "table" and status.idempotency_key or nil
        return type(key) == "string" and key:sub(1, #OWNER_PREFIX) == OWNER_PREFIX
    end

    local function flush_repeat(entry)
        if entry.count == 0 then return end
        local suffix = string.format(" count=%d first_repeat_ms=%.0f last_repeat_ms=%.0f",
            entry.count, entry.firstRepeatAt * 1000, entry.lastSeenAt * 1000)
        if entry.distanceMin ~= nil then
            suffix = suffix .. " distance_first_m=" .. tostring(entry.distanceFirst) ..
                " distance_min_m=" .. tostring(entry.distanceMin) ..
                " distance_max_m=" .. tostring(entry.distanceMax) ..
                " distance_last_m=" .. tostring(entry.distanceLast)
        end
        emit(runtime.repeatLogOptions, "debug", "operative medicine repeated: " .. entry.message .. suffix)
        entry.count, entry.distanceMin, entry.distanceMax = 0, nil, nil
    end

    local function flush_repeat_logs(force)
        if runtime.repeatLogOptions == nil then return end
        local now = now_seconds()
        if not force and now < runtime.nextRepeatFlushAt then return end
        runtime.nextRepeatFlushAt = now + REPEAT_LOG_INTERVAL_SECONDS
        -- At most six decision categories plus submitted-receipt rotation.
        for _, entry in pairs(runtime.repeatLogs) do flush_repeat(entry) end
    end

    local function log_repeated(options, category, message, distance)
        if options.decisionLog ~= true then return end
        runtime.repeatLogOptions = options
        local now = now_seconds()
        local entry = runtime.repeatLogs[category]
        if entry and (entry.message ~= message or
            now - entry.lastSeenAt >= REPEAT_LOG_INTERVAL_SECONDS) then
            flush_repeat(entry)
            entry = nil
        end
        if not entry then
            runtime.repeatLogs[category] = { message = message, count = 0, lastSeenAt = now }
            emit(options, "debug", "operative medicine " .. message ..
                (distance ~= nil and (" distance_m=" .. tostring(distance)) or ""))
        else
            entry.count = entry.count + 1
            if entry.count == 1 then entry.firstRepeatAt = now; entry.distanceFirst = distance end
            entry.lastSeenAt = now
            if distance ~= nil then
                entry.distanceMin = entry.distanceMin and math.min(entry.distanceMin, distance) or distance
                entry.distanceMax = entry.distanceMax and math.max(entry.distanceMax, distance) or distance
                entry.distanceLast = distance
            end
        end
    end

    local function log_decision(options, decision, detail, distance)
        if options.decisionLog ~= true then return end
        local message = "decision: " .. decision .. " detail=" .. tostring(detail or "-")
        if REPEATED_DECISIONS[decision] then
            log_repeated(options, decision, message, distance)
        else
            emit(options, "debug", "operative medicine " .. message)
        end
    end

    local function command_started(status)
        return type(status) == "table" and type(status.core) == "table" and
            status.core.activation_proven == true
    end

    local function service_backstab_start(options)
        local command = runtime.backstabCommand
        if type(command) ~= "string" then return end
        local status = executor:status()
        if type(status) ~= "table" or status.command_handle ~= command then return end
        if command_started(status) then
            runtime.stealthConsumedUntil = now_seconds() + 3.0
            runtime.backstabCommand = nil
            log_decision(options, "stealth_opener", "backstab_start_confirmed")
        elseif status.core and status.core.terminal == true and
            executor:owns_command() ~= true then
            runtime.backstabCommand = nil
        end
    end

    local function service_probe_start(options)
        local command = runtime.probeCommand
        if type(command) ~= "table" or type(command.handle) ~= "string" then return end
        local status = executor:status()
        if type(status) ~= "table" or status.command_handle ~= command.handle then return end
        if command_started(status) then
            runtime.probeEvidence[command.target] = {
                startedAt = now_seconds(), detail = command.detail,
                baselineRemaining = command.baselineRemaining,
                expectedStacks = command.detail == "build_1" and 1 or 2,
            }
            runtime.probeCommand = nil
            log_decision(options, "probe_lifecycle", "start_confirmed_" .. command.detail)
        elseif status.core and status.core.terminal == true and
            executor:owns_command() ~= true then
            runtime.probeCommand = nil
        end
    end

    local function service_submitted_receipt(options)
        if runtime.receiptAvoidTarget and
            submitted_receipt_status_resolved(runtime.lastSubmittedReceiptCommand) then
            runtime.receiptAvoidTarget = nil
        end

        local status = executor:status()
        if type(status) ~= "table" then return end
        local command = status.command_handle
        local core = type(status.core) == "table" and status.core or {}
        if status.disposition == "submitted" and core.state == "submitted" and
            status.reason == "request_submission_completed" and
            FRIENDLY_HEAL[Mirror.canonical(CurrentLoadout, status.ability)] == true and type(command) == "string" then
            if command ~= runtime.lastSubmittedReceiptCommand then
                local handle = core.requested_target_handle
                if type(handle) ~= "string" then
                    local key = status.idempotency_key
                    handle = type(key) == "string" and key:match(":(unit:.+)$") or nil
                end
                runtime.lastSubmittedReceiptCommand = command
                runtime.receiptAvoidTarget = type(handle) == "string" and handle or nil
                if runtime.receiptAvoidTarget then
                    SubmittedReceiptGuard[submitted_receipt_key(
                        Mirror.canonical(CurrentLoadout, status.ability), runtime.receiptAvoidTarget)] = {
                        command = command,
                    }
                    log_decision(options, "submitted_receipt",
                        "activation_unconfirmed_" .. runtime.receiptAvoidTarget)
                end
            end
        elseif status.disposition ~= "submitted" then
            runtime.receiptAvoidTarget = nil
        end
    end

    local function service_heal_lifecycle(options, known)
        local status = executor:status()
        local handle = type(status) == "table" and status.command_handle or nil
        if type(handle) ~= "string" or handle == runtime.lastHealLifecycleCommand or
            not command_started(status) then return end
        runtime.lastHealLifecycleCommand = handle
        local name = Mirror.canonical(CurrentLoadout, status.ability)
        local now = now_seconds()
        if name == KOLTO_INFUSION and type(known) == "table" and
            known[CURATIVE_JOLT] == true and now >= runtime.curativeJoltReadyAt then
            runtime.curativeJoltAvailable = true
            runtime.curativeJoltReadyAt = now + 18.0
            log_decision(options, "curative_jolt", "armed")
        elseif name == SURGICAL_PROBE and runtime.curativeJoltAvailable then
            runtime.curativeJoltAvailable = false
            log_decision(options, "curative_jolt", "consumed")
        end

        -- Accomplished Doctor refreshes an existing two-stack Probe when either
        -- TA heal starts. Record lifecycle evidence so a stale effect snapshot
        -- cannot immediately waste a GCD manually refreshing the same target.
        if type(known) == "table" and known[ACCOMPLISHED_DOCTOR] == true and
            (name == KOLTO_INFUSION or name == SURGICAL_PROBE) and
            type(status.core) == "table" and
            type(status.core.requested_target_handle) == "string" then
            local world = gos.world()
            local unit = world and type(world.resolve) == "function" and
                safe_method(world, "resolve", status.core.requested_target_handle) or nil
            local probe = unit and mine_effect_snapshot(unit, KOLTO_PROBE, "buff") or nil
            if type(probe) == "table" and probe.stacks >= KOLTO_PROBE_MAX_STACKS then
                runtime.probeEvidence[status.core.requested_target_handle] = {
                    startedAt = now, detail = "passive_refresh",
                    baselineRemaining = probe.remaining, expectedStacks = 2,
                }
                log_decision(options, "accomplished_doctor",
                    tostring(name) .. "_probe_refresh")
            end
        end

    end

    local function service_battle_rez_lifecycle(options)
        local pending = runtime.battleRezCommand
        if type(pending) ~= "table" or type(pending.command) ~= "string" then return end
        local status = gos.abilities.command_status(pending.command)
        if type(status) ~= "table" or status.known ~= true then return end
        if status.activation_proven == true or status.acknowledged == true or
            status.state == "started" or status.state == "acknowledged" or
            positive_sequence(status.post_terminal_activation_sequence) or
            positive_sequence(status.post_terminal_replication_sequence) then
            runtime.battleRezCommand = nil
            runtime.battleRezTargetBlockedUntil[pending.target] = nil
            log_decision(options, "battle_rez", "start_confirmed_" .. pending.target)
            return
        end
        if status.state == "failed" or status.state == "cancelled" or
            status.state == "superseded" or status.state == "abandoned" or
            positive_sequence(status.post_terminal_rejection_sequence) then
            runtime.battleRezCommand = nil
            runtime.battleRezBlockedUntil = now_seconds() + BATTLE_REZ_REJECTION_BACKOFF_SECONDS
            runtime.battleRezTargetBlockedUntil[pending.target] = runtime.battleRezBlockedUntil
            log_decision(options, "battle_rez", "rejected_" .. tostring(status.reason or status.state))
        end
    end

    local function stop(reason)
        flush_repeat_logs(true)
        if runtime.repeatLogOptions ~= nil then
            runtime.repeatLogs, runtime.repeatLogOptions = {}, nil
        end
        runtime.lastKitSignature = nil
        runtime.backstabCommand = nil
        runtime.stealthConsumedUntil = 0.0
        runtime.stealthUnknownSince = nil
        runtime.probeRoster = {}
        runtime.probeCommand = nil
        runtime.probeEvidence = {}
        runtime.lastHealLifecycleCommand = nil
        runtime.lastSubmittedReceiptCommand = nil
        runtime.receiptAvoidTarget = nil
        SubmittedReceiptGuard = {}
        runtime.curativeJoltReadyAt = 0.0
        runtime.curativeJoltAvailable = false
        runtime.pressureFocusHandle = nil
        runtime.battleRezCommand = nil
        runtime.battleRezBlockedUntil = 0.0
        runtime.battleRezTargetBlockedUntil = {}
        runtime.nativeAdmission = nil
        runtime.groupRecovery = false
        runtime.triagePlayerHandle = nil
        runtime.triageActorEpoch = nil
        if owns_pending() then
            executor:cancel(reason or "medicine_route_inactive")
            return owns_pending()
        end
        return false
    end

    local function service_native_admission(loadout, options, world, player, resource, triage)
        local intent = runtime.nativeAdmission
        if not intent then return false end
        local player_handle = safe_method(player, "handle")
        local actor_epoch = world and world.actor_epoch or nil
        local state = ability_state(loadout.known, intent.name)
        if player_handle ~= intent.playerHandle or
            intent.actorEpoch ~= nil and actor_epoch ~= nil and
                actor_epoch ~= intent.actorEpoch or
            state == nil or state.abilityHandle ~= intent.abilityHandle then
            runtime.nativeAdmission = nil
            return false
        end
        if finite_number(intent.reserve) and resource.current - state.cost < intent.reserve then
            runtime.nativeAdmission = nil
            return false
        end

        local decision = type(intent.decision) == "string" and intent.decision or ""
        local maintenance = (intent.name == KOLTO_PROBE or intent.name == SURGICAL_PROBE) and
            (decision:match("^focused_hot_first_") or
                decision:match("^protected_hot_uptime_") or
                decision:match("^priority_hot_uptime_") or
                decision:match("^proactive_hot_uptime_"))
        if maintenance and triage and triage.support_required == true and
            triage.handle ~= intent.handle then
            -- No command was accepted; a stale maintenance choice owns no native work.
            runtime.nativeAdmission = nil
            return false
        end

        local unit = intent.unit
        if intent.mode == "explicit" then
            if intent.cleanseCandidate then
                local cap = Cleanse.capabilities(Mirror.raw_loadout(loadout))
                local fresh_candidate
                unit = nil
                if cap.status == "ready" then
                    unit, fresh_candidate = Cleanse.refresh_candidate(intent.cleanseCandidate, {
                        active = true, loadout = Mirror.raw_loadout(loadout), world = world,
                        policy = options.cleanse,
                        preserve_stealth = true,
                        auto_stealth_pending = options.autoStealthPending,
                    }, cap)
                end
                intent.cleanseCandidate = fresh_candidate
            elseif intent.handle == player_handle then
                unit = player
            else
                local ok, resolved = pcall(world.resolve, world, intent.handle)
                unit = ok and resolved or nil
            end
            local current_target = world and world.current_target or nil
            if safe_method(unit, "handle") ~= intent.handle or
                intent.unitReaction == "hostile" and
                    safe_method(current_target, "handle") ~= intent.selectedTargetHandle then
                runtime.nativeAdmission = nil
                return false
            end
        elseif intent.mode == "ground" and
            safe_method(world and world.current_target or nil, "handle") ~= intent.handle then
            runtime.nativeAdmission = nil
            return false
        end

        runtime.nativeAdmission = nil
        options.medicineAdmissionCandidate = intent.cleanseCandidate
        submit_admitted(executor, options, loadout.known, intent.name,
            intent.mode == "explicit" and unit or nil, intent.handle,
            intent.decision, intent.mode, intent.reserve)
        options.medicineAdmissionCandidate = nil
        return true
    end

    local function log_kit(options, known)
        local names = {
            DIAGNOSTIC_SCAN, KOLTO_INJECTION, KOLTO_INFUSION, SURPRISE_SURGERY,
            KOLTO_STIM, KOLTO_BURST, REACTIVE_SUBSTANCE,
            CURBING_STRATEGIES, CLEVER_COUNTERMEASURES, DEBILITATE,
            KOLTO_PROBE, RECUPERATIVE_NANOTECH, MEDICAL_ENGINEERING,
            NANOTECH_STIM, NANO_MARK, CRITICAL_NANOTECH,
            STIM_BURST, TACTICAL_OVERDRIVE, TACTICAL_EFFECTIVENESS,
            SURGICAL_PROBE, SURGICAL_PRECISION,
            INFILTRATOR, ADVANCED_CLOAKING, CHEM_RESISTANT_INLAYS,
            KOLTO_WAVES, ACCOMPLISHED_DOCTOR,
            MED_SHIELD, ENDORPHIN_RUSH, EVASIVE_SCREEN,
            INFILTRATE, FLASH_BANG, HOLOTRAVERSE, MEDICAL_CONSULT,
            TACTICAL_SUPERIORITY, EVASIVE_IMPERATIVE, JARRING_STRIKE,
            BLOW_FOR_BLOW, TACTICAL_MEDICINE, CURATIVE_JOLT,
            SHIELD_PROBE, RESUSCITATION_PROBE, EVASION, NOXIOUS_KNIVES,
        }
        local parts = {}
        for _, name in ipairs(names) do
            parts[#parts + 1] = name .. "=" .. tostring(known[name] == true)
        end
        local signature = table.concat(parts, "|")
        if runtime.lastKitSignature == signature then return end
        runtime.lastKitSignature = signature
        emit(options, "info", "operative medicine kit: " .. table.concat(parts, ","))
    end

    local function try_ta_reserve_shiv(options, world, player, known, resource, ta, reason)
        local policy = dps_policy(options)
        if policy.buildTactical ~= true or known[SHIV] ~= true or
            ta.known ~= true or not finite_number(ta.stacks) or ta.stacks >= 2 then
            return false
        end
        local stealth = observed_effect(player, STEALTH, "buff")
        if type(stealth) == "table" or (stealth == nil and options.inCombat ~= true) then
            return false
        end
        local target, handle = action_target(world)
        if not target or not within_dps_range(target, SHIV) then return false end
        local reserve = reserve_energy(resource, policy)
        local state = ability_state(known, SHIV)
        if not can_afford(state, resource, reserve) then return false end
        local accepted, admission_reason = submit_explicit(executor, options, known, SHIV,
            target, handle, resource,
            "healing_ta_reserve_shiv_" .. tostring(reason or "reserve") .. "_" ..
                tostring(ta.stacks) .. "_to_" .. tostring(math.min(2, ta.stacks + 1)),
            reserve)
        if admission_pending(admission_reason) then return true end
        if accepted then
            log_decision(options, "healing_setup",
                SHIV .. "_ta_reserve_" .. tostring(ta.stacks) .. "_to_" ..
                    tostring(math.min(2, ta.stacks + 1)))
            return true
        end
        return false
    end

    local function try_idle_dps(options, world, player, known, resource, ta)
        local policy = dps_policy(options)
        if policy.enabled ~= true then return false end
        local target, handle, target_reason = action_target(world)
        if not target then
            log_decision(options, "idle_dps_wait", target_reason)
            return false
        end
        local reserve = reserve_energy(resource, policy)
        local now = now_seconds()

        local function try_backstab(reason, stealth_opener)
            local wait_decision = stealth_opener and "stealth_opener_wait" or "idle_dps_skip"
            if policy.backstab ~= true then
                log_decision(options, wait_decision, "backstab_policy_disabled")
                return false
            end
            if known[BACKSTAB] ~= true then
                log_decision(options, wait_decision, "backstab_not_owned")
                return false
            end
            if not within_dps_range(target, BACKSTAB) then
                local raw_distance = safe_method(target, "distance")
                local meters = finite_number(raw_distance) and
                    raw_distance * METERS_PER_WORLD_UNIT or nil
                log_decision(options, wait_decision,
                    meters and "backstab_out_of_range" or "backstab_out_of_range_unknown", meters)
                return false
            end
            local state = ability_state(known, BACKSTAB)
            if state == nil then
                log_decision(options, wait_decision, "backstab_state_unavailable")
                return false
            end
            if not can_afford(state, resource, reserve) then
                log_decision(options, wait_decision, "backstab_energy_reserve")
                return false
            end
            local accepted, submit_reason, result = submit_explicit(executor, options, known,
                BACKSTAB, target, handle, resource, reason, reserve)
            if admission_pending(submit_reason) then return true end
            if not accepted then
                log_decision(options, wait_decision,
                    "backstab_submit_" .. tostring(submit_reason))
            end
            if accepted then
                if stealth_opener then
                    runtime.backstabCommand = type(result) == "table" and
                        result.command_handle or nil
                    -- Core accepted the Stealth opener. Suppress stale/temporarily
                    -- unavailable Stealth observations immediately; later lifecycle
                    -- proof extends it. Routine Backstab does not touch this state.
                    runtime.stealthConsumedUntil = math.max(
                        runtime.stealthConsumedUntil, now_seconds() + 2.0)
                end
                log_decision(options, "idle_dps", stealth_opener and
                    (BACKSTAB .. "_stealth") or (BACKSTAB .. "_routine"))
            end
            return accepted
        end

        local stealth = observed_effect(player, STEALTH, "buff")
        if type(stealth) == "table" then
            runtime.stealthUnknownSince = nil
            -- Preserve the project-wide stealth opener: while Stealth is proven
            -- active, Backstab is the only damaging action Medicine may submit.
            return try_backstab("idle_dps_stealth_tactical", true)
        end

        local safely_unstealthed = stealth == false or options.inCombat == true or
            now < runtime.stealthConsumedUntil
        if stealth == nil and not safely_unstealthed then
            runtime.stealthUnknownSince = runtime.stealthUnknownSince or now
            if try_backstab("idle_dps_unknown_stealth_opener", true) then return true end
            if now - runtime.stealthUnknownSince < 0.75 then
                log_decision(options, "idle_dps_wait",
                    "stealth_observation_unavailable_preserve_opener")
                return false
            end
            log_decision(options, "idle_dps_degraded",
                "stealth_observation_unavailable_timeout")
        else
            runtime.stealthUnknownSince = nil
        end

        -- Even inside the ordinary idle-DPS path, rebuild the healer's two-TA
        -- reserve before spending the GCD on replaceable damage.
        if try_ta_reserve_shiv(options, world, player, known, resource, ta,
                "idle") then return true end

        -- With healing fuel already banked (or TA observation unavailable), the
        -- normal damage APL resumes: worthwhile DoT, legal Backstab, then Shiv.
        if policy.corrosiveDart and known[CORROSIVE_DART] == true and
            within_dps_range(target, CORROSIVE_DART) and
            durable_hostile(target, player) and
            effect_absent_mine(target, CORROSIVE_DART, "debuff") == true then
            local state = ability_state(known, CORROSIVE_DART)
            if can_afford(state, resource, reserve) then
                local accepted, admission_reason = submit_explicit(executor, options, known, CORROSIVE_DART,
                    target, handle, resource, "idle_dps_durable_dot", reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "idle_dps", CORROSIVE_DART)
                    return true
                end
            end
        end

        if try_backstab("idle_dps_backstab", false) then return true end

        if policy.buildTactical and known[SHIV] == true and
            within_dps_range(target, SHIV) then
            local state = ability_state(known, SHIV)
            if can_afford(state, resource, reserve) then
                local accepted, admission_reason = submit_explicit(executor, options, known, SHIV,
                    target, handle, resource, "idle_dps_shiv_damage", reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "idle_dps", SHIV .. "_damage")
                    return true
                end
            end
        end

        if known[CURBING_STRATEGIES] == true and known[NOXIOUS_KNIVES] == true and
            within_dps_range(target, NOXIOUS_KNIVES) then
            local nearby = hostile_count_within(world, DPS_RANGE[NOXIOUS_KNIVES])
            local state = ability_state(known, NOXIOUS_KNIVES)
            if finite_number(nearby) and nearby >= 3 and
                can_afford(state, resource, reserve) then
                local accepted, admission_reason = submit_untargeted(executor, options, known,
                    NOXIOUS_KNIVES, resource, "curbing_strategies_aoe")
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "idle_dps", NOXIOUS_KNIVES .. "_curbing")
                    return true
                end
            end
        end

        if policy.overloadShot and known[OVERLOAD_SHOT] == true and
            within_dps_range(target, OVERLOAD_SHOT) then
            local state = ability_state(known, OVERLOAD_SHOT)
            if can_afford(state, resource, reserve) then
                local accepted, admission_reason = submit_explicit(executor, options, known, OVERLOAD_SHOT,
                    target, handle, resource, "idle_dps_energy_surplus", reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "idle_dps", OVERLOAD_SHOT)
                    return true
                end
            end
        end

        if policy.rifleShot and known[RIFLE_SHOT] == true and
            within_dps_range(target, RIFLE_SHOT) then
            local state = ability_state(known, RIFLE_SHOT)
            if can_afford(state, resource, reserve) then
                local accepted, admission_reason = submit_explicit(executor, options, known, RIFLE_SHOT,
                    target, handle, resource, "idle_dps_free_filler", reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then log_decision(options, "idle_dps", RIFLE_SHOT) end
                return accepted
            end
        end
        return false
    end

    local function tick(loadout, active, options)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        options = type(options) == "table" and options or {}
        options.clearMedicineAdmission = function()
            runtime.nativeAdmission = nil
        end
        options.recordMedicineAdmission = function(intent)
            local admission_world = gos.world()
            local admission_player = admission_world and admission_world.player or nil
            intent.playerHandle = safe_method(admission_player, "handle")
            intent.actorEpoch = admission_world and admission_world.actor_epoch or nil
            intent.selectedTargetHandle = safe_method(
                admission_world and admission_world.current_target or nil, "handle")
            intent.unitReaction = safe_method(intent.unit, "reaction")
            runtime.nativeAdmission = intent
        end
        if options.decisionLog ~= true and runtime.repeatLogOptions ~= nil then
            flush_repeat_logs(true)
            runtime.repeatLogs, runtime.repeatLogOptions = {}, nil
        else
            flush_repeat_logs(false)
        end
        if not is_selected(loadout) then return false end
        local pressure_world = gos.world()
        local pressure_player = pressure_world and pressure_world.player or nil
        observe_pressure_events(options, safe_method(pressure_player, "handle"))
        -- Match Seer hold semantics: inactive means stop before servicing stale
        -- lifecycle receipts from the previous activation.
        if active ~= true then
            stop("rotation_inactive")
            return true
        end
        service_backstab_start(options)
        service_probe_start(options)
        if type(loadout.known) ~= "table" then return true end
        service_heal_lifecycle(options, loadout.known)
        service_submitted_receipt(options)
        service_battle_rez_lifecycle(options)
        if executor:owns_command() then return true end
        log_kit(options, loadout.known)

        local world = gos.world()
        local player = world and world.player or nil
        local resource = safe_method(player, "resource")
        local player_handle = safe_method(player, "handle")
        local prereq_gate = not world and "missing_world" or
            not player and "missing_player" or
            type(player_handle) ~= "string" and "missing_player_handle" or
            type(resource) ~= "table" and "missing_resource" or
            not finite_number(resource.current) and "invalid_resource_current" or
            not finite_number(resource.max) and "invalid_resource_max" or
            resource.max <= 0 and "nonpositive_resource_max" or
            resource.current < 0 and "negative_resource_current" or nil
        if prereq_gate ~= nil then
            if options.decisionLog == true then
                local gate_now = now_seconds()
                if runtime.lastPrereqGate ~= prereq_gate or
                    gate_now - runtime.lastPrereqGateAt >= 1.0 then
                    runtime.lastPrereqGate = prereq_gate
                    runtime.lastPrereqGateAt = gate_now
                    emit(options, "debug", "operative medicine prerequisite gate: " ..
                        prereq_gate .. " resource_current=" ..
                        tostring(type(resource) == "table" and resource.current or nil) ..
                        " resource_max=" ..
                        tostring(type(resource) == "table" and resource.max or nil))
                end
            end
            return true
        end
        runtime.lastPrereqGate = nil

        if runtime.triagePlayerHandle ~= player_handle or
            runtime.triageActorEpoch ~= world.actor_epoch then
            runtime.groupRecovery = false
            runtime.triagePlayerHandle = player_handle
            runtime.triageActorEpoch = world.actor_epoch
        end

        local policy = healing_policy(options)
        local lowest, injured, friendly_scan_ready, probe_candidates, nanotech_candidates =
            collect_injured(world, player, policy)
        if friendly_scan_ready == true and #injured < policy.koltoWavesMinAllies then
            runtime.groupRecovery = false
        end
        local hp_lowest = lowest
        local pressure_active = apply_pressure_triage(injured, policy)
        if pressure_active and #injured > 0 then lowest = injured[1] end
        local now = now_seconds()
        if options.decisionLog == true and pressure_active and lowest and
            hp_lowest and lowest.handle ~= hp_lowest.handle and
            now - runtime.lastPressureDiagnosticAt >= 0.50 then
            runtime.lastPressureDiagnosticAt = now
            local f = lowest.pressure
            emit(options, "debug", string.format(
                "operative medicine pressure triage: model=%s hp_target=%s selected=%s hp=%.1f%% p2=%.1f%% p4=%.1f%% ttd=%.2fs attackers=%d recent=%d persistent=%d band=%d",
                tostring(f.pressure_model or "unknown"),
                tostring(hp_lowest.handle), tostring(lowest.handle),
                lowest.current / lowest.maximum * 100.0,
                f.projected_hp_2s * 100.0, f.projected_hp_4s * 100.0,
                f.ttd, f.attackers_3s, f.recent_attackers or 0,
                f.persistent_attackers or 0, f.risk_band))
        end
        local ta = tactical_state(player, loadout.known)
        local moving = player_moving(player)
        local diagnosticsProbe = diagnostics_probe_snapshot(player)
        local diagnosticsStacks = diagnosticsProbe.known == true and
            finite_number(diagnosticsProbe.stacks) and diagnosticsProbe.stacks or 0
        local diagnosticsInstant = diagnosticsStacks >= DIAGNOSTICS_PROBE_MAX_STACKS
        local rescue_ceiling = burst_ceiling(policy)
        local function needs_burst_heal(row)
            return row ~= nil and row.maximum > 0 and row.current / row.maximum <= rescue_ceiling
        end
        local function movement_allows(name)
            return moving ~= true or heal_usable_while_moving(loadout.known, player, name)
        end
        -- Raw-HP emergency is a safety rail around pressure scoring: a patient
        -- already at/below the established 60% emergency boundary outranks a
        -- merely burst-band patient. Within the same stage preserve triage order.
        local emergency_row
        for _, row in ipairs(injured) do
            if row.maximum > 0 and row.current / row.maximum <= EMERGENCY_HEAL_RATIO and
                not target_skip_active(row.handle) then
                emergency_row = row
                break
            end
        end
        if emergency_row then
            lowest = emergency_row
        else
            for _, row in ipairs(injured) do
                if needs_burst_heal(row) and not target_skip_active(row.handle) then
                    lowest = row
                    break
                end
            end
        end
        if pressure_active and needs_burst_heal(lowest) then
            runtime.pressureFocusHandle = lowest.handle
        end

        if lowest and runtime.receiptAvoidTarget == lowest.handle and #injured > 1 then
            local lowest_ratio = lowest.maximum > 0 and lowest.current / lowest.maximum or 1.0
            -- An unconfirmed receipt is not proof that an urgent patient was
            -- healed. Preserve burst triage for self and allies alike.
            if not needs_burst_heal(lowest) then
                local alternate_ceiling = lowest_ratio <= policy.infusion and
                    policy.infusion or policy.healStart
                for _, row in ipairs(injured) do
                    local ratio = row.maximum > 0 and row.current / row.maximum or 1.0
                    if row.handle ~= runtime.receiptAvoidTarget and
                        not target_skip_active(row.handle) and ratio <= alternate_ceiling then
                        local previous = lowest.handle
                        lowest = row
                        log_repeated(options, "receipt_rotation", "submitted-receipt rotation:" ..
                            " from=" .. tostring(previous) .. " to=" .. tostring(row.handle) ..
                            " reason=activation_unconfirmed")
                        break
                    end
                end
            end
        end

        if lowest and target_skip_active(lowest.handle) and not needs_burst_heal(lowest) then
            for _, row in ipairs(injured or {}) do
                if not target_skip_active(row.handle) then
                    lowest = row
                    break
                end
            end
        end

        local function row_unit(row)
            if not row then return nil end
            if row.handle == player_handle then return player end
            return resolve_friendly(world, row.handle, policy)
        end

        local maintenance_reserve
        local function submit_friendly(name, primary_row, decision, reserve, max_ratio)
            if not primary_row then return false, "target_missing", nil, nil, nil end
            if name == SURGICAL_PROBE and finite_number(maintenance_reserve) then
                reserve = math.max(reserve or 0.0, maintenance_reserve)
            end
            local first_reason = nil
            local tried = {}
            local function attempt(row, is_primary)
                if not movement_allows(name) then return false, "moving", nil, nil end
                if not row or tried[row.handle] then return false, "duplicate", nil, nil end
                tried[row.handle] = true
                local ratio = row.maximum > 0 and row.current / row.maximum or 1.0
                if finite_number(max_ratio) and ratio > max_ratio then
                    return false, "target_above_stage_threshold", nil, nil
                end
                local burst_row = needs_burst_heal(row)
                if target_skip_active(row.handle) and not burst_row then
                    return false, "target_failover_backoff", nil, nil
                end
                local unit = row_unit(row)
                if not unit then
                    if not burst_row then remember_target_skip(row.handle) end
                    return false, "target_unavailable", nil, nil
                end
                local accepted, reason, result = submit_explicit(executor, options,
                    loadout.known, name, unit, row.handle, resource,
                    is_primary and decision or (tostring(decision) .. "_target_failover"), reserve)
                if accepted then
                    TargetSkipUntil[row.handle] = nil
                    return true, reason, result, unit
                end
                if target_backoff_gate(reason) and not burst_row then
                    remember_target_skip(row.handle)
                end
                return false, reason, result, unit
            end

            local accepted, reason, result, unit = attempt(primary_row, true)
            if accepted then return true, reason, result, primary_row, unit end
            first_reason = reason
            if needs_burst_heal(primary_row) and
                (reason == "submitted_receipt_unresolved" or target_specific_gate(reason) or
                    reason == "target_unavailable" or reason == "target_failover_backoff") then
                -- Burst triage is pinned to the endangered patient. A transient
                -- target/view failure must never turn the same healing decision
                -- into a heal on somebody healthier while this patient is dying.
                return false, reason, result, primary_row, unit
            end
            if not target_specific_gate(reason) and reason ~= "target_unavailable" and
                reason ~= "target_failover_backoff" then
                return false, reason, result, primary_row, unit
            end

            for _, row in ipairs(injured or {}) do
                if row.handle ~= primary_row.handle then
                    local ok, alt_reason, alt_result, alt_unit = attempt(row, false)
                    if ok then
                        emit(options, "debug", "operative medicine target failover: ability=" ..
                            tostring(name) .. " from=" .. tostring(primary_row.handle) ..
                            " reason=" .. tostring(first_reason) .. " to=" .. tostring(row.handle))
                        return true, alt_reason, alt_result, row, alt_unit
                    end
                    if alt_reason ~= "duplicate" and alt_reason ~= "target_above_stage_threshold" and
                        alt_reason ~= "target_failover_backoff" and
                        not target_specific_gate(alt_reason) then
                        return false, alt_reason, alt_result, row, alt_unit
                    end
                end
            end
            return false, first_reason or "no_serviceable_friendly", result, primary_row, unit
        end

        if options.abilityDiagnostics == true and now - runtime.lastDiagnosticAt >= 2.0 then
            runtime.lastDiagnosticAt = now
            diagnostics(options, loadout.known, resource, ta, lowest)
        end

        local function update_probe_roster()
            if loadout.known[KOLTO_PROBE] ~= true then
                runtime.probeRoster = {}
                return {}
            end
            local eligible_count = #(probe_candidates or {})
            local limit = policy.koltoProbeEveryone and eligible_count or
                math.min(eligible_count, policy.koltoProbeTargets)
            if limit <= 0 then
                runtime.probeRoster = {}
                return {}
            end
            local by_handle = {}
            for _, row in ipairs(probe_candidates or {}) do
                by_handle[row.handle] = row
            end
            local rows, handles, selected = {}, {}, {}
            local function add(row)
                if row and not selected[row.handle] and #rows < limit then
                    rows[#rows + 1] = row
                    handles[#handles + 1] = row.handle
                    selected[row.handle] = true
                end
            end
            -- Preserve the same maintenance set while those units remain valid.
            for _, handle in ipairs(runtime.probeRoster or {}) do
                add(by_handle[handle])
            end
            -- On reload/re-entry, recover already-probed units before inventing
            -- a new roster. This keeps existing 2-stack HoTs from being abandoned.
            for _, row in ipairs(probe_candidates or {}) do
                if #rows >= limit then break end
                if not selected[row.handle] then
                    local state = mine_effect_snapshot(row.unit, KOLTO_PROBE, "buff")
                    if type(state) == "table" and state.stacks > 0 then add(row) end
                end
            end
            -- Fill remaining slots by the normal heal-target ordering, then keep
            -- them sticky so short-term HP changes cannot churn Probe ownership.
            -- Probe uptime is proactive, so full-health roster members are valid.
            for _, row in ipairs(probe_candidates or {}) do
                if #rows >= limit then break end
                add(row)
            end
            runtime.probeRoster = handles
            return rows
        end

        local probe_roster = update_probe_roster()

        local function effective_probe_snapshot(unit, handle)
            local state = mine_effect_snapshot(unit, KOLTO_PROBE, "buff")
            local evidence = runtime.probeEvidence[handle]
            if type(evidence) ~= "table" then return state, false, nil end

            local age = now_seconds() - (evidence.startedAt or -math.huge)
            local confirmed = false
            if type(state) == "table" then
                if evidence.detail == "build_1" then
                    confirmed = state.stacks >= 1
                elseif evidence.detail == "build_2" then
                    confirmed = state.stacks >= 2
                elseif evidence.detail == "refresh_expiring" or
                    evidence.detail == "passive_refresh" then
                    local baseline = evidence.baselineRemaining
                    confirmed = state.stacks >= 2 and
                        (not finite_number(baseline) or not finite_number(state.remaining) or
                            state.remaining > baseline + 0.50)
                end
            end
            if confirmed then
                runtime.probeEvidence[handle] = nil
                return state, false, nil
            end
            if age >= 0 and age <= PROBE_OBSERVATION_SETTLE_SECONDS then
                -- A started cast is stronger evidence than a stale effect snapshot.
                -- Suppress only this target while the scanner catches up; other
                -- healing/DPS decisions remain available.
                return state, true, evidence
            end
            runtime.probeEvidence[handle] = nil
            return state, false, nil
        end

        local function probe_is_covered(unit, handle)
            local state, settling, evidence = effective_probe_snapshot(unit, handle)
            if settling and type(evidence) == "table" and
                (evidence.expectedStacks or 0) >= KOLTO_PROBE_MAX_STACKS then
                return true, state
            end
            -- Scanner-unavailable is unknown, never evidence that Probe is missing.
            -- This matters most in emergencies: a transient observation hole must
            -- not spend another 10 Energy after a recently confirmed two-stack HoT.
            if type(state) ~= "table" then return nil, nil end
            return state.stacks >= KOLTO_PROBE_MAX_STACKS and
                (not finite_number(state.remaining) or
                    state.remaining > policy.koltoProbeRefreshSeconds), state
        end

        local function probe_reserves_gcd(reason, detail)
            reason = tostring(reason or "")
            if admission_pending(reason) or timing_gate(reason) or reason:sub(1, 13) == "queue_window_" then
                return true
            end
            -- Seeding stack one stays nonblocking on metadata/target-sync trouble:
            -- that avoids the old healer dead-air regression. Once a real first
            -- stack exists, however, finish the pair before donating the next GCD
            -- to DPS. These are short Core synchronization/contention states, not
            -- fabricated script timers. A session-suspended/hard failure is never
            -- reserved here because it requires Core recovery and must not deadlock.
            if detail == "build_2" then
                return reason == "ability_submission_pending" or
                    reason == "explicit_target_sync_pending" or
                    reason == "bridge_busy" or
                    reason == "ability_command_busy" or reason == "command_busy"
            end
            return false
        end

        local function probe_admission_advisory(unit, detail)
            if not gos or not gos.abilities or
                type(gos.abilities.can_cast) ~= "function" then
                return true, false, nil
            end
            local ok, advisory = pcall(Mirror.can_cast, CurrentLoadout, KOLTO_PROBE, unit)
            if not ok or type(advisory) ~= "table" or advisory.ok == true then
                return true, false, nil
            end

            local gate = tostring(advisory.reason or advisory.code or "")
            if timing_gate(gate) then
                local wait_ms = finite_number(advisory.wait_ms) and
                    math.max(0, advisory.wait_ms) or nil
                if not finite_number(wait_ms) and gate == "gcd" then
                    local gcd_seconds = finite_number(advisory.gcd_remaining) and
                        advisory.gcd_remaining or
                        (type(gos.abilities.gcd_remaining) == "function" and
                            gos.abilities.gcd_remaining() or nil)
                    if finite_number(gcd_seconds) then
                        wait_ms = math.max(0, gcd_seconds * 1000.0)
                    end
                end
                local queue_window_ms =
                    math.max(0.0, options.abilityQueueWindow or 0.20) * 1000.0
                if finite_number(wait_ms) and wait_ms > queue_window_ms then
                    return false, true, "queue_window_" .. gate
                end
                -- Inside the native queue window, submit and let Core own admission.
                return true, false, nil
            end

            if probe_reserves_gcd(gate, detail) then
                return false, true, gate
            end
            if transient_gate(gate) then
                return false, false, gate
            end
            return true, false, nil
        end

        local function try_probe_maintenance(reason, mode, focus_handle)
            if loadout.known[KOLTO_PROBE] ~= true then return false, false, false end
            mode = mode or "all"
            local candidates = {}
            for _, row in ipairs(probe_roster or {}) do
                -- In urgent triage, even an expiring HoT on somebody ELSE must
                -- not take the endangered patient's next healing action.
                local allowed = focus_handle == nil or row.handle == focus_handle
                local unit = allowed and (row.handle == player_handle and player or
                    resolve_friendly(world, row.handle, policy)) or nil
                if unit then
                    local state, settling, evidence =
                        effective_probe_snapshot(unit, row.handle)
                    -- A confirmed first Probe cast is enough to advance to stack 2
                    -- even if the effect scanner has not published stack 1 yet.
                    -- Do not similarly infer refresh completion/build-2 completion;
                    -- those stay suppressed until scanner confirmation or grace expiry.
                    if settling and type(evidence) == "table" and
                        evidence.detail == "build_1" then
                        local synthetic = {
                            stacks = math.max(type(state) == "table" and
                                (state.stacks or 0) or 0, 1),
                            remaining = type(state) == "table" and state.remaining or nil,
                        }
                        state, settling = synthetic, false
                    end
                    if not settling and type(state) == "table" then
                        local class, detail
                        if state.stacks <= 0 then
                            class, detail = 2, "build_1"
                        elseif state.stacks < KOLTO_PROBE_MAX_STACKS then
                            class, detail = 0, "build_2"
                        elseif finite_number(state.remaining) and
                            state.remaining <= policy.koltoProbeRefreshSeconds then
                            class, detail = 1, "refresh_expiring"
                        end
                        if class ~= nil then
                            candidates[#candidates + 1] = {
                                row = row, unit = unit, class = class, detail = detail,
                                remaining = state.remaining, stacks = state.stacks,
                            }
                        end
                    end
                end
            end
            table.sort(candidates, function(lhs, rhs)
                if lhs.class ~= rhs.class then return lhs.class < rhs.class end
                if better_heal_target(lhs.row, rhs.row) then return true end
                if better_heal_target(rhs.row, lhs.row) then return false end
                if finite_number(lhs.remaining) and finite_number(rhs.remaining) and
                    lhs.remaining ~= rhs.remaining then
                    return lhs.remaining < rhs.remaining
                end
                return lhs.row.handle < rhs.row.handle
            end)

            local due = false
            local reserve_due = false
            for _, candidate in ipairs(candidates) do
                -- Protected maintenance means "do not let established HoTs decay":
                -- finish stack 2 and refresh an expiring two-stack owner. Fresh
                -- zero->one seeding is intentionally excluded only from this mode.
                local protected = candidate.detail ~= "build_1"
                if not target_skip_active(candidate.row.handle) and
                    (mode ~= "protected" or protected) then
                    due = true
                    local spender_refresh = candidate.detail == "refresh_expiring" and
                        loadout.known[ACCOMPLISHED_DOCTOR] == true and
                        loadout.known[SURGICAL_PROBE] == true and
                        ta.present == true and finite_number(ta.stacks) and ta.stacks >= 2
                    local ability = spender_refresh and SURGICAL_PROBE or KOLTO_PROBE

                    if ability == KOLTO_PROBE then
                        local proceed, reserve, advisory_reason =
                            probe_admission_advisory(candidate.unit, candidate.detail)
                        if not proceed then
                            if reserve then
                                if target_specific_gate(advisory_reason) then
                                    -- Target-scoped synchronization must not block
                                    -- another due Probe owner that can be serviced.
                                    reserve_due = true
                                    goto continue_probe_candidate
                                end
                                return false, true, true
                            end
                            if target_backoff_gate(advisory_reason) then
                                remember_target_skip(candidate.row.handle)
                            end
                            -- A non-timing build-1 synchronization gap must not
                            -- donate the whole healer GCD to dead air; try the next
                            -- roster member or fall through to the normal APL.
                            goto continue_probe_candidate
                        end
                    end

                    local accepted, submit_reason, result = submit_explicit(
                        executor, options, loadout.known, ability,
                        candidate.unit, candidate.row.handle, resource,
                        tostring(reason) .. "_" ..
                            (spender_refresh and "surgical_refresh" or tostring(candidate.detail)), maintenance_reserve)
                    if spender_refresh and not accepted then
                        log_heal_unavailable(options, SURGICAL_PROBE, candidate.row.handle,
                            "hot_refresh", submit_reason, resource,
                            candidate.row.current / candidate.row.maximum, ta)
                        -- Keep the same due HoT covered if the spender is unavailable.
                        -- Shared admission waits and target failures retain their normal handling.
                        if not target_specific_gate(submit_reason) and
                            (submit_reason == "cooldown" or
                                not probe_reserves_gcd(submit_reason, candidate.detail)) then
                            ability = KOLTO_PROBE
                            accepted, submit_reason, result = submit_explicit(
                                executor, options, loadout.known, ability,
                                candidate.unit, candidate.row.handle, resource,
                                tostring(reason) .. "_" .. tostring(candidate.detail), maintenance_reserve)
                        end
                    end
                    if accepted then
                        TargetSkipUntil[candidate.row.handle] = nil
                        if ability == KOLTO_PROBE and type(result) == "table" and
                            type(result.command_handle) == "string" then
                            runtime.probeCommand = {
                                handle = result.command_handle,
                                target = candidate.row.handle,
                                detail = candidate.detail,
                                baselineRemaining = candidate.remaining,
                            }
                        end
                        log_decision(options, "heal",
                            ability .. "_" .. (ability == SURGICAL_PROBE and
                                "probe_refresh" or tostring(candidate.detail)))
                        return true, true, false
                    end
                    if target_specific_gate(submit_reason) then
                        if target_backoff_gate(submit_reason) then
                            remember_target_skip(candidate.row.handle)
                        end
                    elseif probe_reserves_gcd(submit_reason, candidate.detail) then
                        if candidate.detail == "build_2" then
                            log_decision(options, "probe_stack2_reserved",
                                tostring(submit_reason))
                        end
                        return false, true, true
                    end
                    -- Target-specific failure on one roster member must not create
                    -- dead air or prevent another due target from being serviced.
                end
                ::continue_probe_candidate::
            end
            -- Unfocused protected maintenance gets first refusal, but a
            -- target-scoped synchronization gap must still allow the subsequent
            -- broad pass to service another due Probe target. Urgent focused
            -- maintenance keeps the reservation pinned to that patient.
            local effective_reserve = reserve_due and
                (mode ~= "protected" or focus_handle ~= nil)
            return false, due, effective_reserve
        end

        -- Focus-target HoT setup is stricter than broad roster maintenance.
        -- If the current patient is missing Probe coverage, finish that coverage
        -- before ordinary direct healing unless the caller has already proven
        -- that the patient cannot survive the setup window.
        local function try_target_probe_setup(row, unit, reason, strict_target_sync)
            if loadout.known[KOLTO_PROBE] ~= true or not row or not unit then
                return false, false, nil, "probe_unavailable"
            end
            local state, settling, evidence =
                effective_probe_snapshot(unit, row.handle)
            if settling and type(evidence) == "table" and
                evidence.detail == "build_1" then
                state = {
                    stacks = math.max(type(state) == "table" and
                        (state.stacks or 0) or 0, 1),
                    remaining = type(state) == "table" and state.remaining or nil,
                }
                settling = false
            elseif settling and type(evidence) == "table" and
                (evidence.expectedStacks or 0) >= KOLTO_PROBE_MAX_STACKS then
                return false, false, { stacks = 2, remaining = state and state.remaining or nil },
                    "coverage_settling"
            elseif settling then
                return false, true, state, "coverage_settling"
            end
            if type(state) ~= "table" then
                return false, false, nil, "observation_unknown"
            end

            local detail
            if state.stacks <= 0 then
                detail = "build_1"
            elseif state.stacks < KOLTO_PROBE_MAX_STACKS then
                detail = "build_2"
            elseif finite_number(state.remaining) and
                state.remaining <= policy.koltoProbeRefreshSeconds then
                detail = "refresh_expiring"
            else
                return false, false, state, "covered"
            end

            local proceed, reserve, advisory_reason =
                probe_admission_advisory(unit, detail)
            if not proceed then
                if reserve and target_specific_gate(advisory_reason) and
                    strict_target_sync ~= true then
                    -- Ordinary-band target synchronization should not pin the
                    -- whole GCD; roster maintenance can service another due ally.
                    return false, false, state, advisory_reason
                end
                return false, reserve, state, advisory_reason
            end

            local accepted, submit_reason, result = submit_explicit(
                executor, options, loadout.known, KOLTO_PROBE, unit, row.handle,
                resource, tostring(reason) .. "_" .. detail, maintenance_reserve)
            if accepted then
                TargetSkipUntil[row.handle] = nil
                if type(result) == "table" and type(result.command_handle) == "string" then
                    runtime.probeCommand = {
                        handle = result.command_handle,
                        target = row.handle,
                        detail = detail,
                        baselineRemaining = state.remaining,
                    }
                end
                log_decision(options, "heal", KOLTO_PROBE .. "_" .. detail)
                return true, true, state, detail
            end
            if admission_pending(submit_reason) or
                probe_reserves_gcd(submit_reason, detail) or
                transient_gate(submit_reason) then
                -- HoT-first decision is already made for this patient. A short
                -- Core/GCD synchronization state must reserve the decision rather
                -- than donating the tick to an ordinary direct heal.
                return false, true, state, submit_reason
            end
            if target_backoff_gate(submit_reason) then remember_target_skip(row.handle) end
            return false, false, state, submit_reason
        end

        if options.abilityDiagnostics == true and
            now - runtime.lastProbeDiagnosticAt >= 2.0 then
            runtime.lastProbeDiagnosticAt = now
            local rows = {}
            for _, row in ipairs(probe_roster or {}) do
                local unit = row.handle == player_handle and player or
                    resolve_friendly(world, row.handle, policy)
                if unit then
                    local state, settling, evidence =
                        effective_probe_snapshot(unit, row.handle)
                    local ratio = row.maximum > 0 and row.current / row.maximum * 100.0 or 0.0
                    rows[#rows + 1] = table.concat({
                        row.handle, tostring(row.unitType), string.format("hp=%.1f%%", ratio),
                        "stacks=" .. tostring(state and state.stacks or "?"),
                        "remain=" .. tostring(state and state.remaining or "?"),
                        "settling=" .. tostring(settling),
                        "evidence=" .. tostring(evidence and evidence.detail or "none"),
                    }, "/")
                end
            end
            emit(options, "debug", string.format(
                "operative medicine probes: roster=%d/eligible=%d/everyone=%s %s",
                #probe_roster, #(probe_candidates or {}),
                tostring(policy.koltoProbeEveryone), table.concat(rows, ",")))
        end

        local function try_battle_rez()
            if options.medicineAutoBattleRez ~= true or options.inCombat ~= true or
                loadout.known[RESUSCITATION_PROBE] ~= true or
                now_seconds() < runtime.battleRezBlockedUntil or
                runtime.battleRezCommand ~= nil then return false end
            local state = ability_state(loadout.known, RESUSCITATION_PROBE)
            if state == nil or state.onBar ~= true or state.ready ~= true or
                state.cost > resource.current then return false end
            local dead, scan_ready = collect_dead_friendlies(world, player_handle)
            if scan_ready ~= true or #dead == 0 then return false end
            local now = now_seconds()
            local codes = gos.abilities.result_codes or {}
            for _, row in ipairs(dead) do
                if now >= (runtime.battleRezTargetBlockedUntil[row.handle] or 0) then
                    local unit = resolve_dead_friendly(world, row.handle)
                    if unit then
                        local accepted, reason, result = submit_explicit(executor, options,
                            loadout.known, RESUSCITATION_PROBE, unit, row.handle, resource,
                            row.selected and "auto_battle_rez_selected" or "auto_battle_rez_nearest", nil)
                        if admission_pending(reason) then return true end
                        if accepted then
                            runtime.battleRezCommand = {
                                command = type(result) == "table" and result.command_handle or nil,
                                target = row.handle,
                            }
                            log_decision(options, "battle_rez",
                                RESUSCITATION_PROBE .. "_" .. row.handle)
                            return true
                        end
                        local code = type(result) == "table" and result.code or nil
                        if code ~= nil and (code == codes.ability_disabled or
                            code == codes.castability_unavailable or code == codes.cast_unavailable) then
                            runtime.battleRezBlockedUntil = now + BATTLE_REZ_REJECTION_BACKOFF_SECONDS
                            log_decision(options, "battle_rez", "temporarily_unavailable_" .. tostring(reason))
                            return false
                        end
                        if (code ~= nil and code == codes.target_not_dead) or
                            target_specific_gate(reason) then
                            runtime.battleRezTargetBlockedUntil[row.handle] =
                                now + BATTLE_REZ_REJECTION_BACKOFF_SECONDS
                        elseif timing_gate(reason) or admission_pending(reason) then
                            return true
                        end
                    end
                end
            end
            return false
        end

        local cleanse_attempted = {}
        local function try_shared_cleanse(tier)
            if cleanse_attempted[tier] then return false end
            cleanse_attempted[tier] = true
            return Cleanse.attempt({
                active = true, pending = executor:owns_command(), loadout = Mirror.raw_loadout(loadout),
                world = world, policy = options.cleanse, log = options.logLine,
                tier = tier, admission_via_submit = true,
                preserve_stealth = true, auto_stealth_pending = options.autoStealthPending,
                submit = function(candidate, unit)
                    options.medicineAdmissionCandidate = candidate
                    local accepted, reason, result = submit_explicit(executor, options,
                        loadout.known, Mirror.canonical(loadout, candidate.ability), unit, candidate.handle,
                        resource, "pvp_cleanse_" .. candidate.key, nil)
                    options.medicineAdmissionCandidate = nil
                    return { accepted = accepted, admission_pending = admission_pending(reason),
                        owned = executor:owns_command(), reason = reason,
                        code = type(result) == "table" and result.code or nil }
                end,
            })
        end

        if lowest == nil then
            if service_native_admission(loadout, options, world, player, resource) then
                return true
            end
            if friendly_scan_ready ~= true then
                log_decision(options, "wait", "friendly_scan_unavailable_no_dps")
                return true
            end
            -- With no healing crisis, controls and battle rez retain utility
            -- priority, then Medicine restores its defining two-stack Probe blanket
            -- before spending a GCD on TA preparation or damage.
            if try_shared_cleanse("must") then return true end
            if try_battle_rez() then return true end
            if try_shared_cleanse("movement") then return true end
            local probe_submitted, probe_due, probe_reserve =
                try_probe_maintenance("proactive_hot_uptime", "all")
            if probe_submitted then return true end
            if probe_reserve then
                log_decision(options, "wait", "probe_uptime_reserved")
                return true
            end
            if probe_due then
                log_decision(options, "probe_degraded", "due_but_nonblocking")
            end
            if try_ta_reserve_shiv(options, world, player, loadout.known, resource, ta,
                    "no_injured") then return true end
            if try_shared_cleanse("pressure") then return true end
            try_idle_dps(options, world, player, loadout.known, resource, ta)
            return true
        end

        local target = row_unit(lowest)
        if not target then
            if service_native_admission(loadout, options, world, player, resource) then
                return true
            end
            local failed_handle = lowest.handle
            remember_target_skip(failed_handle)
            for _, row in ipairs(injured or {}) do
                if row.handle ~= failed_handle and not target_skip_active(row.handle) then
                    local alternate = row_unit(row)
                    if alternate then
                        lowest, target = row, alternate
                        emit(options, "debug", "operative medicine target failover: ability=triage" ..
                            " from=" .. tostring(failed_handle) ..
                            " reason=target_unavailable to=" .. tostring(row.handle))
                        break
                    end
                    remember_target_skip(row.handle)
                end
            end
        end
        if not target then
            -- No legal heal target exists in this snapshot, so healing has no
            -- action to take. Preserve utility ordering instead of idling.
            if try_shared_cleanse("must") then return true end
            if try_shared_cleanse("movement") then return true end
            if try_shared_cleanse("pressure") then return true end
            log_decision(options, "wait", "no_serviceable_heal_target")
            return true
        end
        local target_ratio = lowest.current / lowest.maximum
        local energy_percent = resource.current / resource.max * 100.0
        local player_hp = safe_method(player, "hp")
        local player_ratio = living_hp(player_hp) and player_hp.current / player_hp.max or nil

        local hot_covered = false
        local target_probe_state, target_probe_settling, target_probe_evidence
        local target_probe_stacks, target_probe_missing
        local target_probe_eligible =
            lowest.unitType == "player" or lowest.unitType == "companion"
        if loadout.known[KOLTO_PROBE] == true then
            hot_covered = probe_is_covered(target, lowest.handle)
            if target_probe_eligible then
                target_probe_state, target_probe_settling, target_probe_evidence =
                    effective_probe_snapshot(target, lowest.handle)
            end
            if type(target_probe_state) == "table" and
                finite_number(target_probe_state.stacks) then
                target_probe_stacks = target_probe_state.stacks
            end
            if target_probe_settling and type(target_probe_evidence) == "table" and
                finite_number(target_probe_evidence.expectedStacks) then
                target_probe_stacks = math.max(target_probe_stacks or 0,
                    target_probe_evidence.expectedStacks)
            end
            if finite_number(target_probe_stacks) then
                target_probe_missing = math.max(0,
                    KOLTO_PROBE_MAX_STACKS - target_probe_stacks)
            end
        end
        local direct_threshold = direct_heal_threshold(policy, lowest.unitType, hot_covered)
        local support_count = 0
        local nearby_injured = 0
        local support_radius_sq = (KOLTO_WAVES_RADIUS_METERS / METERS_PER_WORLD_UNIT) ^ 2
        for _, row in ipairs(injured) do
            local ratio = row.current / row.maximum
            local d2 = distance_squared(lowest, row)
            if d2 ~= nil and d2 <= support_radius_sq then
                nearby_injured = nearby_injured + 1
                if ratio <= policy.injection then
                    local covered = row.handle == lowest.handle and hot_covered or false
                    if row.handle ~= lowest.handle and ratio > policy.infusion then
                        covered = probe_is_covered(row.unit, row.handle)
                    end
                    if ratio <= direct_heal_threshold(policy, row.unitType, covered) then
                        support_count = support_count + 1
                        if support_count >= policy.koltoWavesMinAllies then break end
                    end
                end
            end
        end
        if friendly_scan_ready == true then
            if support_count >= policy.koltoWavesMinAllies then
                runtime.groupRecovery = true
            elseif nearby_injured < policy.koltoWavesMinAllies then
                runtime.groupRecovery = false
            end
        end
        -- Healing two teammates must not abandon the rest of the same group recovery.
        local group_support = support_count >= policy.koltoWavesMinAllies or
            (runtime.groupRecovery and nearby_injured >= policy.koltoWavesMinAllies)
        local isolated_support = needs_burst_heal(lowest) and not group_support

        local emergency = target_ratio <= EMERGENCY_HEAL_RATIO
        local rescue_needed = needs_burst_heal(lowest)
        local target_pressure = type(lowest.pressure) == "table" and
            lowest.pressure or pressure_features(lowest)
        local target_probe_setup_seconds = 0.0
        if finite_number(target_probe_missing) and target_probe_missing > 0 then
            target_probe_setup_seconds = probe_setup_seconds(target, target_probe_missing)
        end
        local raw_life_saving = target_ratio <= LIFE_SAVING_HEAL_RATIO
        local hot_setup_unsafe = finite_number(target_probe_missing) and
            target_probe_missing > 0 and
            ((raw_life_saving and
                (not finite_number(target_probe_setup_seconds) or
                    target_probe_setup_seconds > 0)) or
                (type(target_pressure) == "table" and
                    finite_number(target_pressure.ttd) and
                    finite_number(target_probe_setup_seconds) and
                    target_pressure.ttd <= target_probe_setup_seconds))
        local mobile_zero_ta_emergency = emergency and moving == true and ta.present ~= true
        -- Disable the routine reserve explicitly; an and/or expression cannot
        -- select nil and otherwise keeps the reserve even in emergencies.
        local direct_reserve
        local ta_capped = ta.present == true and finite_number(ta.stacks) and ta.stacks >= ta.max
        local heavy_pressure = emergency or
            (#injured >= 3 and target_ratio <= direct_threshold)
        local stim_burst_pressure = loadout.known[STIM_BURST] == true and
            (target_ratio <= policy.infusion or
                (#injured >= 2 and target_ratio <= direct_threshold))

        local function try_infusion()
            if target_ratio > policy.infusion or loadout.known[KOLTO_INFUSION] ~= true then
                return false
            end
            local stage = emergency and "emergency" or "priority"
            if ta.present ~= true then
                log_heal_unavailable(options, KOLTO_INFUSION, lowest.handle, stage,
                    "tactical_advantage_unavailable", resource, target_ratio, ta)
            else
                local accepted, submit_reason = submit_friendly(KOLTO_INFUSION, lowest,
                    emergency and "emergency_kolto_infusion" or
                        (ta_capped and "ta_cap_kolto_infusion" or "priority_kolto_infusion"),
                    direct_reserve, policy.infusion)
                if admission_pending(submit_reason) then return true end
                if accepted then
                    log_decision(options, "heal", KOLTO_INFUSION)
                    return true
                end
                log_heal_unavailable(options, KOLTO_INFUSION, lowest.handle, stage,
                    submit_reason, resource, target_ratio, ta)
            end
            return false
        end

        local function try_accomplished_doctor_refresh()
            if emergency or loadout.known[ACCOMPLISHED_DOCTOR] ~= true or
                ta.present ~= true then
                return false
            end
            local probe = mine_effect_snapshot(target, KOLTO_PROBE, "buff")
            local expiring = type(probe) == "table" and
                probe.stacks >= KOLTO_PROBE_MAX_STACKS and
                finite_number(probe.remaining) and
                probe.remaining <= policy.koltoProbeRefreshSeconds
            if not expiring then return false end

            -- Prefer the stronger Infusion when the patient is already in that
            -- band; otherwise a safe >=2-TA Surgical Probe refreshes the HoT in
            -- the same GCD without donating a separate Probe cast.
            if target_ratio <= policy.infusion and
                loadout.known[KOLTO_INFUSION] == true and
                movement_allows(KOLTO_INFUSION) then
                local accepted, admission_reason = submit_explicit(
                    executor, options, loadout.known, KOLTO_INFUSION,
                    target, lowest.handle, resource,
                    "accomplished_doctor_infusion_refresh", direct_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", KOLTO_INFUSION .. "_probe_refresh")
                    return true
                end
            end
            if finite_number(ta.stacks) and ta.stacks >= 2 and
                loadout.known[SURGICAL_PROBE] == true then
                local accepted, admission_reason = submit_explicit(
                    executor, options, loadout.known, SURGICAL_PROBE,
                    target, lowest.handle, resource,
                    "accomplished_doctor_surgical_refresh", maintenance_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", SURGICAL_PROBE .. "_probe_refresh")
                    return true
                end
            end
            return false
        end

        -- HoT ownership/timing must never downgrade an actual death warning.
        local pressure_life_saving = type(target_pressure) == "table" and
            target_pressure.risk_band == 0
        local life_saving = raw_life_saving or pressure_life_saving or hot_setup_unsafe
        -- Isolated rescue must not turn into a roster sweep or slow HoT setup.
        local urgent_support = life_saving or emergency or
            (type(target_pressure) == "table" and
                finite_number(target_pressure.risk_band) and
                target_pressure.risk_band <= 2)
        local focus_support_required = urgent_support or isolated_support
        if group_support and not urgent_support then
            maintenance_reserve = BURST_HEAL_ENERGY_RESERVE
        end
        if not rescue_needed or (group_support and not urgent_support) then
            direct_reserve = routine_heal_reserve(resource)
        end
        if runtime.nativeAdmission and service_native_admission(loadout, options, world, player, resource,
                friendly_scan_ready == true and {
                    support_required = focus_support_required, handle = lowest.handle,
                } or nil) then
            return true
        end
        local maintenance_focus = focus_support_required and lowest.handle or nil
        local life_saving_limit = (pressure_life_saving or hot_setup_unsafe) and
            math.max(rescue_ceiling, target_ratio) or rescue_ceiling
        local function submit_life_saving(name, decision)
            local live_hp = safe_method(target, "hp")
            if not living_hp(live_hp) then
                return false, type(live_hp) == "table" and finite_number(live_hp.current) and
                    live_hp.current <= 0 and "target_dead" or "target_unavailable"
            end
            if live_hp.current / live_hp.max > life_saving_limit then
                return false, "target_above_stage_threshold"
            end
            if not movement_allows(name) then return false, "moving" end
            -- Never put an imminent-death patient into the generic target-skip
            -- pool. A transient view/LOS failure must keep this patient pinned
            -- for the next tick instead of rotating to maintenance on somebody else.
            return submit_explicit(executor, options, loadout.known, name, target,
                lowest.handle, resource, decision, nil)
        end
        local function try_life_saving_rescue()
            if not life_saving then return false end
            -- True imminent-death triage gets one complete healing refusal before
            -- even a must-cleanse. Keep every attempt pinned to the endangered
            -- patient: a blocked life-saving target must not turn into a routine
            -- failover heal on somebody else.
            local function attempt(name, decision)
                local accepted, reason = submit_life_saving(name, decision)
                if admission_pending(reason) then return true end
                if accepted then
                    log_decision(options, "heal", name .. "_life_saving")
                    return true
                end
                if reason == "target_dead" then return false end
                if target_specific_gate(reason) or reason == "target_unavailable" then
                    log_decision(options, "wait",
                        "life_saving_target_pinned_" .. tostring(reason))
                    return true
                end
                return false
            end
            -- Diagnostics Probe turns the third observed Heal Sust 01 stack into
            -- an instant Kolto Injection. In a true life-saving window, consume
            -- that proven instant big heal before spending TA on a smaller Probe.
            if diagnosticsInstant and loadout.known[KOLTO_INJECTION] == true then
                if attempt(KOLTO_INJECTION, "life_saving_diagnostics_instant") then return true end
            end
            if ta.present == true and loadout.known[SURGICAL_PROBE] == true then
                if attempt(SURGICAL_PROBE, "life_saving_instant_surgical") then return true end
            end
            -- This path is reached only after Probe setup was proven unsafe
            -- or the patient already had full Probe coverage. Direct throughput
            -- now gets first refusal inside that true life-saving exception.
            if ta.present == true and loadout.known[KOLTO_INFUSION] == true then
                if attempt(KOLTO_INFUSION, "life_saving_kolto_infusion") then return true end
            end
            if not diagnosticsInstant and loadout.known[KOLTO_INJECTION] == true then
                if attempt(KOLTO_INJECTION, "life_saving_injection") then return true end
            end
            if loadout.known[RECUPERATIVE_NANOTECH] == true then
                if attempt(RECUPERATIVE_NANOTECH, "life_saving_instant_nanotech") then return true end
            end
            if loadout.known[DIAGNOSTIC_SCAN] == true and
                (moving ~= true or heal_usable_while_moving(
                    loadout.known, player, DIAGNOSTIC_SCAN)) then
                if attempt(DIAGNOSTIC_SCAN, "life_saving_last_resort") then return true end
            end
            return false
        end

        if try_life_saving_rescue() then return true end
        -- A hard stun/mez returns an ally's entire kit. Once true life-saving
        -- throughput has had first refusal, must-cleanses remain critical utility.
        if try_shared_cleanse("must") then return true end

        -- Shield Probe is the one automatic Medicine defensive. It is self-only,
        -- off-GCD, and fires only from authoritative HP/effect observations. It
        -- stays below life-saving healing and must-cleanse utility in this scheduler.
        if options.medicineAutoShieldProbe == true and options.inCombat == true and
            loadout.known[SHIELD_PROBE] == true and finite_number(player_ratio) and
            player_ratio <= clamp((options.medicineShieldProbeBelow or 75.0) / 100.0, 0.10, 0.95) and
            options.autoStealthPending ~= true then
            local shield = observed_effect(player, SHIELD_PROBE, "buff")
            local stealth = observed_effect(player, STEALTH, "buff")
            if shield == false and type(stealth) ~= "table" then
                local accepted, shield_reason = submit_untargeted(
                    executor, options, loadout.known, SHIELD_PROBE, resource,
                    "medicine_low_self_health")
                if admission_pending(shield_reason) then return true end
                if accepted then
                    log_decision(options, "defensive", SHIELD_PROBE .. "_self")
                    return true
                end
            end
        end

        -- At three Diagnostics Probe stacks, Heal Sust 01 makes Kolto Injection
        -- instant. Consume it before the normal emergency Surgical Probe; this is
        -- especially important while moving, where the unbuffed Injection would
        -- otherwise be rejected by the game.
        if emergency and diagnosticsInstant and not ta_capped and
            loadout.known[KOLTO_INJECTION] == true then
            local accepted, admission_reason = submit_friendly(
                KOLTO_INJECTION, lowest, "diagnostics_probe_emergency_instant", nil,
                EMERGENCY_HEAL_RATIO)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", KOLTO_INJECTION .. "_diagnostics_instant")
                return true
            end
        end

        -- At 47 Surgical Probe is an instant TA spender, but it does NOT yet
        -- refresh Kolto Probe and does NOT refund TA. Those passives arrive later.
        if emergency and ta.present == true and loadout.known[SURGICAL_PROBE] == true then
            local accepted, admission_reason = submit_friendly(
                SURGICAL_PROBE, lowest, "emergency_instant_stabilize", nil,
                EMERGENCY_HEAL_RATIO)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", SURGICAL_PROBE .. "_emergency")
                return true
            end
        end

        -- Level-43 healing windows are throughput setup, so meaningful pressure
        -- must open them before routine HoT maintenance can consume the GCD.
        if options.autoStimBoost == true and loadout.known[STIM_BOOST] == true and
            ((emergency and ta.present ~= true) or stim_burst_pressure) then
            local accepted, admission_reason = submit_untargeted(executor, options, loadout.known,
                STIM_BOOST, resource,
                stim_burst_pressure and "stim_burst_healing_window" or
                    "emergency_tactical_and_instant")
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "healing_setup", STIM_BOOST)
                return true
            end
        end

        if options.autoTacticalOverdrive == true and heavy_pressure and
            loadout.known[TACTICAL_OVERDRIVE] == true then
            local stim_cd = cooldown_remaining(STIM_BOOST)
            local nano_cd = loadout.known[RECUPERATIVE_NANOTECH] == true and
                cooldown_remaining(RECUPERATIVE_NANOTECH) or nil
            local has_reset_value =
                (finite_number(stim_cd) and stim_cd > 0.5) or
                (finite_number(nano_cd) and nano_cd > 0.5)
            local group_pressure = #injured >= 3 and target_ratio <= direct_threshold
            -- Tactical Overdrive also supplies its own Mastery window. Emergency
            -- or real group pressure can justify that throughput directly;
            -- otherwise conserve it until a reset has concrete value.
            if emergency or group_pressure or has_reset_value then
                local accepted, admission_reason = submit_untargeted(executor, options, loadout.known,
                    TACTICAL_OVERDRIVE, resource,
                    emergency and "emergency_overdrive_mastery" or
                        group_pressure and "group_pressure_overdrive_mastery" or
                            "heavy_pressure_reset_value")
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "healing_setup", TACTICAL_OVERDRIVE)
                    return true
                end
            end
        end

        -- Accomplished Doctor combines useful healing and HoT refresh in one
        -- GCD, so it outranks a generic protected Probe refresh.
        if try_accomplished_doctor_refresh() then return true end

        -- Missing stacks are patient setup. Existing two-stack refreshes use
        -- the shared maintenance path, including Surgical Probe when learned.
        local target_probe_due = finite_number(target_probe_missing) and
            target_probe_missing > 0
        if target_probe_due and not life_saving and not isolated_support then
            local probe_submitted, probe_reserved =
                try_target_probe_setup(lowest, target, "focused_hot_first",
                    rescue_needed or emergency)
            if probe_submitted or probe_reserved then
                return true
            end
        end

        -- Preserve roster refreshes during safe maintenance windows, but scope
        -- all maintenance to the patient while emergency/urgent pressure lasts.
        -- Throughput setup above gets first refusal so Stim Burst/Overdrive are
        -- not starved by routine HoT maintenance.
        if focus_support_required then
            log_repeated(options, "hot_focus_guard", "HoT scope: focus=" ..
                tostring(lowest.handle) .. " policy=urgent_patient_before_roster")
        end
        local protected_submitted, protected_due, protected_reserve = false, false, false
        if not isolated_support then
            protected_submitted, protected_due, protected_reserve =
                try_probe_maintenance("protected_hot_uptime", "protected", maintenance_focus)
        end
        if protected_submitted then return true end
        if protected_reserve then
            log_decision(options, "wait", "protected_probe_uptime_reserved")
            return true
        end
        if protected_due then
            log_decision(options, "probe_degraded", "protected_due_but_nonblocking")
        end

        -- A dead teammate is worth recovering before fresh zero->one seeding,
        -- but never before true life-saving healing or protected HoT maintenance.
        if not focus_support_required and try_battle_rez() then return true end

        local nanotech_row, nanotech_injured, nanotech_affected, nanotech_talent
        local nanotech_resolved = false
        local waves_attempted = false
        local function try_group_waves()
            if waves_attempted then return false end
            waves_attempted = true
            if loadout.known[KOLTO_WAVES] ~= true or moving == true or
                target_ratio > policy.injection then return false end
            local cd = cooldown_remaining(KOLTO_WAVES)
            if not finite_number(cd) or cd > 0 then return false end
            local reserve
            if not urgent_support then reserve = routine_heal_reserve(resource) end
            local state = ability_state(loadout.known, KOLTO_WAVES)
            if state and reserve then
                -- Admission may expose one tick; budget the whole channel.
                reserve = reserve + math.max(0.0, KOLTO_WAVES_CHANNEL_ENERGY - state.cost)
            end
            if not state or not state.ready or not state.onBar or
                not can_afford(state, resource, reserve or 0.0) then return false end
            local gcd = gos.abilities.gcd_remaining()
            if finite_number(gcd) and gcd > 0.04 then return false end
            if gos.abilities.is_casting_or_channeling() == true then return false end
            local center, count = best_cluster_center(lowest, injured, KOLTO_WAVES_RADIUS_METERS)
            if not center or count < policy.koltoWavesMinAllies then return false end
            local accepted, reason = submit_ground(executor, options, loadout.known,
                KOLTO_WAVES, center.handle, resource, moving,
                "group_pressure_" .. tostring(count), reserve)
            if accepted then
                log_decision(options, "heal", KOLTO_WAVES .. "_group_" .. tostring(count))
            end
            return accepted or admission_pending(reason) or reason == "ground_start_locked"
        end
        -- Established HoTs keep their priority; group recovery precedes fresh seeding.
        if group_support and not urgent_support then
            local reserve = routine_heal_reserve(resource)
            local cd = cooldown_remaining(RECUPERATIVE_NANOTECH)
            local state = ability_state(loadout.known, RECUPERATIVE_NANOTECH)
            if state and state.ready and state.onBar and finite_number(cd) and cd <= 0 and
                can_afford(state, resource, reserve) then
                nanotech_row, nanotech_injured, nanotech_affected, nanotech_talent =
                    best_nanotech_center(loadout.known, lowest, injured,
                    nanotech_candidates, policy.nanotechMinAllies)
                nanotech_resolved = true
                local unit = nanotech_row and row_unit(nanotech_row)
                if unit and nanotech_injured >= policy.nanotechMinAllies then
                    local accepted, reason = submit_explicit(executor, options, loadout.known,
                        RECUPERATIVE_NANOTECH, unit, nanotech_row.handle, resource,
                        "group_recovery_nanotech", reserve)
                    if accepted or admission_pending(reason) then return true end
                end
            end
            if try_group_waves() then return true end
        end

        -- Broad coverage is maintenance, not rescue. Resume it when the current
        -- patient leaves the emergency/urgent pressure window.
        if not focus_support_required then
            local blanket_submitted, blanket_due, blanket_reserve =
                try_probe_maintenance("priority_hot_uptime", "all")
            if blanket_submitted then return true end
            if blanket_reserve then
                log_decision(options, "wait", "probe_uptime_reserved")
                return true
            end
            if blanket_due then
                log_decision(options, "probe_degraded", "due_but_nonblocking")
            end
        end

        -- Recover Energy before any optional paid HoT/passive-refresh maintenance.
        -- Under real healing pressure, do not wait below 40% even if the user's
        -- historical setting is lower; the configured threshold still applies
        -- normally outside that pressure window.
        if options.autoAdrenalineProbe == true and
            loadout.known[ADRENALINE_PROBE] == true then
            local configured_recovery = options.adrenalineProbeThresholdPercent or 40
            local recovery_threshold = target_ratio <= direct_threshold and
                math.max(configured_recovery, 40) or configured_recovery
            if energy_percent <= recovery_threshold then
                -- Same no-external-target contract already used by the DPS routes.
                local accepted, recovery_reason = submit_untargeted(
                    executor, options, loadout.known, ADRENALINE_PROBE,
                    resource, "healing_energy_recovery")
                if admission_pending(recovery_reason) then return true end
                if accepted then
                    log_decision(options, "healing_setup", ADRENALINE_PROBE)
                    return true
                end
                log_heal_unavailable(options, ADRENALINE_PROBE, player_handle,
                    "energy_recovery", recovery_reason, resource, target_ratio, ta)
            end
        end

        -- Outside burst triage, movement control is more valuable than routine
        -- maintenance.
        if not rescue_needed and try_shared_cleanse("movement") then return true end

        -- Kolto Burst converts a self Injection into group healing. When the
        -- configured cluster is already injured in the moderate direct-heal band,
        -- take that multi-target value before donating the same Injection GCD to
        -- a single ally merely to rebuild TA.
        local kolto_burst_ready = not rescue_needed and
            target_ratio > policy.infusion and target_ratio <= policy.injection and
            loadout.known[KOLTO_BURST] == true and
            kolto_burst_count(player, injured) >= policy.koltoBurstMinAllies and
            loadout.known[KOLTO_INJECTION] == true and
            movement_allows(KOLTO_INJECTION)
        if kolto_burst_ready then
            local accepted, admission_reason = submit_explicit(
                executor, options, loadout.known, KOLTO_INJECTION,
                player, player_handle, resource, "kolto_burst_group_pressure", nil)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", "Kolto Burst via self Injection")
                return true
            end
        end

        if not nanotech_resolved then
            nanotech_row, nanotech_injured, nanotech_affected, nanotech_talent =
                best_nanotech_center(loadout.known, lowest, injured, nanotech_candidates,
                    policy.nanotechMinAllies)
        end

        -- Recuperative Nanotech is efficient instant healing on an already-HoT-covered
        -- patient. Give that real healing value first refusal before spending the
        -- same GCD on an Injection whose secondary purpose is merely rebuilding TA.
        -- Nanotech Stim keeps its specialized cooldown-reduction branch below.
        local nanotech_group_pressure =
            nanotech_injured >= policy.nanotechMinAllies and
            target_ratio <= policy.injection
        local routine_nanotech_cd = cooldown_remaining(RECUPERATIVE_NANOTECH)
        local routine_nanotech_ready = (not rescue_needed or (group_support and not urgent_support)) and
            loadout.known[RECUPERATIVE_NANOTECH] == true and nanotech_row and
            (target_ratio <= direct_threshold or nanotech_group_pressure) and
            loadout.known[NANOTECH_STIM] ~= true and
            (not finite_number(routine_nanotech_cd) or routine_nanotech_cd <= 0)
        if routine_nanotech_ready then
            local nanotech_target = nanotech_row.handle == player_handle and player or
                resolve_friendly(world, nanotech_row.handle, policy)
            if nanotech_target then
                local accepted, admission_reason = submit_explicit(
                    executor, options, loadout.known, RECUPERATIVE_NANOTECH,
                    nanotech_target, nanotech_row.handle, resource,
                    nanotech_talent .. "_routine_pressure", direct_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal",
                        RECUPERATIVE_NANOTECH .. "_routine_pressure")
                    return true
                end
                if target_backoff_gate(admission_reason) then
                    remember_target_skip(nanotech_row.handle)
                end
            end
        end

        -- If no higher-value instant/group heal exists, a useful Injection can both
        -- heal and rebuild TA. Otherwise restore the reserve with a legal selected-target Shiv.
        local useful_injection_due = not rescue_needed and
            target_ratio <= direct_threshold and loadout.known[KOLTO_INJECTION] == true
        if useful_injection_due and ta.known == true and finite_number(ta.stacks) and
            ta.stacks < 2 then
            local accepted, submit_reason = submit_friendly(
                KOLTO_INJECTION, lowest, "ta_reserve_heal_builder",
                routine_heal_reserve(resource), direct_threshold)
            if admission_pending(submit_reason) then return true end
            if accepted then
                log_decision(options, "healing_setup", KOLTO_INJECTION .. "_ta_reserve")
                return true
            end
            log_heal_unavailable(options, KOLTO_INJECTION, lowest.handle,
                "ta_reserve_builder", submit_reason, resource, target_ratio, ta)
        end
        if not rescue_needed and not useful_injection_due and
            try_ta_reserve_shiv(options, world, player, loadout.known, resource, ta,
                "stable_injured") then return true end

        -- Nanotech Stim has exact extra value beyond the HoT itself: every target
        -- affected removes 2s from the *current* Stim Boost cooldown, up to RN's
        -- four-target cap (8s). Outside burst triage, exploit that synergy before
        -- routine Probe maintenance when the configured number of injured allies
        -- fit the cluster and Stim Boost is actually on cooldown. The cast target
        -- is still an injured patient; full-health allies only influence coverage.
        local stim_cd_for_nanotech = loadout.known[NANOTECH_STIM] == true and
            cooldown_remaining(STIM_BOOST) or nil
        local nanotech_stim_opportunity = not rescue_needed and
            loadout.known[NANOTECH_STIM] == true and
            nanotech_injured >= policy.nanotechMinAllies and
            finite_number(stim_cd_for_nanotech) and stim_cd_for_nanotech > 0.5
        if nanotech_stim_opportunity and
            loadout.known[RECUPERATIVE_NANOTECH] == true and nanotech_row then
            local nanotech_target = nanotech_row.handle == player_handle and player or
                resolve_friendly(world, nanotech_row.handle, policy)
            if nanotech_target then
                local decision = nanotech_talent .. "_stim_value_injured_" ..
                    tostring(nanotech_injured) .. "_affected_" ..
                    tostring(nanotech_affected) .. "_stim_reduce_" ..
                    tostring(nanotech_affected * 2) .. "s"
                local accepted, admission_reason = submit_explicit(
                    executor, options, loadout.known, RECUPERATIVE_NANOTECH,
                    nanotech_target, nanotech_row.handle, resource, decision, direct_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", RECUPERATIVE_NANOTECH .. "_" .. decision)
                    return true
                end
                if target_backoff_gate(admission_reason) then
                    remember_target_skip(nanotech_row.handle)
                end
            end
        end

        -- From level 60 onward, heal and refresh the current target in one GCD:
        -- Accomplished Doctor makes Infusion/Surgical Probe refresh an existing
        -- two-stack Kolto Probe. Preserve scarce last-TA cases for the manual
        -- Kolto Probe fallback instead of spending the final stack casually.
        if not emergency and loadout.known[ACCOMPLISHED_DOCTOR] == true and
            ta.present == true then
            local probe = mine_effect_snapshot(target, KOLTO_PROBE, "buff")
            local expiring = type(probe) == "table" and
                probe.stacks >= KOLTO_PROBE_MAX_STACKS and
                finite_number(probe.remaining) and
                probe.remaining <= policy.koltoProbeRefreshSeconds
            if expiring and target_ratio <= policy.infusion and
                loadout.known[KOLTO_INFUSION] == true and
                movement_allows(KOLTO_INFUSION) then
                local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                    KOLTO_INFUSION, target, lowest.handle, resource,
                    "accomplished_doctor_infusion_refresh", direct_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", KOLTO_INFUSION .. "_probe_refresh")
                    return true
                end
            end
            if expiring and finite_number(ta.stacks) and ta.stacks >= 2 and
                loadout.known[SURGICAL_PROBE] == true then
                local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                    SURGICAL_PROBE, target, lowest.handle, resource,
                    "accomplished_doctor_surgical_refresh", maintenance_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", SURGICAL_PROBE .. "_probe_refresh")
                    return true
                end
            end
        end

        -- Curative Jolt (78) guarantees the next Surgical Probe crit after an
        -- Infusion. Consume that proc before another cast-time direct heal when
        -- the current target still has meaningful damage.
        if runtime.curativeJoltAvailable and ta.present == true and
            target_ratio <= direct_threshold and loadout.known[SURGICAL_PROBE] == true then
            local accepted, admission_reason = submit_friendly(
                SURGICAL_PROBE, lowest, "curative_jolt_guaranteed_crit", nil,
                direct_threshold)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", SURGICAL_PROBE .. "_curative_jolt")
                return true
            end
        end

        -- Kolto Stim rewards self-Injection with extra TA (and the current live
        -- node also buffs that self-heal). Exploit it only from zero TA and only
        -- when self is itself a legitimate near-priority target; never abandon a
        -- substantially lower ally just to farm resources.
        if loadout.known[KOLTO_STIM] == true and
            loadout.known[KOLTO_INJECTION] == true and movement_allows(KOLTO_INJECTION) and
            ta.known == true and
            ta.present ~= true and finite_number(player_ratio) and
            player_ratio < 1.0 and player_ratio <= policy.injection and
            player_ratio <= target_ratio + 0.03 and target_ratio > policy.infusion then
            local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                KOLTO_INJECTION, player, player_handle, resource,
                "kolto_stim_self_tactical_advantage", routine_heal_reserve(resource))
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", KOLTO_INJECTION .. "_kolto_stim")
                return true
            end
        end

        -- Spend capped TA before an Injection builder or the chip-damage exit.
        -- Stable-patient HoT maintenance above keeps its priority and coverage.
        if not emergency and ta_capped then
            if try_infusion() then return true end
            if loadout.known[SURGICAL_PROBE] == true then
                local accepted, admission_reason = submit_friendly(
                    SURGICAL_PROBE, lowest, "ta_cap_avoid_overcap", nil, policy.healStart)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", SURGICAL_PROBE .. "_ta_cap")
                    return true
                end
                log_heal_unavailable(options, SURGICAL_PROBE, lowest.handle,
                    "ta_cap", admission_reason, resource, target_ratio, ta)
            end
        end

        -- Do not throw away a proven three-stack Diagnostics Probe window on
        -- another routine Surgical Probe. At current 7.x values this Injection is
        -- instant; below TA cap it is the safest high-throughput direct heal. One-
        -- and two-stack reductions need no special cast path because the game
        -- applies their shorter native cast time automatically.
        if diagnosticsInstant and not ta_capped and
            target_ratio <= direct_threshold and loadout.known[KOLTO_INJECTION] == true and
            (moving ~= true or heal_usable_while_moving(
                loadout.known, player, KOLTO_INJECTION)) then
            local accepted, admission_reason = submit_friendly(
                KOLTO_INJECTION, lowest, "diagnostics_probe_instant", direct_reserve,
                direct_threshold)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", KOLTO_INJECTION .. "_diagnostics_instant")
                return true
            end
        end

        -- Maintain Reactive Substance after a useful capped-TA spender has had
        -- first refusal. Below the cap its existing setup priority is preserved.
        if target_ratio > EMERGENCY_HEAL_RATIO and target_ratio <= direct_threshold and
            loadout.known[REACTIVE_SUBSTANCE] == true and
            loadout.known[KOLTO_INJECTION] == true and
            movement_allows(KOLTO_INJECTION) then
            local reactive_stacks = mine_effect_stacks(target, REACTIVE_SUBSTANCE, "buff")
            if reactive_stacks ~= nil and reactive_stacks < 2 then
                local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                    KOLTO_INJECTION, target, lowest.handle, resource,
                    "reactive_substance_maintenance",
                    direct_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", KOLTO_INJECTION .. "_reactive")
                    return true
                end
            end
        end

        -- Capped non-emergency TA already tried Infusion above.
        if (emergency or not ta_capped) and try_infusion() then return true end

        -- In the ordinary rescue band, an already-HoT-covered patient gets the
        -- instant/efficient RN before a cast-time Injection used largely to build
        -- TA. True emergency/life-saving rails above remain unchanged.
        local rescue_nanotech_cd = cooldown_remaining(RECUPERATIVE_NANOTECH)
        if rescue_needed and not emergency and
            loadout.known[RECUPERATIVE_NANOTECH] == true and nanotech_row and
            (not finite_number(rescue_nanotech_cd) or rescue_nanotech_cd <= 0) then
            local nanotech_target = nanotech_row.handle == player_handle and player or
                resolve_friendly(world, nanotech_row.handle, policy)
            if nanotech_target then
                local accepted, admission_reason = submit_explicit(
                    executor, options, loadout.known, RECUPERATIVE_NANOTECH,
                    nanotech_target, nanotech_row.handle, resource,
                    nanotech_talent .. "_rescue_pressure", direct_reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal",
                        RECUPERATIVE_NANOTECH .. "_rescue_pressure")
                    return true
                end
                if target_backoff_gate(admission_reason) then
                    remember_target_skip(nanotech_row.handle)
                end
            end
        end

        if rescue_needed and loadout.known[KOLTO_INJECTION] == true then
            local accepted, submit_reason = submit_friendly(
                KOLTO_INJECTION, lowest,
                emergency and "emergency_build_tactical" or "burst_build_tactical",
                nil, rescue_ceiling)
            if admission_pending(submit_reason) then return true end
            if accepted then
                log_decision(options, "heal", KOLTO_INJECTION)
                return true
            end
            log_heal_unavailable(options, KOLTO_INJECTION, lowest.handle,
                emergency and "emergency" or "burst", submit_reason,
                resource, target_ratio, ta)
        end

        -- If cast-time healing is blocked by movement, zero TA is a degraded
        -- healing state. Use an exact selected melee hostile to rebuild TA before
        -- drifting into weaker maintenance. A real last TA is still spent on the
        -- Surgical Probe below before we consider rebuilding it. This resource
        -- preparation does not depend on the Idle DPS master toggle.
        if rescue_needed and not emergency and moving == true and
            ta.known == true and finite_number(ta.stacks) and ta.stacks == 0 and
            try_ta_reserve_shiv(options, world, player, loadout.known, resource, ta,
                "burst_mobile_zero") then return true end

        -- Above the emergency band, direct throughput still owns the rescue GCD.
        -- Do not seed/refresh Kolto Probe ahead of Surgical Probe on a collapsing
        -- patient; HoT maintenance resumes only after the direct rescue chain.
        if rescue_needed and not emergency and ta.present == true and
            loadout.known[SURGICAL_PROBE] == true then
            local accepted, admission_reason = submit_friendly(
                SURGICAL_PROBE, lowest, "burst_instant_surgical", nil, rescue_ceiling)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", SURGICAL_PROBE .. "_burst_instant")
                return true
            end
            log_heal_unavailable(options, SURGICAL_PROBE, lowest.handle,
                "burst_instant", admission_reason, resource, target_ratio, ta)
        end

        -- Once Kolto Probe is available, do not spend the healer's recovery band
        -- rebuilding/refreshing HoTs or Nanotech. Recover first unless the target
        -- has already fallen into the immediate Infusion/burst band.
        if loadout.known[KOLTO_PROBE] == true and energy_percent <= 60 and
            target_ratio > policy.infusion and
            loadout.known[DIAGNOSTIC_SCAN] == true and
            (moving ~= true or heal_usable_while_moving(
                loadout.known, player, DIAGNOSTIC_SCAN)) then
            local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                DIAGNOSTIC_SCAN, target, lowest.handle, resource,
                "energy_recovery_before_hot_maintenance", nil)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", DIAGNOSTIC_SCAN .. "_recovery_before_hots")
                return true
            end
        end

        -- With no TA while moving, Recuperative Nanotech is the strongest
        -- available instant rescue. Anchor it on the endangered patient rather
        -- than moving the cast to a healthier cluster center, but still retain
        -- exact affected/injured counts for Nanotech Stim diagnostics.
        if mobile_zero_ta_emergency then
            nanotech_row = lowest
            nanotech_injured = math.min(RECUPERATIVE_NANOTECH_MAX_TARGETS,
                cluster_count(lowest, injured, RECUPERATIVE_NANOTECH_RADIUS_METERS))
            nanotech_affected = math.min(RECUPERATIVE_NANOTECH_MAX_TARGETS,
                cluster_count(lowest, nanotech_candidates, RECUPERATIVE_NANOTECH_RADIUS_METERS))
            nanotech_talent = "mobile_zero_ta_emergency"
        end
        local nanotech_ready_cd = cooldown_remaining(RECUPERATIVE_NANOTECH)
        if loadout.known[RECUPERATIVE_NANOTECH] == true and nanotech_row and
            (mobile_zero_ta_emergency or nanotech_group_pressure or
                target_ratio <= direct_threshold) and
            (not finite_number(nanotech_ready_cd) or nanotech_ready_cd <= 0) then
            local nanotech_target = nanotech_row.handle == player_handle and player or
                resolve_friendly(world, nanotech_row.handle, policy)
            if nanotech_target then
                local group_detail = nanotech_talent .. "_group_injured_" ..
                    tostring(nanotech_injured) .. "_affected_" .. tostring(nanotech_affected)
                if loadout.known[NANOTECH_STIM] == true then
                    group_detail = group_detail .. "_stim_reduce_" ..
                        tostring(nanotech_affected * 2) .. "s"
                end
                local single_detail = nanotech_talent .. "_single_affected_" ..
                    tostring(nanotech_affected)
                local decision = mobile_zero_ta_emergency and
                    "mobile_zero_ta_emergency" or
                    (nanotech_group_pressure and group_detail or single_detail)
                local reserve = direct_reserve
                local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                    RECUPERATIVE_NANOTECH, nanotech_target, nanotech_row.handle,
                    resource, decision, reserve)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "heal", RECUPERATIVE_NANOTECH .. "_" .. decision)
                    return true
                end
                if target_specific_gate(admission_reason) then
                    remember_target_skip(nanotech_row.handle)
                    if admission_reason == "target_dead" then
                        log_decision(options, "wait", "nanotech_target_dead_retriage")
                        return true
                    end
                end
                -- During the exact TA=0/mobile emergency from the arena log,
                -- reserve an imminently opening GCD for RN instead of falling
                -- into a weaker channel/ground-start path. Cooldown/not-ready
                -- still falls through to Probe/Diagnostic Scan immediately.
                if mobile_zero_ta_emergency and
                    (admission_reason == "gcd" or admission_reason == "busy" or
                        admission_reason == "ability_submission_pending" or
                        admission_reason == "explicit_target_sync_pending" or
                        admission_reason == "bridge_busy" or
                        admission_reason == "ability_command_busy" or
                        admission_reason == "command_busy") then
                    log_decision(options, "wait", "mobile_zero_ta_rn_reserved")
                    return true
                end
            end
        end

        -- Kolto Waves (60) is sustained group throughput, never a single-target
        -- filler. RN gets first refusal; Waves follows when at least the configured
        -- number of genuinely injured allies fit inside the exact 8m cluster.
        if try_group_waves() then return true end

        -- Emergency direct healing and RN/Waves have already had first refusal.
        -- If movement still blocks Injection and exact TA is below two, Shiv is
        -- now a healing-resource action rather than dead air. A ready RN retains
        -- priority because its admission path above returns before this point.
        if rescue_needed and emergency and moving == true and
            try_ta_reserve_shiv(options, world, player, loadout.known, resource, ta,
                "emergency_mobile") then return true end

        -- Diagnostic Scan is intentionally weak sustained/recovery throughput.
        -- When the target is already in the Infusion/burst band, never commit a
        -- spare GCD/channel to it just because Injection/Infusion are blocked.
        -- At levels before Surgical Probe, use an instant Kolto Probe on the
        -- endangered target if its two-stack HoT is not safely established;
        -- otherwise wait for real burst throughput to become admissible.
        if target_ratio <= policy.infusion and loadout.known[KOLTO_PROBE] == true then
            local covered, probe_state = probe_is_covered(target, lowest.handle)
            if covered == false then
                local probe_detail = "refresh_expiring"
                if probe_state.stacks <= 0 then
                    probe_detail = "build_1"
                elseif probe_state.stacks < KOLTO_PROBE_MAX_STACKS then
                    probe_detail = "build_2"
                end
                local accepted, admission_reason, result, actual_row = submit_friendly(
                    KOLTO_PROBE, lowest,
                    emergency and "emergency_instant_hot_fallback" or
                        "burst_instant_hot_fallback",
                    BURST_HEAL_ENERGY_RESERVE, policy.infusion)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    if type(result) == "table" and type(result.command_handle) == "string" and
                        type(actual_row) == "table" then
                        runtime.probeCommand = {
                            handle = result.command_handle,
                            target = actual_row.handle,
                            detail = probe_detail,
                            baselineRemaining = probe_state.remaining,
                        }
                    end
                    log_decision(options, "heal",
                        KOLTO_PROBE .. "_burst_fallback_" .. probe_detail)
                    return true
                end
            elseif covered == nil then
                log_decision(options, "wait", "probe_observation_unknown_preserve_energy")
            end
        end

        -- Emergency/burst throughput above had first refusal. Roots and other
        -- enabled movement controls now outrank ordinary healing maintenance.
        if try_shared_cleanse("movement") then return true end

        -- Spend available TA on useful instant healing before the free Scan or
        -- routine Injection builder. Preserve the last stack's throughput buff.
        if not rescue_needed and ta.present == true and loadout.known[SURGICAL_PROBE] == true and
            target_ratio <= direct_threshold and
            (loadout.known[TACTICAL_EFFECTIVENESS] ~= true or
                (finite_number(ta.stacks) and ta.stacks >= 2)) then
            local accepted, admission_reason = submit_friendly(
                SURGICAL_PROBE, lowest, "spare_tactical_surgical", nil, direct_threshold)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", SURGICAL_PROBE .. "_spare_tactical")
                return true
            end
            log_heal_unavailable(options, SURGICAL_PROBE, lowest.handle,
                "spare_tactical", admission_reason, resource, target_ratio, ta)
        end

        -- Diagnostic Scan has three deliberate burst-band jobs, never a generic
        -- replacement for a stronger ready heal:
        --   1) <=35% Energy: free recovery bridge while native regen catches up.
        --   2) active movement: mobile throughput only when the paid cast-time
        --      heals themselves are not movement-usable and every instant/group
        --      option above already had first refusal.
        --   3) <=20% HP: last-resort life-saving throughput after every stronger
        --      heal above has already failed this tick. An empty GCD at 5% HP is
        --      worse than a weak channel.
        local scan_mobile_escape = moving == true and
            loadout.known[DIAGNOSTIC_SCAN] == true and
            heal_usable_while_moving(loadout.known, player, DIAGNOSTIC_SCAN) and
            ((loadout.known[KOLTO_INJECTION] == true and
                not heal_usable_while_moving(loadout.known, player, KOLTO_INJECTION)) or
             (loadout.known[KOLTO_INFUSION] == true and
                not heal_usable_while_moving(loadout.known, player, KOLTO_INFUSION)))
        local scan_energy_bridge = energy_percent <= 35
        local scan_life_saving = target_ratio <= LIFE_SAVING_HEAL_RATIO
        if target_ratio <= policy.infusion and
            (scan_energy_bridge or scan_mobile_escape or scan_life_saving) and
            loadout.known[DIAGNOSTIC_SCAN] == true and
            (moving ~= true or heal_usable_while_moving(
                loadout.known, player, DIAGNOSTIC_SCAN)) then
            local scan_reason = scan_life_saving and "life_saving_last_resort" or
                scan_energy_bridge and "critical_energy_recovery_bridge" or
                    "critical_mobile_fallback"
            local accepted, submit_reason = submit_friendly(
                DIAGNOSTIC_SCAN, lowest, scan_reason, nil, policy.infusion)
            if admission_pending(submit_reason) then return true end
            if accepted then
                local suffix = scan_life_saving and "_life_saving" or
                    scan_energy_bridge and "_critical_recovery" or "_mobile_fallback"
                log_decision(options, "heal", DIAGNOSTIC_SCAN .. suffix)
                return true
            end
            local scan_stage = scan_life_saving and "life_saving_last_resort" or
                scan_energy_bridge and "critical_energy_recovery" or
                    "critical_mobile_fallback"
            log_heal_unavailable(options, DIAGNOSTIC_SCAN, lowest.handle,
                scan_stage, submit_reason, resource, target_ratio, ta)
        end

        -- Once HoT/Nanotech/Waves maintenance is satisfied, chip damage above the
        -- direct-heal threshold belongs to the HoTs. Optional pressure cleansing
        -- gets the final healer GCD before the route starts doing damage.
        if target_ratio > direct_threshold then
            if try_shared_cleanse("pressure") then return true end
            if try_idle_dps(options, world, player, loadout.known, resource, ta) then
                return true
            end
            log_decision(options, "wait", hot_covered and
                "hot_covered_chip_no_dps_target" or "chip_damage_no_dps_target")
            return true
        end

        if loadout.known[KOLTO_PROBE] ~= true and energy_percent <= 60 and
            target_ratio > policy.infusion and loadout.known[DIAGNOSTIC_SCAN] == true and
            (moving ~= true or heal_usable_while_moving(
                loadout.known, player, DIAGNOSTIC_SCAN)) then
            local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                DIAGNOSTIC_SCAN, target, lowest.handle, resource,
                "energy_recovery_heal", nil)
            if admission_pending(admission_reason) then return true end
            if accepted then
                log_decision(options, "heal", DIAGNOSTIC_SCAN .. "_recovery")
                return true
            end
        end

        if target_ratio <= direct_threshold and loadout.known[KOLTO_INJECTION] == true then
            local accepted, submit_reason = submit_friendly(
                KOLTO_INJECTION, lowest, "direct_heal_build_tactical",
                direct_reserve,
                direct_threshold)
            if admission_pending(submit_reason) then return true end
            if accepted then
                log_decision(options, "heal", KOLTO_INJECTION)
                return true
            end
            log_heal_unavailable(options, KOLTO_INJECTION, lowest.handle,
                "direct", submit_reason, resource, target_ratio, ta)
        end

        if loadout.known[DIAGNOSTIC_SCAN] == true and
            (loadout.known[KOLTO_PROBE] ~= true or target_ratio > policy.infusion) and
            (moving ~= true or heal_usable_while_moving(
                loadout.known, player, DIAGNOSTIC_SCAN)) then
            local accepted, submit_reason = submit_friendly(
                DIAGNOSTIC_SCAN, lowest, "light_heal_energy_positive", nil,
                direct_threshold)
            if admission_pending(submit_reason) then return true end
            if accepted then
                log_decision(options, "heal", DIAGNOSTIC_SCAN)
                return true
            end
            log_heal_unavailable(options, DIAGNOSTIC_SCAN, lowest.handle,
                "fallback", submit_reason, resource, target_ratio, ta)
        end

        -- All normal healing has now had first refusal. Pressure debuffs are
        -- optional, but still healer utility and therefore outrank DPS/peels.
        if try_shared_cleanse("pressure") then return true end

        -- Debilitate is not routine healer throughput. When selected, use it as
        -- a last-resort peel only after every real heal above failed and only
        -- while self is critical against a stunnable close hostile.
        if loadout.known[DEBILITATE] == true and options.inCombat == true and
            finite_number(player_ratio) and player_ratio <= EMERGENCY_HEAL_RATIO then
            local hostile, hostile_handle = action_target(world)
            if hostile and can_stun_for_peel(hostile) and
                within_dps_range(hostile, DEBILITATE) then
                local accepted, admission_reason = submit_explicit(executor, options, loadout.known,
                    DEBILITATE, hostile, hostile_handle, resource,
                    "emergency_debilitate_peel", nil)
                if admission_pending(admission_reason) then return true end
                if accepted then
                    log_decision(options, "healing_setup", DEBILITATE .. "_peel")
                    return true
                end
            end
        end

        log_decision(options, "wait", "healing_needed_no_safe_cast")
        return true
    end

    return {
        build_id = "medicine-triage-r18-isolated-and-group-support",
        is_selected = is_selected,
        has_local_pending = function()
            return runtime.nativeAdmission ~= nil or owns_pending()
        end,
        owns_pending = owns_pending,
        stop = stop,
        tick = tick,
    }
end

return M
