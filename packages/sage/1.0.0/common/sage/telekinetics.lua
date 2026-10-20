-- sage/telekinetics.lua
--
-- Telekinetics route for scripts/live/sage.lua. The class dispatcher owns
-- the shared AbilityExecutor and polls it once; this module only owns the
-- Telekinetics state, priority, overlays, and command submissions.
--
-- HARD INVARIANTS:
--   * Telekinetic Wave is used ONLY with an event-confirmed or observed Tidal Force.
--   * Telekinetic Wave is NEVER hard-cast.
--   * Every priority rejects abilities whose current Force cost is unaffordable.
--   * Only executor ownership blocks unrelated decisions. A submitted Wave
--     claims its proc generation while its receipt awaits exact activation.

local PressureTracker = require("combat.pressure_tracker")
local Mirror = require("sage.mirror")
local M = {}
local Executor

local TELEKINETIC_WAVE_ID = "Telekinetic Wave"
local POWER_OF_THE_FORCE_ID = "Power of the Force"
local METERS_PER_WORLD_UNIT = 10.0
local MAX_HOSTILES = 512
local MAX_COMBAT_EVENT_DRAIN_PASSES = 4
local COOLDOWN_READY_SLACK = 0.04
local BURST_FILLER_WINDOW_SECONDS = 1.5
local ExpectedCombatStyle = "sage"
local ExpectedDiscipline = "Telekinetics"

local Config = {
    abilityQueueWindow = 0.20,
    manualRelevantTargets = 1,
    automaticTargetCount = false,
    targetClusterRadius = 4.0,
    forcequakeClusterRadius = 4.0,
    showTargetCountVisual = false,
    showMobilityBar = true,
    mobilityBarX = 0,
    mobilityBarY = 160,
    mobilityBarRefresh = 0.05,
    mobilityBarPlanRefresh = 0.10,
    targetCountVisualRefresh = 0.20,
    targetCountRefresh = 0.10,
    tremorsForcequakeMinTargets = 2,
    forcequakeMinTargets = 4,
    durableHpRatio = 1.0,
    mindCrushMinHpPercent = 50,
    telekineticsBurstPooling = false,
    telekineticsBurstStatusLabel = true,
    telekineticsBurstProgressLabel = true,
    tidalInternalCooldown = 10.0,
    castLog = false,
    decisionLog = false,
}

local Ability = {
    MentalAlacrity = {
        id = "Mental Alacrity",
        self = true,
        castTime = 0.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 0.0,
    },
    ForcePotency = {
        id = "Force Potency",
        self = true,
        castTime = 0.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 0.0,
    },
    ForceSpeed = {
        id = "Force Speed",
        self = true,
        castTime = 0.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 0.0,
        cooldownTime = 20.0,
    },
    Benevolence = {
        id = "Benevolence",
        self = true,
        castTime = 1.5,
        channelTime = 0.0,
        stationary = true,
        gcdTime = 1.5,
        -- 7.7d raised the shared Sage base cost to 85 Force. Live ability
        -- telemetry can omit the cost for this off-spec heal, so the
        -- Reserved Light path uses this only as a conservative admission
        -- fallback; Executor/Core still performs the authoritative cast check.
        resourceCostFallback = 85.0,
    },
    TelekineticWave = {
        id = TELEKINETIC_WAVE_ID,
        range = 35,
        castTime = 2.0,
        channelTime = 0.0,
        stationary = true,
        gcdTime = 1.5,
        cooldownTime = 6.0,
    },
    Forcequake = {
        id = "Forcequake",
        range = 35,
        castTime = 0.0,
        channelTime = 3.0,
        stationary = true,
        groundTarget = true,
        tidalGenerator = true,
        tidalProcTiming = "start",
    },
    WeakenMind = {
        id = "Weaken Mind",
        range = 35,
        castTime = 0.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 1.5,
        cooldownTime = 0.0,
        appliedDuration = 18.0,
    },
    Turbulence = {
        id = "Turbulence",
        range = 35,
        castTime = 2.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 1.5,
        cooldownTime = 9.0,
        cooldownStartsOnCompletion = true,
        tidalGenerator = true,
        -- The proc is usable when Turbulence completes/lands, not when the
        -- cast is merely submitted. Predict against the finish to prevent
        -- an early Wave from becoming a real hard-cast.
        tidalProcTiming = "finish",
    },
    TelekineticGust = {
        id = "Telekinetic Gust",
        range = 30,
        castTime = 0.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 1.5,
        cooldownTime = 14.0,
        appliedDuration = 12.0,
    },
    MindCrush = {
        id = "Mind Crush",
        range = 35,
        castTime = 2.0,
        channelTime = 0.0,
        stationary = true,
        cooldownStartsOnCompletion = true,
    },
    TelekineticThrow = {
        id = "Telekinetic Throw",
        range = 35,
        castTime = 0.0,
        channelTime = 2.0,
        stationary = true,
    },
    ForcefulRetribution = {
        id = "Forceful Retribution",
        range = 35,
        castTime = 1.5,
        channelTime = 0.0,
        stationary = true,
        tidalGenerator = true,
        tidalProcTiming = "finish",
    },
    Disturbance = {
        id = "Disturbance",
        range = 40,
        castTime = 1.5,
        channelTime = 0.0,
        stationary = true,
        gcdTime = 1.5,
        cooldownTime = 0.0,
        tidalGenerator = true,
        tidalProcTiming = "finish",
    },
    TelekineticBurst = {
        id = "Telekinetic Burst",
        range = 30,
        castTime = 1.5,
        channelTime = 0.0,
        stationary = true,
        gcdTime = 1.5,
        cooldownTime = 0.0,
        tidalGenerator = true,
        tidalProcTiming = "finish",
    },
    Project = {
        id = "Project",
        range = 40,
        castTime = 0.0,
        channelTime = 0.0,
        stationary = false,
        gcdTime = 1.5,
        cooldownTime = 6.0,
    },
}

local AbilityList = {
    Ability.MentalAlacrity,
    Ability.ForcePotency,
    Ability.ForceSpeed,
    Ability.Benevolence,
    Ability.TelekineticWave,
    Ability.Forcequake,
    Ability.WeakenMind,
    Ability.Turbulence,
    Ability.TelekineticGust,
    Ability.MindCrush,
    Ability.TelekineticThrow,
    Ability.ForcefulRetribution,
    Ability.Disturbance,
    Ability.TelekineticBurst,
    Ability.Project,
}

local AbilityById = {}
for _, ability in ipairs(AbilityList) do
    AbilityById[ability.id] = ability
end
AbilityById[POWER_OF_THE_FORCE_ID] = Ability.TelekineticWave

local BurstRequired = {
    -- Mental Alacrity is intentionally NOT a burst hard requirement.
    -- IDF owns its timing so the manual burst package cannot hold or waste it.
    Ability.ForcePotency,
    Ability.TelekineticGust,
    Ability.Turbulence,
    Ability.TelekineticWave,
    Ability.MindCrush,
    Ability.Project,
}

local BurstForceAbilities = {
    Ability.TelekineticGust,
    Ability.Turbulence,
    Ability.TelekineticWave,
    Ability.MindCrush,
    Ability.Project,
}

local Runtime = {
    loadout = nil,
    tidal = {
        activeLastTick = false,
        lastRemaining = nil,
        readyAt = 0.0,
        readyKnown = false,
        lastObservedProcAt = nil,
        effectConsumed = false,
        observedClaim = nil,
    },
    procGrants = {},
    commandWatches = {},
    nativeAdmission = nil,
    sessionPlayerHandle = nil,
    sessionActorEpoch = nil,
    combatCursor = nil,
    pressureTracker = PressureTracker.new(),
    targetCountCache = nil,
    targetCountVisualSignature = nil,
    targetCountVisualNextAt = 0.0,
    mobilityBarNextAt = 0.0,
    mobilityBarPlanNextAt = 0.0,
    mobilityBarStartedAt = nil,
    mobilityBarStandAt = nil,
    mobilityBarAbility = nil,
    mobilityBarDiagnostic = nil,
    mobilityBarHoldUntil = 0.0,
    clipTremorsForcequake = false,
    clamoring = { charges = 0, observed = nil },
    burst = {
        mode = "idle",
        step = "weaken_mind",
        targetHandle = nil,
        pressPending = false,
        readiness = 0,
        blockedReason = nil,
        justCompleted = false,
    },
    lastDecisionLogKey = nil,
    lastNoDecisionDiagnosticAt = 0.0,
    castAdmissionDiagnostic = nil,
    lastLoadoutState = nil,
}

-- Each rule turns an exact local combat event into a one-shot consumer grant.
-- Only this event edge or the authoritative effect observation permits the
-- consumer input.
local ProcRules = {
    {
        id = "tidal_force",
        cooldownState = "tidal",
        cooldownSeconds = Config.tidalInternalCooldown,
        generators = {
            [Ability.Forcequake.id] = {
                kind = "ability",
                action = "ability_activate",
            },
            [Ability.Turbulence.id] = {
                kind = "resource",
                action = "spend_force",
            },
            [Ability.ForcefulRetribution.id] = {
                kind = "resource",
                action = "spend_force",
            },
            [Ability.Disturbance.id] = {
                kind = "resource",
                action = "spend_force",
            },
            [Ability.TelekineticBurst.id] = {
                kind = "resource",
                action = "spend_force",
            },
        },
    },
}

local function now_seconds()
    local value = gos.time_ms()
    if type(value) ~= "number" then
        return 0.0
    end
    return value / 1000.0
end

local function clamp(value, minimum, maximum)
    if type(value) ~= "number" then
        return minimum
    end
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

local function positive(value)
    if type(value) == "number" and value > 0 then
        return value
    end
    return 0.0
end

local function bool_text(value)
    return value and "on" or "off"
end

local function log_line(level, message)
    if level == "debug" and Config.decisionLog ~= true then
        return
    end
    if level == "info" and
        not (Config.castLog == true or Config.decisionLog == true) then
        return
    end
    local logger = gos and gos.log or nil
    local fn = logger and logger[level] or nil
    if type(fn) == "function" then
        fn(message)
    end
end

local function log_info(message)
    if Config.castLog then
        log_line("info", message)
    end
end

local function log_warn(message)
    log_line("warn", message)
end

local function log_debug(message)
    if Config.decisionLog then
        log_line("debug", message)
    end
end

local function safe_method(unit, method_name, ...)
    if not unit then
        return nil
    end
    local method = unit[method_name]
    if type(method) ~= "function" then
        return nil
    end
    local ok, a, b, c = pcall(method, unit, ...)
    if not ok then
        return nil
    end
    return a, b, c
end

local function unit_handle(unit)
    local value = safe_method(unit, "handle")
    return value
end

local function unit_reaction(unit)
    local value = safe_method(unit, "reaction")
    return value
end


local function unit_distance(unit)
    local value = safe_method(unit, "distance")
    if type(value) == "number" then
        return value * METERS_PER_WORLD_UNIT
    end
    return nil
end

local function unit_speed(unit)
    local value = safe_method(unit, "speed")
    if type(value) == "number" then
        return value
    end
    return nil
end

local function unit_hp(unit)
    if not unit then
        return nil
    end

    local hp = safe_method(unit, "hp")
    if hp == nil then
        local raw = unit.hp
        if type(raw) == "table" or type(raw) == "number" then
            hp = raw
        end
    end

    if type(hp) == "number" then
        return {
            current = nil,
            max = nil,
            percent = hp,
        }
    end

    if type(hp) ~= "table" then
        return nil
    end

    local current = type(hp.current) == "number" and hp.current or nil
    local maximum = type(hp.max) == "number" and hp.max or nil
    local percent = type(hp.percent) == "number" and hp.percent or nil
    if percent == nil and current ~= nil and maximum ~= nil and maximum > 0 then
        percent = (current / maximum) * 100.0
    end

    return {
        current = current,
        max = maximum,
        percent = percent,
    }
end

local function unit_resource(unit)
    local resource = safe_method(unit, "resource")
    if type(resource) ~= "table" then
        return nil
    end

    local current = type(resource.current) == "number" and resource.current or nil
    local maximum = type(resource.max) == "number" and resource.max or nil
    local percent = type(resource.percent) == "number" and resource.percent or nil
    if percent == nil and current ~= nil and maximum ~= nil and maximum > 0 then
        percent = (current / maximum) * 100.0
    end

    return {
        current = current,
        max = maximum,
        percent = percent,
    }
end

local function unit_toughness(unit)
    local label, value = safe_method(unit, "toughness")
    if type(label) ~= "string" and type(value) ~= "number" then
        return nil
    end
    return {
        label = label,
        value = value,
    }
end

local function parse_position(a, b, c)
    if type(a) == "number" and type(b) == "number" then
        return {
            x = a,
            y = b,
            z = type(c) == "number" and c or 0.0,
        }
    end

    if type(a) ~= "table" then
        return nil
    end

    local x = type(a.x) == "number" and a.x or a[1]
    local y = type(a.y) == "number" and a.y or a[2]
    local z = type(a.z) == "number" and a.z or a[3]
    if type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end

    return {
        x = x,
        y = y,
        z = type(z) == "number" and z or 0.0,
    }
end

local function unit_position(unit)
    local a, b, c = safe_method(unit, "position")
    return parse_position(a, b, c)
end

local function distances_between_positions(a, b)
    if not a or not b then
        return nil
    end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    local planar = math.sqrt(dx * dx + dz * dz)
    return math.sqrt(planar * planar + dy * dy) * METERS_PER_WORLD_UNIT,
        planar * METERS_PER_WORLD_UNIT,
        math.abs(dy) * METERS_PER_WORLD_UNIT
end

local function effect_snapshot(unit, name, options)
    if not unit or type(unit.effect) ~= "function" then
        return {
            known = false,
            present = false,
            remaining = nil,
            status = "unavailable",
            mine = false,
        }
    end

    local actual
    actual, options = Mirror.effect_query(Runtime.loadout, name, options)
    if actual == nil then
        return {
            known = false,
            present = false,
            remaining = nil,
            status = "mirror_name_unavailable",
            mine = false,
        }
    end
    local ok, effect = pcall(unit.effect, unit, actual, options)
    if not ok or type(effect) ~= "table" then
        return {
            known = false,
            present = false,
            remaining = nil,
            status = "unavailable",
            mine = false,
        }
    end

    local status = effect.status
    local known = status == nil or status == "ready"
    return {
        known = known,
        present = known and effect.present == true,
        remaining = type(effect.remaining) == "number" and effect.remaining or nil,
        status = status,
        kind = effect.kind,
        reason = effect.reason,
        mine = known and effect.mine == true,
        stacks = type(effect.stacks) == "number" and effect.stacks or nil,
        ageMs = type(effect.age_ms) == "number" and effect.age_ms or nil,
    }
end

local function ability_snapshot()
    local snapshot = {}
    for _, ability in ipairs(AbilityList) do
        local actual = Mirror.ability(Runtime.loadout, ability.id)
        local info = actual and gos.abilities.info(actual) or nil
        local cooldown = actual and gos.abilities.cooldown_remaining(actual) or nil
        local info_known = type(info) == "table"
        local cooldown_known = type(cooldown) == "number"
        local has_resource_cost
        if info_known and type(info.has_resource_cost) == "boolean" then
            has_resource_cost = info.has_resource_cost
        end
        local uses_global_cooldown
        if info_known and type(info.uses_global_cooldown) == "boolean" then
            uses_global_cooldown = info.uses_global_cooldown
        end
        snapshot[ability.id] = {
            resolved = info_known and info.ability_handle ~= nil,
            abilityHandle = info_known and info.ability_handle or nil,
            ready = actual ~= nil and gos.abilities.is_ready(actual) == true,
            submissionPending = info_known and info.submission_pending == true,
            cooldownKnown = cooldown_known,
            cooldown = cooldown_known and math.max(0.0, cooldown) or nil,
            cooldownDuration = info_known and
                type(info.cooldown_duration) == "number" and
                math.max(0.0, info.cooldown_duration) or nil,
            gcdDuration = info_known and type(info.gcd_duration) == "number" and
                math.max(0.0, info.gcd_duration) or nil,
            usesGlobalCooldown = uses_global_cooldown,
            hasResourceCost = has_resource_cost,
            resourceCost = info_known and type(info.resource_cost) == "number" and
                info.resource_cost or nil,
        }
    end
    return snapshot
