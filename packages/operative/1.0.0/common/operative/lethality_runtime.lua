-- Dedicated Lethality runtime; isolates it from concurrent Concealment edits.
-- Capability-driven through level 80: gos.abilities.loadout().known is SSOT.
-- Active buttons, passives and tree choices are used only when actually learned.

local Mirror = require("operative.mirror")
local CurrentLoadout
local M = {}
M.targetMode = "native_current_selection"
M.build_id = "lethality80-r4-exact-admission-retry"

local READY_SLACK = 0.04
local FAILURE_BACKOFF = 0.40
local CONTENTION_BACKOFF = 0.12
local ACCEPTED_UNCONFIRMED_BACKOFF = 0.75
local METERS_PER_WORLD_UNIT = 10.0
local DOT_OBSERVATION_GRACE = 1.50
local TA_OBSERVATION_GRACE = 2.00
local TACTICAL_OPPORTUNITY_PREDICTION_GRACE = 0.75
local DOT_EFFECT = "Corrosive Dart"
local GRENADE_EFFECT = "Corrosive Grenade"
local FATALITY_EFFECT = "Fatality"
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
-- Current-client primary periodic definitions, not the parent ability name.
-- Assailable/Marked, slows and 5s lingering poisons must not extend upkeep.
-- Source: docs/research/pvp_cleanse_effects_20260907.csv; same API as Commando.
local POISON_FILTERS = {
    [DOT_EFFECT] = { kind = "debuff", timed = true,
        definition_key = "effectdef:C1434E7686FF7AF0" },
    [GRENADE_EFFECT] = { kind = "debuff", timed = true,
        definition_key = "effectdef:69B5B6CAE4F828EA" },
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
    local is_lethality = true
    assert(spec.discipline == "Lethality", "Lethality runtime requires its exact spec")
    local owner_prefix = spec.owner .. ":"
    local grenade_ttl = type(spec.grenadeDuration) == "number" and spec.grenadeDuration or 24.0
    local Ability = {
        RifleShot = { id = "Rifle Shot", range = 30.0, fallbackCost = 0.0 },
        Shiv = { id = "Shiv", range = 4.0, fallbackCost = 15.0 },
        OverloadShot = { id = "Overload Shot", range = 10.0, fallbackCost = 15.0 },
        FragmentationGrenade = {
            id = "Fragmentation Grenade", range = 30.0, fallbackCost = 20.0,
            aoeRadius = 5.0, maxTargets = 7,
        },
        CorrosiveDart = { id = "Corrosive Dart", range = 30.0, fallbackCost = 15.0 },
        Backstab = {
            id = "Backstab", range = 4.0, fallbackCost = 15.0,
        },
        LethalStrike = {
            id = "Lethal Strike", range = 4.0, fallbackCost = 15.0,
        },
        Holotraverse = {
            id = "Holotraverse", range = 30.0, fallbackCost = 0.0,
            offGcd = true,
        },
        TacticalSuperiority = {
            id = "Tactical Superiority", targetless = true, offGcd = true,
            fallbackCost = 0.0, requiresTacticalAdvantage = true,
        },
        StimBoost = {
            id = "Stim Boost", targetless = true, offGcd = true, fallbackCost = 0.0,
        },
        AdrenalineProbe = {
            id = "Adrenaline Probe", targetless = true, offGcd = true, fallbackCost = 0.0,
        },
        NoxiousKnives = {
            id = "Noxious Knives", targetless = true,
            fallbackCost = 15.0,
        },
        CripplingSlice = {
            id = "Crippling Slice", range = 4.0, fallbackCost = 0.0,
        },
        CripplingThrow = {
            id = "Crippling Throw", range = 10.0, fallbackCost = 0.0,
        },
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
        ShieldProbe = {
            id = "Shield Probe", targetless = true, offGcd = true, fallbackCost = 0.0,
        },
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
        Ability.RifleShot, Ability.Shiv, Ability.OverloadShot,
        Ability.FragmentationGrenade, Ability.CorrosiveDart, Ability.Backstab,
        Ability.LethalStrike, Ability.Holotraverse, Ability.TacticalSuperiority,
        Ability.StimBoost, Ability.AdrenalineProbe, Ability.NoxiousKnives,
        Ability.CripplingSlice, Ability.CripplingThrow, Ability.VolatileSubstance,
        Ability.CorrosiveGrenade, Ability.ToxicHaze, Ability.ToxicBlast,
        Ability.TacticalOverdrive, Ability.ShieldProbe, Ability.Spender,
    }

    local Runtime = {
        nativeAdmission = nil, pending = nil,
        observations = {}, applications = {},
        eventCursor = nil, eventPlayer = nil,
        eventIdentities = {}, nextIdentityAt = 0,
        eventStats = {activations=0,localActivations=0,matched=0,unmatched=0},
        taRejectedAfter = nil, requests = {},
        taLedger = nil, fatalityLedger = nil,
        lastActivated = {}, noticeTimes = {},
        lastDecisionAt = -math.huge, lastProgressionAt = -math.huge,
        stopped = true, observationContinuity = true,
        taActivationAt = -math.huge,
        fatalityActivationAt = -math.huge,
        lifetimeSamples = {},
        lifetimeTarget = nil,
        failureBackoff = {},
        contentionUntil = 0.0,
        targetBlockUntil = 0.0,
        targetBlockHandle = nil,
        dotAttemptTarget = nil,
        dotAttemptUntil = 0.0,
        dotKnownUntil = {},
        grenadeAttemptTarget = nil,
        grenadeAttemptUntil = 0.0,
        grenadeKnownUntil = {},
        grenadeGraceUntil = {},
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
        concealmentSequence = nil,
        cripplingFollowup = nil,
        stealthConsumedUntil = 0.0,
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
        if type(logger) == "function" then logger(level, message) end
    end
    local function notice(options, level, key, message, interval)
        local now = gos.time_ms()/1000.0
        if now < (Runtime.noticeTimes[key] or -math.huge) + (interval or 2.0) then return end
        Runtime.noticeTimes[key] = now
        emit(options, level, message)
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

    local function evidence_key(handle, name)
        return tostring(handle or "none") .. ":" .. name
    end
    -- Names on combat events are optional. Both handles below come from the
    -- exact ability row; neither display names nor guessed numeric IDs identify activations.
    local function register_identity(name, info)
        if type(info) ~= "table" then return end
        local submission, activation = info.ability_handle, info.activation_handle
        if type(submission) ~= "string" and type(activation) ~= "string" then return end
        Runtime.eventIdentities[name] = { submission = submission, activation = activation }
    end
    local function activation_name(event)
        if type(event.ability_handle) ~= "string" then return nil, "missing_ability_handle" end
        local found
        for name, identity in pairs(Runtime.eventIdentities) do
            if event.ability_handle == identity.activation or event.ability_handle == identity.submission then
                if found and found ~= name then return nil, "ambiguous_ability_handle" end
                found = name
            end
        end
        return found, found and "exact_handle" or "unmapped_ability_handle"
    end
    local function observe_events(batch, loadout, player_handle)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        if not is_selected(loadout) or type(batch) ~= "table" then return end
        local combat_style = Mirror.raw_loadout(loadout).combat_style
        if batch.cursor == Runtime.eventCursor and Runtime.eventStyle == combat_style then return end
        local discontinuity = Runtime.eventPlayer ~= player_handle or Runtime.eventStyle ~= combat_style or (batch.dropped or 0) > 0 or
            (finite(batch.cursor) and finite(Runtime.eventCursor) and batch.cursor < Runtime.eventCursor)
        Runtime.eventCursor = batch.cursor
        if discontinuity then
            Runtime.observations, Runtime.applications = {}, {}
            Runtime.taLedger, Runtime.fatalityLedger = nil, nil
            Runtime.lastActivated, Runtime.requests = {}, {}
            Runtime.taRejectedAfter = nil
            Runtime.eventIdentities, Runtime.nextIdentityAt = {}, 0
            Runtime.eventPlayer = player_handle
            Runtime.eventStyle = combat_style
        end
        if player_handle == nil then return end
        local now = gos.time_ms()/1000.0
        if now >= Runtime.nextIdentityAt then
            Runtime.nextIdentityAt = now + 2.0
            -- Bounded worker-cadence metadata refresh; normal ability_snapshot also
            -- keeps these identities current using the rows it already reads.
            for _, ability in ipairs(AbilityList) do
                if loadout_has(loadout, ability.id) then
                    register_identity(ability.id, Mirror.info(CurrentLoadout, ability.id))
                else Runtime.eventIdentities[ability.id] = nil end
            end
        end
        for index = 1, math.min(64, #(batch.events or {})) do
            local event = batch.events[index]
            if type(event) == "table" and event.kind == "ability" and event.action == "ability_activate" then
                Runtime.eventStats.activations = Runtime.eventStats.activations + 1
                if event.source_handle == player_handle then
                    Runtime.eventStats.localActivations = Runtime.eventStats.localActivations + 1
                    local name, identity_reason = activation_name(event)
                    if not name then
                        Runtime.eventStats.unmatched = Runtime.eventStats.unmatched + 1
                        notice(Runtime.lastOptions, "debug", "event_identity",
                            "lethality activation unmatched: reason="..identity_reason..
                            " handle="..tostring(event.ability_handle).." name="..tostring(event.name), 5.0)
                    else
                        local t = finite(event.timestamp) and event.timestamp/1000.0 or now
                        if t > (Runtime.lastActivated[name] or -math.huge) then
                            Runtime.eventStats.matched = Runtime.eventStats.matched + 1
                            Runtime.lastActivated[name] = t
                            local request = Runtime.requests[name]
                            if request and not request.failed and not request.confirmedAt and
                                t >= request.submittedAt and t-request.submittedAt <= 2.0 then
                                request.confirmedAt = t
                                request.receiptAt = nil
                            else request = nil end
                            if Runtime.lastOptions and Runtime.lastOptions.castLog then
                                emit(Runtime.lastOptions, "info", "lethality activated: "..name..
                                    " source=server_event identity=exact_handle origin="..
                                    (request and "lua_request_correlated" or "observed_player_activation"))
                            end
                            local ledger = Runtime.taLedger
                            local n = ledger and (ledger.count == 0 or ledger.untilTime > t) and ledger.count or nil
                            local exact = ledger and ledger.exact == true or false
                            local grant = name == "Shiv" or name == "Toxic Blast" or name == "Stim Boost" or
                                name == "Holotraverse" or
                                ((name == "Backstab" or name == "Lethal Strike") and request and request.fromStealth)
                            local spend = name == "Corrosive Assault" or name == "Toxic Haze" or
                                name == "Tactical Superiority"
                            -- A newer effect snapshot already contains this activation. Do
                            -- not apply its delta again when the event arrives a tick late.
                            if (grant or spend) and (not ledger or ledger.changedAt < t) then
                                local count
                                if grant then
                                    count = math.min(2, (n or 0) + 1)
                                    if name == "Stim Boost" and loadout_has(loadout,"Tactical Stims") then
                                        count, exact = 2, true
                                    end
                                elseif finite(n) and exact then count = math.max(0, n - 1)
                                else count, exact = nil, false end
                                Runtime.taLedger = {count=count, exact=exact, changedAt=t,
                                    settleUntil=t+0.35, untilTime=t+24.0,
                                    source=grant and "confirmed_generation" or "confirmed_consumption"}
                            end
                            if grant then Runtime.taRejectedAfter = nil end
                            if name == "Corrosive Assault" then
                                local f = Runtime.fatalityLedger
                                if not f or f.changedAt < t then
                                    Runtime.fatalityLedger={untilTime=0,changedAt=t,settleUntil=t+0.35,
                                        source="confirmed_consumption"}
                                end
                                -- Fatality and Corrosive Return refunds may arrive separately
                                -- (the saved fight goes 1 -> 0 -> 1 -> 2). Only their actual
                                -- charge observation reconciles the refund; never guess a cap.
                            elseif name == "Shiv" and loadout_has(loadout,"Fatality") and
                                t >= Runtime.fatalityReadyAt then
                                local f = Runtime.fatalityLedger
                                if not f or f.changedAt < t then
                                    Runtime.fatalityLedger={untilTime=t+15.0,changedAt=t,settleUntil=t+0.35,
                                        source="confirmed_shiv_proc"}
                                end
                                Runtime.fatalityReadyAt=t+10.0
                            end
                            if name == "Backstab" or name == "Lethal Strike" then
                                Runtime.stealthLatched=false
                                Runtime.stealthConsumedUntil=now+1.0
                            end
                            if name=="Corrosive Dart" or name=="Corrosive Grenade" then
                                local target=event.target_handle
                                if request and request.targetMode=="selected" then
                                    local original_key=evidence_key(request.targetHandle,name)
                                    local original=Runtime.applications[original_key]
                                    if target and target~=player_handle and target~=request.targetHandle and
                                        original and original.request==request and not original.confirmed then
                                        Runtime.applications[original_key]=nil
                                    end
                                    -- No substitution of current/captured selection for an
                                    -- unknown server recipient. Fresh owned effects settle
                                    -- the application independently.
                                elseif (target==nil or target==player_handle) and request then
                                    target=request.targetHandle
                                end
                                if target and target~=player_handle then
                                    local key=evidence_key(target,name)
                                    local app=Runtime.applications[key]
                                    if not app or t>=app.time then
                                        app=app or {}
                                        app.time,app.confirmed,app.activatedAt=t,true,t
                                        app.settledAt=nil
                                        Runtime.applications[key]=app
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local function read_effect(now, unit, name, own, options)
        local handle=safe_method(unit,"handle")
        local poison_filter = own and POISON_FILTERS[name] or nil
        -- Keep semantic names for the activation/continuity ledgers, but query
        -- only the exact effect identity. Empty name avoids a second name gate.
        local raw=unit_effect(unit,poison_filter and "" or name,
            poison_filter or (own and DOT_FILTER or BUFF_FILTER))
        local result=observed_effect(now,raw,own)
        local sample=type(raw)=="table" and finite(raw.age_ms) and now-raw.age_ms/1000.0 or now
        local key=evidence_key(handle,name)
        local continuity=options.lethalityEffectContinuity~=false
        if name==TACTICAL_ADVANTAGE_EFFECT then
            local ledger=Runtime.taLedger
            local new_sample=result.status=="ready" and
                (not ledger or sample>math.max(ledger.changedAt,ledger.settleUntil or -math.huge))
            if new_sample then
                local n=result.present and result.stacks or 0
                if finite(n) then
                    result.stacks=n
                    Runtime.taLedger={count=n,exact=true,changedAt=sample,
                        untilTime=now+(result.remaining or (n>0 and 24 or 0)),source="effect"}
                    ledger=Runtime.taLedger
                    if n>0 and Runtime.taRejectedAfter and sample>Runtime.taRejectedAfter then
                        Runtime.taRejectedAfter=nil
                    end
                end
            elseif continuity and ledger and finite(ledger.count) and
                (ledger.count==0 or ledger.untilTime>now) then
                -- Zero is a known state, not an expiring buff. It survives scanner
                -- outages until a real generator, new charge sample or stream reset.
                result={status="ready",present=ledger.count>0,stacks=ledger.count,
                    source=ledger.source,remaining=math.max(0,ledger.untilTime-now)}
            end
        elseif name==FATALITY_EFFECT then
            local ledger=Runtime.fatalityLedger
            if result.status=="ready" and
                (not ledger or sample>math.max(ledger.changedAt,ledger.settleUntil or -math.huge)) then
                Runtime.fatalityLedger={changedAt=sample,
                    untilTime=result.present and finite(result.remaining) and now+result.remaining or 0,
                    source="effect"}
                if result.present and finite(result.remaining) then
                    Runtime.fatalityReadyAt=now+math.max(0,result.remaining-5.0)
                end
            elseif continuity and ledger then
                result={status="ready",present=ledger.untilTime>now,
                    remaining=math.max(0,ledger.untilTime-now),source=ledger.source}
            end
        elseif own then
            local cache=Runtime.observations[key]
            local app=Runtime.applications[key]
            local activation=app and (app.activatedAt or app.time)
            local expiry=result.present and result.mine and finite(result.remaining) and now+result.remaining or nil
            local fresh=result.status=="ready" and (not app or sample>activation)
            local refreshed=fresh and expiry and
                (not app or not app.baselineExpiry or expiry>app.baselineExpiry+READY_SLACK)
            if refreshed then
                Runtime.observations[key]={expiresAt=expiry,sampleAt=sample}
                if app then app.settledAt=sample end
            elseif app and not app.settledAt and
                (not fresh or sample<activation+1.5 or (expiry and app.baselineExpiry and expiry<=app.baselineExpiry+READY_SLACK)) then
                -- The old timer/removal can race a new application. Reconcile to
                -- the activation timestamp, not the earlier queue receipt. A
                -- snapshot from before activation cannot acknowledge this refresh.
                result={status="pending",present=false,mine=false,source="application_reconciling"}
                if continuity and cache and cache.expiresAt>now then
                    result.present,result.mine,result.remaining=true,true,cache.expiresAt-now
                end
            elseif fresh then
                if not result.present or result.mine==false then Runtime.observations[key]=nil end
                if app then app.settledAt=sample end
            elseif continuity and cache and cache.expiresAt>now then
                result={status="ready",present=true,mine=true,remaining=cache.expiresAt-now,
                    source="observed_timer_continuity"}
            end
        end
        return result
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
            tacticalOpportunity = loadout_has(loadout, "Tactical Opportunity"),
            culling = loadout_has(loadout, "Culling"),
            eliteEducation = loadout_has(loadout, "Elite Education"),
            fatality = loadout_has(loadout, "Fatality"),
            lethalProliferation = loadout_has(loadout, "Lethal Proliferation"),
            corrosiveMicrobes = loadout_has(loadout, "Corrosive Microbes"),
            acidicCompounds = loadout_has(loadout, "Acidic Compounds"),
            lethalPurpose = loadout_has(loadout, "Lethal Purpose"),
            quickening = loadout_has(loadout, "Quickening"),
            devouringMicrobes = loadout_has(loadout, "Devouring Microbes"),
            augmentedToxins = loadout_has(loadout, "Augmented Toxins"),
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
            if known then register_identity(ability.id, info) end
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
                gcdDuration = type(info) == "table" and finite(info.gcd_duration) and info.gcd_duration or nil,
                cooldownKnown = type(cooldown) == "number",
                cooldown = type(cooldown) == "number" and math.max(0, cooldown) or nil,
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
        -- PvP players are always meaningful burst targets. For NPCs, reserve
        -- automatic Stim Boost for Champion/boss-family threats only.
        if state.targetType == "player" then return true end
        return toughness_is_major_threat(state.targetToughness)
    end

    local function sync_stealth_evidence(now, observed)
        if now < Runtime.stealthConsumedUntil then
            Runtime.stealthLatched = false
            return { status = observed and observed.status or nil, present = false,
                source = "opener_consumed" }
        end

        local status = observed and observed.status or nil
        if status == "ready" then
            if observed.present == true then
                Runtime.stealthLatched = true
                return { status = status, present = true, source = "effect" }
            end
            -- Only an authoritative ready+absent sample may clear Stealth.
            Runtime.stealthLatched = false
            return { status = status, present = false, source = "effect_absent" }
        end

        if Runtime.stealthLatched then
            return { status = status, present = true,
                source = "latched_" .. tostring(status or "unavailable") }
        end
        return { status = status, present = false,
            source = tostring(status or "unavailable") }
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
        local dot=read_effect(now,target,DOT_EFFECT,true,options)
        local grenade=read_effect(now,target,GRENADE_EFFECT,true,options)
        local fatality=read_effect(now,player,FATALITY_EFFECT,false,options)
        local tactical_advantage=read_effect(now,player,TACTICAL_ADVANTAGE_EFFECT,false,options)
        local stealth=sync_stealth_evidence(now,unit_effect(player,STEALTH_EFFECT,BUFF_FILTER))
        local stim_boost=unit_effect(player,STIM_BOOST_EFFECT,TIMED_BUFF_FILTER)
        local gcd = gos.abilities.gcd_remaining()
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
            targetToughness = unit_toughness(target),
            moving = type(speed) == "number" and math.abs(speed) > 0.001 or false,
            movementKnown = type(speed) == "number",
            busy = gos.abilities.is_casting_or_channeling() == true,
            gcdRemaining = type(gcd) == "number" and math.max(0, gcd) or nil,
            currentAction = current_cast(),
            abilities = ability_snapshot(loadout),
            progression = progression(loadout),
            dot = dot,
            grenade = grenade,
            fatality = fatality,
            tacticalAdvantage = tactical_advantage,
            stealth = stealth,

            shieldProbe = options.lethalityAutoShieldProbe == true and
                loadout_has(loadout, "Shield Probe") and unit_effect(player, "Shield Probe", BUFF_FILTER) or nil,
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

    local function sample_target_lifetime(handle, hp, now)
        if Runtime.lifetimeTarget ~= handle then
            Runtime.lifetimeTarget, Runtime.lifetimeSamples = handle, {}
        end
        local samples = Runtime.lifetimeSamples
        if not finite(hp) or hp <= 0 or not finite(now) then return nil end
        local last = samples[#samples]
        if last and hp > last.hp then
            samples = {}
            Runtime.lifetimeSamples = samples
            last = nil
        end
        if not last or now - last.t >= 0.25 then
            samples[#samples + 1] = { t = now, hp = hp }
            while #samples > 12 or (#samples > 1 and now - samples[1].t > 3.0) do
                table.remove(samples, 1)
            end
        end
        local first = samples[1]
        if first and now - first.t >= 0.75 and first.hp > hp then
            return hp * (now - first.t) / (first.hp - hp)
        end
        return nil
    end

    local function lethality_context(state, options)
        if not is_lethality then return end
        state.targetControlled, state.targetControlObserved =
            breakable_control(state.target)
        state.hazeTargets, state.knivesTargets, state.fragmentationTargets = 0, 0, 0
        local target_control_unknown = state.targetType == "player" and
            state.targetControlObserved ~= true
        state.hazeUnsafe = state.targetControlled == true
        state.knivesUnsafe = state.targetControlled == true
        state.grenadeUnsafe = state.targetControlled == true
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
            local splash_unsafe = cc == true
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

        state.targetLifetime = sample_target_lifetime(
            state.targetHandle, state.targetHp, state.now)
        if finite(state.targetLifetime) then
            state.lifetimeSource = "recent_hp_loss_estimate"
        end
    end

    local function lifetime_allows(state, seconds)
        return not finite(state.targetLifetime) or state.targetLifetime >= seconds
    end

    local function ability_state(state, ability)
        return state.abilities[ability.id] or { known = false }
    end
    local function learned_strike(state)
        if ability_state(state, Ability.LethalStrike).known == true then return Ability.LethalStrike end
        if ability_state(state, Ability.Backstab).known == true then return Ability.Backstab end
        return nil
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
        local receipt = Runtime.requests[ability.id]
        if receipt and receipt.receiptAt and not receipt.confirmedAt and not receipt.failed and
            state.now < receipt.submittedAt + 2.0 then
            return false, "activation_confirmation_pending"
        end
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
        local floor = clamp(options.energyFloorPercent or 60, 0, 95)
        -- Lethal Purpose restores Energy from real poison damage events. We do not
        -- predict those refunds; this only relaxes the Lua policy reserve once the
        -- passive is actually learned. Core remains authoritative on affordability.
        if state.progression.lethalPurpose then floor = math.min(floor, 50) end
        if state.progression.lethalPurpose and options.lethalityTactical == "Synox Shots" then
            floor = math.min(floor, 40)
        end
        if ability == Ability.OverloadShot then
            floor=math.max(60,floor) -- paid filler cannot drain the core-ability reserve
        end
        if projected / maximum * 100.0 < floor then
            return false, "energy_floor", cost
        end
        return true, "energy_floor_ok", cost
    end

    local function policy_allows(state, ability, options)
        local ready, reason = ability_ready(state, ability)
        if not ready then return false, reason end
        if ability.requiresTacticalAdvantage == true then
            if Runtime.taRejectedAfter then
                return false, "awaiting_new_tactical_advantage_evidence"
            end
            local ta = state.tacticalAdvantage
            if is_lethality and type(ta) == "table" and ta.status ~= "ready" then
                -- Unknown is not a guessed stack: actual Core admission remains required at submit.
            elseif type(ta) ~= "table" or ta.present ~= true then
                return false, type(ta) == "table" and
                    ("tactical_advantage_" .. tostring(ta.source or "absent")) or
                    "tactical_advantage_unavailable"
            end
            if type(ta.stacks) == "number" and ta.stacks < 1 then
                return false, "tactical_advantage_zero"
            end
        end
        -- is_ready is now-only cooldown/GCD/busy metadata, not a TA or
        -- positional-condition check (AbilityReadinessPolicy.hpp). A positive
        -- GCD, including its last 40ms, makes it false for every GCD ability.
        -- ability_ready already checks cooldown eligibility at the next start;
        -- actual Core admission and native activation still judge the cast.
        -- Do not let this duplicate GCD gate replace Strike/Assault with filler.
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
            if type(ability.range) == "number" then
                if type(state.targetDistance) ~= "number" then
                    return false, "distance_unavailable"
                end
                if state.targetDistance > ability.range then return false, "out_of_range" end
            end
        end
        local resource_ok, resource_reason = resource_allows(state, ability, options)
        if not resource_ok then return false, resource_reason end
        -- This is policy eligibility, not permission from the client. The
        -- shared executor's submit calls Core's authoritative live admission.
        -- Requiring a separate can_cast sample here would gate live admission
        -- behind a different request identity and lose its one-tick response.
        -- Core still enforces targeting, LOS, facing, resources and readiness.
        return true, reason
    end

    local function poison_due(state, ability, effect, refresh, options)
        if not ability_state(state,ability).known then return false,"not_owned" end
        if not lifetime_allows(state,options.lethalityMinDotLifetime or 6.0) then return false,"short_lived" end
        if ability==Ability.CorrosiveGrenade and state.grenadeUnsafe then return false,"nearby_control" end
        local application=Runtime.applications[evidence_key(state.targetHandle,ability.id)]
        if application and state.now-(application.activatedAt or application.time)<1.5 then
            return false,"application_in_flight"
        end
        if effect.source=="application_reconciling" then return false,"application_reconciling" end
        if effect.present and effect.mine then
            return finite(effect.remaining) and effect.remaining<=refresh,"refresh"
        end
        if effect.status=="ready" then return true,"missing" end
        -- Unknown cannot permanently veto an initial application. A retry budget
        -- tracks actual server activations separately from observed poison presence.
        local activated=application and (application.confirmed or
            application.request and application.request.confirmedAt~=nil)
        -- A confirmed selected-mode use with an omitted recipient still consumed
        -- the ability. Bound its retry budget without inventing poison presence.
        return application==nil or state.now-application.time>=(activated and 24.0 or 2.0),
            application and "unobserved_recheck" or "initial_application_no_snapshot"
    end
    local function corrosive_dart_due(state,options)
        return poison_due(state,Ability.CorrosiveDart,state.dot,
            options.corrosiveDartRefreshSeconds or 1.5,options)
    end

    local function corrosive_grenade_due(state,options)
        return poison_due(state,Ability.CorrosiveGrenade,state.grenade,
            options.corrosiveGrenadeRefreshSeconds or 1.5,options)
    end

    local function recent_confirmed_application(state, ability, seconds)
        local application = Runtime.applications[evidence_key(state.targetHandle, ability.id)]
        if not application or application.confirmed ~= true then return false end
        local activated = application.activatedAt or application.time
        return finite(activated) and state.now - activated <= (seconds or 8.0)
    end

    local function tactical_advantage_stacks(state)
        local ta = state.tacticalAdvantage
        if is_lethality and (type(ta) ~= "table" or ta.status ~= "ready") then return nil end
        if type(ta) ~= "table" or ta.present ~= true then return 0 end
        if is_lethality and not finite(ta.stacks) then return nil end
        return type(ta.stacks) == "number" and math.max(0, ta.stacks) or 1
    end

    local function owned_poison_covers_start(effect, state)
        if type(effect) ~= "table" or effect.present ~= true or effect.mine ~= true then
            return false
        end
        -- Observed-timer continuity is valid evidence; unknown or queued-only
        -- application state is not. Check expiry at the prospective start.
        local lock = action_lock(state)
        if not finite(lock) then return false end
        return not finite(effect.remaining) or effect.remaining > lock
    end

    local function poisons_ready(state)
        if not owned_poison_covers_start(state.dot, state) then return false end
        local grenade = ability_state(state, Ability.CorrosiveGrenade)
        if grenade.known == true and grenade.resolved == true and grenade.bound == true then
            return owned_poison_covers_start(state.grenade, state)
        end
        -- A learned but unusable/unbound Grenade must not deadlock all spenders.
        -- Core/quickbar capability is authoritative: require the second poison only
        -- when this script can actually submit it.
        return true
    end

    local function decision(ability, reason)
        return { ability = ability, reason = reason }
    end

    local function consider(state, ability, reason, options)
        local castable, why = policy_allows(state, ability, options)
        local admission = castable and "ready" or why
        if ability == Ability.ToxicBlast then state.blastAdmission = admission
        elseif ability == Ability.Spender then state.assaultAdmission = admission
        elseif ability == Ability.LethalStrike or ability == Ability.Backstab then
            state.strikeAdmission = admission
        elseif ability == Ability.ToxicHaze then state.hazeAdmission = admission
        elseif ability == Ability.Shiv then state.shivAdmission = admission
        elseif ability == Ability.OverloadShot then state.overloadAdmission = admission end
        return castable and decision(ability, reason) or nil
    end

    -- Level 47+: use Blast ahead of a non-expiring Fatality only when the
    -- engine's next-GCD duration proves the free Assault survives that delay.
    local function blast_can_precede_proc(state, has_free_assault)
        if not has_free_assault then return true end
        local duration = ability_state(state, Ability.ToxicBlast).gcdDuration
        local lock = action_lock(state)
        return state.fatality.present == true and finite(state.fatality.remaining) and
            finite(duration) and duration > 0 and finite(lock) and
            state.fatality.remaining > lock + duration + READY_SLACK
    end

    local function haze_worthy(state, options)
        local pack = (state.hazeTargets or 0) >= (options.aoeMinTargets or 3)
        local pve = state.targetType ~= "player" and target_is_durable(state) and
            options.lethalitySingleTargetHaze ~= false and
            (state.targetSpeed == nil or state.targetSpeed == 0)
        return options.aoeEnabled == true and not state.hazeUnsafe and
            (pack or pve) and finite(state.targetDistance) and
            state.targetDistance <= 8.0 and lifetime_allows(state, 6.0), pack
    end

    local function select_shield_probe(state, options)
        if options.lethalityAutoShieldProbe ~= true or options.inCombat ~= true or
            state.busy or state.stealth.present == true or
            options.autoStealthPending == true or state.playerHandle == nil or
            not finite(state.playerHp) or state.playerHp <= 0 or
            not finite(state.playerHpPercent) or
            state.playerHpPercent > (options.lethalityShieldProbeBelow or 75.0) then
            return nil
        end
        local shield = state.shieldProbe
        -- Do not invent shield expiry or overwrite a shield on stale effects.
        if not shield or shield.status ~= "ready" or shield.truncated == true or
            shield.present ~= false then return nil end
        return consider(state, Ability.ShieldProbe, "shield_probe_low_self_health", options)
    end

    local function select_offgcd(state, options)
        if state.busy or state.now < Runtime.contentionUntil then return nil end
        -- Holotraverse is the learned level-68 PvE mobility/TA choice. It does not
        -- break Stealth, so a real gap-close takes precedence over waiting outside
        -- the range of the currently learned strike.
        local strike = learned_strike(state)
        if options.allowAutoHolotraverse ~= false and strike and
            ability_state(state, Ability.Holotraverse).known == true and
            finite(state.targetDistance) and state.targetDistance > (strike.range or 4.0) and
            state.targetDistance <= 30.0 then
            local selected = consider(state, Ability.Holotraverse,
                "holotraverse_gap_close", options)
            if selected then return selected end
        end
        -- Preserve the stealth strike once already in range. Other off-GCD commands
        -- can occupy the shared executor and delay the opener by a lifecycle tick.
        if state.stealth.present == true then return nil end
        if is_lethality and state.stealth.status ~= "ready" and
            state.stealth.source ~= "opener_consumed" and options.inCombat ~= true then return nil end
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
        if lethal_burst_ready and options.autoStimBoost == true and target_is_stim_worthy(state) and
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
        local ta_for_raid = tactical_advantage_stacks(state)
        if options.lethalityAutoTacticalSuperiority == true and
            ability_state(state, Ability.TacticalSuperiority).known == true and
            state.targetType ~= "player" and target_is_stim_worthy(state) and
            poisons_ready(state) and ta_for_raid ~= nil and ta_for_raid > 0 then
            local selected = consider(state, Ability.TacticalSuperiority,
                "tactical_superiority_pve_burst", options)
            if selected then return selected end
        end
        local ta_for_holo = tactical_advantage_stacks(state)
        if options.allowAutoHolotraverse ~= false and
            ability_state(state, Ability.Holotraverse).known == true and
            ta_for_holo ~= nil and ta_for_holo < 2 and poisons_ready(state) and
            lifetime_allows(state, 6.0) and finite(state.targetDistance) and
            state.targetDistance <= 30.0 then
            local selected = consider(state, Ability.Holotraverse,
                "holotraverse_tactical_advantage", options)
            if selected then return selected end
        end
        if is_lethality and options.lethalityAutoTacticalOverdrive == true and
            state.progression.level43 == "Tactical Overdrive" and
            state.now >= Runtime.tacticalOverdriveAttemptUntil and
            target_is_stim_worthy(state) and poisons_ready(state) and
            lifetime_allows(state, 6.0) and finite(state.targetDistance) and state.targetDistance <= 4.0 then
            local strike = learned_strike(state)
            local haze, strike_state, stim = ability_state(state, Ability.ToxicHaze),
                strike and ability_state(state, strike) or { known = false },
                ability_state(state, Ability.StimBoost)
            local reset_window = strike ~= nil and
                haze.bound and haze.cooldownKnown and haze.cooldown > READY_SLACK and
                strike_state.bound and strike_state.cooldownKnown and strike_state.cooldown > READY_SLACK and
                (options.autoStimBoost ~= true or stim.cooldownKnown and stim.cooldown > READY_SLACK)
            if reset_window then
                local selected = consider(state, Ability.TacticalOverdrive,
                    "lethality_reset_used_haze_" .. string.lower(strike.id:gsub(" ", "_")), options)
                if selected then return selected end
            end
        end
        return nil
    end

    local function paid_filler_budget(state, options)
        -- Optional filler must not manufacture TA, poison refunds or Synox income.
        -- All permitted generators and primary DoT work have already had priority.
        local ta = tactical_advantage_stacks(state)
        if ta ~= 0 then
            return false, ta == nil and "ta_unknown" or "ta_available"
        end
        local info = ability_state(state, Ability.OverloadShot)
        local cost = scaled_cost(state, Ability.OverloadShot)
        if info.costSource ~= "runtime" or not finite(cost) or cost < 0 then
            return false, "filler_cost_unavailable"
        end
        if not finite(state.energyCurrent) or not finite(state.energyMax) or
            state.energyMax <= 0 then return false, "energy_unavailable" end
        local floor = math.max(60, clamp(options.energyFloorPercent or 60, 0, 95)) *
            state.energyMax / 100.0
        local after = state.energyCurrent - cost
        state.fillerCost, state.fillerAfter = cost, after
        state.fillerReserve, state.fillerNextCost = floor, 0
        state.fillerNext = "none"
        if after < floor then return false, "post_cast_energy_floor" end
        local lock = action_lock(state)
        if not finite(lock) or not finite(info.gcdDuration) or info.gcdDuration <= 0 then
            return false, "filler_timing_unavailable"
        end
        local horizon = lock + info.gcdDuration + READY_SLACK
        local next_cost, next_name = 0, "none"
        local function reserve(ability, enabled, effect, refresh)
            local candidate = ability_state(state, ability)
            if enabled == false or not candidate.known or not candidate.resolved or
                not candidate.bound then return true end
            if finite(ability.range) and (not finite(state.targetDistance) or
                state.targetDistance > ability.range) then return true end
            if effect and effect.status == "ready" and effect.present and effect.mine and
                finite(effect.remaining) and effect.remaining > horizon + refresh then
                return true
            end
            if not candidate.cooldownKnown or not finite(candidate.cooldown) then
                state.fillerNext = ability.id
                return false
            end
            if candidate.cooldown > horizon then return true end
            local candidate_cost = scaled_cost(state, ability)
            if candidate.costSource ~= "runtime" or not finite(candidate_cost) or
                candidate_cost < 0 then
                state.fillerNext = ability.id
                return false
            end
            -- Only one GCD action can follow. Reserve the greatest possible
            -- immediate cost, not the sum of mutually exclusive next actions.
            if candidate_cost > next_cost then
                next_cost, next_name = candidate_cost, ability.id
            end
            return true
        end
        local strike = learned_strike(state)
        local dot_window = lifetime_allows(state, options.lethalityMinDotLifetime or 6.0)
        if not reserve(Ability.Shiv, true) or
            not reserve(Ability.ToxicBlast, options.lethalityAutoToxicBlast ~= false) or
            (strike and not reserve(strike, true)) or
            not reserve(Ability.CorrosiveDart, dot_window, state.dot,
                options.corrosiveDartRefreshSeconds or 1.5) or
            not reserve(Ability.CorrosiveGrenade, dot_window and not state.grenadeUnsafe, state.grenade,
                options.corrosiveGrenadeRefreshSeconds or 1.5) then
            return false, "priority_metadata_unavailable"
        end
        state.fillerNext, state.fillerNextCost = next_name, next_cost
        state.fillerReserve = floor + next_cost
        if after < state.fillerReserve then return false, "next_core_ability_reserve" end
        return true, "energy_budget_ok"
    end

    local function select_priority(state, options)
        local strike = learned_strike(state)
        if state.stealth.present or (state.stealth.status~="ready" and
            state.stealth.source~="opener_consumed" and options.inCombat~=true) then
            if not strike then return nil end
            return consider(state, strike,
                "stealth_" .. string.lower(strike.id:gsub(" ", "_")) .. "_only", options)
        end
        local high_level = ability_state(state, Ability.LethalStrike).known == true
        local tactical = options.lethalityTactical or "Auto / Unknown"
        local catalyzed = high_level and state.targetType == "player" and
            tactical == "Catalyzed Toxins"
        local ta=tactical_advantage_stacks(state)
        local native_free=ability_state(state,Ability.Spender).costSource=="runtime" and
            ability_state(state,Ability.Spender).cost==0
        local fatality=state.fatality.present==true
        local full = poisons_ready(state)
        state.blastAdmission = options.lethalityAutoToxicBlast == false and "disabled" or
            (full and "priority_not_reached" or "required_owned_poison_missing")
        local function assault(reason)
            -- Core may legally cast Assault with no poisons. The damage APL
            -- must not: every owned primary poison is required, even for Fatality.
            if not full then
                state.assaultBlocked = "required_owned_poison_missing"
                return nil
            end
            return consider(state, Ability.Spender, reason, options)
        end
        local grenade_due, grenade_reason = corrosive_grenade_due(state, options)
        local dart_due, dart_reason = corrosive_dart_due(state, options)
        local catalyzed_blast_window = false
        if catalyzed and options.lethalityAutoToxicBlast ~= false then
            local blast_ready = policy_allows(state, Ability.ToxicBlast, options)
            catalyzed_blast_window = blast_ready == true
        end
        if catalyzed_blast_window then
            -- Catalyzed Toxins consumes the remaining poison damage on Toxic Blast.
            -- Freshen each poison once per observed burst window, keyed to an exact
            -- confirmed application. Never loop refreshes and never assume a queued
            -- command landed or that Toxic Blast consumed anything.
            if ability_state(state, Ability.CorrosiveGrenade).known == true and
                not recent_confirmed_application(state, Ability.CorrosiveGrenade, 8.0) then
                grenade_due, grenade_reason = true, "catalyzed_fresh_setup"
            end
            if ability_state(state, Ability.CorrosiveDart).known == true and
                not recent_confirmed_application(state, Ability.CorrosiveDart, 8.0) then
                dart_due, dart_reason = true, "catalyzed_fresh_setup"
            end
        end
        -- Setup/refresh comes BEFORE proc spending. A rejected or unavailable
        -- Dart is not permission to pretend the single remaining poison is enough.
        local act = grenade_due and consider(state, Ability.CorrosiveGrenade,
            "corrosive_grenade_" .. grenade_reason, options) or nil
        if act then return act end
        act = dart_due and consider(state, Ability.CorrosiveDart,
            "corrosive_dart_" .. dart_reason, options) or nil
        if act then return act end

        local blast = options.lethalityAutoToxicBlast ~= false and full and
            consider(state, Ability.ToxicBlast, "toxic_blast_poison_window", options) or nil
        if high_level then
            local use_haze, pack = haze_worthy(state, options)
            if catalyzed and blast then
                -- PvP Catalyzed spike: freshly confirmed poisons -> Lethal Strike
                -- -> Toxic Blast. If Strike is not presently legal, do not stall
                -- the whole rotation; Blast remains the next legal spike button.
                act = strike and consider(state, strike, "lethal_strike_catalyzed_spike", options) or nil
                if act then return act end
                return blast
            end
            if blast and ta ~= nil and ta < 2 and
                blast_can_precede_proc(state, fatality or native_free) then
                return blast
            end
            if blast and ta == 2 and use_haze and
                blast_can_precede_proc(state, fatality or native_free) then
                act = consider(state, Ability.ToxicHaze,
                    pack and "toxic_haze_make_room_for_blast_pack" or
                        "toxic_haze_make_room_for_blast", options)
                if act then return act end
            end
            if blast and ta == 2 then
                act = assault("corrosive_assault_make_room_for_toxic_blast")
                if act then return act end
            end
            if blast and ta ~= 2 then return blast end

            -- Once Toxic Blast is committed/on cooldown, Haze is the next guide
            -- priority. Viral Elements receives no imaginary spread: the existing
            -- real player-centered pack geometry is still required in PvP.
            if use_haze and (full or pack and state.dot.present and state.dot.mine) then
                local reason = tactical == "Viral Elements" and pack and
                    "toxic_haze_viral_elements_pack" or
                    (pack and "toxic_haze_pack" or "toxic_haze_pve")
                act = consider(state, Ability.ToxicHaze, reason, options)
                if act then return act end
            end
            if strike then
                act = consider(state, strike,
                    state.progression.augmentedToxins and "lethal_strike_augmented_toxins" or
                        "lethal_strike_priority", options)
                if act then return act end
            end
            if state.progression.fatality and not fatality and
                state.now >= Runtime.fatalityReadyAt and ta ~= 2 then
                act = consider(state, Ability.Shiv, "shiv_fatality_builder", options)
                if act then return act end
            end
            if ta == 2 then
                act = assault("corrosive_assault_ta_cap")
                if act then return act end
            end
            if (fatality or native_free) and ta ~= nil and ta > 0 then
                act = assault("corrosive_assault_fatality")
                if act then return act end
            end
            if ta == 0 or ta == nil then
                act = consider(state, Ability.Shiv,
                    "shiv_build_missing_tactical_advantage", options)
                if act then return act end
            end
            act = assault("corrosive_assault_both_owned_poisons")
            if act then return act end
        else
        if blast and ta ~= nil and ta < 2 and
            blast_can_precede_proc(state, fatality or native_free) then
            return blast
        end
        if blast and ta == 2 and haze_worthy(state, options) and
            blast_can_precede_proc(state, fatality or native_free) then
            -- Haze spends a TA even when Fatality would refund Assault. This
            -- creates room for Blast instead of cycling refundable capped Assaults.
            act = consider(state, Ability.ToxicHaze, "toxic_haze_make_room_for_blast", options)
            if act then return act end
        end
        if fatality or native_free and ta ~= nil and ta > 0 then
            act = assault("corrosive_assault_fatality")
            if act then return act end
        end
        if blast and ta ~= 2 then return blast end
        if ta == 2 then
            act = assault("corrosive_assault_ta_cap")
            if act then return act end
        end
        -- Generate the resource before lower-value filler. Missing snapshots are
        -- not evidence that we are capped; server activation ledger disambiguates it.
        if ta==0 or ta==nil then
            act=consider(state,Ability.Shiv,"shiv_build_missing_tactical_advantage",options)
            if act then return act end
        end
        local use_haze, pack = haze_worthy(state, options)
        if use_haze and (full or pack and state.dot.present and state.dot.mine) then
            act=consider(state,Ability.ToxicHaze,pack and "toxic_haze_pack" or "toxic_haze_pve",options)
            if act then return act end
        end
        if state.progression.fatality and not fatality and state.now>=Runtime.fatalityReadyAt and ta~=2 then
            act=consider(state,Ability.Shiv,"shiv_fatality_builder",options)
            if act then return act end
        end
        act=assault("corrosive_assault_both_owned_poisons")
        if act then return act end
        end -- pre-Lethal-Strike 1-49 priority branch
        if options.aoeEnabled then
            local minimum=options.aoeMinTargets or 3
            if not state.knivesUnsafe and (state.knivesTargets or 0)>=minimum then
                act=consider(state,Ability.NoxiousKnives,"aoe_knives",options)
                if act then return act end
            end
            if not state.grenadeUnsafe and (state.fragmentationTargets or 0)>=minimum then
                act=consider(state,Ability.FragmentationGrenade,"aoe_fragmentation",options)
                if act then return act end
            end
        end
        if ta~=2 then
            act=consider(state,Ability.Shiv,"shiv_before_filler",options)
            if act then return act end
        end
        if not high_level then
            act=consider(state,Ability.Backstab,"backstab_legal_filler",options)
            if act then return act end
        end
        local paid_ok, filler_gate = paid_filler_budget(state, options)
        state.fillerGate = filler_gate
        if paid_ok then
            act=consider(state,Ability.OverloadShot,"overload_zero_ta_budgeted",options)
            if act then return act end
            state.fillerGate = state.overloadAdmission
        end
        return consider(state,Ability.RifleShot,"rifle_shot_regeneration",options)
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
            tostring(state.progression.fatality == true),
            tostring(state.progression.eliteEducation == true),
            tostring(state.progression.corrosiveMicrobes == true),
            tostring(state.progression.acidicCompounds == true),
            tostring(state.progression.lethalPurpose == true),
            tostring(state.progression.quickening == true),
            tostring(state.progression.devouringMicrobes == true),
            tostring(state.progression.augmentedToxins == true),
            tostring(ability_state(state, Ability.ShieldProbe).known == true),
            tostring(ability_state(state, Ability.CorrosiveDart).known == true),
            tostring(ability_state(state, Ability.CorrosiveGrenade).known == true),
            tostring(ability_state(state, Ability.ToxicHaze).known == true),
            tostring(ability_state(state, Ability.ToxicBlast).known == true),
            tostring(ability_state(state, Ability.Backstab).known == true),
            tostring(ability_state(state, Ability.LethalStrike).known == true),
            tostring(ability_state(state, Ability.Holotraverse).known == true),
            tostring(ability_state(state, Ability.TacticalSuperiority).known == true),
            tostring(ability_state(state, Ability.Spender).known == true),
            tostring(ability_state(state, Ability.StimBoost).known == true),
        }, "|")
        if Runtime.lastProgression == signature then return end
        if state.now-Runtime.lastProgressionAt<2.0 then return end
        Runtime.lastProgressionAt=state.now
        Runtime.lastProgression = signature
        emit(options, "info", "operative progression: route=" .. spec.owner ..
            " runtime=" .. M.build_id ..
            " tactical_setting=" .. tostring(options.lethalityTactical or "Auto / Unknown") ..
            " autoStimBoost=" .. bool_text(options.autoStimBoost == true) ..
            " level23=" .. tostring(state.progression.level23 or "none") ..
            " level27=" .. tostring(state.progression.level27 or "none") ..
            " level39=" .. tostring(state.progression.level39 or "none") ..
            " level43=" .. tostring(state.progression.level43 or "none") ..
            " level51=" .. tostring(state.progression.level51 or "none") ..
            " level64=" .. tostring(state.progression.level64 or "none") ..
            " level68=" .. tostring(state.progression.level68 or "none") ..
            " level73=" .. tostring(state.progression.level73 or "none") ..
            " passives{fatality=" .. bool_text(state.progression.fatality == true) ..
            ",eliteEducation=" .. bool_text(state.progression.eliteEducation == true) ..
            ",corrosiveMicrobes=" .. bool_text(state.progression.corrosiveMicrobes == true) ..
            ",acidicCompounds=" .. bool_text(state.progression.acidicCompounds == true) ..
            ",lethalPurpose=" .. bool_text(state.progression.lethalPurpose == true) ..
            ",quickening=" .. bool_text(state.progression.quickening == true) ..
            ",devouringMicrobes=" .. bool_text(state.progression.devouringMicrobes == true) ..
            ",augmentedToxins=" .. bool_text(state.progression.augmentedToxins == true) .. "}" ..
            " known{shiv=" .. bool_text(ability_state(state, Ability.Shiv).known == true) ..
            ",dart=" .. bool_text(ability_state(state, Ability.CorrosiveDart).known == true) ..
            ",grenade=" .. bool_text(ability_state(state, Ability.CorrosiveGrenade).known == true) ..
            ",haze=" .. bool_text(ability_state(state, Ability.ToxicHaze).known == true) ..
            ",blast=" .. bool_text(ability_state(state, Ability.ToxicBlast).known == true) ..
            ",shield=" .. bool_text(ability_state(state, Ability.ShieldProbe).known == true) ..
            ",backstab=" .. bool_text(ability_state(state, Ability.Backstab).known == true) ..
            ",lethalStrike=" .. bool_text(ability_state(state, Ability.LethalStrike).known == true) ..
            ",holotraverse=" .. bool_text(ability_state(state, Ability.Holotraverse).known == true) ..
            ",tacticalSuperiority=" .. bool_text(ability_state(state, Ability.TacticalSuperiority).known == true) ..
            ",spender=" .. bool_text(ability_state(state, Ability.Spender).known == true) ..
            "} bound{blast=" .. bool_text(ability_state(state, Ability.ToxicBlast).bound == true) ..
            ",shield=" .. bool_text(ability_state(state, Ability.ShieldProbe).bound == true) ..
            ",shiv=" .. bool_text(ability_state(state, Ability.Shiv).bound == true) ..
            ",dart=" .. bool_text(ability_state(state, Ability.CorrosiveDart).bound == true) ..
            ",backstab=" .. bool_text(ability_state(state, Ability.Backstab).bound == true) ..
            ",lethalStrike=" .. bool_text(ability_state(state, Ability.LethalStrike).bound == true) ..
            ",holotraverse=" .. bool_text(ability_state(state, Ability.Holotraverse).bound == true) ..
            ",tacticalSuperiority=" .. bool_text(ability_state(state, Ability.TacticalSuperiority).bound == true) ..
            ",spender=" .. bool_text(ability_state(state, Ability.Spender).bound == true) ..
            "} costs{blast=" .. optional_number(ability_state(state, Ability.ToxicBlast).cost, "%.0f") ..
            ",shiv=" .. optional_number(ability_state(state, Ability.Shiv).cost, "%.0f") ..
            ",dart=" .. optional_number(ability_state(state, Ability.CorrosiveDart).cost, "%.0f") ..
            ",backstab=" .. optional_number(ability_state(state, Ability.Backstab).cost, "%.0f") ..
            ",spender=" .. optional_number(ability_state(state, Ability.Spender).cost, "%.0f") .. "}")
    end
    local function ability_diagnostics(state, options)
        if options.abilityDiagnostics ~= true or state.now - Runtime.lastDiagnosticAt < 10.0 then
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

    local function decision_log(state,options,kind,detail)
        if options.decisionLog~=true or state.now-Runtime.lastDecisionAt<1.0 then return end
        local key=kind..":"..tostring(detail):gsub("locked_for=.*","gcd")
        if key==Runtime.lastDecision and state.now-Runtime.lastDecisionAt<5.0 then return end
        Runtime.lastDecision,Runtime.lastDecisionAt=key,state.now
        emit(options,"debug","lethality state: "..kind.." "..tostring(detail)..
            " energy="..optional_number(state.energyPercent,"%.0f")..
            " gcd="..optional_number(state.gcdRemaining,"%.3f")..
            " distance="..optional_number(state.targetDistance,"%.1f")..
            " blast_gate="..tostring(state.blastAdmission or "not_evaluated")..
            " assault_gate="..tostring(state.assaultBlocked or state.assaultAdmission or "priority_not_reached")..
            " strike_gate="..tostring(state.strikeAdmission or "priority_not_reached")..
            " haze_gate="..tostring(state.hazeAdmission or "priority_not_reached")..
            " shiv_gate="..tostring(state.shivAdmission or "priority_not_reached")..
            " dot="..tostring(state.dot.source).." grenade="..tostring(state.grenade.source)..
            " ta="..tostring(state.tacticalAdvantage.stacks or "unknown")..
            "/"..tostring(state.tacticalAdvantage.source).." fatality="..tostring(state.fatality.present)..
            (state.fillerGate and (" filler_gate="..tostring(state.fillerGate)..
                " filler_cost="..optional_number(state.fillerCost,"%.1f")..
                " filler_after="..optional_number(state.fillerAfter,"%.1f")..
                " filler_reserve="..optional_number(state.fillerReserve,"%.1f")..
                " filler_next="..tostring(state.fillerNext or "none")..
                " filler_next_cost="..optional_number(state.fillerNextCost,"%.1f")) or ""))
    end
    local function native_not_ready(result)
        -- Captured B934 enum, not a guessed string heuristic. See the checked-in
        -- ABILITY_MINIQUEUE_IDA_HANDOFF: 0x13 = effResultNotReady.
        return type(result) == "table" and result.ability_activate_eff_result == 0x13
    end

    local function shared_wait(reason)
        return reason=="castability_pending" or reason=="gcd" or reason=="cooldown" or reason=="command_busy" or
            reason=="ability_command_busy" or reason=="bridge_busy" or
            reason=="ability_submission_pending" or reason=="executor_command_pending" or
            reason=="selected_target_changed" or reason=="melee_prequeue_deferred" or
            reason=="explicit_target_sync_pending" or reason=="native_not_ready_gcd"
    end
    local function rejection(state,ability,target,reason,result,options)
        local core=type(result)=="table" and result.core or nil
        if reason=="castability_pending" then
            -- No command exists yet. Retry live admission on the next worker
            -- tick, without a failure timer or a different-ability retry.
            notice(options,"debug","admission:"..ability.id,
                "lethality admission pending: "..ability.id..
                " target="..tostring(ability.targetless and state.playerHandle or target)..
                " policy=next_tick_live_admission",2.0)
            return reason
        end
        if reason=="explicit_target_sync_suspended" or reason=="ability_command_unavailable" then
            notice(options,"warn","native_core_unavailable",
                "lethality Core blocked: reason="..reason..
                " target_mode=native_current_selection; Lua reload does not reset Core session failure",10.0)
            Runtime.contentionUntil=math.max(Runtime.contentionUntil,state.now+0.10)
            return
        end
        if shared_wait(reason) then
            local ms=type(core)=="table" and (core.ready_in_ms or core.wait_ms) or nil
            local delay=finite(ms) and clamp(ms/1000,0.015,0.20) or 0.10
            Runtime.contentionUntil=math.max(Runtime.contentionUntil,state.now+delay)
            decision_log(state,options,"wait",reason)
            return
        end
        if ability.offGcd ~= true and native_not_ready(core) and
            finite(state.gcdRemaining) and state.gcdRemaining > 0 then
            -- This attempt really failed, but during an observed GCD. Do not
            -- blacklist its ability for 400ms and let filler steal the next GCD.
            -- Wait on the engine's CURRENT action lock, then reevaluate the APL.
            -- No queued future cast, predicted activation, or TA loss is created.
            Runtime.nativeNotReadyWait = true
            notice(options, "debug", "native_not_ready_gcd",
                "lethality native not-ready: " .. ability.id ..
                " native_eff=0x13 gcd=" .. optional_number(state.gcdRemaining, "%.3f") ..
                " policy=wait_observed_gcd_then_reselect", 2.0)
            return "native_not_ready_gcd"
        end
        Runtime.failureBackoff[failure_key(ability,target)]=state.now+FAILURE_BACKOFF
        if ability.targetless ~= true and
            (reason=="not_in_line_of_sight" or reason=="out_of_range" or
             reason=="not_facing" or reason=="not_behind_target" or
             reason=="invalid_target" or reason=="target_dead" or
             reason=="gameplay_rejected" or reason=="ability_activate_failed" or
             reason=="explicit_target_activate_failed") then
            -- A target/environment rejection applies to the whole immediate APL,
            -- not merely this button. Hold selection briefly so we retry the real
            -- priority instead of carousel-spamming every lower-priority attack.
            Runtime.targetBlockHandle=target
            Runtime.targetBlockUntil=math.max(Runtime.targetBlockUntil,state.now+FAILURE_BACKOFF)
        end
        local native_eff = type(core)=="table" and core.ability_activate_eff_result or nil
        local native_detail = finite(native_eff) and
            string.format(" native_eff=0x%X", native_eff) or ""
        notice(options,"warn",ability.id..":"..reason,
            "lethality rejected: "..ability.id.." reason="..reason..native_detail,2.0)
    end
    local function check_receipts(now, options)
        for name, request in pairs(Runtime.requests) do
            if request.receiptAt and not request.confirmedAt and not request.failed and
                not request.reported and now >= request.submittedAt + 2.0 then
                request.reported = true
                local stats=Runtime.eventStats
                notice(options,"debug","unconfirmed:"..name,
                    "lethality activation not observed by deadline: "..name..
                    " events="..tostring(stats.activations).." local="..tostring(stats.localActivations)..
                    " matched="..tostring(stats.matched).." unmatched="..tostring(stats.unmatched),5.0)
            end
        end
    end
    local function service_pending(state,options)
        check_receipts(state.now,options)
        local pending=Runtime.pending
        if not pending then return executor:owns_command() end
        if executor:owns_command() then return true end
        local status=executor:status()
        if type(status)=="table" and status.idempotency_key==pending.key then
            local terminal=tostring(status.core.state or "unknown")
            if terminal=="failed" or terminal=="cancelled" or terminal=="abandoned" or terminal=="superseded" then
                if not pending.confirmedAt then
                    pending.failed=true
                    local key=evidence_key(pending.targetHandle,pending.ability.id)
                    local application=Runtime.applications[key]
                    if application and application.request==pending and not application.confirmed then
                        Runtime.applications[key]=nil
                    end
                    local reason=tostring(status.reason or terminal)
                    if pending.ability.requiresTacticalAdvantage and
                        not native_not_ready(status.core) and
                        (reason=="ability_activate_failed" or reason=="explicit_target_activate_failed" or
                            reason=="requires_tactical_advantage") then
                        -- A generic activation failure is not proof of zero TA.
                        -- Stop speculative spender retries until new positive TA
                        -- evidence, rather than cycling Haze -> Assault blindly.
                        Runtime.taRejectedAfter=state.now
                    end
                    rejection(state,pending.ability,pending.targetHandle,reason,status,options)
                end
            elseif not pending.confirmedAt then
                -- Transport normally completes before the server event. Keep the
                -- exact request available for delayed confirmation; do not warn or
                -- penalize the ability at this earlier receipt tick.
                pending.receiptAt=state.now
            end
        end
        Runtime.pending=nil
        return true
    end
    local function submit(state,selected,options,phase)
        local ability=selected.ability
        if ability.targetless ~= true then
            local world=gos.world()
            local current=world and world.current_target or nil
            if safe_method(current, "handle") ~= state.targetHandle then
                return false, "selected_target_changed"
            end
        end
        if phase~="offgcd" and type(state.gcdRemaining)=="number" and
            state.gcdRemaining>READY_SLACK and
            (ability==Ability.Shiv or ability==Ability.Backstab or ability==Ability.LethalStrike) then
            Runtime.contentionUntil=math.max(Runtime.contentionUntil,
                state.now+math.max(0.010,state.gcdRemaining-READY_SLACK))
            return false,"melee_prequeue_deferred"
        end
        local key=table.concat({spec.owner,phase or "regular",ability.id,
            tostring(state.targetHandle or "none")},":")
        Runtime.nativeAdmission=nil
        local result=Mirror.submit(executor, CurrentLoadout, ability.id,nil,{idempotencyKey=key})
        local core=type(result)=="table" and type(result.core)=="table" and result.core or {}
        if type(result)=="table" and
            (result.accepted==true or result.admission_pending==true) then
            -- targetless describes Lua's gameplay policy/area geometry, not
            -- Core's native target-kind classification. The same omitted-target
            -- submission can legitimately return selected (e.g. Toxic Haze) or
            -- none. Follow that exact result, never recast with another target.
            local native_selected = core.target_mode=="selected" and
                state.targetHandle~=nil and core.target_valid==true and
                core.target_handle==state.targetHandle
            local native_none = ability.targetless==true and core.target_mode=="none" and
                core.target_valid~=true and core.target_handle==nil
            local target_ok=core.fallback_used~=true and core.target_override~=true and
                core.requested_target_handle==nil and (native_selected or native_none)
            if not target_ok then
                if owns_pending() then executor:cancel("lethality_target_contract") end
                notice(options,"warn","target_contract",
                    "lethality target contract mismatch: "..ability.id..
                    " mode="..tostring(core.target_mode)..
                    " captured="..tostring(state.targetHandle)..
                    " actual="..tostring(core.target_handle)..
                    " valid="..tostring(core.target_valid)..
                    " override="..tostring(core.target_override)..
                    " fallback="..tostring(core.fallback_used)..
                    "; no alternate target path",2.0)
                return false,"target_contract_mismatch"
            end
            if result.admission_pending==true then
                Runtime.nativeAdmission={selected=selected,phase=phase,key=key,
                    abilityHandle=ability_state(state,ability).abilityHandle,
                    playerHandle=state.playerHandle,
                    actorEpoch=state.world and state.world.actor_epoch or nil,
                    worldTargetHandle=state.targetHandle,targetMode=core.target_mode,
                    targetHandle=core.target_handle}
            end
        end
        if type(result)~="table" or result.admission_pending~=true then
            Runtime.nativeAdmission=nil
        end
        if type(result)~="table" or result.accepted~=true then
            local reason=type(result)=="table" and tostring(result.reason or result.code or "cast_failed") or "invalid_result"
            local retry_reason=rejection(state,ability,state.targetHandle,reason,result,options)
            return false,retry_reason or reason
        end
        local pending={ability=ability,key=key,targetHandle=state.targetHandle,
            targetMode=core.target_mode,
            submittedAt=state.now,reason=selected.reason,commandHandle=result.command_handle,
            fromStealth=(ability==Ability.Backstab or ability==Ability.LethalStrike) and
                state.stealth.present==true}
        Runtime.pending=pending
        Runtime.requests=Runtime.requests or {}
        Runtime.requests[ability.id]=pending
        if ability==Ability.CorrosiveDart or ability==Ability.CorrosiveGrenade then
            local application_key=evidence_key(state.targetHandle,ability.id)
            local previous=Runtime.observations[application_key]
            Runtime.applications[application_key]={time=state.now,confirmed=false,request=pending,
                baselineExpiry=previous and previous.expiresAt or nil}
        elseif ability==Ability.StimBoost then Runtime.stimAttemptUntil=state.now+1.5
        elseif ability==Ability.AdrenalineProbe then Runtime.probeAttemptUntil=state.now+1.5
        elseif ability==Ability.TacticalOverdrive then Runtime.tacticalOverdriveAttemptUntil=state.now+1.5 end
        if options.castLog then
            emit(options,"info","lethality queued: "..ability.id.." reason="..selected.reason..
                " target_mode="..pending.targetMode)
        end
        return true
    end
    local function service_native_admission(state,options)
        local intent=Runtime.nativeAdmission
        if not intent then return false end
        local snapshot=ability_state(state,intent.selected.ability)
        local actor_epoch=state.world and state.world.actor_epoch or nil
        local target_matches=state.targetHandle==intent.worldTargetHandle and
            (intent.targetMode~="selected" or state.targetHandle==intent.targetHandle)
        if state.playerHandle~=intent.playerHandle or
            intent.actorEpoch~=nil and actor_epoch~=nil and actor_epoch~=intent.actorEpoch or
            snapshot.abilityHandle~=intent.abilityHandle or not target_matches then
            Runtime.nativeAdmission=nil
            return false
        end
        submit(state,intent.selected,options,intent.phase)
        return true
    end
    local function stop(reason)
        Runtime.nativeNotReadyWait = false
        Runtime.nativeAdmission = nil
        if owns_pending() then executor:cancel(reason or "lethality_inactive"); return owns_pending() end
        if not Runtime.stopped then
            Runtime.stopped=true
            Runtime.pending=nil
        end
        -- Key release is not a talent change or a loss of an observed DoT. Keep
        -- capability/log/effect identities; their timestamps still age naturally.
        return false
    end
    local function tick(loadout,active,options)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        options=type(options)=="table" and options or {}
        if not is_selected(loadout) then return false end
        if active~=true then
            -- Keep only the cheap target-HP trend sampler alive while the hold key
            -- is released. Do not run ability metadata, effect scans, progression
            -- logging, or the full decision context on inactive frames.
            local now_ms = gos.time_ms()
            local world = gos.world()
            local target = world and world.current_target or nil
            local hp = unit_hp(target)
            sample_target_lifetime(safe_method(target, "handle"),
                hp and hp.current or nil,
                type(now_ms) == "number" and now_ms / 1000.0 or nil)
            stop("rotation_inactive")
            return true
        end
        Runtime.stopped=false
        Runtime.lastOptions=options
        local state=read_state(loadout,options)
        local pending=Runtime.pending
        if pending and pending.targetMode=="selected" and executor:owns_command() and
            pending.targetHandle~=state.targetHandle then
            -- Only this route's cancellable command may be released on selection
            -- changes. The executor/Core retain already game-owned commands.
            if owns_pending() then executor:cancel("lethality_selection_changed") end
        end
        if service_pending(state,options) then return true end
        if executor:owns_command() then return true end
        if service_native_admission(state,options) then return true end
        progression_log(state,options)
        if state.now<Runtime.contentionUntil then return true end
        -- Self-only defensive: may run during a GCD or with no hostile selection.
        -- The same executor owns it; no explicit target swap or healing GCD.
        local shield=select_shield_probe(state,options)
        if shield then
            submit(state,shield,options,"offgcd")
            -- Re-evaluate fresh state next tick, never switch requests mid-tick.
            return true
        end
        -- Most active ticks are inside a GCD: avoid a complete hostile effect
        -- scan until there is a decision to make. Off-GCD recovery remains allowed.
        local ok,why=valid_target(state)
        if not ok then decision_log(state,options,"waiting_target",why); return true end
        if Runtime.targetBlockHandle ~= state.targetHandle then
            Runtime.targetBlockHandle,Runtime.targetBlockUntil=nil,0.0
        elseif state.now < Runtime.targetBlockUntil then
            return true
        elseif Runtime.targetBlockHandle ~= nil then
            Runtime.targetBlockHandle,Runtime.targetBlockUntil=nil,0.0
        end
        if state.now<Runtime.contentionUntil then return true end
        local lock=action_lock(state)
        if type(lock)~="number" then decision_log(state,options,"waiting_lock","unknown_timing"); return true end
        local emergency=options.autoAdrenalineProbe and finite(state.energyPercent) and
            state.energyPercent<=(options.adrenalineProbeThresholdPercent or 40)
        if lock>(options.abilityQueueWindow or 0.20) and not emergency then return true end
        lethality_context(state,options)
        if state.targetControlled then return true end
        ability_diagnostics(state,options)
        local off=select_offgcd(state,options)
        if off then
            submit(state,off,options,"offgcd")
            -- Re-evaluate fresh state next tick, never switch requests mid-tick.
            return true
        end
        if Runtime.nativeNotReadyWait then
            if lock > 0 then return true end
            Runtime.nativeNotReadyWait = false
        end
        if lock>(options.abilityQueueWindow or 0.20) then return true end
        do -- One live-admission submission; all retries use a fresh tick.
            local selected=select_priority(state,options)
            if not selected then decision_log(state,options,"no_action","no_castable_priority"); return true end
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
            local accepted,reason=submit(state,selected,options,"regular")
            if accepted then decision_log(state,options,"selected",selected.ability.id); return true end
            return true
        end
    end
    -- Called only for an exact local-player Kolto Infusion activation.
    -- It may consume TA (or be free under Quickening): require the actual new
    -- charge snapshot rather than guessing the cost or reusing pre-heal stacks.
    local function observe_self_heal_ta(activation_time)
        if not finite(activation_time) or activation_time<=(Runtime.selfHealTaAt or -math.huge) then return end
        Runtime.selfHealTaAt=activation_time
        local ledger=Runtime.taLedger
        if ledger and ledger.changedAt>=activation_time then return end
        Runtime.taLedger={count=nil,exact=false,changedAt=activation_time,
            settleUntil=activation_time,untilTime=activation_time,source="self_heal_ta_reconcile"}
        Runtime.taRejectedAfter=activation_time
    end
    return {is_selected=is_selected,
        has_local_pending=function() return Runtime.nativeAdmission~=nil or owns_pending() end,
        owns_pending=owns_pending,stop=stop,tick=tick,
        observe_events=observe_events,observe_self_heal_ta=observe_self_heal_ta}
end
return M