end

local function current_action_snapshot()
    local cast = gos.abilities.current_cast()
    if type(cast) ~= "table" then
        return nil
    end

    local canonical = type(cast.name) == "string" and
        Mirror.canonical(Runtime.loadout, cast.name) or nil
    return {
        name = canonical,
        ability = canonical and AbilityById[canonical] or nil,
        remaining = type(cast.remaining) == "number" and math.max(0.0, cast.remaining) or nil,
        hasTiming = cast.has_timing == true or type(cast.remaining) == "number",
    }
end

local function target_centered_relevant_target_counts(world, target, collect_samples)
    if not world or not target then
        return nil, nil, "world_or_target_unavailable"
    end

    local target_position = unit_position(target)
    if not target_position then
        return nil, nil, "target_position_unavailable"
    end

    local ok, units = pcall(world.units, world, { reaction = "hostile" })
    if not ok or type(units) ~= "table" or #units > MAX_HOSTILES then
        return nil, nil, "hostile_unit_list_unavailable"
    end

    local target_handle = unit_handle(target)
    local counted_target = false
    local forceful_count = 0
    local forcequake_count = 0
    local samples = collect_samples and {} or nil

    for _, unit in ipairs(units) do
        local handle = unit_handle(unit)
        local is_target = safe_method(unit, "is_current_target") == true or
            (target_handle ~= nil and handle == target_handle)
        local hp = unit_hp(unit)
        local alive = unit_reaction(unit) == "hostile" and hp ~= nil and
            type(hp.current) == "number" and hp.current > 0
        local position = unit_position(unit)
        local distance, planar, vertical =
            distances_between_positions(position, target_position)
        local forceful_counted = alive and distance ~= nil and
            distance <= Config.targetClusterRadius
        local forcequake_counted = alive and distance ~= nil and
            distance <= Config.forcequakeClusterRadius

        if samples then
            samples[#samples + 1] = {
                unit = unit,
                handle = handle,
                hpCurrent = hp and hp.current or nil,
                position = position,
                distance = distance,
                planarDistance = planar,
                verticalDistance = vertical,
                forcefulCounted = forceful_counted,
                forcequakeCounted = forcequake_counted,
                isTarget = is_target,
                zeroPosition = position ~= nil and position.x == 0.0 and
                    position.y == 0.0 and position.z == 0.0,
            }
        end

        if is_target then
            counted_target = true
        end
        if forceful_counted then
            forceful_count = forceful_count + 1
        end
        if forcequake_counted then
            forcequake_count = forcequake_count + 1
        end
    end

    if not counted_target then
        forceful_count = forceful_count + 1
        forcequake_count = forcequake_count + 1
    end

    return clamp(forceful_count, 1, 8), clamp(forcequake_count, 1, 8),
        "target_centered", samples
end

local function automatic_relevant_target_counts(world, target, collect_samples)
    if not Config.automaticTargetCount then
        return nil, nil, "disabled"
    end
    return target_centered_relevant_target_counts(world, target, collect_samples)
end

local function relevant_target_counts(world, target, collect_samples, now)
    if not Config.automaticTargetCount then
        Runtime.targetCountCache = nil
        return Config.manualRelevantTargets, Config.manualRelevantTargets, "manual", nil
    end

    local cache_key = table.concat({
        tostring(unit_handle(target) or "-"),
        string.format("%.1f", Config.targetClusterRadius),
        string.format("%.1f", Config.forcequakeClusterRadius),
        tostring(Config.manualRelevantTargets),
        bool_text(collect_samples),
    }, "|")
    local cached = Runtime.targetCountCache
    if cached and cached.key == cache_key and now < cached.expiresAt then
        return cached.forceful, cached.forcequake, cached.source, cached.samples
    end

    local forceful, forcequake, reason, samples =
        automatic_relevant_target_counts(world, target, collect_samples)
    if forceful ~= nil then
        Runtime.targetCountCache = {
            key = cache_key,
            expiresAt = now + Config.targetCountRefresh,
            forceful = forceful,
            forcequake = forcequake,
            source = reason,
            samples = samples,
        }
        return forceful, forcequake, reason, samples
    end

    Runtime.targetCountCache = nil
    return nil, nil, reason, samples
end

local function forcequake_target_count(world, target, now)
    if not world or not target or unit_reaction(target) ~= "hostile" then
        return nil, "hostile_target_unavailable"
    end
    local cache_key = table.concat({
        "seer_forcequake",
        tostring(unit_handle(target) or "-"),
        string.format("%.1f", Config.forcequakeClusterRadius),
    }, "|")
    local cached = Runtime.targetCountCache
    if cached and cached.key == cache_key and now < cached.expiresAt then
        return cached.forcequake, cached.source
    end

    local _, forcequake, reason =
        target_centered_relevant_target_counts(world, target, false)
    Runtime.targetCountCache = {
        key = cache_key,
        expiresAt = now + Config.targetCountRefresh,
        forcequake = forcequake,
        source = reason,
    }
    return forcequake, reason
end

local function read_state(loadout)
    Runtime.loadout = loadout
    local now = now_seconds()
    local loadout_known = type(loadout) == "table" and
        loadout.status == "ready" and type(loadout.known) == "table" and
        loadout.known or nil
    local magnifying_vibrations_selected = loadout_known ~= nil and
        loadout_known["Magnifying Vibrations"] == true
    if loadout_known ~= nil then
        Ability.TelekineticWave.id = loadout_known[POWER_OF_THE_FORCE_ID] == true and
            POWER_OF_THE_FORCE_ID or TELEKINETIC_WAVE_ID
    end
    local refresh_target_count_visual = Config.showTargetCountVisual and
        now >= Runtime.targetCountVisualNextAt
    if refresh_target_count_visual then
        Runtime.targetCountVisualNextAt = now + Config.targetCountVisualRefresh
    end
    local world = gos.world()
    local player = world and world.player or nil
    local target = world and world.current_target or nil

    local player_hp = unit_hp(player)
    local player_resource = unit_resource(player)
    local target_hp = unit_hp(target)
    local target_toughness = unit_toughness(target)
    local speed = unit_speed(player)
    local movement_known = type(speed) == "number"
    local moving = movement_known and speed ~= 0 or false
    local gcd_remaining = gos.abilities.gcd_remaining()
    if type(gcd_remaining) == "number" then
        gcd_remaining = math.max(0.0, gcd_remaining)
    else
        gcd_remaining = nil
    end

    local state = {
        now = now,
        loadout = loadout,
        world = world,
        playerUnit = player,
        targetUnit = target,
        refreshTargetCountVisual = refresh_target_count_visual,
        movementKnown = movement_known,
        moving = moving,
        dormantTremorsSelected = loadout_known ~= nil and
            loadout_known["Dormant Tremors"] == true,
        forcefulRetributionSelected = loadout_known ~= nil and
            loadout_known[Ability.ForcefulRetribution.id] == true,
        clamoringForceSelected = loadout_known ~= nil and
            loadout_known["Clamoring Force"] == true,
        magnifyingVibrationsSelected = magnifying_vibrations_selected,
        clamoringCharges = Runtime.clamoring.charges,
        telekineticsFiller = loadout_known ~= nil and
            loadout_known[Ability.TelekineticBurst.id] == true and
            Ability.TelekineticBurst or Ability.Disturbance,
        speed = speed,
        busy = gos.abilities.is_casting_or_channeling() == true,
        gcdRemaining = gcd_remaining,
        currentAction = current_action_snapshot(),
        abilities = ability_snapshot(),
        player = {
            hpCurrent = player_hp and player_hp.current or nil,
            hpMax = player_hp and player_hp.max or nil,
            hpPercent = player_hp and player_hp.percent or nil,
            forceCurrent = player_resource and player_resource.current or nil,
            forceMax = player_resource and player_resource.max or nil,
            forcePercent = player_resource and player_resource.percent or nil,
        },
        target = {
            exists = target ~= nil,
            handle = unit_handle(target),
            type = safe_method(target, "type"),
            reaction = unit_reaction(target),
            hpCurrent = target_hp and target_hp.current or nil,
            hpMax = target_hp and target_hp.max or nil,
            hpPercent = target_hp and target_hp.percent or nil,
            distance = unit_distance(target),
            toughnessLabel = target_toughness and target_toughness.label or nil,
            toughnessValue = target_toughness and target_toughness.value or nil,
        },
        buffs = {
            tidal = effect_snapshot(player, "Tidal Force", { timed = true }),
            tremors = effect_snapshot(player, "Tremors", { kind = "buff", timed = true }),
            clamoringForce = effect_snapshot(player, "Clamoring Force", { kind = "buff", timed = true }),
            forceGust = effect_snapshot(player, "Telekinetic Gust", { kind = "buff", timed = true }),
            mentalAlacrity = effect_snapshot(player, "Mental Alacrity", {
                kind = "buff", timed = true,
            }),
            reservedLight = magnifying_vibrations_selected and
                effect_snapshot(player, "Reserved Light", { kind = "buff" }) or nil,
        },
        debuffs = {
            weakenMind = effect_snapshot(target, "Weaken Mind", { kind = "debuff", timed = true }),
            tremors = effect_snapshot(target, "Tremors", { kind = "debuff", timed = true }),
        },
    }

    state.relevantTargets, state.forcequakeTargets, state.targetCountSource,
        state.targetCountSamples = relevant_target_counts(
            world, target, Config.showTargetCountVisual, now)
    return state
end

-- ---------------------------------------------------------------------------
-- Loadout gate
-- ---------------------------------------------------------------------------

-- Resolved combat_style + discipline must match exactly before any priority
-- work runs. pending = first observation not yet published by the worker;
-- unavailable = native snapshot invalid/overflow/concurrently changed; any
-- other combat_style/discipline = wrong character or wrong spec.
-- Logs only on transition, never per-tick.
local function loadout_match(loadout)
    loadout = Mirror.adapt_loadout(loadout or gos.abilities.loadout())
    if type(loadout) ~= "table" then
        return false, "invalid_response"
    end
    local status = loadout.status
    if status == "pending" then
        return false, "pending"
    end
    if status == "unavailable" then
        return false, "unavailable"
    end
    if status ~= "ready" then
        return false, "unknown_status:" .. tostring(status)
    end
    if loadout.combat_style ~= ExpectedCombatStyle then
        return false, "style:" .. tostring(loadout.combat_style)
    end
    if loadout.discipline ~= ExpectedDiscipline then
        return false, "disc:" .. tostring(loadout.discipline)
    end
    return true, "ready"
end

local function log_loadout_state(reason)
    if not (Config.castLog == true or Config.decisionLog == true) then
        return
    end
    if Runtime.lastLoadoutState == reason then
        return
    end
    Runtime.lastLoadoutState = reason
    if reason == "ready" then
        log_line("info", "loadout ready: style=" .. ExpectedCombatStyle ..
            " disc=" .. ExpectedDiscipline)
    else
        log_line("warn", "loadout gate: reason=" .. reason ..
            " expected=style:" .. ExpectedCombatStyle ..
            "/disc:" .. ExpectedDiscipline)
    end
end

local function proc_grant(rule)
    return Runtime.procGrants[rule.id]
end

local function clear_proc_grant(rule, reason)
    if Runtime.procGrants[rule.id] and Config.decisionLog then
        log_debug("clear proc grant: key=" .. rule.id .. " reason=" .. tostring(reason))
    end
    Runtime.procGrants[rule.id] = nil
end

local function update_proc_grants(state, events, player_handle)
    if type(events) ~= "table" or player_handle == nil then
        return
    end

    for index = 1, #events do
        local event = events[index]
        if type(event) == "table" and event.source_handle == player_handle and
            type(event.timestamp) == "number" then
            local event_name = type(event.name) == "string" and
                Mirror.canonical(Runtime.loadout, event.name) or nil
            for rule_index = 1, #ProcRules do
                local rule = ProcRules[rule_index]
                local edge = rule.generators[event_name]
                if type(edge) == "table" and event.kind == edge.kind and
                    event.action == edge.action then
                    local cooldown = Runtime[rule.cooldownState]
                    local event_at = event.timestamp / 1000.0
                    if type(cooldown) == "table" and cooldown.readyKnown == true and
                        type(cooldown.readyAt) == "number" and
                        event_at >= cooldown.readyAt then
                        cooldown.readyAt = event_at + rule.cooldownSeconds
                        Runtime.procGrants[rule.id] = {
                            sourceAbility = event_name,
                            targetHandle = event.target_handle,
                            grantedAt = event_at,
                            effectObserved = false,
                        }
                        log_info("PROC grant: key=" .. rule.id ..
                            " source=" .. tostring(event_name) ..
                            " event=" .. edge.kind .. "/" .. edge.action ..
                            " ready_again_in=" .. string.format("%.2f", rule.cooldownSeconds))
                    end
                end
            end
        end
    end
end

local function update_player_activations(state)
    local events = {}
    local dropped = 0
    for _ = 1, MAX_COMBAT_EVENT_DRAIN_PASSES do
        local batch = gos.events.combat(Runtime.combatCursor)
        if type(batch) ~= "table" then
            return
        end
        Runtime.combatCursor = batch.cursor
        if type(batch.dropped) == "number" and batch.dropped > 0 then
            dropped = dropped + batch.dropped
        end
        if type(batch.events) == "table" then
            for index = 1, #batch.events do
                events[#events + 1] = batch.events[index]
            end
        end
        if batch.more ~= true then
            break
        end
    end

    if dropped > 0 then
        log_warn("combat events dropped; no proc grant inferred for lost rows: count=" ..
            tostring(dropped))
    end

    local player_handle = unit_handle(state.playerUnit)
    if player_handle == nil then
        return
    end

    -- Reuse the exact same combat-event stream already owned by Telekinetics.
    -- Extra reads happen only when Core explicitly reports more queued rows.
    local now_ms = gos.time_ms()
    if type(now_ms) == "number" then
        Runtime.pressureTracker:observe(events, player_handle, dropped, now_ms)
        if type(state.player.hpCurrent) == "number" and
            type(state.player.hpMax) == "number" and state.player.hpMax > 0 then
            state.selfPressure = Runtime.pressureTracker:features({
                handle = player_handle,
                current = state.player.hpCurrent,
                maximum = state.player.hpMax,
            }, now_ms)
        end
    end

    update_proc_grants(state, events, player_handle)

    for index = 1, #events do
        local event = events[index]
        if event.kind == "ability" and event.source_handle == player_handle and
            (event.action == "ability_interrupt" or event.action == "ability_cancel" or
                event.action == "ability_deactivate") then
            log_info("typed player ability terminal: action=" .. tostring(event.action) ..
                " ability=" .. tostring(event.name or event.ability_handle or "-") ..
                " timestamp=" .. tostring(event.timestamp or "-"))
        end
    end
end
local function update_target_count_visual(state)
    if not Config.showTargetCountVisual then
        Runtime.targetCountVisualSignature = nil
        Runtime.targetCountVisualNextAt = 0.0
        return
    end
    if not state.refreshTargetCountVisual then
        return
    end
    if not state.targetUnit or not gos.overlay then
        return
    end

    if type(gos.overlay.draw_circle) == "function" then
        gos.overlay.draw_circle("r5_count_range", {
            at = { unit = state.targetUnit, anchor = "origin" },
            world_radius = Config.targetClusterRadius / METERS_PER_WORLD_UNIT,
            color = "cyan",
            segments = 64,
            thickness = 2.0,
            ttl = 0.25,
        })
        gos.overlay.draw_circle("r5_fq_range", {
            at = { unit = state.targetUnit, anchor = "origin" },
            world_radius = Config.forcequakeClusterRadius / METERS_PER_WORLD_UNIT,
            color = "yellow",
            segments = 64,
            thickness = 2.0,
            ttl = 0.25,
        })
    end
    if type(gos.overlay.draw_text) == "function" then
        gos.overlay.draw_text("r5_count_summary", {
            at = { unit = state.targetUnit, anchor = "top",
                pixel_offset = { x = 0, y = -36 } },
            text = string.format("R5 %s FR %d@%.1fm FQ %d@%.1fm | 3D/XZ",
                string.upper(tostring(state.targetCountSource or "-")),
                state.relevantTargets,
                Config.targetClusterRadius,
                state.forcequakeTargets,
                Config.forcequakeClusterRadius),
            color = "cyan",
            shadow = true,
            center_x = true,
            ttl = 0.25,
        })
    end

    local samples = state.targetCountSamples
    if type(samples) ~= "table" then
        return
    end
    table.sort(samples, function(a, b)
        return (a.distance or math.huge) < (b.distance or math.huge)
    end)

    local shown = 0
    local forceful_contributors = {}
    local forcequake_contributors = {}
    for _, sample in ipairs(samples) do
        if sample.forcefulCounted and #forceful_contributors < 8 then
            forceful_contributors[#forceful_contributors + 1] = string.format("%s@%.1f/%.1f",
                tostring(sample.handle or "-"),
                sample.distance or -1.0,
                sample.planarDistance or -1.0)
        end
        if sample.forcequakeCounted and #forcequake_contributors < 8 then
            forcequake_contributors[#forcequake_contributors + 1] = string.format("%s@%.1f/%.1f",
                tostring(sample.handle or "-"),
                sample.distance or -1.0,
                sample.planarDistance or -1.0)
        end

        -- ponytail: sixteen nearest labels keep this opt-in diagnostic below
        -- Core's bounded overlay budget; raise only if a live pack needs it.
        if not sample.isTarget and sample.unit and shown < 16 and
            type(gos.overlay.unit_label) == "function" then
            local hp_text = type(sample.hpCurrent) == "number" and
                string.format("%.0f", sample.hpCurrent) or "?"
            local text
            if sample.distance == nil then
                text = "OUT 3D? XZ? Y? HP" .. hp_text
            else
                local membership = sample.forcefulCounted and
                    (sample.forcequakeCounted and "FR+FQ" or "FR") or
                    (sample.forcequakeCounted and "FQ" or "OUT")
                text = string.format("%s 3D%.1f XZ%.1f Y%.1f HP%s",
                    membership,
                    sample.distance,
                    sample.planarDistance,
                    sample.verticalDistance,
                    hp_text)
            end
            if sample.zeroPosition then
                text = "ZERO " .. text
            end
            gos.overlay.unit_label("r5_count", sample.unit, {
                text = text,
                color = sample.zeroPosition and "magenta" or
                    (sample.forcefulCounted and "green" or
                        (sample.forcequakeCounted and "yellow" or "red")),
                ttl = 0.25,
            })
            shown = shown + 1
        end
    end

    local signature = table.concat({
        tostring(state.target.handle or "-"),
        tostring(state.targetCountSource or "-"),
        tostring(state.relevantTargets),
        tostring(state.forcequakeTargets),
        string.format("%.1f", Config.targetClusterRadius),
        string.format("%.1f", Config.forcequakeClusterRadius),
        table.concat(forceful_contributors, ","),
        table.concat(forcequake_contributors, ","),
    }, "|")
    if Runtime.targetCountVisualSignature ~= signature then
        Runtime.targetCountVisualSignature = signature
        log_line("info", "target count visual: source=" ..
            tostring(state.targetCountSource) ..
            " forceful=" .. tostring(state.relevantTargets) .. "@" ..
                string.format("%.1f", Config.targetClusterRadius) ..
            " forcequake=" .. tostring(state.forcequakeTargets) .. "@" ..
                string.format("%.1f", Config.forcequakeClusterRadius) ..
            " fr=" .. (#forceful_contributors > 0 and
                table.concat(forceful_contributors, ",") or "-") ..
            " fq=" .. (#forcequake_contributors > 0 and
                table.concat(forcequake_contributors, ",") or "-"))
    end
end

local function toughness_is_durable(label, value)
    if type(value) == "number" then
        if (value >= 4 and value <= 6) or (value >= 9 and value <= 14) then
            return true
        end
    end

    if type(label) == "string" then
        local lower = string.lower(label)
        if string.find(lower, "strong", 1, true) or
            string.find(lower, "elite", 1, true) or
            string.find(lower, "champion", 1, true) or
            string.find(lower, "boss", 1, true) or
            string.find(lower, "conqueror", 1, true) then
            return true
        end
    end

    return false
end

local function target_is_durable(state)
    if state.target.type == "player" then
        return true
    end

    if toughness_is_durable(state.target.toughnessLabel, state.target.toughnessValue) then
        return true
    end

    if type(state.target.hpCurrent) == "number" and
        type(state.player.hpMax) == "number" and
        state.player.hpMax > 0 then
        return state.target.hpCurrent >= state.player.hpMax * Config.durableHpRatio
    end

    return false
end

local function force_gust_confirmed(state)
    return state.buffs.forceGust.known and state.buffs.forceGust.present
end

local function mind_crush_target_worthwhile(state)
    if type(state.target.hpPercent) ~= "number" or
        state.target.hpPercent <= Config.mindCrushMinHpPercent then
        return false
    end

    return state.target.type == "player" or
        toughness_is_durable(state.target.toughnessLabel, state.target.toughnessValue)
end

local function mind_crush_worthwhile(state)
    return force_gust_confirmed(state) and
        mind_crush_target_worthwhile(state)
end

local function valid_hostile_target(state)
    if not state.target.exists or state.target.handle == nil then
        return false, "missing_current_target"
    end
    if state.target.reaction ~= "hostile" then
        return false, "target_not_hostile_or_unobserved"
    end
    if type(state.target.hpCurrent) == "number" and state.target.hpCurrent <= 0 then
        return false, "target_dead"
    end
    return true, "target_ready"
end

local function ability_state(state, ability)
    return state.abilities[ability.id] or {}
end

local function cooldown_remaining(state, ability)
    local snapshot = ability_state(state, ability)
    if type(snapshot.cooldown) == "number" then
        return snapshot.cooldown
    end
    return nil
end

local function clamoring_force_observed(state)
    return state.clamoringForceSelected == true and
        state.buffs.clamoringForce.known and state.buffs.clamoringForce.present
end

local function clamoring_force_spendable(state)
    return clamoring_force_observed(state) and
        type(state.clamoringCharges) == "number" and
        state.clamoringCharges > 0
end

local function update_clamoring_observation(state)
    local clamoring = Runtime.clamoring
    if state.clamoringForceSelected ~= true then
        clamoring.charges = 0
        clamoring.observed = nil
    elseif state.buffs.clamoringForce.known then
        local present = state.buffs.clamoringForce.present == true
        if clamoring.observed == false and present and
            clamoring.charges == 0 then
            clamoring.charges = 2
            log_info("route=telekinetics phase=clamoring state=granted charges=2" ..
                " evidence=effect_observed")
        elseif clamoring.observed == true and not present then
            clamoring.charges = 0
        end
        clamoring.observed = present
    end
    state.clamoringCharges = clamoring.charges
end

local function tidal_observed_spendable(state, own_wave)
    if Runtime.tidal.effectConsumed == true or
        not state.buffs.tidal.known or not state.buffs.tidal.present then
        return false
    end
    local claim = Runtime.tidal.observedClaim
    if claim ~= nil and claim ~= own_wave and
        claim.tidalProcAt == Runtime.tidal.lastObservedProcAt then
        return false -- Claim only this observed proc, even after receipt eviction.
    end
    return true
end

local function tremors_active(state)
    if state.dormantTremorsSelected ~= true then
        return false
    end
    if Runtime.clipTremorsForcequake and state.currentAction and
        state.currentAction.name == Ability.Forcequake.id then
        return false
    end
    if state.buffs.tremors.known and state.buffs.tremors.present then
        return true
    end
    return state.debuffs.tremors.known and state.debuffs.tremors.present
end

local function effective_duration(ability, state, instant_override)
    if instant_override then
        return 0.0
    end
    if (ability == Ability.Disturbance or ability == Ability.TelekineticBurst) and
        clamoring_force_spendable(state) then
        return 0.0
    end
    if ability == Ability.MindCrush and force_gust_confirmed(state) then
        return 1.5
    end
    return math.max(positive(ability.castTime), positive(ability.channelTime))
end

local function action_lock_remaining(state)
    if type(state.gcdRemaining) ~= "number" then
        return nil, "gcd_unavailable"
    end
    if state.busy then
        if state.currentAction and type(state.currentAction.remaining) == "number" then
            if Runtime.clipTremorsForcequake and
                state.currentAction.name == Ability.Forcequake.id then
                return state.gcdRemaining, "tremors_forcequake_gcd"
            end
            return math.max(state.gcdRemaining, state.currentAction.remaining)
        end
        return nil, "busy_without_timing"
    end
    return state.gcdRemaining, "gcd"
end

local function ability_ready(state, ability)
    local snapshot = ability_state(state, ability)
    if snapshot.resolved ~= true then
        return false, "unresolved"
    end

    if snapshot.submissionPending == true then
        return false, "ability_submission_pending"
    end

    local remaining = cooldown_remaining(state, ability)

    if ability.cooldownStartsOnCompletion == true and state.currentAction and
        state.currentAction.name == ability.id then
        return false, "same_cooldown_action_active"
    end

    if type(remaining) == "number" then
        local starts_in = action_lock_remaining(state)
        if type(starts_in) ~= "number" then
            return false, "start_time_unavailable"
        end
        if remaining > starts_in + COOLDOWN_READY_SLACK then
            return false, "cooldown_not_ready_at_start"
        end
        return true, "cooldown_ready_at_start"
    end

    if snapshot.ready == true then
        return true, "ready_api_true"
    end
    return false, "readiness_unavailable"
end

local function can_cast(state, ability, options)
    options = options or {}

    if ability == Ability.ForcefulRetribution and
        state.forcefulRetributionSelected ~= true then
        return false, "not_selected"
    end

    local ready, ready_reason = ability_ready(state, ability)
    if not ready then
        return false, ready_reason
    end

    if ability.self ~= true then
        local target_ok, target_reason = valid_hostile_target(state)
        if not target_ok then
            return false, target_reason
        end

        if type(ability.range) == "number" then
            if type(state.target.distance) ~= "number" then
                return false, "distance_unavailable"
            end
            if state.target.distance > ability.range then
                return false, "out_of_range"
            end
        end
    end

    local snapshot = ability_state(state, ability)
    if type(state.player.forceCurrent) == "number" then
        local resource_cost
        if snapshot.hasResourceCost == true then
            if type(snapshot.resourceCost) ~= "number" then
                return false, "resource_cost_unavailable"
            end
            resource_cost = snapshot.resourceCost
        elseif options.allowResourceFallback == true and
            type(ability.resourceCostFallback) == "number" then
            -- Known paid abilities may have incomplete live telemetry. Prefer
            -- their conservative authored cost over assuming they are free.
            resource_cost = ability.resourceCostFallback
        elseif snapshot.hasResourceCost == false then
            -- Core explicitly says this ability has no Force cost. That is a
            -- proven zero-cost ability, not missing telemetry.
            resource_cost = 0.0
        else
            return false, "resource_cost_unavailable"
        end
        if resource_cost > state.player.forceCurrent then
            return false, "insufficient_force"
        end
    end

    local duration = effective_duration(ability, state, options.instant == true)
    if ability.stationary and duration > 0 then
        if not state.movementKnown then
            return false, "movement_unavailable"
        end
        if state.moving then
            return false, "moving"
        end
    end

    return true, "castable"
end

local function log_no_decision_diagnostics(state)
    if not Config.decisionLog then
        return
    end
    if state.now - Runtime.lastNoDecisionDiagnosticAt < 1.0 then
        return
    end
    Runtime.lastNoDecisionDiagnosticAt = state.now

    local parts = {}
    for _, ability in ipairs(AbilityList) do
        local castable, reason = can_cast(state, ability)
        local snapshot = ability_state(state, ability)
        parts[#parts + 1] = ability.id .. "=" .. tostring(reason or castable) ..
            "/resolved=" .. bool_text(snapshot.resolved == true) ..
            "/ready=" .. bool_text(snapshot.ready == true)
    end

    log_warn("no castable priority diagnostics: target_distance=" ..
        tostring(state.target.distance) ..
        " force=" .. tostring(state.player.forceCurrent) ..
        " gcd=" .. tostring(state.gcdRemaining) ..
        " busy=" .. bool_text(state.busy) ..
        " moving=" .. bool_text(state.moving) ..
        " reasons={" .. table.concat(parts, "; ") .. "}")
end

local function can_queue_input(state)
    local remaining, reason = action_lock_remaining(state)
    if remaining == nil then
        return false, reason
    end
    if remaining > Config.abilityQueueWindow then
        return false, "locked_for=" .. string.format("%.3f", remaining)
    end
    return true, "queue_open"
end

local function executor_options(state, ability, phase)
    return {
        idempotencyKey = table.concat({
            "telekinetics",
            phase or "cast",
            ability.id,
            tostring(ability.self and "self" or
                state.target.handle or "selected"),
        }, ":"),
    }
end

local function update_tidal_observation(state)
    local tidal = state.buffs.tidal
    if not tidal.known then
        return
    end

    local active = tidal.present == true
    local refreshed = active and Runtime.tidal.activeLastTick and
        type(tidal.remaining) == "number" and
        type(Runtime.tidal.lastRemaining) == "number" and
        tidal.remaining > Runtime.tidal.lastRemaining + 0.50

    if active and (not Runtime.tidal.activeLastTick or refreshed) then
        local proc_at = state.now
        local grant = proc_grant(ProcRules[1])
        if grant then
            grant.effectObserved = true
            proc_at = grant.grantedAt
        end

        Runtime.tidal.lastObservedProcAt = proc_at
        Runtime.tidal.readyKnown = true
        Runtime.tidal.readyAt = math.max(Runtime.tidal.readyAt,
            proc_at + Config.tidalInternalCooldown)
        Runtime.tidal.effectConsumed = false

        log_debug("observed Tidal proc: ready_again_in=" ..
            string.format("%.2f", math.max(0.0, Runtime.tidal.readyAt - state.now)))
    end

    Runtime.tidal.activeLastTick = active
    Runtime.tidal.lastRemaining = active and tidal.remaining or nil
    if tidal.known and not active then Runtime.tidal.effectConsumed = false end
end

local function tidal_event_grant_spendable()
    local grant = proc_grant(ProcRules[1])
    return grant ~= nil and grant.claimed ~= true and
        grant.effectObserved ~= true
end

local function weaken_mind_effective_state(state)
    return state.debuffs.weakenMind
end

local function weaken_mind_needs_application(state)
    if not state.moving and not target_is_durable(state) then
        return false, "target_not_durable"
    end

    local weaken_mind = weaken_mind_effective_state(state)
    if not weaken_mind.known then
        return false, "debuff_observation_unavailable"
    end
    if not weaken_mind.present then
        return true, "missing"
    end
    if not weaken_mind.mine then
        return true, "not_mine"
    end
    if type(weaken_mind.remaining) ~= "number" then
        return false, "timer_unavailable"
    end

    local turbulence_cooldown = cooldown_remaining(state, Ability.Turbulence)
    if type(turbulence_cooldown) == "number" and
        turbulence_cooldown <= Config.abilityQueueWindow and
        weaken_mind.remaining <= Ability.Turbulence.castTime + Config.abilityQueueWindow + 0.15 then
        return true, "refresh_before_turbulence"
    end

    return false, "not_due"
end

local function weaken_mind_covers_turbulence(state)
    local weaken_mind = weaken_mind_effective_state(state)
    if not weaken_mind.known or not weaken_mind.present or not weaken_mind.mine then
        return false
    end
    if type(weaken_mind.remaining) ~= "number" then
        return false
    end
    return weaken_mind.remaining > Ability.Turbulence.castTime + Config.abilityQueueWindow + 0.10
end


-- This mirrors the branch order below.  The mobility forecast uses it to
-- compare what it can cast while moving against the stationary recommendation.
local MobilityPriority = {
    ReservedLightHeal = 1,
    MentalAlacrityIDF = 2,
    ObservedTidal = 3,
    EventTidal = 4,
    ReservedMindCrush = 5,
    WeakenMind = 7,
    Turbulence = 8,
    TelekineticGust = 9,
    TremorsForcequake = 10,
    MindCrush = 11,
    ForcefulRetribution = 12,
    Forcequake = 13,
    ClamoringForceFiller = 14,
    Filler = 15,
    Project = 16,
}

local function decision(ability, reason, options, priority)
    return {
        ability = ability,
        reason = reason,
        options = options or {},
        priority = priority,
    }
end

local function known_resource_cost(snapshot)
    if snapshot.hasResourceCost == true and
        type(snapshot.resourceCost) == "number" then
        return snapshot.resourceCost
    end
    return nil
end

local function select_reserved_light_self_heal(state)
    local reserved_light = state.buffs.reservedLight
    if state.magnifyingVibrationsSelected ~= true or
        type(state.player.hpPercent) ~= "number" or
        state.player.hpPercent > 85.0 or
        type(reserved_light) ~= "table" or
        not reserved_light.known or not reserved_light.present then
        return nil
    end

    -- One Reserved Light stack is already spendable. Stack count is useful
    -- telemetry, not an admission requirement: a present effect implies at
    -- least one proc even when Core cannot publish the scalar this frame.
    local castable = can_cast(state, Ability.Benevolence, {
        instant = true,
        allowResourceFallback = true,
    })
    if not castable then return nil end
    return decision(Ability.Benevolence, "reserved_light_self_heal", {
        instant = true,
        selfTarget = true,
        reservedLightStacks = reserved_light.stacks,
    }, MobilityPriority.ReservedLightHeal)
end

local function mental_alacrity_idf_reason(state)
    local pressure = state.selfPressure
    if type(pressure) ~= "table" or
        type(pressure.risk_band) ~= "number" or
        type(pressure.fast_pressure) ~= "number" or
        pressure.fast_pressure <= 0 then
        return nil
    end

    -- IDF bands 0/1 are emergency/urgent forecasts. Band 2 is admitted only
    -- with sustained-focus evidence so one mild isolated hit cannot burn MA.
    if pressure.risk_band <= 1 then
        return "idf_urgent_alacrity"
    end
    local recent = type(pressure.recent_attackers) == "number" and
        pressure.recent_attackers or 0
    local persistent = type(pressure.persistent_attackers) == "number" and
        pressure.persistent_attackers or 0
    if pressure.risk_band == 2 and (persistent >= 1 or recent >= 2) then
        return "idf_sustained_alacrity"
    end
    return nil
end

local function select_idf_mental_alacrity(state)
    local reason = mental_alacrity_idf_reason(state)
    if reason == nil then return nil end
    if not valid_hostile_target(state) then return nil end

    local active = state.buffs.mentalAlacrity
    if type(active) == "table" and active.known and active.present then
        return nil
    end

    local castable = can_cast(state, Ability.MentalAlacrity)
    if not castable then return nil end
    local pressure = state.selfPressure
    return decision(Ability.MentalAlacrity, reason, {
        selfTarget = true,
        idfRiskBand = pressure.risk_band,
        idfProjectedHp2s = pressure.projected_hp_2s,
        idfTtd = pressure.ttd,
    }, MobilityPriority.MentalAlacrityIDF)
end

local function select_priority_action(state)
    local reserved = select_reserved_light_self_heal(state)
    if reserved then return reserved end

    local mental_alacrity = select_idf_mental_alacrity(state)
    if mental_alacrity then return mental_alacrity end
    -- An observed proc owns the consumer priority.
    if tidal_observed_spendable(state) then
        local castable = can_cast(state, Ability.TelekineticWave, {
            instant = true,
        })
        if castable then
            return decision(Ability.TelekineticWave, "active_tidal_force",
                { instant = true, tidalSpend = "observed" },
                MobilityPriority.ObservedTidal)
        end
    end

    if tidal_event_grant_spendable() then
        local castable = can_cast(state, Ability.TelekineticWave, {
            instant = true,
        })
        if castable then
            return decision(Ability.TelekineticWave,
                "tidal_event_from_" .. Runtime.procGrants.tidal_force.sourceAbility,
                { instant = true, tidalSpend = "event" },
                MobilityPriority.EventTidal)
        end
    end

    local weaken_needed, weaken_reason = weaken_mind_needs_application(state)
    if weaken_needed then
        local castable = can_cast(state, Ability.WeakenMind)
        if castable then
            return decision(Ability.WeakenMind,
                "weaken_mind_" .. tostring(weaken_reason), nil,
                MobilityPriority.WeakenMind)
        end
    end

    if (state.moving or target_is_durable(state)) and weaken_mind_covers_turbulence(state) then
        local castable = can_cast(state, Ability.Turbulence)
        if castable then
            return decision(Ability.Turbulence, "turbulence_with_weaken_mind", nil,
                MobilityPriority.Turbulence)
        end
    end

    local below_forcequake_threshold =
        state.forcequakeTargets < Config.forcequakeMinTargets
    local forceful_retribution_path = state.forcefulRetributionSelected == true and
        state.relevantTargets >= 2 and
        state.relevantTargets <= 3 and
        below_forcequake_threshold

    if below_forcequake_threshold and mind_crush_target_worthwhile(state) and
        not force_gust_confirmed(state) then
        local castable = can_cast(state, Ability.TelekineticGust)
        if castable then
            return decision(Ability.TelekineticGust, "force_gust_for_mind_crush", nil,
                MobilityPriority.TelekineticGust)
        end
    end

    if state.forcequakeTargets >= Config.tremorsForcequakeMinTargets and
        tremors_active(state) then
        local castable = can_cast(state, Ability.Forcequake)
        if castable then
            return decision(Ability.Forcequake, "tremors_forcequake", {
                clipAfterGcd = state.forcequakeTargets <= 3,
            }, MobilityPriority.TremorsForcequake)
        end
    end

    if mind_crush_worthwhile(state) then
        local castable = can_cast(state, Ability.MindCrush)
        if castable then
            return decision(Ability.MindCrush, "durable_mind_crush", nil,
                MobilityPriority.MindCrush)
        end
    end

    if forceful_retribution_path then
        local castable = can_cast(state, Ability.ForcefulRetribution)
        if castable then
            return decision(Ability.ForcefulRetribution, "forceful_cleave_filler", nil,
                MobilityPriority.ForcefulRetribution)
        end
    end

    if state.forcequakeTargets >= Config.forcequakeMinTargets then
        local castable = can_cast(state, Ability.Forcequake)
        if castable then
            return decision(Ability.Forcequake, "normal_forcequake", nil,
                MobilityPriority.Forcequake)
        end
    end

    if clamoring_force_spendable(state) then
        local filler = state.telekineticsFiller
        local castable = can_cast(state, filler, { instant = true })
        if castable then
            return decision(filler, "clamoring_force_filler",
                { instant = true }, MobilityPriority.ClamoringForceFiller)
        end
    end

    local filler = state.telekineticsFiller
    local castable = can_cast(state, filler)
    if castable then
        return decision(filler, "single_target_filler", nil,
            MobilityPriority.Filler)
    end

    if state.moving then
        local castable = can_cast(state, Ability.Project)
        if castable then
            return decision(Ability.Project, "moving_project", nil,
                MobilityPriority.Project)
        end
    end

    return nil
end

local function reset_burst(reason, state)
    local burst = Runtime.burst
    if burst.mode ~= "idle" or burst.pressPending then
        log_line("info", "route=telekinetics phase=burst state=cancelled" ..
            " reason=" .. tostring(reason or "reset") ..
            " target=" .. tostring(
                state and state.target.handle or burst.targetHandle or "-"))
    end
    burst.mode = "idle"
    burst.step = "weaken_mind"
    burst.targetHandle = nil
    burst.pressPending = false
    burst.readiness = 0
    burst.blockedReason = nil
    burst.justCompleted = false
end

local function complete_burst(state)
    local burst = Runtime.burst
    log_line("info", "route=telekinetics phase=burst state=completed" ..
        " toggle=off target=" .. tostring(state.target.handle) ..
        " force=" .. tostring(state.player.forceCurrent) ..
            "/" .. tostring(state.player.forceMax))
    burst.mode = "idle"
    burst.step = "weaken_mind"
    burst.targetHandle = nil
    burst.pressPending = false
    burst.readiness = 100
    burst.blockedReason = nil
    burst.justCompleted = true
end

local function burst_active()
    local burst = Runtime.burst
    return burst.mode ~= "idle" or burst.pressPending
end

local function burst_loadout_gate(loadout)
    local known = type(loadout) == "table" and loadout.known or nil
    if type(known) ~= "table" then
        return false, "loadout_known_unavailable"
    end
    if known[Ability.TelekineticWave.id] ~= true then
        return false, "talented_wave_not_in_loadout"
    end
    for _, ability in ipairs(BurstRequired) do
        if known[ability.id] ~= true then
            return false, "not_in_loadout_" ..
                ability.id:gsub(" ", "_"):lower()
        end
    end
    if known["Clamoring Force"] == true then
        if known[Ability.ForceSpeed.id] ~= true then
            return false, "not_in_loadout_force_speed"
        end
        if known[Ability.TelekineticBurst.id] ~= true and
            known[Ability.Disturbance.id] ~= true then
            return false, "not_in_loadout_clamoring_filler"
        end
    end
    return true, "ready"
end

local function burst_force_required(state)
    local required = 0.0
    for _, ability in ipairs(BurstForceAbilities) do
        local snapshot = ability_state(state, ability)
        if not snapshot.resolved then
            return nil, "ability_unresolved_" ..
                ability.id:gsub(" ", "_"):lower()
        end
        if snapshot.hasResourceCost == true then
            if type(snapshot.resourceCost) ~= "number" then
                return nil, "force_cost_unknown_" ..
                    ability.id:gsub(" ", "_"):lower()
            end
            required = required + snapshot.resourceCost
        end
    end

    if not weaken_mind_covers_turbulence(state) then
        local weaken = ability_state(state, Ability.WeakenMind)
        if not weaken.resolved then
            return nil, "ability_unresolved_weaken_mind"
        end
        if weaken.hasResourceCost == true then
            if type(weaken.resourceCost) ~= "number" then
                return nil, "force_cost_unknown_weaken_mind"
            end
            required = required + weaken.resourceCost
        end
    end
    if state.clamoringForceSelected == true then
        local filler = ability_state(state, state.telekineticsFiller)
        if not filler.resolved then
            return nil, "ability_unresolved_clamoring_filler"
        end
        if filler.hasResourceCost == true then
            if type(filler.resourceCost) ~= "number" then
                return nil, "force_cost_unknown_clamoring_filler"
            end
            required = required + filler.resourceCost * 2
        end
    end
    return required, "known"
end

local function burst_tidal_ready(state)
    if Runtime.tidal.readyKnown ~= true then
        return false, "tidal_icd_unknown"
    end
    local wait = math.max(0.0, Runtime.tidal.readyAt - state.now)
    if wait > COOLDOWN_READY_SLACK then
        return false, "tidal_icd_" .. string.format("%.1f", wait)
    end
    return true, "generator_ready"
end

local function burst_hard_ready(state, loadout)
    local loadout_ok, loadout_reason = burst_loadout_gate(loadout)
    if not loadout_ok then
        return false, loadout_reason
    end

    for _, ability in ipairs(BurstRequired) do
        local snapshot = ability_state(state, ability)
        if not snapshot.resolved then
            return false, "ability_unresolved_" ..
                ability.id:gsub(" ", "_"):lower()
        end
        if not snapshot.cooldownKnown or type(snapshot.cooldown) ~= "number" then
            return false, "cooldown_unknown_" ..
                ability.id:gsub(" ", "_"):lower()
        end
        if snapshot.cooldown > COOLDOWN_READY_SLACK then
            return false, ability.id:gsub(" ", "_"):lower() ..
                "_cooldown_" .. string.format("%.1f", snapshot.cooldown)
        end
    end
    if state.clamoringForceSelected == true then
        local force_speed = ability_state(state, Ability.ForceSpeed)
        if not force_speed.resolved then
            return false, "ability_unresolved_force_speed"
        end
        if not force_speed.cooldownKnown or
            type(force_speed.cooldown) ~= "number" then
            return false, "cooldown_unknown_force_speed"
        end
        if force_speed.cooldown > COOLDOWN_READY_SLACK then
            return false, "force_speed_cooldown_" ..
                string.format("%.1f", force_speed.cooldown)
        end
    end

    local force_required, force_reason = burst_force_required(state)
    if type(force_required) ~= "number" then
        return false, force_reason
    end
    if type(state.player.forceCurrent) ~= "number" then
        return false, "force_unavailable"
    end
    if state.player.forceCurrent < force_required then
        return false, "force_" .. tostring(math.floor(state.player.forceCurrent)) ..
            "_need_" .. tostring(math.ceil(force_required))
    end

    return burst_tidal_ready(state)
end

local function burst_readiness_percent(state, loadout)
    if not burst_loadout_gate(loadout) then
        return 0
    end

    local sum = 0.0
    local count = 0
    for _, ability in ipairs(BurstRequired) do
        local snapshot = ability_state(state, ability)
        sum = sum + ((snapshot.resolved and snapshot.cooldownKnown and
            type(snapshot.cooldown) == "number" and
            snapshot.cooldown <= COOLDOWN_READY_SLACK) and 1 or 0)
        count = count + 1
    end
    if state.clamoringForceSelected == true then
        local force_speed = ability_state(state, Ability.ForceSpeed)
        sum = sum + ((force_speed.resolved and force_speed.cooldownKnown and
            type(force_speed.cooldown) == "number" and
            force_speed.cooldown <= COOLDOWN_READY_SLACK) and 1 or 0)
        count = count + 1
    end

    local force_required = burst_force_required(state)
    local force = state.player.forceCurrent
    sum = sum + ((type(force_required) == "number" and
        type(force) == "number") and
        clamp(force_required > 0 and force / force_required or 1.0, 0.0, 1.0) or 0)
    count = count + 1

    local tidal_ready = burst_tidal_ready(state)
    sum = sum + (tidal_ready and 1 or 0)
    count = count + 1
    return math.floor(sum / count * 100 + 0.5)
end

local function burst_cooldown_wait(state)
    local wait = 0.0
    for _, ability in ipairs(BurstRequired) do
        local snapshot = ability_state(state, ability)
        if not snapshot.resolved or not snapshot.cooldownKnown or
            type(snapshot.cooldown) ~= "number" then
            return nil
        end
        wait = math.max(wait, snapshot.cooldown)
    end
    if state.clamoringForceSelected == true then
        local force_speed = ability_state(state, Ability.ForceSpeed)
        if not force_speed.resolved or not force_speed.cooldownKnown or
            type(force_speed.cooldown) ~= "number" then
            return nil
        end
        wait = math.max(wait, force_speed.cooldown)
    end
    if Runtime.tidal.readyKnown ~= true then
        return math.huge
    end
    return math.max(wait, math.max(0.0, Runtime.tidal.readyAt - state.now))
end

local function select_burst_pool_action(state, loadout)
    local ready, reason = burst_hard_ready(state, loadout)
    if ready then
        return nil, "burst_ready"
    end
    if not burst_loadout_gate(loadout) then
        return nil, "burst_pool_" .. tostring(reason)
    end
    if state.busy then
        return nil, "burst_pool_casting_or_channeling"
    end

    local cooldown_wait = burst_cooldown_wait(state)
    local force_required, force_reason = burst_force_required(state)
    if cooldown_wait == nil or type(force_required) ~= "number" then
        return nil, "burst_pool_" .. tostring(force_reason or reason)
    end
    if type(state.player.forceCurrent) ~= "number" then
        return nil, "burst_pool_force_unavailable"
    end
    if cooldown_wait <= BURST_FILLER_WINDOW_SECONDS and
        state.player.forceCurrent >= force_required then
        return nil, "burst_pool_cooldown_window_" ..
            string.format("%.1f", cooldown_wait)
    end

    local filler = state.telekineticsFiller
    local filler_cost = known_resource_cost(ability_state(state, filler))
    if type(filler_cost) == "number" and
        state.player.forceCurrent >= force_required + filler_cost then
        local castable = can_cast(state, filler)
        if castable then
            return decision(filler, "burst_pool_filler")
        end
    end

    local castable, throw_reason = can_cast(state, Ability.TelekineticThrow)
    if castable then
        return decision(Ability.TelekineticThrow,
            "burst_pool_force_recovery")
    end
    return nil, "burst_pool_wait_" .. tostring(throw_reason)
end

local function select_burst_action(state)
    local burst = Runtime.burst
    if state.busy then
        return nil, "burst_casting_or_channeling"
    end

    for _ = 1, 8 do
        if burst.step == "weaken_mind" then
            local weaken = state.debuffs.weakenMind
            if not weaken.known then
                return nil, "burst_wait_weaken_mind_observation"
            end
            if weaken_mind_covers_turbulence(state) then
                burst.step = "telekinetic_gust"
            else
                local castable, reason = can_cast(state, Ability.WeakenMind)
                if castable then
                    return decision(Ability.WeakenMind,
                        "burst_weaken_mind")
                end
                return nil, "burst_wait_weaken_mind_" .. tostring(reason)
            end
        elseif burst.step == "telekinetic_gust" then
            local castable, reason = can_cast(state, Ability.TelekineticGust)
            if castable then
                return decision(Ability.TelekineticGust,
                    "burst_telekinetic_gust")
            end
            return nil, "burst_wait_telekinetic_gust_" .. tostring(reason)
        elseif burst.step == "force_potency" then
            local castable, reason = can_cast(state, Ability.ForcePotency)
            if castable then
                return decision(Ability.ForcePotency,
                    "burst_force_potency")
            end
            return nil, "burst_wait_force_potency_" .. tostring(reason)
        elseif burst.step == "turbulence" then
            if not state.debuffs.weakenMind.known then
                return nil, "burst_wait_weaken_mind_observation"
            end
            if not weaken_mind_covers_turbulence(state) then
                local castable, reason = can_cast(state, Ability.WeakenMind)
                if castable then
                    return decision(Ability.WeakenMind,
                        "burst_refresh_weaken_mind")
                end
                return nil, "burst_wait_weaken_mind_" .. tostring(reason)
            end
            local castable, reason = can_cast(state, Ability.Turbulence)
            if castable then
                return decision(Ability.Turbulence, "burst_turbulence")
            end
            return nil, "burst_wait_turbulence_" .. tostring(reason)
        elseif burst.step == "telekinetic_wave" then
            if tidal_observed_spendable(state) then
                local castable, reason = can_cast(state,
                    Ability.TelekineticWave, {
                        instant = true,
                    })
                if castable then
                    return decision(Ability.TelekineticWave,
                        "burst_tidal_wave_observed", {
                            instant = true,
                            tidalSpend = "observed",
                        })
                end
                return nil, "burst_wait_telekinetic_wave_" .. tostring(reason)
            end
            if tidal_event_grant_spendable() then
                local castable, reason = can_cast(state,
                    Ability.TelekineticWave, {
                        instant = true,
                    })
                if castable then
                    return decision(Ability.TelekineticWave,
                        "burst_tidal_wave_event", {
                            instant = true,
                            tidalSpend = "event",
                        })
                end
                return nil, "burst_wait_telekinetic_wave_" .. tostring(reason)
            end
            return nil, "burst_wait_tidal_force"
        elseif burst.step == "mind_crush" then
            if not state.buffs.forceGust.known then
                return nil, "burst_wait_force_gust_observation"
            end
            if not force_gust_confirmed(state) then
                return nil, "burst_wait_force_gust"
            end
            local castable, reason = can_cast(state, Ability.MindCrush)
            if castable then
                return decision(Ability.MindCrush, "burst_mind_crush")
            end
            return nil, "burst_wait_mind_crush_" .. tostring(reason)
        elseif burst.step == "project" then
            local castable, reason = can_cast(state, Ability.Project)
            if castable then
                return decision(Ability.Project, "burst_project")
            end
            return nil, "burst_wait_project_" .. tostring(reason)
        elseif burst.step == "force_speed" then
            local castable, reason = can_cast(state, Ability.ForceSpeed)
            if castable then
                return decision(Ability.ForceSpeed, "burst_force_speed")
            end
            return nil, "burst_wait_force_speed_" .. tostring(reason)
        elseif burst.step == "clamoring_filler_1" or
            burst.step == "clamoring_filler_2" then
            if not clamoring_force_spendable(state) then
                return nil, "burst_wait_clamoring_force"
            end
            local filler = state.telekineticsFiller
            local castable, reason = can_cast(state, filler, { instant = true })
            if castable then
                return decision(filler, "burst_" .. burst.step,
                    { instant = true })
            end
            return nil, "burst_wait_" .. burst.step .. "_" .. tostring(reason)
        else
            return nil, "burst_invalid_step_" .. tostring(burst.step)
        end
    end
    return nil, "burst_step_limit"
end

local BurstNextStep = {
    [Ability.WeakenMind.id] = {
        from = "weaken_mind",
        to = "telekinetic_gust",
    },
    [Ability.TelekineticGust.id] = {
        from = "telekinetic_gust",
        to = "force_potency",
    },
    [Ability.ForcePotency.id] = {
        from = "force_potency",
        to = "turbulence",
    },
    [Ability.Turbulence.id] = {
        from = "turbulence",
        to = "telekinetic_wave",
    },
    [Ability.TelekineticWave.id] = {
        from = "telekinetic_wave",
        to = "mind_crush",
    },
    [Ability.MindCrush.id] = {
        from = "mind_crush",
        to = "project",
    },
    [Ability.ForceSpeed.id] = {
        from = "force_speed",
        to = "clamoring_filler_1",
    },
}
BurstNextStep[POWER_OF_THE_FORCE_ID] = BurstNextStep[TELEKINETIC_WAVE_ID]

local function advance_burst_after_start(state, ability)
    local burst = Runtime.burst
    if burst.mode ~= "active" then
        return
    end
    if ability == Ability.Project and burst.step == "project" then
        if state.clamoringForceSelected == true then
            burst.step = "force_speed"
        else
            complete_burst(state)
        end
        return
    end
    if ability == state.telekineticsFiller and
        burst.step == "clamoring_filler_1" then
        burst.step = "clamoring_filler_2"
        burst.blockedReason = nil
        return
    end
    if ability == state.telekineticsFiller and
        burst.step == "clamoring_filler_2" then
        complete_burst(state)
        return
    end
    local transition = BurstNextStep[ability.id]
    if transition and burst.step == transition.from then
        burst.step = transition.to
        burst.blockedReason = nil
    end
end

local function burst_target_problem(state)
    if not burst_active() then
        return nil
    end
    local target_ok, target_reason = valid_hostile_target(state)
    if not target_ok then
        return target_reason
    end
    local pinned = Runtime.burst.targetHandle
    if pinned ~= nil and state.target.handle ~= pinned then
        return "target_changed"
    end
    return nil
end

local function log_burst_loadout(loadout)
    local known = type(loadout) == "table" and loadout.known or {}
    log_line("info", "route=telekinetics phase=burst_loadout" ..
        " dormant_tremors=" .. tostring(known["Dormant Tremors"] == true) ..
        " mysteries_of_the_force=" ..
            tostring(known["Mysteries of the Force"] == true) ..
        " power_of_the_force=" ..
            tostring(known["Power of the Force"] == true) ..
        " incoming_turbulence=" ..
            tostring(known["Incoming Turbulence"] == true) ..
        " mental_disparity=" ..
            tostring(known["Mental Disparity"] == true) ..
        " off_balance=" .. tostring(known["Off Balance"] == true) ..
        " clamoring_force=" ..
            tostring(known["Clamoring Force"] == true) ..
        " force_speed=" .. tostring(known[Ability.ForceSpeed.id] == true) ..
        " telekinetic_burst=" ..
            tostring(known["Telekinetic Burst"] == true))
end

local function prepare_burst(state, loadout)
    local burst = Runtime.burst
    burst.justCompleted = false
    if burst.pressPending then
        burst.pressPending = false
        if burst.mode ~= "idle" then
            reset_burst("hotkey_cancelled", state)
            return false
        end
        burst.mode = "armed"
        burst.step = "weaken_mind"
        burst.targetHandle = state.target.handle
        burst.blockedReason = nil
        log_burst_loadout(loadout)
        log_line("info", "route=telekinetics phase=burst state=armed" ..
            " target=" .. tostring(state.target.handle) ..
            " force=" .. tostring(state.player.forceCurrent) ..
                "/" .. tostring(state.player.forceMax))
    end

    if burst.mode == "armed" then
        local ready = burst_hard_ready(state, loadout)
        if ready then
            burst.mode = "active"
            burst.step = "weaken_mind"
            burst.blockedReason = nil
            log_line("info", "route=telekinetics phase=burst state=started" ..
                " target=" .. tostring(state.target.handle) ..
                " force=" .. tostring(state.player.forceCurrent) ..
                    "/" .. tostring(state.player.forceMax))
        end
    end
    burst.readiness = burst.mode == "active" and 100 or
        burst_readiness_percent(state, loadout)
    return true
end

local function burst_overlay_reason(reason)
    local text = tostring(reason or "waiting")
    text = text:gsub("^burst_wait_", ""):gsub("^burst_pool_", "")
    text = string.upper(text:gsub("_", " "))
    if #text > 56 then
        text = text:sub(1, 53) .. "..."
    end
    return text
end

local function draw_burst_overlay(state)
    local burst = Runtime.burst
    if not gos.overlay or not state.targetUnit or
        (Config.telekineticsBurstStatusLabel == false and
            Config.telekineticsBurstProgressLabel == false) or
        burst.justCompleted or
        (burst.mode == "idle" and not burst.pressPending and
            Config.telekineticsBurstPooling ~= true) then
        return
    end
    if burst.targetHandle ~= nil and
        state.target.handle ~= burst.targetHandle then
        return
    end

    local blocked = burst.blockedReason ~= nil and
        (burst.mode == "active" or burst.mode == "armed" or
            burst.pressPending)
    local status
    local color
    if blocked then
        status = "BURST BLOCKED"
        color = "red"
    elseif burst.mode == "active" then
        status = "BURST ACTIVE"
        color = "magenta"
    elseif burst.mode == "armed" or burst.pressPending then
        status = burst.readiness >= 100 and "BURST READY" or "BURST PREP"
        color = burst.readiness >= 100 and "green" or "yellow"
    else
        status = burst.readiness >= 100 and "BURST READY" or "BURST POOL"
        color = burst.readiness >= 100 and "green" or "cyan"
    end

    if Config.telekineticsBurstStatusLabel ~= false and
        type(gos.overlay.draw_text) == "function" then
        gos.overlay.draw_text("sage_burst_status", {
            at = { unit = state.targetUnit, anchor = "top",
                pixel_offset = { x = 0, y = -82 } },
            text = status,
            color = color,
            font_size = 22,
            shadow = true,
            center_x = true,
            ttl = 0.12,
        })
    end
    if Config.telekineticsBurstProgressLabel ~= false then
        if type(gos.overlay.draw_text) == "function" then
            gos.overlay.draw_text("sage_burst_progress", {
                at = { unit = state.targetUnit, anchor = "top",
                    pixel_offset = { x = 0, y = -56 } },
                text = blocked and burst_overlay_reason(burst.blockedReason) or
                    ("READY " .. tostring(burst.readiness) .. "%"),
                color = color,
                font_size = 18,
                shadow = true,
                center_x = true,
                ttl = 0.12,
            })
        end
        if type(gos.overlay.draw_bar) == "function" then
            gos.overlay.draw_bar("sage_burst_bar", {
                at = { unit = state.targetUnit, anchor = "top",
                    pixel_offset = { x = -50, y = -35 } },
                width = 100,
                height = 5,
                value = blocked and 0 or burst.readiness / 100,
                color = color,
                bg_color = { 12, 14, 16, 220 },
                border_color = "black",
                ttl = 0.12,
            })
        end
    end
end

local function copy_table(source)
    local copy = {}
    if type(source) == "table" then
        for key, value in pairs(source) do
            copy[key] = value
        end
    end
    return copy
end

local function copy_table_map(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = copy_table(value)
    end
    return copy
end

local function mobility_projection_state(state)
    local abilities = {}
    for id, snapshot in pairs(state.abilities) do
        abilities[id] = copy_table(snapshot)
    end
    return {
        now = state.now,
        movementKnown = true,
        moving = state.moving,
        busy = state.busy,
        gcdRemaining = state.gcdRemaining,
        currentAction = state.currentAction and copy_table(state.currentAction) or nil,
        abilities = abilities,
        loadout = state.loadout,
        telekineticsFiller = state.telekineticsFiller,
        dormantTremorsSelected = state.dormantTremorsSelected,
        forcefulRetributionSelected = state.forcefulRetributionSelected,
        clamoringForceSelected = state.clamoringForceSelected,
        magnifyingVibrationsSelected = state.magnifyingVibrationsSelected,
        clamoringCharges = state.clamoringCharges,
        player = copy_table(state.player),
        target = copy_table(state.target),
        selfPressure = state.selfPressure and copy_table(state.selfPressure) or nil,
        buffs = copy_table_map(state.buffs),
        debuffs = copy_table_map(state.debuffs),
        relevantTargets = state.relevantTargets,
        forcequakeTargets = state.forcequakeTargets,
    }
end

local MOBILITY_RUNTIME_KEYS = {
    "tidal",
    "procGrants",
    "clipTremorsForcequake",
}

local function copy_proc_grants(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = copy_table(value)
    end
    return copy
end

local function mobility_projection_runtime(source)
    source = source or Runtime
    return {
        tidal = copy_table(source.tidal),
        procGrants = copy_proc_grants(source.procGrants),
        clipTremorsForcequake = source.clipTremorsForcequake,
        pendingTidalAt = source.pendingTidalAt,
        pendingTidalSource = source.pendingTidalSource,
    }
end

local function mobility_select_action(state, projected_runtime, moving, mode)
    local saved = {}
    local saved_moving = state.moving
    state.moving = moving == true
    for _, key in ipairs(MOBILITY_RUNTIME_KEYS) do
        saved[key] = Runtime[key]
        Runtime[key] = projected_runtime[key]
    end

    local ok, selected
    if mode == "pool" then
        ok, selected = pcall(select_burst_pool_action, state, state.loadout)
    else
        ok, selected = pcall(select_priority_action, state)
    end

    for _, key in ipairs(MOBILITY_RUNTIME_KEYS) do
        projected_runtime[key] = Runtime[key]
        Runtime[key] = saved[key]
    end
    state.moving = saved_moving
    if not ok then
        error(selected, 0)
    end
    return selected
end

local function mobility_advance_effect(effect, elapsed)
    if effect.present and type(effect.remaining) == "number" then
        effect.remaining = math.max(0.0, effect.remaining - elapsed)
        if effect.remaining <= 0.0 then
            effect.present = false
        end
    end
end

local function mobility_activate_projected_tidal(state, projected_runtime)
    local pending_at = projected_runtime.pendingTidalAt
    if type(pending_at) ~= "number" or
        state.now + COOLDOWN_READY_SLACK < pending_at then
        return
    end

    local source = projected_runtime.pendingTidalSource
    projected_runtime.pendingTidalAt = nil
    projected_runtime.pendingTidalSource = nil
    projected_runtime.tidal.readyKnown = true
    projected_runtime.tidal.readyAt =
        pending_at + Config.tidalInternalCooldown
    projected_runtime.procGrants.tidal_force = {
        sourceAbility = source or "mobility_projection",
        targetHandle = state.target.handle,
        grantedAt = pending_at,
        effectObserved = false,
        projected = true,
    }
end

local function mobility_advance(state, projected_runtime, elapsed)
    if elapsed <= 0.0 then
        mobility_activate_projected_tidal(state, projected_runtime)
        return
    end
    state.now = state.now + elapsed
    state.gcdRemaining = math.max(0.0, state.gcdRemaining - elapsed)
    if state.currentAction and type(state.currentAction.remaining) == "number" then
        state.currentAction.remaining = math.max(0.0,
            state.currentAction.remaining - elapsed)
        if state.currentAction.remaining <= 0.0 then
            state.currentAction = nil
            state.busy = false
        end
    end
    for _, snapshot in pairs(state.abilities) do
        if type(snapshot.cooldown) == "number" then
            snapshot.cooldown = math.max(0.0, snapshot.cooldown - elapsed)
            snapshot.ready = snapshot.cooldown <= 0.0
        end
    end
    for _, effect in pairs(state.buffs) do
        mobility_advance_effect(effect, elapsed)
    end
    for _, effect in pairs(state.debuffs) do
        mobility_advance_effect(effect, elapsed)
    end
    mobility_activate_projected_tidal(state, projected_runtime)
end

local function mobility_gcd_duration(state, ability)
    local snapshot = ability_state(state, ability)
    if snapshot.usesGlobalCooldown == false then
        return 0.0
    end
    if type(snapshot.gcdDuration) == "number" then
        return math.max(0.0, snapshot.gcdDuration)
    end

    -- Live Core does not guarantee gcd_duration/uses_global_cooldown on every
    -- resolved ability snapshot. The rotation still knows the static GCD
    -- contract, so missing optional timing metadata must not erase the advisor.
    if type(ability.gcdTime) == "number" then
        return math.max(0.0, ability.gcdTime)
    end
    return 1.5
end

local function mobility_haste_scale(state)
    for _, ability in ipairs(AbilityList) do
        local snapshot = ability_state(state, ability)
        if positive(ability.gcdTime) > 0.0 and
            type(snapshot.gcdDuration) == "number" and
            snapshot.gcdDuration > 0.0 then
            return snapshot.gcdDuration / ability.gcdTime
        end
    end

    -- Optional runtime GCD duration is frequently absent in live snapshots.
    -- Falling back to the authored ability timings is better than suppressing
    -- the entire mobility overlay. When runtime timing exists above, it still
    -- wins and preserves haste-aware forecasting.
    return 1.0
end

local function mobility_effective_duration(ability, state, instant_override)
    local duration = effective_duration(ability, state, instant_override)
    if duration <= 0.0 then
        return 0.0
    end
    return duration * mobility_haste_scale(state)
end

local function mobility_apply_action(state, projected_runtime, selected, duration)
    local ability = selected.ability
    local snapshot = ability_state(state, ability)
    if snapshot.hasResourceCost == true and
        type(snapshot.resourceCost) == "number" and
        type(state.player.forceCurrent) == "number" then
        state.player.forceCurrent = math.max(0.0,
            state.player.forceCurrent - snapshot.resourceCost)
        if type(state.player.forceMax) == "number" and state.player.forceMax > 0.0 then
            state.player.forcePercent = state.player.forceCurrent /
                state.player.forceMax * 100.0
        end
    end

    local cooldown = type(snapshot.cooldownDuration) == "number" and
        math.max(0.0, snapshot.cooldownDuration) or positive(ability.cooldownTime)
    if ability.cooldownStartsOnCompletion then
        cooldown = cooldown + duration
    end
    snapshot.cooldown = cooldown
    snapshot.ready = cooldown <= 0.0

    if ability == Ability.WeakenMind then
        state.debuffs.weakenMind.known = true
        state.debuffs.weakenMind.present = true
        state.debuffs.weakenMind.mine = true
        state.debuffs.weakenMind.remaining = ability.appliedDuration
    elseif ability == Ability.TelekineticGust then
        state.buffs.forceGust.known = true
        state.buffs.forceGust.present = true
        state.buffs.forceGust.remaining = ability.appliedDuration
    elseif ability == Ability.MentalAlacrity then
        state.buffs.mentalAlacrity = state.buffs.mentalAlacrity or {}
        state.buffs.mentalAlacrity.known = true
        state.buffs.mentalAlacrity.present = true
        state.buffs.mentalAlacrity.remaining = 15.0
    elseif ability == Ability.TelekineticWave then
        state.buffs.tidal.present = false
        state.buffs.tidal.remaining = 0.0
        projected_runtime.procGrants.tidal_force = nil
        if state.dormantTremorsSelected == true then
            state.buffs.tremors.known = true
            state.buffs.tremors.present = true
            state.buffs.tremors.remaining = 15.0
        end
    elseif (ability == Ability.Disturbance or ability == Ability.TelekineticBurst) and
        selected.options.instant == true and state.clamoringCharges > 0 then
        state.clamoringCharges = state.clamoringCharges - 1
        if state.clamoringCharges == 0 then
            state.buffs.clamoringForce.present = false
            state.buffs.clamoringForce.remaining = 0.0
        end
    end

    if ability.tidalGenerator == true and
        projected_runtime.tidal.readyKnown == true and
        type(projected_runtime.tidal.readyAt) == "number" and
        projected_runtime.procGrants.tidal_force == nil then
        local proc_at = state.now
        if ability.tidalProcTiming == "finish" then
            proc_at = proc_at + duration
        end
        if proc_at + COOLDOWN_READY_SLACK >= projected_runtime.tidal.readyAt then
            projected_runtime.pendingTidalAt = proc_at
            projected_runtime.pendingTidalSource = ability.id
            mobility_activate_projected_tidal(state, projected_runtime)
        end
    end

    local gcd_duration = mobility_gcd_duration(state, ability)
    if type(gcd_duration) ~= "number" then
        return false
    end
    state.gcdRemaining = gcd_duration
    if duration > 0.0 then
        state.busy = true
        state.currentAction = {
            name = ability.id,
            ability = ability,
            remaining = duration,
            hasTiming = true,
        }
    else
        state.busy = false
        state.currentAction = nil
    end
    return true
end

local function mobility_diagnostic(reason)
    reason = tostring(reason or "unknown")
    local previous = Runtime.mobilityBarDiagnostic
    Runtime.mobilityBarDiagnostic = reason
    if Config.decisionLog == true and previous ~= reason then
        log_line("debug", "mobility forecast: " .. reason)
    end
end

local function mobility_bar_state(state)
    if not state.movementKnown or not state.moving or
        type(state.gcdRemaining) ~= "number" then
        mobility_diagnostic("state_unavailable")
        return nil
    end
    if Runtime.burst.pressPending == true or Runtime.burst.mode ~= "idle" then
        -- The explicit burst state machine advances on proven starts and has
        -- its own status UI. Normal-priority movement advice here would be a
        -- different plan, so fail closed rather than tell the player to plant
        -- for an action the burst sequence will not actually choose.
        mobility_diagnostic("burst_sequence_active")
        return nil
    end
    local selector_mode = Config.telekineticsBurstPooling == true and
        "pool" or "normal"
    if state.busy and (state.currentAction == nil or
        state.currentAction.ability == nil or
        type(state.currentAction.remaining) ~= "number") then
        mobility_diagnostic("busy_without_timing")
        return nil
    end
    if state.currentAction and state.currentAction.ability.stationary then
        mobility_diagnostic("stand:" .. state.currentAction.ability.id)
        return 0.0, state.currentAction.ability
    end

    local projected = mobility_projection_state(state)
    local projected_runtime = mobility_projection_runtime()
    local started_at = projected.now
    -- ponytail: one pass over the ten known abilities bounds this tick-time forecast;
    -- increase only when the live priority list can legally chain more mobile actions.
    for _ = 1, #AbilityList do
        local lock = action_lock_remaining(projected)
        if type(lock) ~= "number" then
            mobility_diagnostic("lock_unavailable")
            return nil
        end
        local advance = math.max(0.0, lock - Config.abilityQueueWindow)
        local pending_at = projected_runtime.pendingTidalAt
        if type(pending_at) == "number" then
            local until_pending = math.max(0.0, pending_at - projected.now)
            if until_pending > advance and
                until_pending <= lock + COOLDOWN_READY_SLACK then
                -- A guaranteed projected Tidal edge cannot be queued before it
                -- exists. Stay mobile through the generator completion instead
                -- of planting for a lower-priority hardcast 200ms too early.
                advance = until_pending
            end
        end
        mobility_advance(projected, projected_runtime, advance)

        local stationary = mobility_select_action(projected,
            mobility_projection_runtime(projected_runtime), false, selector_mode)
        local selected = mobility_select_action(projected, projected_runtime, true,
            selector_mode)
        if stationary then
            local stationary_duration = mobility_effective_duration(
                stationary.ability, projected, stationary.options.instant == true)
            if stationary_duration == nil then
                mobility_diagnostic("stationary_timing_unavailable:" ..
                    stationary.ability.id)
                return nil
            end
            local stationary_wins = selector_mode == "pool" and
                (selected == nil or selected.ability ~= stationary.ability) or
                (selector_mode == "normal" and
                    (selected == nil or type(stationary.priority) ~= "number" or
                        type(selected.priority) ~= "number" or
                        stationary.priority <= selected.priority))
            if stationary.ability.stationary and stationary_duration > 0.0 and
                stationary_wins then
                mobility_diagnostic("stand:" .. stationary.ability.id)
                return math.max(0.0, projected.now - started_at), stationary.ability
            end
        end
        if selector_mode == "pool" and stationary ~= nil and selected ~= nil and
            stationary.ability ~= selected.ability then
            mobility_diagnostic("pool_selector_diverged")
            return nil
        end
        if selected == nil then
            mobility_diagnostic("no_mobile_priority")
            return nil
        end
        local duration = mobility_effective_duration(selected.ability, projected,
            selected.options.instant == true)
        local gcd_duration = mobility_gcd_duration(projected, selected.ability)
        if type(duration) ~= "number" or type(gcd_duration) ~= "number" then
            mobility_diagnostic("selected_timing_unavailable:" ..
                selected.ability.id)
            return nil
        end

        if gcd_duration > 0.0 then
            local starts_in = action_lock_remaining(projected)
            if type(starts_in) ~= "number" then
                return nil
            end
            mobility_advance(projected, projected_runtime, starts_in)
        end
        if not mobility_apply_action(projected, projected_runtime, selected, duration) then
            mobility_diagnostic("projection_apply_failed:" .. selected.ability.id)
            return nil
        end
    end
    mobility_diagnostic("projection_exhausted")
    return nil
end

local function clear_mobility_bar_plan()
    Runtime.mobilityBarPlanNextAt = 0.0
    Runtime.mobilityBarStartedAt = nil
    Runtime.mobilityBarStandAt = nil
    Runtime.mobilityBarAbility = nil
    Runtime.mobilityBarHoldUntil = 0.0
end

local function update_mobility_bar(state)
    if not Config.showMobilityBar or not gos.overlay or
        type(gos.overlay.viewport) ~= "function" or
        type(gos.overlay.draw_bar) ~= "function" or
        type(gos.overlay.draw_text) ~= "function" then
        mobility_diagnostic("overlay_unavailable_or_disabled")
        clear_mobility_bar_plan()
        return
    end
    if not valid_hostile_target(state) then
        mobility_diagnostic("target_unavailable")
        clear_mobility_bar_plan()
        return
    end
    if not state.movementKnown or not state.moving then
        mobility_diagnostic("not_moving")
        clear_mobility_bar_plan()
        return
    end
    if state.now < Runtime.mobilityBarNextAt then
        return
    end
    Runtime.mobilityBarNextAt = state.now + Config.mobilityBarRefresh

    if state.now >= Runtime.mobilityBarPlanNextAt then
        Runtime.mobilityBarPlanNextAt = state.now + Config.mobilityBarPlanRefresh
        local projected_stop, ability = mobility_bar_state(state)
        if projected_stop == nil then
            local transient = Runtime.mobilityBarDiagnostic == "busy_without_timing" or
                Runtime.mobilityBarDiagnostic == "lock_unavailable" or
                Runtime.mobilityBarDiagnostic == "state_unavailable"
            if transient and Runtime.mobilityBarStandAt ~= nil and
                state.now <= Runtime.mobilityBarHoldUntil then
                -- Core can briefly report busy before current_cast timing is
                -- published. Keep the last proven countdown for a few frames
                -- instead of blinking the whole advisor off.
            else
                clear_mobility_bar_plan()
                return
            end
        else
            if Runtime.mobilityBarStartedAt == nil or
                Runtime.mobilityBarAbility ~= ability.id then
                Runtime.mobilityBarStartedAt = state.now
            end
            Runtime.mobilityBarStandAt = state.now + projected_stop
            Runtime.mobilityBarAbility = ability.id
            Runtime.mobilityBarHoldUntil = state.now + 0.35
        end
    end
    if Runtime.mobilityBarStandAt == nil then
        return
    end

    local stop_in = math.max(0.0, Runtime.mobilityBarStandAt - state.now)
    local total = math.max(0.0,
        Runtime.mobilityBarStandAt - Runtime.mobilityBarStartedAt)
    local value = stop_in <= 0.0 and 1.0 or
        (total > 0.0 and clamp((state.now - Runtime.mobilityBarStartedAt) / total,
            0.0, 1.0) or 0.0)
    local text = stop_in > 0.0 and
        string.format("STAND IN %.1fs", stop_in) or "STAND NOW"
    local color = stop_in > 0.0 and "yellow" or "red"

    local viewport = gos.overlay.viewport()
    if type(viewport) ~= "table" or viewport.available ~= true or
        type(viewport.width) ~= "number" or type(viewport.height) ~= "number" then
        return
    end

    local center_x = math.floor(viewport.width * 0.5 + Config.mobilityBarX)
    local y = math.floor(viewport.height * 0.5 + Config.mobilityBarY)
    gos.overlay.draw_bar("r5_mobility_bar", {
        at = { screen = { x = center_x - 110, y = y } },
        width = 220,
        height = 10,
        value = value,
        color = color,
        bg_color = { 12, 14, 16, 220 },
        border_color = "black",
        ttl = 0.10,
    })
    gos.overlay.draw_text("r5_mobility_text", {
        at = { screen = { x = center_x, y = y - 18 } },
        text = text,
        color = color,
        shadow = true,
        center_x = true,
        ttl = 0.10,
    })
end

local function record_action_start(state, tracked, evidence)
    local ability = tracked.ability
    local clamoring = Runtime.clamoring
    if ability == Ability.ForceSpeed and state.clamoringForceSelected == true then
        clamoring.charges = 2
        clamoring.observed = state.buffs.clamoringForce.known and
            state.buffs.clamoringForce.present
        state.clamoringCharges = clamoring.charges
        log_info("route=telekinetics phase=clamoring state=granted charges=2" ..
            " evidence=" .. tostring(evidence))
    elseif (ability == Ability.Disturbance or
            ability == Ability.TelekineticBurst) and
        clamoring.charges > 0 then
        clamoring.charges = clamoring.charges - 1
        state.clamoringCharges = clamoring.charges
        log_info("route=telekinetics phase=clamoring state=spent ability=" ..
            ability.id .. " charges=" .. tostring(clamoring.charges) ..
            " evidence=" .. tostring(evidence))
    end

    advance_burst_after_start(state, tracked.ability)

end

local function settle_wave_proc_grant(wave, reusable, reason)
    local grant = wave and wave.procGrant
    if grant == nil or proc_grant(ProcRules[1]) ~= grant then
        return
    end
    if reusable then
        grant.claimed = false
        log_debug("release proc grant: key=tidal_force reason=" .. tostring(reason))
        return
    end
    clear_proc_grant(ProcRules[1], reason)
end

local function track_command(state, selected, result, kind)
    local handle = result.command_handle
    local tracked = {
        ability = selected.ability,
        reason = selected.reason,
        kind = kind or "regular",
        commandHandle = handle,
        targetHandle = selected.options.selfTarget == true and
            unit_handle(state.playerUnit) or state.target.handle,
        clipAfterGcd = selected.options.clipAfterGcd == true,
        tidalSpend = selected.options.tidalSpend,
    }
    if tracked.kind == "wave" then
        tracked.procGrant = proc_grant(ProcRules[1])
        tracked.tidalProcAt = tracked.procGrant and tracked.procGrant.grantedAt or
            Runtime.tidal.lastObservedProcAt
        Runtime.tidal.observedClaim = tracked
        if tracked.procGrant then tracked.procGrant.claimed = true end
        log_info("SPEND Tidal submitted: " .. Ability.TelekineticWave.id .. " via " ..
            tostring(selected.reason) .. "; proc generation claimed")
    end
    Runtime.commandWatches[handle] = tracked
    return tracked
end

local function finish_wave_start(state, wave)
    if wave.tidalProcAt == Runtime.tidal.lastObservedProcAt then
        Runtime.tidal.effectConsumed = true
    end
    settle_wave_proc_grant(wave, false, "consumer_started")
end

local function after_forcequake_confirmed(state, result, clip_after_gcd)
    Runtime.clipTremorsForcequake = clip_after_gcd == true
end

local function service_command_watches(state)
    local blocking, started_any = false, false
    local owner = Executor:owns_command() and Executor:status().command_handle or nil
    for handle, tracked in pairs(Runtime.commandWatches) do
        local receipt = Executor:receipt(handle)
        local core = type(receipt) == "table" and receipt.core or nil
        if receipt == nil then
            -- Executor history is bounded. Eviction is neither activation nor
            -- failure and cannot create route ownership.
            log_info("command receipt unavailable: ability=" .. tracked.ability.id ..
                " command=" .. handle .. " outcome=unconfirmed")
            Runtime.commandWatches[handle] = nil
        else
            local failed = receipt.disposition == "failed" or
                receipt.disposition == "cancelled" or
                receipt.disposition == "abandoned"
            local started = not failed and type(core) == "table" and
                core.known == true and core.activation_proven == true
            if started then
                record_action_start(state, tracked, "activation_proven")
                if tracked.kind == "wave" then
                    finish_wave_start(state, tracked)
                elseif tracked.kind == "ground" then
                    after_forcequake_confirmed(state, receipt, tracked.clipAfterGcd)
                    log_info("ground target activated: ability=" .. tracked.ability.id ..
                        " evidence=activation_proven" ..
                        " clip_after_gcd=" .. bool_text(tracked.clipAfterGcd))
                end
                Runtime.commandWatches[handle] = nil
                started_any = true
            else
                if failed then
                    if tracked.kind == "wave" then
                        local reusable = tracked.tidalSpend == "event" and
                            tracked.procGrant ~= nil and
                            proc_grant(ProcRules[1]) == tracked.procGrant or
                            tracked.tidalSpend == "observed" and
                                tidal_observed_spendable(state, tracked)
                        settle_wave_proc_grant(tracked, reusable,
                            "consumer_command_failed")
                        if Runtime.tidal.observedClaim == tracked then
                            Runtime.tidal.observedClaim = nil
                        end
                    end
                    log_info("submitted action settled without activation: ability=" ..
                        tracked.ability.id .. " state=" ..
                        tostring(core and core.state or "unknown") .. " reason=" ..
                        tostring(receipt.reason or "unknown"))
                    Runtime.commandWatches[handle] = nil
                elseif handle == owner and
                    (tracked.kind == "wave" or tracked.kind == "ground") then
                    blocking = true
                    if tracked.kind == "wave" then
                        local reservation_valid =
                            tracked.tidalSpend == "event" and
                                tracked.procGrant ~= nil and
                                proc_grant(ProcRules[1]) == tracked.procGrant or
                            tracked.tidalSpend == "observed" and
                                tidal_observed_spendable(state, tracked)
                        if not reservation_valid or
                            state.target.handle ~= tracked.targetHandle then
                            Executor:cancel("wave_proc_or_target_invalid")
                        end
                    end
                end
            end
        end
    end
    return blocking, started_any
end

local function metric_text(value)
    return type(value) == "number" and string.format("%.3f", value) or "nil"
end

local function optional_bool_text(value)
    return type(value) == "boolean" and bool_text(value) or "nil"
end

local function cast_result_text(result, state, selected)
    if type(result) ~= "table" then
        return "invalid_result"
    end
    local core = type(result.core) == "table" and result.core or {}
    local text = tostring(result.reason or result.code or core.command_state or "unknown")
    if result.command_handle ~= nil then
        text = text .. " handle=" .. tostring(result.command_handle)
    end
    if core.command_state ~= nil then
        text = text .. " state=" .. tostring(core.command_state)
    end
    if result.disposition ~= nil then
        text = text .. " executor=" .. tostring(result.disposition)
    end
    if result.disposition == "adopted" then
        text = text .. " adopted=true"
    end
    if core.command_admission_blocked == true then
        local ability = selected and selected.ability or nil
        local options = selected and selected.options or {}
        local snapshot = state and ability and ability_state(state, ability) or {}
        local current = state and state.currentAction or nil
        text = text ..
            " admission=blocked_before_queue" ..
            " wait_ms=" .. tostring(core.wait_ms or 0) ..
            " core_uses_gcd=" .. optional_bool_text(core.uses_global_cooldown) ..
            " core_gcd_duration=" .. metric_text(core.gcd_duration) ..
            " core_gcd=" .. metric_text(core.gcd_remaining) ..
            " core_busy=" .. optional_bool_text(core.busy) ..
            " core_current=" .. tostring(core.current_cast_name or "-") ..
            " core_current_timing=" ..
                optional_bool_text(core.current_cast_has_timing) ..
            " core_current_remaining=" ..
                metric_text(core.current_cast_remaining) ..
            " lua_gcd=" .. metric_text(state and state.gcdRemaining) ..
            " lua_busy=" .. optional_bool_text(state and state.busy) ..
            " lua_current=" .. tostring(current and current.name or "-") ..
            " lua_current_remaining=" ..
                metric_text(current and current.remaining) ..
            " movement_known=" ..
                optional_bool_text(state and state.movementKnown) ..
            " moving=" .. optional_bool_text(state and state.moving) ..
            " speed=" .. metric_text(state and state.speed) ..
            " script_instant=" .. bool_text(options.instant == true) ..
            " tidal_spend=" .. bool_text(options.tidalSpend == true) ..
            " stationary=" ..
                bool_text(ability ~= nil and ability.stationary == true) ..
            " script_gcd=" .. metric_text(ability and ability.gcdTime) ..
            " script_cast=" .. metric_text(ability and ability.castTime) ..
            " script_channel=" .. metric_text(ability and ability.channelTime) ..
            " cooldown_known=" ..
                optional_bool_text(snapshot.cooldownKnown) ..
            " cooldown=" .. metric_text(snapshot.cooldown) ..
            " api_ready=" .. optional_bool_text(snapshot.ready)
    end
    return text
end

local function log_cast_failure(state, selected, result)
    local prefix = "cast failed: ability=" .. selected.ability.id ..
        " reason=" .. selected.reason ..
        " result=" .. cast_result_text(result, state, selected)
    local core = type(result) == "table" and
        type(result.core) == "table" and result.core or {}
    if type(result) ~= "table" or core.command_admission_blocked ~= true then
        Runtime.castAdmissionDiagnostic = nil
        log_warn(prefix)
        return
    end

    local current_name = state.currentAction and state.currentAction.name or "-"
    local key = table.concat({
        selected.ability.id,
        tostring(result.reason or result.code or "-"),
        tostring(core.current_cast_name or "-"),
        current_name,
        optional_bool_text(state.movementKnown),
        optional_bool_text(state.moving),
    }, "|")
    local diagnostic = Runtime.castAdmissionDiagnostic
    if diagnostic and diagnostic.key == key then
        diagnostic.attempts = diagnostic.attempts + 1
        diagnostic.lastAt = state.now
        return
    end

    Runtime.castAdmissionDiagnostic = {
        key = key,
        ability = selected.ability.id,
        reason = tostring(result.reason or result.code or "-"),
        startedAt = state.now,
        lastAt = state.now,
        attempts = 1,
    }
    log_warn(prefix)
end

local function log_cast_admission_cleared(state, selected, result)
    local diagnostic = Runtime.castAdmissionDiagnostic
    if not diagnostic then
        return
    end
    local core = type(result) == "table" and
        type(result.core) == "table" and result.core or {}
    log_line("info", "cast admission cleared: blocked_ability=" ..
        tostring(diagnostic.ability) ..
        " blocked_reason=" .. tostring(diagnostic.reason) ..
        " queued_ability=" .. selected.ability.id ..
        " attempts=" .. tostring(diagnostic.attempts) ..
        " blocked_ms=" ..
            tostring(math.max(0, math.floor(
                (state.now - diagnostic.startedAt) * 1000 + 0.5))) ..
        " final_core_gcd=" .. metric_text(core.gcd_remaining) ..
        " final_core_busy=" .. optional_bool_text(core.busy) ..
        " final_lua_gcd=" .. metric_text(state.gcdRemaining) ..
        " final_lua_busy=" .. optional_bool_text(state.busy) ..
        " moving=" .. optional_bool_text(state.moving) ..
        " speed=" .. metric_text(state.speed))
    Runtime.castAdmissionDiagnostic = nil
end

local function submission_diagnostics(state, ability)
    local snapshot = ability_state(state, ability)
    local cooldown = type(snapshot.cooldown) == "number" and
        string.format("%.3f", snapshot.cooldown) or "nil"
    local force_current = type(state.player.forceCurrent) == "number" and
        string.format("%.1f", state.player.forceCurrent) or "nil"
    local force_max = type(state.player.forceMax) == "number" and
        string.format("%.1f", state.player.forceMax) or "nil"
    local resource_cost = type(snapshot.resourceCost) == "number" and
        string.format("%.1f", snapshot.resourceCost) or "nil"
    return " cooldown_known=" .. bool_text(snapshot.cooldownKnown == true) ..
        " cooldown=" .. cooldown ..
        " api_ready=" .. bool_text(snapshot.ready == true) ..
        " force=" .. force_current .. "/" .. force_max ..
        " resource_cost_known=" .. bool_text(snapshot.hasResourceCost == true) ..
        " resource_cost=" .. resource_cost
end

local function begin_ground_target_action(state, selected)
    -- Core owns both ground-target legs under one command handle.
    if state.busy or type(state.gcdRemaining) ~= "number" or
        state.gcdRemaining > 0.0 then
        return false
    end

    local result = Executor:submit(selected.ability.id, nil,
        executor_options(state, selected.ability, "ground"))
    Runtime.nativeAdmission = nil
    if type(result) == "table" and result.admission_pending == true then
        Runtime.nativeAdmission = {
            ability = selected.ability,
            abilityHandle = ability_state(state, selected.ability).abilityHandle,
            targetHandle = state.target.handle,
            reason = selected.reason,
            options = copy_table(selected.options),
            burstMode = Runtime.burst.mode,
            burstStep = Runtime.burst.step,
        }
        log_cast_failure(state, selected, result)
        return true, false
    end
    if type(result) ~= "table" or result.accepted ~= true then
        log_cast_failure(state, selected, result)
        return type(result) == "table" and result.blocks_submission == true, false
    end
    if result.new_command ~= true then return true, false end

    log_cast_admission_cleared(state, selected, result)
    track_command(state, selected, result, "ground")

    log_info("ground target queued: ability=" .. selected.ability.id ..
        " reason=" .. selected.reason ..
        " targets=" .. tostring(state.forcequakeTargets) ..
        " clip_after_gcd=" .. bool_text(selected.options.clipAfterGcd == true) ..
        submission_diagnostics(state, selected.ability))
    return true, true
end

local function submit_regular_action(state, selected)
    -- Absolute safety rail: no code path may hard-cast Telekinetic Wave.
    if selected.ability == Ability.TelekineticWave and not selected.options.tidalSpend then
        log_warn("BLOCKED illegal hard-cast " .. Ability.TelekineticWave.id .. ": reason=" ..
            tostring(selected.reason))
        return false
    end

    local replacing = Executor:owns_command() and Executor:can_replace()
    if replacing and selected.ability == Ability.TelekineticWave then
        return false
    end

    local options = executor_options(state, selected.ability, "regular")
    local target = selected.options.selfTarget == true and state.playerUnit or nil
    local result = replacing and
        Executor:replace(selected.ability.id, target, options) or
        Executor:submit(selected.ability.id, target, options)
    Runtime.nativeAdmission = nil
    if type(result) == "table" and result.admission_pending == true then
        Runtime.nativeAdmission = {
            ability = selected.ability,
            abilityHandle = ability_state(state, selected.ability).abilityHandle,
            targetHandle = selected.options.selfTarget == true and
                unit_handle(state.playerUnit) or state.target.handle,
            worldTargetHandle = state.target.handle,
            reason = selected.reason,
            options = copy_table(selected.options),
            burstMode = Runtime.burst.mode,
            burstStep = Runtime.burst.step,
        }
        log_cast_failure(state, selected, result)
        return true, false
    end
    if type(result) ~= "table" or result.accepted ~= true then
        log_cast_failure(state, selected, result)
        return type(result) == "table" and result.blocks_submission == true, false
    end
    if result.disposition == "deduplicated" then
        return true, false
    end
    if result.new_command ~= true then return true, false end

    log_cast_admission_cleared(state, selected, result)
    if selected.ability == Ability.TelekineticWave then
        track_command(state, selected, result, "wave")
    else
        track_command(state, selected, result, "regular")
    end

    log_info((replacing and "cast replaced: ability=" or "cast queued: ability=") ..
        selected.ability.id ..
        " reason=" .. selected.reason ..
        " target_hp_percent=" .. tostring(state.target.hpPercent) ..
        " targets_fr=" .. tostring(state.relevantTargets) ..
        " targets_fq=" .. tostring(state.forcequakeTargets) ..
        " count_source=" .. tostring(state.targetCountSource) ..
        submission_diagnostics(state, selected.ability))
    return true, true
end

local function submit_action(state, selected)
    if Executor:owns_command() and selected.ability.groundTarget then
        return false
    end
    local consumed, new_command
    if selected.ability.groundTarget then
        consumed, new_command = begin_ground_target_action(state, selected)
    else
        consumed, new_command = submit_regular_action(state, selected)
    end
    if new_command then
        Runtime.clipTremorsForcequake = false
    end
    return consumed, new_command
end

local function reset_transient_state(preserve_observations)
    if Runtime.castAdmissionDiagnostic then
        log_line("info", "cast admission ended: blocked_ability=" ..
            tostring(Runtime.castAdmissionDiagnostic.ability) ..
            " blocked_reason=" ..
            tostring(Runtime.castAdmissionDiagnostic.reason) ..
            " attempts=" ..
            tostring(Runtime.castAdmissionDiagnostic.attempts) ..
            " reason=rotation_inactive")
        Runtime.castAdmissionDiagnostic = nil
    end
    Runtime.commandWatches = {}
    Runtime.nativeAdmission = nil
    Runtime.targetCountCache = nil
    Runtime.clipTremorsForcequake = false

    -- Key-up is not a world/session reset. Keep authoritative proc/effect
    -- observation edges and the combat cursor alive across activation-key idle.
    if preserve_observations ~= true then
        Runtime.sessionPlayerHandle = nil
        Runtime.sessionActorEpoch = nil
        Runtime.combatCursor = nil
        Runtime.pressureTracker:reset()
        Runtime.targetCountVisualSignature = nil
        Runtime.targetCountVisualNextAt = 0.0
        Runtime.mobilityBarNextAt = 0.0
        Runtime.mobilityBarDiagnostic = nil
        Runtime.lastDecisionLogKey = nil
        Runtime.lastNoDecisionDiagnosticAt = 0.0
        Runtime.tidal.activeLastTick = false
        Runtime.tidal.lastRemaining = nil
        Runtime.tidal.readyAt = 0.0
        Runtime.tidal.readyKnown = false
        Runtime.tidal.lastObservedProcAt = nil
        Runtime.tidal.effectConsumed = false
        Runtime.tidal.observedClaim = nil
        Runtime.clamoring.charges = 0
        Runtime.clamoring.observed = nil
        for rule_index = 1, #ProcRules do
            clear_proc_grant(ProcRules[rule_index], "observation_reset")
        end
    end
    clear_mobility_bar_plan()
end
local function log_decision_state(state, phase, detail)
    if not Config.decisionLog then
        return
    end

    local current_name = state.currentAction and state.currentAction.name or "-"
    local moving_text = state.movementKnown and bool_text(state.moving) or "unknown"
    local gcd_text = type(state.gcdRemaining) == "number" and
        string.format("%.3f", state.gcdRemaining) or "unknown"
    local pressure = state.selfPressure
    local idf_band = type(pressure) == "table" and pressure.risk_band or nil
    local idf_p2 = type(pressure) == "table" and pressure.projected_hp_2s or nil
    local idf_ttd = type(pressure) == "table" and pressure.ttd or nil
    local key = table.concat({
        phase,
        tostring(detail or "-"),
        tostring(state.target.handle or "-"),
        tostring(state.relevantTargets),
        tostring(state.forcequakeTargets),
        moving_text,
        bool_text(state.buffs.tidal.present),
        tostring(state.buffs.forceGust.status or "unknown"),
        bool_text(state.buffs.forceGust.present),
        current_name,
        tostring(idf_band or "-"),
        tostring(idf_p2 or "-"),
        tostring(idf_ttd or "-"),
        Runtime.burst.mode,
        Runtime.burst.step,
        tostring(Runtime.burst.readiness),
        tostring(Runtime.burst.blockedReason or "-"),
    }, "|")

    if Runtime.lastDecisionLogKey == key then
        return
    end
    Runtime.lastDecisionLogKey = key

    local speed_text = type(state.speed) == "number" and
        string.format("%.3f", state.speed) or "unknown"
    log_debug("state: phase=" .. phase ..
        " detail=" .. tostring(detail or "-") ..
        " target=" .. tostring(state.target.handle or "-") ..
        " reaction=" .. tostring(state.target.reaction or "-") ..
        " moving=" .. moving_text ..
        " speed=" .. speed_text ..
        " gcd=" .. gcd_text ..
        " current=" .. current_name ..
        " targets_fr=" .. tostring(state.relevantTargets) ..
        " targets_fq=" .. tostring(state.forcequakeTargets) ..
        " source=" .. tostring(state.targetCountSource) ..
        " durable=" .. bool_text(target_is_durable(state)) ..
        " tidal=" .. bool_text(state.buffs.tidal.present) ..
        " force_gust=" .. tostring(state.buffs.forceGust.status or "unknown") ..
        "/" .. bool_text(state.buffs.forceGust.present) ..
        " tidal_ready_in=" .. string.format("%.2f",
            math.max(0.0, Runtime.tidal.readyAt - state.now)) ..
        " idf_band=" .. tostring(idf_band or "-") ..
        " idf_p2=" .. (type(idf_p2) == "number" and
            string.format("%.3f", idf_p2) or "-") ..
        " idf_ttd=" .. (type(idf_ttd) == "number" and
            string.format("%.2f", idf_ttd) or "-") ..
        " burst_mode=" .. Runtime.burst.mode ..
        " burst_step=" .. Runtime.burst.step ..
        " burst_percent=" .. tostring(Runtime.burst.readiness) ..
        " burst_blocked=" .. tostring(Runtime.burst.blockedReason or "-"))
end

local Route = {}

local function choose_action(state, loadout)
    -- Normal priority already contains these two survival/pressure actions.
    -- Burst/pooling has its own selector, so preflight them here as well:
    -- Reserved Light remains first refusal; IDF alone owns Mental Alacrity.
    if Runtime.burst.mode ~= "idle" or Config.telekineticsBurstPooling == true then
        local reserved = select_reserved_light_self_heal(state)
        if reserved then return reserved, reserved.reason end
        local mental_alacrity = select_idf_mental_alacrity(state)
        if mental_alacrity then return mental_alacrity, mental_alacrity.reason end
    end
    if Runtime.burst.mode == "active" then
        return select_burst_action(state)
    end
    if Runtime.burst.mode == "armed" or Config.telekineticsBurstPooling == true then
        return select_burst_pool_action(state, loadout)
    end
    local selected = select_priority_action(state)
    return selected, selected and selected.reason or "no_castable_priority"
end
local function choose_with_native_admission(state, loadout)
    local intent = Runtime.nativeAdmission
    if intent == nil then return choose_action(state, loadout) end
    local world_target = intent.worldTargetHandle or intent.targetHandle
    local snapshot = ability_state(state, intent.ability)
    if world_target ~= state.target.handle or
        Runtime.burst.mode ~= intent.burstMode or
        Runtime.burst.step ~= intent.burstStep or
        snapshot.abilityHandle ~= intent.abilityHandle then
        Runtime.nativeAdmission = nil
        return choose_action(state, loadout)
    end

    local submission_pending = snapshot.submissionPending
    snapshot.submissionPending = false
    local selected, reason = choose_action(state, loadout)
    snapshot.submissionPending = submission_pending

    local selected_handle = selected and selected.options.selfTarget == true and
        unit_handle(state.playerUnit) or state.target.handle
    if selected == nil or selected.ability ~= intent.ability or
        selected_handle ~= intent.targetHandle then
        Runtime.nativeAdmission = nil
    end
    return selected, reason
end

local function pending_owner()
    if not Executor:owns_command() then
        return nil
    end
    local status = Executor:status()
    local key = type(status) == "table" and status.idempotency_key or nil
    return type(key) == "string" and key:match("^([^:]+):") or "unknown"
end

local function cancel_owned_telekinetics(reason)
    if pending_owner() ~= "telekinetics" then
        return false
    end
    Executor:cancel(reason)
    return pending_owner() == "telekinetics"
end

function Route.configure(config)
    if type(config) == "table" then
        Config = config
    end
end

function Route.is_selected(loadout)
    return loadout_match(loadout)
end

function Route.owns_pending()
    return pending_owner() == "telekinetics"
end

function Route.burst_active()
    return burst_active()
end

function Route.blocks_cleanse()
    local handle = Executor:owns_command() and Executor:status().command_handle or nil
    local tracked = handle and Runtime.commandWatches[handle] or nil
    return tracked ~= nil and (tracked.kind == "wave" or tracked.kind == "ground")
end

function Route.clear_native_admission()
    Runtime.nativeAdmission = nil
end

function Route.forcequake_target_count(world, target, now)
    return forcequake_target_count(world, target, now or now_seconds())
end

function Route.stop(reason)
    reset_burst(reason)
    if Executor:owns_command() then
        if not Route.owns_pending() then
            reset_transient_state()
            return false
        end
        Executor:cancel(reason)
        if Executor:owns_command() then
            return Route.owns_pending()
        end
    end
    reset_transient_state()
    return false
end

function Route.tick(loadout, rotation_active, burst_pressed)
    local loadout_ok, loadout_reason = loadout_match(loadout)
    if not loadout_ok then
        reset_burst("loadout_gate:" .. loadout_reason)
        cancel_owned_telekinetics("loadout_gate:" .. loadout_reason)
        reset_transient_state()
        log_loadout_state(loadout_reason)
        return
    end
    log_loadout_state("ready")

    local state = read_state(loadout)
    local player_handle = unit_handle(state.playerUnit)
    local actor_epoch = state.world and state.world.actor_epoch or nil
    local player_changed = type(player_handle) == "string" and
        Runtime.sessionPlayerHandle ~= nil and Runtime.sessionPlayerHandle ~= player_handle
    local epoch_changed = actor_epoch ~= nil and Runtime.sessionActorEpoch ~= nil and
        Runtime.sessionActorEpoch ~= actor_epoch
    if player_changed or epoch_changed then
        cancel_owned_telekinetics("telekinetics_session_changed")
        reset_transient_state()
        Runtime.sessionPlayerHandle, Runtime.sessionActorEpoch =
            player_handle, actor_epoch
        if Executor:owns_command() then return end
    end
    if type(player_handle) ~= "string" then
        if not rotation_active and not burst_active() then
            Route.stop("rotation_inactive")
        end
        log_decision_state(state, "waiting_observation", "player_unavailable")
        return
    end
    Runtime.sessionPlayerHandle = player_handle
    if actor_epoch ~= nil then Runtime.sessionActorEpoch = actor_epoch end
    update_player_activations(state)
    update_tidal_observation(state)
    update_clamoring_observation(state)

    if burst_pressed then
        Runtime.burst.pressPending = true
    end
    local active = rotation_active or burst_active()

    local target_problem = burst_target_problem(state)
    if target_problem then
        reset_burst(target_problem, state)
        cancel_owned_telekinetics("telekinetics_burst_" .. target_problem)
        return
    end

    if not active then
        if Executor:owns_command() then
            local owner = pending_owner()
            if owner == "telekinetics" then
                -- release_command either cancels the still-queued bridge call
                -- or requests one exact native miniqueue cancel; Core remains
                -- owner until the matching game token clear is observed.
                Executor:cancel("rotation_inactive")
            end
            if Executor:owns_command() then
                log_decision_state(state, "inactive",
                    owner == "telekinetics" and "awaiting_command_terminal" or
                    "non_telekinetics_command_pending")
                return
            end
        end
        reset_transient_state(true)
        log_decision_state(state, "inactive", "activation_key_up")
        return
    end

    local command_barrier, started_action = service_command_watches(state)
    if started_action then
        log_decision_state(state, "submitted_activation", "exact_lifecycle")
        return
    end
    if command_barrier then
        log_decision_state(state, "command_barrier", "awaiting_exact_activation")
        return
    end

    if Executor:owns_command() then
        if pending_owner() ~= "telekinetics" then
            log_decision_state(state, "command_pending", "foreign_executor_owner")
            return
        end
        if not Executor:can_replace() then
            log_decision_state(state, "command_pending", "executor_owned")
            return
        end
    end

    if Config.automaticTargetCount and
        (type(state.relevantTargets) ~= "number" or
            type(state.forcequakeTargets) ~= "number") then
        log_decision_state(state, "waiting_observation",
            "target_count:" .. tostring(state.targetCountSource or "unavailable"))
        return
    end
    update_target_count_visual(state)
    update_mobility_bar(state)
    Runtime.burst.readiness = Runtime.burst.mode == "active" and 100 or
        burst_readiness_percent(state, loadout)
    draw_burst_overlay(state)

    if not prepare_burst(state, loadout) then
        return
    end
    draw_burst_overlay(state)

    local target_ok, target_reason = valid_hostile_target(state)
    if not target_ok then
        log_decision_state(state, "waiting_target", target_reason)
        return
    end

    local queueable, queue_reason = can_queue_input(state)
    if not queueable then
        log_decision_state(state, "waiting_lock", queue_reason)
        return
    end

    local selected, selected_reason = choose_with_native_admission(state, loadout)

    if Runtime.burst.mode == "active" and selected == nil and
        selected_reason ~= "burst_casting_or_channeling" then
        Runtime.burst.blockedReason = selected_reason
    else
        Runtime.burst.blockedReason = nil
    end
    draw_burst_overlay(state)

    if not selected then
        if Runtime.burst.mode == "idle" and
            Config.telekineticsBurstPooling ~= true then
            log_no_decision_diagnostics(state)
        end
        log_decision_state(state, "no_decision", selected_reason)
        return
    end

    log_decision_state(state, "selected", selected.ability.id .. ":" .. selected.reason)
    submit_action(state, selected)
end

function M.new(executor)
    assert(type(executor) == "table" and type(executor.submit) == "function" and
        type(executor.status) == "function",
        "sage.telekinetics.new requires the top-level AbilityExecutor")
    Executor = executor

    -- require() can keep this module alive across script reloads/test worlds.
    -- A newly bound executor is a new route lifetime: never inherit event
    -- cursors, proc edges, or overlay cadence from the previous instance.
    reset_transient_state()
    log_debug("telekinetics route bind: runtime reset")
    Runtime.burst.mode = "idle"
    Runtime.burst.step = "weaken_mind"
    Runtime.burst.targetHandle = nil
    Runtime.burst.pressPending = false
    Runtime.burst.readiness = 0
    Runtime.burst.blockedReason = nil
    Runtime.burst.justCompleted = false
    return Route
end

return M
