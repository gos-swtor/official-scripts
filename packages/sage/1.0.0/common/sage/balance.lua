-- Capability-driven Balance route for scripts/live/sage.lua.
--
-- The selected loadout is the authority for both the discipline and every
-- ability used here. Missing loadout, effect, cooldown, resource, movement, or
-- target data leaves the route inert.

local Mirror = require("sage.mirror")
local M = {}
local CurrentLoadout

local EXPECTED_STYLE = "sage"
local EXPECTED_DISCIPLINE = "Balance"
local OWNER_PREFIX = "balance:"
local METERS_PER_WORLD_UNIT = 10.0
local READY_SLACK = 0.04
-- The 7.9 static route clips the 18-second DoTs to keep its 15-second cycle.
local DOT_REFRESH_SECONDS = 3.0
local PRESENCE_MAX_STACKS = 4
-- One 1.5s instant GCD plus the observed ~2.2s full Throw rebuilds four stacks.
-- Project plus immediate Sever Force and Weaken Mind reapplication is 3 GCDs.
local TEACHINGS_REAPPLY_SECONDS = 4.5
local FORCE_IN_BALANCE_RADIUS_METERS = 5.0
local FORCEQUAKE_RADIUS_METERS = 8.0
local DOT_SPREAD_MIN_TARGETS = 2
local FORCEQUAKE_FILLER_MIN_TARGETS = 2
local FORCEQUAKE_PRIORITY_MIN_TARGETS = 4
local REJUVENATE = "Rejuvenate"
local MENDING_FORCE_ARMOR = "Mending Force Armor"
-- Match Seer's proven cross-discipline/cross-faction shield contract. Core can
-- expose the lockout under its historical name or as a same-name debuff.
local FORCE_ARMOR_BLOCKING_BUFFS = {
    "Preserved Force Armor",
    "Mending Force Armor",
    "Force Armor",
    "Static Barrier",
    "Soothing Protection",
}
local FORCE_ARMOR_BLOCKING_DEBUFFS = {
    "Force-imbalanced",
    "Deionized",
    "Preserved Force Armor",
    "Mending Force Armor",
    "Force Armor",
    "Static Barrier",
}
local SORCERER_ARMOR_BLOCKERS = {
    { "Imbued Force Armor", "buff" }, { "Imbued Force Armor", "debuff" },
    { "Sustaining Darkness", "buff" },
}
local HOSTILE_UNITS_FILTER = { reaction = "hostile" }
local TIMED_DEBUFF_FILTER = { kind = "debuff", timed = true }

local Ability = {
    ["Mind Crush"] = { range = 30, stationary = true },
    ["Vanquish"] = { range = 30, stationary = true },
    ["Sever Force"] = { range = 30, stationary = false },
    ["Weaken Mind"] = { range = 30, stationary = false },
    ["Force in Balance"] = {
        range = 30,
        stationary = false,
        groundTarget = true,
    },
    ["Shifted Balance"] = { range = 30, stationary = false },
    -- Force Mobility has been baseline for Balance since 7.3.1.
    ["Force Serenity"] = { range = 30, stationary = false },
    ["Forcequake"] = {
        range = 30,
        stationary = true,
        groundTarget = true,
    },
    ["Telekinetic Throw"] = { range = 30, stationary = true },
    ["Disturbance"] = { range = 30, stationary = true },
    ["Destructive Wave"] = { range = 30, stationary = true },
    ["Project"] = { range = 30, stationary = false },
    ["Telekinetic Blitz"] = { range = 30, stationary = false },
    [REJUVENATE] = { range = 30, stationary = false },
    [MENDING_FORCE_ARMOR] = { range = 30, stationary = false },
}

local RequiredAbilities = {
    "Sever Force",
    "Weaken Mind",
    "Force Serenity",
    "Telekinetic Throw",
}

local function safe_method(unit, name, ...)
    if not unit then
        return nil, nil, "owner_unavailable"
    end
    if type(unit[name]) ~= "function" then
        return nil, nil, "method_unavailable"
    end
    local ok, a, b = pcall(unit[name], unit, ...)
    if not ok then
        return nil, nil, "call_failed"
    end
    return a, b, nil
end

local function emit(options, level, message)
    local logger = type(options) == "table" and options.logLine or nil
    if type(logger) == "function" then
        logger(level, message)
    end
end

local function emit_diagnostic(options, level, message)
    if type(options) ~= "table" or options.decisionLog ~= true then
        return false
    end
    emit(options, level, message)
    return true
end

local function number_text(value, decimals)
    if type(value) ~= "number" then
        return "?"
    end
    return string.format("%." .. tostring(decimals or 0) .. "f", value)
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

local function selected_suppression_ability(known)
    if type(known) ~= "table" then
        return nil
    end
    if known["Shifted Balance"] == true then
        return "Shifted Balance"
    end
    if known["Force in Balance"] == true then
        return "Force in Balance"
    end
    return nil
end

local function selected_primary_dot(known)
    if type(known) ~= "table" then
        return nil, nil
    end
    if known["Vanquish"] == true then
        -- The direct ability also applies a long Vulnerable-family debuff named
        -- "Vanquish". The actual periodic damage effect exposed by the live
        -- EffectScanner is "Crushed (Vanquish)".
        return "Vanquish", "Crushed (Vanquish)"
    end
    if known["Mind Crush"] == true then
        -- EffectScanner exposes abl.jedi_consular.mind_blast by this name.
        return "Mind Crush", "Mind Blast"
    end
    return nil, nil
end

local function selected_presence_filler(known)
    if type(known) ~= "table" then
        return nil
    end
    if known["Destructive Wave"] == true then
        return "Destructive Wave"
    end
    if known["Disturbance"] == true then
        return "Disturbance"
    end
    return nil
end

local function is_selected(loadout)
    loadout = Mirror.adapt_loadout(loadout)
    return type(loadout) == "table" and loadout.status == "ready" and
        loadout.combat_style == EXPECTED_STYLE and
        loadout.discipline == EXPECTED_DISCIPLINE
end

local function validated_loadout(loadout)
    loadout = Mirror.adapt_loadout(loadout)
    if type(loadout) ~= "table" then
        return nil, "loadout", "snapshot", "invalid_response"
    end
    if loadout.status ~= "ready" then
        return nil, "loadout", "status", tostring(loadout.status or "missing")
    end
    if loadout.combat_style ~= EXPECTED_STYLE then
        return nil, "loadout", "combat_style",
            tostring(loadout.combat_style or "missing")
    end
    if loadout.discipline ~= EXPECTED_DISCIPLINE then
        return nil, "loadout", "discipline",
            tostring(loadout.discipline or "missing")
    end
    if type(loadout.known) ~= "table" then
        return nil, "loadout", "known", "unavailable"
    end
    for _, name in ipairs(RequiredAbilities) do
        if loadout.known[name] ~= true then
            return nil, "loadout", name, "not_known"
        end
    end
    local suppression = selected_suppression_ability(loadout.known)
    local primary_dot, primary_effect = selected_primary_dot(loadout.known)
    local presence_filler = selected_presence_filler(loadout.known)
    if suppression == nil then
        return nil, "loadout", "suppression", "choice_unavailable"
    end
    if primary_dot == nil then
        return nil, "loadout", "primary_dot", "choice_unavailable"
    end
    if presence_filler == nil then
        return nil, "loadout", "presence_filler", "choice_unavailable"
    end
    return {
        suppression = suppression,
        primaryDot = primary_dot,
        primaryEffect = primary_effect,
        presenceFiller = presence_filler,
    }
end

local function effect_state(unit, name, options, literal_name)
    local actual = name
    if not literal_name then actual, options = Mirror.effect_query(CurrentLoadout, name, options) end
    if actual == nil then return nil, "mirror_name_unavailable" end
    local effect, _, call_error = safe_method(unit, "effect", actual, options)
    if call_error ~= nil then
        return nil, call_error
    end
    if type(effect) ~= "table" then
        return nil, "invalid_result"
    end
    if effect.status ~= "ready" then
        return nil, "status_" .. tostring(effect.status or "missing") ..
            "_" .. tostring(effect.reason or "unspecified"),
            " effect_status=" .. tostring(effect.status or "missing") ..
            " effect_reason=" .. tostring(effect.reason or "unspecified") ..
            " effect_age_ms=" .. number_text(effect.age_ms, 0) ..
            " effect_truncated=" .. tostring(effect.truncated == true) ..
            " effect_producer_stage=" .. tostring(effect.producer_stage or "none") ..
            " effect_producer_operation=" .. tostring(effect.producer_operation or "none") ..
            " effect_producer_method=" .. tostring(effect.producer_method or "none") ..
            " effect_producer_node=" .. tostring(effect.producer_node or "none") ..
            " effect_producer_list_index=" .. tostring(effect.producer_list_index) ..
            " effect_producer_effect_index=" .. tostring(effect.producer_effect_index) ..
            " effect_producer_field_index=" .. tostring(effect.producer_field_index) ..
            " effect_producer_item_index=" .. tostring(effect.producer_item_index)
    end
    return {
        present = effect.present == true,
        mine = effect.mine == true,
        hasCharges = effect.has_charges == true,
        chargeConflicted = effect.charge_conflicted == true,
        stacks = type(effect.stacks) == "number" and effect.stacks or nil,
        remaining = type(effect.remaining) == "number" and
            math.max(0.0, effect.remaining) or nil,
        kind = effect.kind,
        status = effect.status,
        reason = effect.reason,
        ageMs = type(effect.age_ms) == "number" and effect.age_ms or nil,
        truncated = effect.truncated == true,
    }
end

local function armor_allowed(unit)
    local sorcerer = CurrentLoadout and CurrentLoadout._sage_mirror_style == "sorcerer"
    if sorcerer then
        for _, blocker in ipairs(SORCERER_ARMOR_BLOCKERS) do
            local effect, reason, diagnostic = effect_state(unit, blocker[1], { kind = blocker[2] }, true)
            if effect == nil then return nil, blocker[1] .. ":" .. tostring(reason), diagnostic end
            if effect.present then return false end
        end
    end
    -- Query both factions literally so another healer's shield is never renamed.
    for _, name in ipairs(FORCE_ARMOR_BLOCKING_DEBUFFS) do
        local effect, reason, diagnostic =
            effect_state(unit, name, { kind = "debuff" }, true)
        if effect == nil then
            return nil, name .. ":" .. tostring(reason), diagnostic
        end
        if effect.present then return false, name .. ":debuff" end
    end
    for _, name in ipairs(FORCE_ARMOR_BLOCKING_BUFFS) do
        local effect, reason, diagnostic =
            effect_state(unit, name, { kind = "buff" }, true)
        if effect == nil then
            return nil, name .. ":" .. tostring(reason), diagnostic
        end
        if effect.present then return false, name .. ":buff" end
    end
    return true, nil
end

local function effect_diagnostic_detail(effect)
    return " effect_status=" .. tostring(effect and effect.status or "missing") ..
        " effect_reason=" .. tostring(effect and effect.reason or "unspecified") ..
        " effect_age_ms=" .. number_text(effect and effect.ageMs or nil, 0) ..
        " effect_truncated=" .. tostring(effect and effect.truncated == true) ..
        " effect_charge_conflicted=" ..
            tostring(effect and effect.chargeConflicted == true)
end

local function effect_presence_text(effect)
    return effect == nil and "unavailable" or tostring(effect.present)
end

local function owned_active(effect)
    return effect ~= nil and effect.present and effect.mine and
        type(effect.remaining) == "number" and effect.remaining > 0
end

local function ability_state(name, current_cast, throw_active)
    local actual = Mirror.ability(CurrentLoadout, name)
    if actual == nil then return nil, "mirror_name_unavailable" end
    local info = gos.abilities.info(actual)
    local cooldown = gos.abilities.cooldown_remaining(actual)
    if type(info) ~= "table" then
        return nil, "info_invalid"
    end
    if type(info.ability_handle) ~= "string" then
        return nil, "ability_handle_unavailable"
    end
    if name == "Telekinetic Throw" and
        type(info.activation_handle) ~= "string" then
        return nil, "activation_handle_unavailable"
    end
    local current_throw = name == "Telekinetic Throw" and
        (throw_active == true or
            (type(current_cast) == "table" and
                type(current_cast.abilityHandle) == "string" and
                current_cast.abilityHandle == info.activation_handle))
    if (info.has_resource_cost ~= true or
            type(info.resource_cost) ~= "number") and not current_throw then
        return nil, "resource_cost_unavailable"
    end

    if type(cooldown) ~= "number" and not current_throw then
        return nil, "cooldown_unavailable"
    end
    return {
        handle = info.ability_handle,
        activationHandle = type(info.activation_handle) == "string" and
            info.activation_handle or nil,
        submissionPending = info.submission_pending == true,
        cooldown = type(cooldown) == "number" and
            math.max(0.0, cooldown) or nil,
        cooldownKnown = type(cooldown) == "number",
        cooldownDuration = type(info.cooldown_duration) == "number" and
            math.max(0.0, info.cooldown_duration) or nil,
        gcdDuration = type(info.gcd_duration) == "number" and
            math.max(0.0, info.gcd_duration) or nil,
        usesGlobalCooldown = type(info.uses_global_cooldown) == "boolean" and
            info.uses_global_cooldown or nil,
        cost = info.resource_cost,
    }
end

local function request_selected_ability_metadata(loadout, selection, options)
    local function request(name)
        local actual = Mirror.ability(CurrentLoadout, name)
        if actual ~= nil then gos.abilities.info(actual) end
    end
    request(selection.primaryDot)
    request(selection.presenceFiller)
    request(selection.suppression)
    for _, name in ipairs(RequiredAbilities) do
        request(name)
    end
    if loadout.known["Forcequake"] == true then
        request("Forcequake")
    end
    if loadout.known["Project"] == true then
        request("Project")
    end
    if loadout.known["Telekinetic Blitz"] == true then
        request("Telekinetic Blitz")
    end
    if type(options) == "table" and options.movingRejuvenate == true and
        loadout.known[REJUVENATE] == true then
        request(REJUVENATE)
    end
    if type(options) == "table" and options.selfArmor == true and
        loadout.known[MENDING_FORCE_ARMOR] == true then
        request(MENDING_FORCE_ARMOR)
    end
end

local function current_cast_state()
    local current = gos.abilities.current_cast()
    if type(current) ~= "table" or
        (type(current.name) ~= "string" and
         type(current.ability_handle) ~= "string") then
        return nil
    end
    return {
        name = type(current.name) == "string" and
            Mirror.canonical(CurrentLoadout, current.name) or nil,
        abilityHandle = type(current.ability_handle) == "string" and
            current.ability_handle or nil,
        remaining = type(current.remaining) == "number" and
            math.max(0.0, current.remaining) or nil,
    }
end

local function unit_position(unit)
    local position = safe_method(unit, "position")
    if type(position) ~= "table" or type(position.x) ~= "number" or
        type(position.y) ~= "number" or type(position.z) ~= "number" then
        return nil
    end
    return position
end

local function squared_distance_meters(a, b)
    if not a or not b then
        return nil
    end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return (dx * dx + dy * dy + dz * dz) *
        METERS_PER_WORLD_UNIT * METERS_PER_WORLD_UNIT
end

local function read_target_clusters(world, target, spread_enabled, max_spread,
        direct_spread_radius, forcequake_radius, forcequake_min_targets)
    local target_position = unit_position(target)
    if not target_position then
        return nil, "target_position_unavailable"
    end
    local units, _, units_error = safe_method(
        world, "units", HOSTILE_UNITS_FILTER)
    if units_error ~= nil then
        return nil, "hostile_units_" .. units_error
    end
    if type(units) ~= "table" then
        return nil, "hostile_units_invalid_result"
    end

    local cluster = {
        forceInBalanceTargets = 1,
        forcequakeTargets = 1,
        spreadNeeded = false,
        spreadObservationPending = false,
        directSpreadObservationPending = false,
        forcequakeMinTargets = forcequake_min_targets,
        forcequakePriorityTargets = math.max(
            FORCEQUAKE_PRIORITY_MIN_TARGETS, forcequake_min_targets),
    }
    for _, unit in ipairs(units) do
        if unit ~= target then
            local hp = safe_method(unit, "hp")
            local distance_squared = squared_distance_meters(
                unit_position(unit), target_position)
            if type(hp) == "table" and type(hp.current) == "number" and
                hp.current > 0 and type(distance_squared) == "number" then
                if distance_squared <= forcequake_radius ^ 2 then
                    cluster.forcequakeTargets = cluster.forcequakeTargets + 1
                end
                if distance_squared <= FORCE_IN_BALANCE_RADIUS_METERS ^ 2 then
                    cluster.forceInBalanceTargets =
                        cluster.forceInBalanceTargets + 1
                end

                local in_native_spread = spread_enabled and
                    distance_squared <= FORCE_IN_BALANCE_RADIUS_METERS ^ 2
                local in_direct_spread = max_spread and
                    distance_squared <= direct_spread_radius ^ 2
                if in_native_spread or in_direct_spread then
                    local weaken_mind, weaken_mind_error =
                        effect_state(unit, "Weaken Mind",
                        TIMED_DEBUFF_FILTER)
                    local sever_force, sever_force_error =
                        effect_state(unit, "Sever Force",
                        TIMED_DEBUFF_FILTER)
                    if weaken_mind == nil or sever_force == nil then
                        if cluster.observationReason == nil then
                            cluster.observationReason = weaken_mind == nil and
                                ("Weaken Mind:" ..
                                    tostring(weaken_mind_error or "unavailable")) or
                                ("Sever Force:" ..
                                    tostring(sever_force_error or "unavailable"))
                            cluster.observationHandle =
                                safe_method(unit, "handle")
                        end
                        if in_native_spread then
                            cluster.spreadObservationPending = true
                        end
                        if in_direct_spread then
                            cluster.directSpreadObservationPending = true
                        end
                    else
                        local missing_weaken_mind =
                            not owned_active(weaken_mind)
                        local missing_sever_force =
                            not owned_active(sever_force)
                        local missing_count =
                            (missing_weaken_mind and 1 or 0) +
                            (missing_sever_force and 1 or 0)
                        if in_native_spread and missing_count > 0 then
                            cluster.spreadNeeded = true
                        end
                        if in_direct_spread and missing_count > 0 then
                            local handle = safe_method(unit, "handle")
                            local player_distance = safe_method(unit, "distance")
                            local player_distance_meters =
                                type(player_distance) == "number" and
                                player_distance * METERS_PER_WORLD_UNIT or nil
                            local better = type(handle) == "string" and
                                type(player_distance_meters) == "number" and
                                player_distance_meters <= Ability["Sever Force"].range and
                                (cluster.directSpreadTarget == nil or
                                    missing_count > cluster.directSpreadMissingCount or
                                    (missing_count == cluster.directSpreadMissingCount and
                                        (distance_squared <
                                            cluster.directSpreadDistanceSquared or
                                            (distance_squared ==
                                                cluster.directSpreadDistanceSquared and
                                                handle < cluster.directSpreadHandle))))
                            if better then
                                cluster.directSpreadTarget = unit
                                cluster.directSpreadHandle = handle
                                cluster.directSpreadAbility =
                                    missing_sever_force and "Sever Force" or
                                        "Weaken Mind"
                                cluster.directSpreadMissingCount = missing_count
                                cluster.directSpreadDistanceSquared =
                                    distance_squared
                                cluster.directSpreadPlayerDistance =
                                    player_distance_meters
                            end
                        end
                    end
                end
            end
        end
    end
    return cluster, nil
end

local function draw_max_spread_range(options, target, radius)
    if type(options) ~= "table" or options.maxSpread ~= true or not target or
        not gos.overlay or type(gos.overlay.draw_circle) ~= "function" then
        return
    end
    gos.overlay.draw_circle("balance_spread_range", {
        at = { unit = target, anchor = "origin" },
        world_radius = radius / METERS_PER_WORLD_UNIT,
        color = "cyan",
        segments = 64,
        thickness = 2.0,
        ttl = 0.25,
    })
    gos.overlay.draw_circle("balance_spread_mode_target", {
        at = { unit = target, anchor = "center" },
        radius = 24,
        color = "cyan",
        segments = 32,
        thickness = 2.0,
        ttl = 0.25,
    })
    if type(gos.overlay.draw_text) == "function" then
        local key = type(options.spreadKey) == "string" and
            options.spreadKey or ""
        gos.overlay.draw_text("balance_spread_mode_text", {
            at = { unit = target, anchor = "top",
                pixel_offset = { x = 0, y = -48 } },
            text = key ~= "" and
                ("MAX SPREAD  [" .. string.upper(key) .. "]") or
                "MAX SPREAD",
            color = "cyan",
            font_size = 14,
            center_x = true,
            ttl = 0.25,
        })
    end
end

local function draw_max_spread_candidate(options, cluster)
    local target = cluster and cluster.directSpreadTarget or nil
    if type(options) ~= "table" or options.maxSpread ~= true or not target or
        not gos.overlay or type(gos.overlay.draw_circle) ~= "function" then
        return
    end
    gos.overlay.draw_circle("balance_spread_candidate", {
        at = { unit = target, anchor = "center" },
        radius = 18,
        color = "orange",
        segments = 32,
        thickness = 2.0,
        ttl = 0.25,
    })
end

local function read_state(loadout, selection, options, world, cluster,
        cluster_error, throw_active)
    if not world then
        return nil, "world", "snapshot", "unavailable"
    end
    local player = world and world.player or nil
    local target = world and world.current_target or nil
    if not player then
        return nil, "world", "player", "unavailable"
    end
    if not target then
        return nil, "world", "current_target", "unavailable"
    end

    local target_handle, _, target_handle_error = safe_method(target, "handle")
    local player_handle, _, player_handle_error = safe_method(player, "handle")
    local reaction, _, reaction_error = safe_method(target, "reaction")
    local hp, _, hp_error = safe_method(target, "hp")
    local distance, _, distance_error = safe_method(target, "distance")
    local resource, _, resource_error = safe_method(player, "resource")
    local speed, _, speed_error = safe_method(player, "speed")
    local gcd = gos.abilities.gcd_remaining()
    local now_ms = gos.time_ms()
    local busy = gos.abilities.is_casting_or_channeling()
    if type(target_handle) ~= "string" then
        return nil, "target", "handle", target_handle_error or "invalid"
    end
    if type(player_handle) ~= "string" then
        return nil, "player", "handle", player_handle_error or "invalid"
    end
    if reaction ~= "hostile" then
        return nil, "target", "reaction",
            reaction_error or tostring(reaction or "unavailable")
    end
    if type(hp) ~= "table" or type(hp.current) ~= "number" then
        return nil, "target", "hp", hp_error or "invalid"
    end
    if hp.current <= 0 then
        return nil, "target", "hp", "dead"
    end
    if type(distance) ~= "number" then
        return nil, "target", "distance", distance_error or "invalid"
    end
    if type(resource) ~= "table" or type(resource.current) ~= "number" then
        return nil, "player", "resource", resource_error or "invalid"
    end
    if type(speed) ~= "number" then
        return nil, "player", "speed", speed_error or "invalid"
    end
    if type(gcd) ~= "number" then
        return nil, "abilities", "gcd", "unavailable"
    end
    if type(busy) ~= "boolean" then
        return nil, "abilities", "busy", "unavailable"
    end
    if type(now_ms) ~= "number" then
        return nil, "time", "milliseconds", "unavailable"
    end

    local primary_dot, primary_dot_error, primary_dot_diagnostic = effect_state(
        target, selection.primaryEffect, { kind = "debuff", timed = true })
    if primary_dot == nil then
        return nil, "effect", selection.primaryEffect,
            primary_dot_error or "unavailable", primary_dot_diagnostic
    end
    local sever_force, sever_force_error, sever_force_diagnostic = effect_state(
        target, "Sever Force", { kind = "debuff", timed = true })
    if sever_force == nil then
        return nil, "effect", "Sever Force",
            sever_force_error or "unavailable", sever_force_diagnostic
    end
    local weaken_mind, weaken_mind_error, weaken_mind_diagnostic = effect_state(
        target, "Weaken Mind", { kind = "debuff", timed = true })
    if weaken_mind == nil then
        return nil, "effect", "Weaken Mind",
            weaken_mind_error or "unavailable", weaken_mind_diagnostic
    end
    local presence, presence_error, presence_diagnostic = effect_state(
        player, "Presence of Mind", { timed = true, charged = true })
    if presence == nil then
        return nil, "effect", "Presence of Mind",
            presence_error or "unavailable", presence_diagnostic
    end
    if presence.present and
        (not presence.hasCharges or type(presence.stacks) ~= "number") then
        return nil, "effect", "Presence of Mind",
            presence.chargeConflicted and "charges_conflicted" or
                "charges_unavailable",
            effect_diagnostic_detail(presence)
    end

    local moving_rejuvenate = type(options) == "table" and
        options.movingRejuvenate == true and
        loadout.known[REJUVENATE] == true
    local rejuvenate_hp_percent = type(options) == "table" and
        type(options.rejuvenateHpPercent) == "number" and
        math.max(1, math.min(100,
            math.floor(options.rejuvenateHpPercent + 0.5))) or 90
    local self_armor = type(options) == "table" and
        options.selfArmor == true and
        loadout.known[MENDING_FORCE_ARMOR] == true
    local player_hp_percent = nil
    local rejuvenate = nil
    local force_armor_allowed = nil
    local force_armor_blocker = nil
    local support_faults = {}
    if moving_rejuvenate and speed ~= 0 then
        local player_hp, _, player_hp_error = safe_method(player, "hp")
        if type(player_hp) == "table" and
            type(player_hp.percent) == "number" then
            player_hp_percent = player_hp.percent
        else
            support_faults[#support_faults + 1] =
                "player_hp:" .. tostring(player_hp_error or "percent_unavailable")
        end
        local rejuvenate_error
        rejuvenate, rejuvenate_error = effect_state(
            player, REJUVENATE, { kind = "buff", timed = true })
        if rejuvenate == nil then
            support_faults[#support_faults + 1] =
                REJUVENATE .. "_effect:" ..
                    tostring(rejuvenate_error or "unavailable")
        end
    end
    if self_armor then
        local armor_error, armor_diagnostic
        force_armor_allowed, force_armor_blocker, armor_diagnostic =
            armor_allowed(player)
        if force_armor_allowed == nil then
            armor_error = force_armor_blocker
            support_faults[#support_faults + 1] =
                "force_armor:" .. tostring(armor_error or "unavailable") ..
                    tostring(armor_diagnostic or "")
        end
    end

    local state = {
        now = now_ms / 1000.0,
        loadout = loadout,
        player = player,
        playerHandle = player_handle,
        target = target,
        targetHandle = target_handle,
        distance = distance * METERS_PER_WORLD_UNIT,
        force = resource.current,
        moving = speed ~= 0,
        playerHpPercent = player_hp_percent,
        movingRejuvenate = moving_rejuvenate,
        rejuvenateHpPercent = rejuvenate_hp_percent,
        selfArmor = self_armor,
        gcd = math.max(0.0, gcd),
        busy = busy,
        currentCast = current_cast_state(),
        clusterStatus = cluster and "ready" or "unavailable",
        clusterReason = cluster_error,
        clusterObservationReason = cluster and
            cluster.observationReason or nil,
        clusterObservationHandle = cluster and
            cluster.observationHandle or nil,
        forceInBalanceTargets = cluster and
            cluster.forceInBalanceTargets or nil,
        forcequakeTargets = cluster and cluster.forcequakeTargets or nil,
        forcequakeMinTargets = cluster and
            cluster.forcequakeMinTargets or nil,
        forcequakePriorityTargets = cluster and
            cluster.forcequakePriorityTargets or nil,
        spreadNeeded = cluster and cluster.spreadNeeded == true,
        spreadObservationPending = cluster and
            cluster.spreadObservationPending == true,
        directSpreadTarget = cluster and cluster.directSpreadTarget or nil,
        directSpreadHandle = cluster and cluster.directSpreadHandle or nil,
        directSpreadAbility = cluster and cluster.directSpreadAbility or nil,
        directSpreadDistance = cluster and
            cluster.directSpreadPlayerDistance or nil,
        directSpreadObservationPending = cluster and
            cluster.directSpreadObservationPending == true,
        suppressionAbility = selection.suppression,
        primaryDotAbility = selection.primaryDot,
        presenceFillerAbility = selection.presenceFiller,
        teachingsSelected = loadout.known["Teachings of Rajivari"] == true,
        telekineticBlitzSelected =
            loadout.known["Telekinetic Blitz"] == true,
        maxSpread = type(options) == "table" and options.maxSpread == true,
        queueWindow = type(options) == "table" and
            type(options.abilityQueueWindow) == "number" and
            math.max(0.0, options.abilityQueueWindow) or READY_SLACK,
        effects = {
            primaryDot = primary_dot,
            severForce = sever_force,
            weakenMind = weaken_mind,
            presenceOfMind = presence,
            rejuvenate = rejuvenate,
            forceArmorAllowed = force_armor_allowed,
            forceArmorBlocker = force_armor_blocker,
        },
        abilities = {},
        abilityFaults = support_faults,
    }

    local observing_throw = throw_active == true and busy == true

    local function capture_ability(name)
        if state.abilities[name] ~= nil then
            return true
        end
        local snapshot, snapshot_error =
            ability_state(name, state.currentCast, observing_throw)
        if snapshot == nil then
            return false, snapshot_error or "unavailable"
        end
        state.abilities[name] = snapshot
        return true
    end

    for _, name in ipairs(RequiredAbilities) do
        local ready, reason = capture_ability(name)
        if not ready then
            if observing_throw then
                state.abilityFaults[#state.abilityFaults + 1] =
                    name .. ":" .. tostring(reason)
            else
                return nil, "ability", name, reason
            end
        end
    end
    for _, name in ipairs({
        selection.primaryDot,
        selection.presenceFiller,
        selection.suppression,
    }) do
        local ready, reason = capture_ability(name)
        if not ready then
            if observing_throw and name == selection.suppression then
                state.abilityFaults[#state.abilityFaults + 1] =
                    name .. ":" .. tostring(reason)
            else
                return nil, "ability", name, reason
            end
        end
    end
    if loadout.known["Forcequake"] == true then
        local ready, reason = capture_ability("Forcequake")
        if not ready then
            state.abilityFaults[#state.abilityFaults + 1] =
                "Forcequake:" .. tostring(reason)
        end
    end
    if loadout.known["Project"] == true then
        local ready, reason = capture_ability("Project")
        if not ready then
            state.abilityFaults[#state.abilityFaults + 1] =
                "Project:" .. tostring(reason)
        end
    end
    if state.telekineticBlitzSelected then
        local ready, reason = capture_ability("Telekinetic Blitz")
        if not ready then
            state.abilityFaults[#state.abilityFaults + 1] =
                "Telekinetic Blitz:" .. tostring(reason)
        end
    end
    if moving_rejuvenate then
        local ready, reason = capture_ability(REJUVENATE)
        if not ready then
            state.abilityFaults[#state.abilityFaults + 1] =
                REJUVENATE .. ":" .. tostring(reason)
        end
    end
    if self_armor then
        local ready, reason = capture_ability(MENDING_FORCE_ARMOR)
        if not ready then
            state.abilityFaults[#state.abilityFaults + 1] =
                MENDING_FORCE_ARMOR .. ":" .. tostring(reason)
        end
    end
    return state
end

local function dot_due(effect)
    if not effect.present or not effect.mine then
        return true
    end
    return type(effect.remaining) == "number" and
        effect.remaining <= DOT_REFRESH_SECONDS
end

local function can_use(state, name, instant, distance)
    local ability = Ability[name]
    local current = state.abilities[name]
    return ability ~= nil and current ~= nil and
        not current.submissionPending and
        type(current.cooldown) == "number" and
        type(current.cost) == "number" and
        current.cooldown <= READY_SLACK and current.cost <= state.force and
        (distance or state.distance) <= ability.range and
        (not ability.stationary or instant == true or not state.moving)
end

local function telekinetic_throw_active(state)
    if state.presenceThrowActive == true then
        return true
    end
    local current = state.currentCast
    local throw = state.abilities["Telekinetic Throw"]
    return state.busy and current and throw and
        current.abilityHandle == throw.activationHandle
end

local function telekinetic_throw_queue_open(state)
    local current = state.currentCast
    return telekinetic_throw_active(state) and
        type(current) == "table" and
        type(current.remaining) == "number" and
        current.remaining <= state.queueWindow and
        state.gcd <= state.queueWindow
end

local function observed_presence_stacks(state)
    local presence = state.effects.presenceOfMind
    return presence.present and
        type(presence.stacks) == "number" and presence.stacks or 0
end

local function presence_projection(state)
    local observed = observed_presence_stacks(state)
    if observed >= PRESENCE_MAX_STACKS then
        return true, observed, "observed"
    end
    return false, observed, "observed"
end

local function select_action(state)
    local presence_ready, presence_stacks, presence_source =
        presence_projection(state)
    local observed_throw_preempt =
        presence_source == "observed" and
        presence_stacks >= PRESENCE_MAX_STACKS and
        telekinetic_throw_active(state) and
        state.gcd <= state.queueWindow
    local queueing_presence_spender = presence_ready and observed_throw_preempt
    local effects = state.effects
    local suppression = state.suppressionAbility
    local primary_dot = state.primaryDotAbility
    local presence_filler = state.presenceFillerAbility
    local primary_spender_ready = presence_ready and
        can_use(state, primary_dot, true)
    local filler_spender_ready = presence_ready and
        not primary_spender_ready and can_use(state, presence_filler, true)
    local maintained_dots_active = owned_active(effects.severForce) and
        owned_active(effects.weakenMind)
    if state.busy or state.gcd > READY_SLACK then
        if queueing_presence_spender then
            if primary_spender_ready then
                return primary_dot,
                    observed_throw_preempt and
                        "presence_of_mind_vanquish_clip_throw" or
                        "presence_of_mind_vanquish",
                    presence_stacks, presence_source
            end
            if filler_spender_ready then
                return presence_filler,
                    observed_throw_preempt and
                        "presence_of_mind_clip_throw" or "presence_of_mind",
                    presence_stacks, presence_source
            end
        end
        return nil, state.busy and "casting_or_channeling" or "gcd",
            presence_stacks, presence_source
    end

    if state.presenceStackTickReady == true and not presence_ready then
        return nil, "presence_stack_tick_wait_effect",
            presence_stacks, presence_source
    end

    -- Four Presence of Mind stacks are a complete proc and must be spent
    -- before ordinary maintenance/filler work. Vanquish is the preferred
    -- spender whenever it is usable; the filler is only the alternate spender.
    if primary_spender_ready then
        return primary_dot,
            presence_source == "telekinetic_throw_stack_tick_observed" and
                "presence_of_mind_vanquish_stack_tick" or
                "presence_of_mind_vanquish",
            presence_stacks, presence_source
    end
    if filler_spender_ready then
        return presence_filler,
            presence_source == "telekinetic_throw_stack_tick_observed" and
                "presence_of_mind_stack_tick" or "presence_of_mind",
            presence_stacks, presence_source
    end

    if state.selfArmor and
        effects.forceArmorAllowed == true and
        can_use(state, MENDING_FORCE_ARMOR, true, 0) then
        return MENDING_FORCE_ARMOR, "self_armor_ready",
            presence_stacks, presence_source, state.player
    end

    if dot_due(effects.severForce) and can_use(state, "Sever Force") then
        return "Sever Force", "sever_force_refresh", presence_stacks,
            presence_source
    end
    if dot_due(effects.weakenMind) and can_use(state, "Weaken Mind") then
        return "Weaken Mind", "weaken_mind_refresh", presence_stacks,
            presence_source
    end

    if state.teachingsSelected and owned_active(effects.weakenMind) and
        can_use(state, "Force Serenity") then
        return "Force Serenity", "teachings_weaken_mind_active",
            presence_stacks, presence_source
    end

    local cluster_spread_ready = suppression == "Force in Balance" and
        state.spreadNeeded and
        type(state.forceInBalanceTargets) == "number" and
        state.forceInBalanceTargets >= DOT_SPREAD_MIN_TARGETS and
        maintained_dots_active and
        can_use(state, suppression)
    if state.maxSpread and cluster_spread_ready and
        dot_due(effects.primaryDot) and not presence_ready and
        can_use(state, "Telekinetic Throw") then
        return "Telekinetic Throw", "max_spread_presence_builder",
            presence_stacks, presence_source
    end
    if cluster_spread_ready then
        return suppression, "cluster_dot_spread", presence_stacks,
            presence_source
    end

    if maintained_dots_active and can_use(state, suppression) then
        return suppression, "maintained_dots_active", presence_stacks,
            presence_source
    end
    local forcequake_targets = state.forcequakeTargets or 0
    local forcequake_min_targets = state.forcequakeMinTargets or
        FORCEQUAKE_FILLER_MIN_TARGETS
    local forcequake_priority_targets = state.forcequakePriorityTargets or
        FORCEQUAKE_PRIORITY_MIN_TARGETS
    local forcequake_ready =
        forcequake_targets >= forcequake_min_targets and
        can_use(state, "Forcequake")
    if forcequake_targets >= forcequake_priority_targets then
        if presence_ready and forcequake_ready then
            if telekinetic_throw_queue_open(state) then
                return nil, "forcequake_waiting_for_throw_completion",
                    presence_stacks, presence_source
            end
            return "Forcequake", "four_target_aoe_filler", presence_stacks,
                presence_source
        end
        if not presence_ready and can_use(state, "Telekinetic Throw") then
            return "Telekinetic Throw", "aoe_presence_builder",
                presence_stacks, presence_source
        end
    end
    if presence_ready and forcequake_ready then
        if telekinetic_throw_queue_open(state) then
            return nil, "forcequake_waiting_for_throw_completion",
                presence_stacks, presence_source
        end
        return "Forcequake", "multi_target_aoe_filler", presence_stacks,
            presence_source
    end
    if owned_active(effects.weakenMind) and can_use(state, "Force Serenity") then
        return "Force Serenity", "weaken_mind_active", presence_stacks,
            presence_source
    end
    if state.maxSpread and state.directSpreadTarget and
        state.directSpreadAbility and
        can_use(state, state.directSpreadAbility, true,
            state.directSpreadDistance) then
        return state.directSpreadAbility, "max_spread_direct_dot",
            presence_stacks, presence_source, state.directSpreadTarget
    end
    if state.teachingsSelected and maintained_dots_active and
        state.abilities[primary_dot].cooldown > TEACHINGS_REAPPLY_SECONDS and
        state.abilities[suppression].cooldown > TEACHINGS_REAPPLY_SECONDS and
        state.abilities["Force Serenity"].cooldown >
            TEACHINGS_REAPPLY_SECONDS and can_use(state, "Project") then
        return "Project", "teachings_reapply_window", presence_stacks,
            presence_source
    end
    if can_use(state, "Telekinetic Throw") then
        return "Telekinetic Throw", "presence_builder", presence_stacks,
            presence_source
    end
    if state.movingRejuvenate and state.moving and
        type(state.playerHpPercent) == "number" and
        state.playerHpPercent < state.rejuvenateHpPercent and
        effects.rejuvenate ~= nil and dot_due(effects.rejuvenate) and
        can_use(state, REJUVENATE, true, 0) then
        return REJUVENATE, "moving_self_upkeep",
            presence_stacks, presence_source, state.player
    end
    if not state.teachingsSelected and state.moving and
        can_use(state, "Project") then
        return "Project", "moving_filler", presence_stacks, presence_source
    end
    if state.telekineticBlitzSelected and state.moving and
        can_use(state, "Telekinetic Blitz") then
        return "Telekinetic Blitz", "moving_telekinetic_blitz_filler",
            presence_stacks, presence_source
    end
    return nil, "no_castable_priority", presence_stacks, presence_source
end

local function mobility_copy_table(source)
    if type(source) ~= "table" then
        return source
    end
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

local function mobility_copy_state(state)
    local copy = {}
    for key, value in pairs(state) do
        if key ~= "abilities" and key ~= "effects" and key ~= "currentCast" then
            copy[key] = value
        end
    end
    copy.currentCast = mobility_copy_table(state.currentCast)
    copy.abilities = {}
    for name, snapshot in pairs(state.abilities or {}) do
        copy.abilities[name] = mobility_copy_table(snapshot)
    end
    copy.effects = {}
    for name, effect in pairs(state.effects or {}) do
        copy.effects[name] = mobility_copy_table(effect)
    end
    return copy
end

local function mobility_advance_effect(effect, elapsed)
    if type(effect) ~= "table" or elapsed <= 0.0 then
        return
    end
    if effect.present and type(effect.remaining) == "number" then
        effect.remaining = math.max(0.0, effect.remaining - elapsed)
        if effect.remaining <= 0.0 then
            effect.present = false
        end
    end
end

local function mobility_advance_state(state, elapsed)
    if elapsed <= 0.0 then
        return
    end
    state.now = state.now + elapsed
    state.gcd = math.max(0.0, state.gcd - elapsed)
    if state.currentCast and type(state.currentCast.remaining) == "number" then
        state.currentCast.remaining = math.max(0.0,
            state.currentCast.remaining - elapsed)
        if state.currentCast.remaining <= 0.0 then
            state.currentCast = nil
            state.busy = false
        end
    end
    for _, snapshot in pairs(state.abilities or {}) do
        if type(snapshot.cooldown) == "number" then
            snapshot.cooldown = math.max(0.0, snapshot.cooldown - elapsed)
        end
    end
    for _, effect in pairs(state.effects or {}) do
        mobility_advance_effect(effect, elapsed)
    end
end

local function mobility_select_action(state, moving)
    local saved_moving = state.moving
    state.moving = moving == true
    local ok, selected, reason, presence_stacks, presence_source, selected_target =
        pcall(select_action, state)
    state.moving = saved_moving
    if not ok then
        return nil, "advisor_priority_error", nil, nil, nil
    end
    return selected, reason, presence_stacks, presence_source, selected_target
end

local function mobility_requires_standing(state, selected, presence_stacks)
    local ability = selected and Ability[selected] or nil
    if ability == nil or ability.stationary ~= true then
        return false
    end
    if (selected == state.primaryDotAbility or
            selected == state.presenceFillerAbility) and
        type(presence_stacks) == "number" and
        presence_stacks >= PRESENCE_MAX_STACKS then
        return false
    end
    return true
end

local function mobility_action_label(state, selected, presence_stacks)
    if type(selected) ~= "string" then
        return nil
    end
    if (selected == state.primaryDotAbility or
            selected == state.presenceFillerAbility) and
        type(presence_stacks) == "number" and
        presence_stacks >= PRESENCE_MAX_STACKS then
        return selected .. " (instant)"
    end
    return selected
end

local function mobility_current_stationary(state)
    local name = state.currentCast and state.currentCast.name or nil
    if name == nil and state.presenceThrowActive == true then
        name = "Telekinetic Throw"
    end
    local ability = name and Ability[name] or nil
    if state.busy and ability and ability.stationary == true then
        return name,
            state.currentCast and state.currentCast.remaining or nil
    end
    return nil, nil
end

local function mobility_lock_remaining(state)
    local queue_window = type(state.queueWindow) == "number" and
        math.max(READY_SLACK, state.queueWindow) or READY_SLACK
    local gcd_ready = type(state.gcd) == "number" and
        math.max(0.0, state.gcd - READY_SLACK) or 0.0
    local gcd_stand = type(state.gcd) == "number" and
        math.max(0.0, state.gcd - queue_window) or 0.0
    if not state.busy then
        return gcd_ready, gcd_stand
    end
    if state.currentCast and type(state.currentCast.remaining) == "number" then
        -- Evaluate the priority at the script's true ready edge, but tell the
        -- player to plant at the configured queue-window edge so human movement
        -- does not make the hardcast miss that ready edge.
        return math.max(gcd_ready, state.currentCast.remaining),
            math.max(gcd_stand,
                math.max(0.0, state.currentCast.remaining - queue_window))
    end
    return nil, nil
end

local function mobility_activate_effect(effect, remaining)
    if type(effect) ~= "table" then
        return false
    end
    effect.present = true
    effect.mine = true
    effect.remaining = remaining
    return true
end

local function mobility_apply_action(state, selected, presence_stacks, selected_target)
    if type(selected) ~= "string" then
        return false
    end
    -- Alternate-target spread changes a different unit's effect state. Do not
    -- fabricate that future state; hide the advisor until the live snapshot
    -- catches up instead of producing a confident wrong countdown.
    if selected_target ~= nil and selected_target ~= state.target then
        return false
    end

    local snapshot = state.abilities[selected]
    if type(snapshot) ~= "table" then
        return false
    end
    if type(snapshot.cost) == "number" and type(state.force) == "number" then
        state.force = math.max(0.0, state.force - snapshot.cost)
    end
    if type(snapshot.cooldownDuration) ~= "number" then
        return false
    end
    snapshot.cooldown = math.max(0.0, snapshot.cooldownDuration)

    local gcd_duration
    if snapshot.usesGlobalCooldown == false then
        gcd_duration = 0.0
    elseif type(snapshot.gcdDuration) == "number" then
        gcd_duration = math.max(0.0, snapshot.gcdDuration)
    else
        return false
    end

    if selected == state.primaryDotAbility then
        if not mobility_activate_effect(state.effects.primaryDot, 9.0) then
            return false
        end
    elseif selected == "Sever Force" then
        if not mobility_activate_effect(state.effects.severForce, 18.0) then
            return false
        end
    elseif selected == "Weaken Mind" then
        if not mobility_activate_effect(state.effects.weakenMind, 18.0) then
            return false
        end
    elseif selected == REJUVENATE then
        if not mobility_activate_effect(state.effects.rejuvenate, 15.0) then
            return false
        end
    elseif selected == MENDING_FORCE_ARMOR then
        state.effects.forceArmorAllowed = false
        state.effects.forceArmorBlocker = "projected_self_armor"
    end

    if (selected == state.primaryDotAbility or
            selected == state.presenceFillerAbility) and
        type(presence_stacks) == "number" and
        presence_stacks >= PRESENCE_MAX_STACKS then
        local presence = state.effects.presenceOfMind
        if type(presence) ~= "table" then
            return false
        end
        presence.present = false
        presence.stacks = 0
        presence.remaining = 0.0
    end

    state.gcd = gcd_duration
    -- Force Serenity is the one baseline mobile cast/channel in this route.
    -- Its hasted duration tracks the authoritative runtime GCD duration; all
    -- other projected mobile priorities here are instant.
    if selected == "Force Serenity" and gcd_duration > 0.0 then
        state.busy = true
        state.currentCast = {
            name = selected,
            remaining = gcd_duration,
        }
    else
        state.busy = false
        state.currentCast = nil
    end
    return true
end

local function mobility_bar_state(state)
    if state.moving ~= true then
        return nil
    end

    local current_name = mobility_current_stationary(state)
    if current_name ~= nil then
        return 0.0, current_name
    end

    local projected = mobility_copy_state(state)
    local started_at = projected.now
    local step_limit = 2
    for _ in pairs(projected.abilities or {}) do
        step_limit = step_limit + 1
    end

    for _ = 1, step_limit do
        local elapsed_before = math.max(0.0, projected.now - started_at)
        local ready_lock, stand_lock = mobility_lock_remaining(projected)
        if ready_lock == nil or stand_lock == nil then
            return nil
        end
        if ready_lock > 0.0 then
            mobility_advance_state(projected, ready_lock)
        end
        projected.gcd = math.min(projected.gcd, READY_SLACK)
        if projected.currentCast == nil then
            projected.busy = false
        end

        local standing, standing_reason, standing_stacks =
            mobility_select_action(projected, false)
        local moving, moving_reason, moving_stacks, _, moving_target =
            mobility_select_action(projected, true)
        if standing_reason == "advisor_priority_error" or
            moving_reason == "advisor_priority_error" then
            return nil
        end

        if mobility_requires_standing(projected, standing, standing_stacks) then
            return math.max(0.0, elapsed_before + stand_lock),
                mobility_action_label(projected, standing, standing_stacks)
        end

        -- Only project through an action that both stationary and moving
        -- priority agree is next. Movement-only fallbacks must not postpone a
        -- higher-value future plant decision.
        if standing == nil or moving == nil or standing ~= moving then
            return nil
        end
        if not mobility_apply_action(projected, moving, moving_stacks,
                moving_target) then
            return nil
        end
    end
    return nil
end

function M.new(executor)
    assert(type(executor) == "table" and type(executor.submit) == "function" and
        type(executor.status) == "function",
        "sage.balance.new requires the top-level AbilityExecutor")

    local last_decision_key = nil
    local last_cast_failure_key = nil
    local native_admission = nil
    local route_player_handle, route_actor_epoch = nil, nil
    local presence_combat_cursor = nil
    local presence_player_handle = nil
    local presence_throw_handle = nil
    local presence_throw_active = false
    local presence_throw_tick_count = 0
    local presence_stack_tick_ready = false
    local presence_stack_tick_ready_ms = nil
    local presence_stack_tick_disproved = false
    local presence_stack_tick_suppressed = false
    local presence_throw_start_stacks = nil
    local presence_last_observed_stacks = nil
    local presence_throw_activation_ms = nil
    local presence_throw_first_tick_ms = nil
    local presence_throw_last_tick_ms = nil
    local presence_throw_predicted_next_tick_ms = nil
    local presence_first_tick_mean_ms = nil
    local presence_first_tick_samples = 0
    local presence_tick_interval_mean_ms = nil
    local presence_tick_interval_samples = 0
    local presence_completion_observed = false
    local presence_event_fault = nil
    local last_gate_key = nil
    local last_gate_name = nil
    local last_gate_subject = nil
    local last_gate_reason = nil
    local mobility_bar_next_at = 0.0
    local mobility_bar_plan_next_at = 0.0
    local mobility_bar_started_at = nil
    local mobility_bar_stand_at = nil
    local mobility_bar_ability = nil

    local function log_gate(options, gate, subject, reason, detail)
        if type(options) ~= "table" or options.decisionLog ~= true then
            last_gate_key = nil
            last_gate_name = nil
            last_gate_subject = nil
            last_gate_reason = nil
            return
        end
        gate = tostring(gate or "unknown")
        subject = tostring(subject or "-")
        reason = tostring(reason or "unavailable")
        local key = gate .. "|" .. subject .. "|" .. reason
        if key == last_gate_key then
            return
        end
        last_gate_key = key
        last_gate_name = gate
        last_gate_subject = subject
        last_gate_reason = reason
        last_decision_key = nil
        emit_diagnostic(options, "debug",
            "route=balance phase=gate state=blocked" ..
            " gate=" .. gate ..
            " subject=" .. subject ..
            " reason=" .. reason ..
            tostring(detail or ""))
    end

    local function clear_gate(options)
        if last_gate_key == nil then
            return
        end
        emit_diagnostic(options, "debug",
            "route=balance phase=gate state=cleared" ..
            " gate=" .. tostring(last_gate_name) ..
            " subject=" .. tostring(last_gate_subject) ..
            " reason=" .. tostring(last_gate_reason))
        last_gate_key = nil
        last_gate_name = nil
        last_gate_subject = nil
        last_gate_reason = nil
    end

    local function clear_mobility_bar_plan()
        mobility_bar_plan_next_at = 0.0
        mobility_bar_started_at = nil
        mobility_bar_stand_at = nil
        mobility_bar_ability = nil
    end

    local function update_mobility_bar(options, state)
        if type(options) ~= "table" or options.mobilityAdvisor ~= true or
            state.moving ~= true or not gos.overlay or
            type(gos.overlay.viewport) ~= "function" or
            type(gos.overlay.draw_bar) ~= "function" or
            type(gos.overlay.draw_text) ~= "function" then
            clear_mobility_bar_plan()
            return
        end
        if state.now < mobility_bar_next_at then
            return
        end
        mobility_bar_next_at = state.now + 0.05

        if state.now >= mobility_bar_plan_next_at then
            mobility_bar_plan_next_at = state.now + 0.10
            local projected_stop, ability = mobility_bar_state(state)
            if projected_stop == nil then
                clear_mobility_bar_plan()
                return
            end
            if mobility_bar_started_at == nil or
                mobility_bar_ability ~= ability then
                mobility_bar_started_at = state.now
            end
            mobility_bar_stand_at = state.now + projected_stop
            mobility_bar_ability = ability
        end
        if mobility_bar_stand_at == nil then
            return
        end

        local stop_in = math.max(0.0, mobility_bar_stand_at - state.now)
        local total = math.max(0.0,
            mobility_bar_stand_at - mobility_bar_started_at)
        local value = stop_in <= 0.0 and 1.0 or
            (total > 0.0 and clamp(
                (state.now - mobility_bar_started_at) / total, 0.0, 1.0) or 0.0)
        local text = stop_in > 0.0 and
            string.format("STAND IN %.1fs", stop_in) or "STAND NOW"
        local color = stop_in > 0.0 and "yellow" or "red"

        local viewport = gos.overlay.viewport()
        if type(viewport) ~= "table" or viewport.available ~= true or
            type(viewport.width) ~= "number" or
            type(viewport.height) ~= "number" then
            return
        end
        local width = type(options.mobilityWidth) == "number" and
            math.floor(clamp(options.mobilityWidth, 160, 640) + 0.5) or 220
        local x_offset = type(options.mobilityX) == "number" and
            clamp(options.mobilityX, -3840, 3840) or 0
        local y_offset = type(options.mobilityY) == "number" and
            clamp(options.mobilityY, -2160, 2160) or 160
        local center_x = math.floor(viewport.width * 0.5 + x_offset)
        local y = math.floor(viewport.height * 0.5 + y_offset)

        gos.overlay.draw_bar("balance_mobility_bar", {
            at = { screen = {
                x = center_x - math.floor(width * 0.5), y = y } },
            width = width,
            height = 10,
            value = value,
            color = color,
            bg_color = { 12, 14, 16, 220 },
            border_color = "black",
            ttl = 0.10,
        })
        gos.overlay.draw_text("balance_mobility_text", {
            at = { screen = { x = center_x, y = y - 18 } },
            text = text,
            color = color,
            shadow = true,
            center_x = true,
            ttl = 0.10,
        })
    end

    local function update_running_mean(mean, samples, value)
        if type(value) ~= "number" or value <= 0.0 then
            return mean, samples
        end
        samples = samples + 1
        if type(mean) ~= "number" then
            return value, samples
        end
        return mean + (value - mean) / samples, samples
    end

    local function reset_presence_lifecycle(reset_cursor)
        presence_throw_active = false
        presence_throw_tick_count = 0
        presence_stack_tick_ready = false
        presence_stack_tick_ready_ms = nil
        presence_stack_tick_disproved = false
        presence_throw_start_stacks = nil
        presence_throw_activation_ms = nil
        presence_throw_first_tick_ms = nil
        presence_throw_last_tick_ms = nil
        presence_throw_predicted_next_tick_ms = nil
        presence_completion_observed = false
        presence_event_fault = nil
        if reset_cursor then
            presence_stack_tick_suppressed = false
            presence_combat_cursor = nil
            presence_player_handle = nil
            presence_throw_handle = nil
            presence_last_observed_stacks = nil
        end
    end

    local function report_presence_event_fault(options, reason)
        if type(options) ~= "table" or options.decisionLog ~= true then
            presence_event_fault = nil
            return
        end
        if presence_event_fault == reason then
            return
        end
        presence_event_fault = reason
        emit_diagnostic(options, "warn",
            "route=balance phase=presence_lifecycle state=unavailable" ..
            " reason=" .. tostring(reason))
    end

    local function observe_presence_lifecycle(options, world)
        local player = world and world.player or nil
        local player_handle = safe_method(player, "handle")
        local throw_actual = Mirror.ability(CurrentLoadout, "Telekinetic Throw")
        local throw_info = throw_actual and gos.abilities.info(throw_actual) or nil
        local throw_handle = type(throw_info) == "table" and
            throw_info.activation_handle or nil
        local throw_name = type(throw_info) == "table" and
            type(throw_info.name) == "string" and throw_info.name or nil
        if type(player_handle) ~= "string" or
            type(throw_handle) ~= "string" or
            type(throw_name) ~= "string" then
            return false, false, nil, 0, 0
        end

        if (presence_player_handle ~= nil and
                presence_player_handle ~= player_handle) or
            (presence_throw_handle ~= nil and
                presence_throw_handle ~= throw_handle) then
            reset_presence_lifecycle(true)
            presence_first_tick_mean_ms = nil
            presence_first_tick_samples = 0
            presence_tick_interval_mean_ms = nil
            presence_tick_interval_samples = 0
        end
        presence_player_handle = player_handle
        presence_throw_handle = throw_handle

        local batch = gos.events.combat(presence_combat_cursor)
        if type(batch) ~= "table" or type(batch.cursor) ~= "number" or
            type(batch.dropped) ~= "number" or
            type(batch.more) ~= "boolean" or
            type(batch.events) ~= "table" then
            reset_presence_lifecycle(false)
            report_presence_event_fault(options, "invalid_batch")
            return false, false, nil, 0, 0
        end

        presence_combat_cursor = batch.cursor
        if batch.dropped > 0 then
            reset_presence_lifecycle(false)
            report_presence_event_fault(options,
                "dropped_" .. tostring(batch.dropped))
        else
            presence_event_fault = nil
        end

        for index = 1, #batch.events do
            local event = batch.events[index]
            if type(event) == "table" and
                event.source_handle == player_handle then
                local lifecycle_event = event.kind == "ability" and
                    event.ability_handle == throw_handle
                local damage_tick = event.kind == "damage" and
                    presence_throw_active and event.name == throw_name and
                    type(event.timestamp) == "number"
                if lifecycle_event and event.action == "ability_activate" then
                    presence_throw_active = true
                    presence_throw_tick_count = 0
                    presence_stack_tick_ready = false
                    presence_stack_tick_ready_ms = nil
                    presence_stack_tick_disproved = false
                    presence_stack_tick_suppressed = false
                    presence_throw_start_stacks = presence_last_observed_stacks
                    presence_throw_activation_ms =
                        type(event.timestamp) == "number" and event.timestamp or nil
                    presence_throw_first_tick_ms = nil
                    presence_throw_last_tick_ms = nil
                    presence_throw_predicted_next_tick_ms =
                        type(presence_throw_activation_ms) == "number" and
                        type(presence_first_tick_mean_ms) == "number" and
                        presence_throw_activation_ms + presence_first_tick_mean_ms or nil
                    presence_completion_observed = false
                elseif damage_tick then
                    local previous_tick_ms = presence_throw_last_tick_ms
                    presence_throw_tick_count = presence_throw_tick_count + 1
                    if not presence_stack_tick_ready and
                        not presence_stack_tick_disproved and
                        type(presence_throw_start_stacks) == "number" and
                        presence_throw_start_stacks + presence_throw_tick_count >=
                            PRESENCE_MAX_STACKS then
                        if presence_stack_tick_suppressed then
                            emit_diagnostic(options, "debug",
                                "route=balance phase=presence_handoff" ..
                                " state=late_stack_tick_ignored" ..
                                " reason=spender_executor_owned" ..
                                " start=" ..
                                    number_text(presence_throw_start_stacks, 0) ..
                                " ticks=" .. tostring(presence_throw_tick_count))
                        else
                            presence_stack_tick_ready = true
                            presence_stack_tick_ready_ms = event.timestamp
                            emit_diagnostic(options, "info",
                                "route=balance phase=presence_handoff" ..
                                " state=stack_tick_observed" ..
                                " start=" ..
                                    number_text(presence_throw_start_stacks, 0) ..
                                " ticks=" .. tostring(presence_throw_tick_count))
                        end
                    end
                    if presence_throw_first_tick_ms == nil then
                        presence_throw_first_tick_ms = event.timestamp
                        if type(presence_throw_activation_ms) == "number" and
                            event.timestamp > presence_throw_activation_ms then
                            presence_first_tick_mean_ms,
                                presence_first_tick_samples = update_running_mean(
                                    presence_first_tick_mean_ms,
                                    presence_first_tick_samples,
                                    event.timestamp - presence_throw_activation_ms)
                        end
                    end
                    if type(previous_tick_ms) == "number" and
                        event.timestamp > previous_tick_ms then
                        presence_tick_interval_mean_ms,
                            presence_tick_interval_samples = update_running_mean(
                                presence_tick_interval_mean_ms,
                                presence_tick_interval_samples,
                                event.timestamp - previous_tick_ms)
                    end
                    presence_throw_last_tick_ms = event.timestamp

                    local next_interval_ms = nil
                    if presence_throw_tick_count >= 2 and
                        type(presence_throw_first_tick_ms) == "number" and
                        event.timestamp > presence_throw_first_tick_ms then
                        next_interval_ms =
                            (event.timestamp - presence_throw_first_tick_ms) /
                            (presence_throw_tick_count - 1)
                    elseif type(presence_tick_interval_mean_ms) == "number" then
                        next_interval_ms = presence_tick_interval_mean_ms
                    end
                    presence_throw_predicted_next_tick_ms =
                        type(next_interval_ms) == "number" and
                        event.timestamp + next_interval_ms or nil
                elseif lifecycle_event and
                    (event.action == "ability_interrupt" or
                        event.action == "ability_cancel") then
                    reset_presence_lifecycle(false)
                elseif lifecycle_event and
                    event.action == "ability_deactivate" then
                    if presence_throw_active then
                        presence_completion_observed = true
                    end
                    presence_throw_active = false
                end
            end
        end

        return batch.more == true, batch.cursor, #batch.events, batch.dropped
    end

    local function select_with_native_admission(state)
        local intent = native_admission
        if intent == nil or intent.worldTargetHandle ~= state.targetHandle then
            native_admission = nil
            return select_action(state)
        end
        local snapshot = state.abilities[intent.ability]
        if type(snapshot) ~= "table" or snapshot.handle ~= intent.abilityHandle then
            native_admission = nil
            return select_action(state)
        end
        local submission_pending = snapshot.submissionPending
        snapshot.submissionPending = false
        local selected, reason, stacks, source, target = select_action(state)
        snapshot.submissionPending = submission_pending
        local selected_handle = target and safe_method(target, "handle") or state.targetHandle
        if selected ~= intent.ability or selected_handle ~= intent.targetHandle then
            native_admission = nil
        end
        return selected, reason, stacks, source, target
    end

    local function log_decision(options, state, selected, reason,
            presence_stacks, presence_source, selected_target_handle)
        if type(options) ~= "table" or options.decisionLog ~= true then
            return
        end

        local effects = state.effects
        local presence = effects.presenceOfMind
        local suppression = state.suppressionAbility
        local primary_dot_active = owned_active(effects.primaryDot)
        local sever_force_active = owned_active(effects.severForce)
        local weaken_mind_active = owned_active(effects.weakenMind)
        local all_dots_active = primary_dot_active and
            sever_force_active and weaken_mind_active
        local suppression_ready = can_use(state, suppression)
        local serenity_ready = can_use(state, "Force Serenity")
        local presence_filler_ready =
            can_use(state, state.presenceFillerAbility, true)
        local primary_dot_cooldown =
            state.abilities[state.primaryDotAbility].cooldown
        local key = table.concat({
            tostring(selected or "-"),
            tostring(reason or "-"),
            tostring(selected_target_handle or state.targetHandle),
            tostring(presence.present),
            tostring(presence.hasCharges),
            tostring(presence.truncated),
            number_text(presence.stacks, 0),
            number_text(presence_stacks, 0),
            tostring(presence_source),
            tostring(state.presenceThrowActive == true),
            tostring(state.presenceThrowTickCount or 0),
            tostring(state.presenceStackTickReady == true),
            number_text(state.presenceThrowStartStacks, 0),
            tostring(state.primaryDotAbility),
            tostring(state.presenceFillerAbility),
            tostring(state.teachingsSelected),
            tostring(state.telekineticBlitzSelected),
            tostring(state.maxSpread),
            tostring(state.movingRejuvenate),
            number_text(state.playerHpPercent, 1),
            tostring(state.rejuvenateHpPercent),
            effect_presence_text(effects.rejuvenate),
            tostring(state.selfArmor),
            tostring(effects.forceArmorAllowed),
            tostring(effects.forceArmorBlocker or "-"),
            tostring(primary_dot_active),
            tostring(sever_force_active),
            tostring(weaken_mind_active),
            tostring(suppression_ready),
            tostring(serenity_ready),
            tostring(presence_filler_ready),
            tostring(state.forceInBalanceTargets or "-"),
            tostring(state.forcequakeTargets or "-"),
            tostring(state.clusterStatus or "-"),
            tostring(state.clusterReason or "-"),
            tostring(state.clusterObservationReason or "-"),
            tostring(state.clusterObservationHandle or "-"),
            table.concat(state.abilityFaults, ","),
            tostring(state.spreadNeeded),
            tostring(state.spreadObservationPending),
            tostring(state.directSpreadAbility or "-"),
            tostring(state.directSpreadHandle or "-"),
            tostring(state.directSpreadObservationPending),
            tostring(dot_due(effects.primaryDot)),
            tostring(state.busy),
            tostring(state.currentCast and state.currentCast.name or "-"),
        }, "|")
        if key == last_decision_key then
            return
        end
        last_decision_key = key

        local function effect_text(effect)
            return tostring(effect.present) .. "/" .. tostring(effect.mine) ..
                "/" .. number_text(effect.remaining, 2) ..
                "/" .. tostring(effect.kind or "-") ..
                "/age=" .. number_text(effect.ageMs, 0) ..
                "/truncated=" .. tostring(effect.truncated)
        end

        local ability_parts = {}
        local seen_abilities = {}
        local function append_ability(name, instant)
            if seen_abilities[name] then
                return
            end
            seen_abilities[name] = true
            local snapshot = state.abilities[name]
            if snapshot == nil then
                ability_parts[#ability_parts + 1] = name .. "{missing}"
                return
            end
            ability_parts[#ability_parts + 1] = name ..
                "{handle=" .. tostring(snapshot.handle or "-") ..
                ",cd=" .. number_text(snapshot.cooldown, 2) ..
                ",cost=" .. number_text(snapshot.cost, 0) ..
                ",usable=" .. tostring(can_use(state, name, instant)) .. "}"
        end
        append_ability(suppression)
        append_ability(state.primaryDotAbility,
            type(presence_stacks) == "number" and
                presence_stacks >= PRESENCE_MAX_STACKS)
        append_ability("Sever Force")
        append_ability("Weaken Mind")
        append_ability("Force Serenity")
        append_ability("Telekinetic Throw")
        append_ability(state.presenceFillerAbility,
            type(presence_stacks) == "number" and
                presence_stacks >= PRESENCE_MAX_STACKS)
        if state.abilities["Forcequake"] ~= nil then
            append_ability("Forcequake")
        end
        if state.abilities["Project"] ~= nil then
            append_ability("Project")
        end
        if state.abilities["Telekinetic Blitz"] ~= nil then
            append_ability("Telekinetic Blitz")
        end
        if state.abilities[REJUVENATE] ~= nil then
            append_ability(REJUVENATE, true)
        end
        if state.abilities[MENDING_FORCE_ARMOR] ~= nil then
            append_ability(MENDING_FORCE_ARMOR, true)
        end

        emit(options, "debug",
            "route=balance phase=decision" ..
            " selected=" .. tostring(selected or "-") ..
            " reason=" .. tostring(reason or "-") ..
            " target=" ..
                tostring(selected_target_handle or state.targetHandle) ..
            " distance=" .. number_text(state.distance, 1) ..
            " force=" .. number_text(state.force, 0) ..
            " moving=" .. tostring(state.moving) ..
            " gcd=" .. number_text(state.gcd, 2) ..
            " busy=" .. tostring(state.busy) ..
            " current=" ..
                tostring(state.currentCast and state.currentCast.name or "-") ..
            " current_handle=" ..
                tostring(state.currentCast and
                    state.currentCast.abilityHandle or "-") ..
            " current_remaining=" ..
                number_text(state.currentCast and
                    state.currentCast.remaining or nil, 2) ..
            " pom=" .. tostring(presence.present) ..
                ":" .. number_text(presence.stacks, 0) ..
            " pom_has_charges=" .. tostring(presence.hasCharges) ..
            " pom_age_ms=" .. number_text(presence.ageMs, 0) ..
            " pom_truncated=" .. tostring(presence.truncated) ..
            " pom_projected=" .. number_text(presence_stacks, 0) ..
            " pom_source=" .. tostring(presence_source) ..
            " pom_throw_active=" ..
                tostring(state.presenceThrowActive == true) ..
            " pom_throw_start=" ..
                number_text(state.presenceThrowStartStacks, 0) ..
            " pom_throw_ticks=" ..
                tostring(state.presenceThrowTickCount or 0) ..
            " pom_stack_tick_ready=" ..
                tostring(state.presenceStackTickReady == true) ..
            " pom_first_tick_mean_ms=" ..
                number_text(state.presenceFirstTickMeanMs, 0) ..
            " pom_tick_interval_mean_ms=" ..
                number_text(state.presenceTickIntervalMeanMs, 0) ..
            " pom_next_tick_in_ms=" ..
                number_text(type(state.presencePredictedNextTickMs) == "number" and
                    math.max(0.0,
                        state.presencePredictedNextTickMs - state.now * 1000.0) or
                    nil, 0) ..
            " primary_dot=" .. tostring(state.primaryDotAbility) ..
                ":" .. effect_text(effects.primaryDot) ..
            " sever_force=" .. effect_text(effects.severForce) ..
            " weaken_mind=" .. effect_text(effects.weakenMind) ..
            " primary_dot_cd=" .. number_text(primary_dot_cooldown, 2) ..
            " primary_dot_due=" .. tostring(dot_due(effects.primaryDot)) ..
            " all_dots=" .. tostring(all_dots_active) ..
            " teachings=" .. tostring(state.teachingsSelected) ..
            " telekinetic_blitz=" ..
                tostring(state.telekineticBlitzSelected) ..
            " max_spread=" .. tostring(state.maxSpread) ..
            " player_hp=" .. number_text(state.playerHpPercent, 1) ..
            " moving_rejuvenate=" .. tostring(state.movingRejuvenate) ..
                ":" .. tostring(state.rejuvenateHpPercent) ..
                ":" .. effect_presence_text(effects.rejuvenate) ..
            " self_armor=" .. tostring(state.selfArmor) ..
                ":allowed=" .. tostring(effects.forceArmorAllowed) ..
                ":blocker=" .. tostring(effects.forceArmorBlocker or "-") ..
            " suppression=" .. tostring(suppression) ..
                ":" .. tostring(suppression_ready) ..
            " serenity=" .. tostring(serenity_ready) ..
                ":" .. number_text(
                    state.abilities["Force Serenity"] and
                        state.abilities["Force Serenity"].cooldown or nil, 2) ..
            " presence_filler=" .. tostring(state.presenceFillerAbility) ..
                ":" .. tostring(presence_filler_ready) ..
            " fib_targets=" .. tostring(state.forceInBalanceTargets or "-") ..
            " forcequake_targets=" ..
                tostring(state.forcequakeTargets or "-") ..
            " cluster=" .. tostring(state.clusterStatus or "-") ..
                ":" .. tostring(state.clusterReason or "-") ..
            " cluster_observation=" ..
                tostring(state.clusterObservationReason or "-") .. ":" ..
                tostring(state.clusterObservationHandle or "-") ..
            " spread_needed=" .. tostring(state.spreadNeeded) ..
            " spread_pending=" ..
                tostring(state.spreadObservationPending) ..
            " direct_spread=" ..
                tostring(state.directSpreadAbility or "-") .. ":" ..
                tostring(state.directSpreadHandle or "-") ..
            " direct_pending=" ..
                tostring(state.directSpreadObservationPending) ..
            " ability_faults=" ..
                (#state.abilityFaults > 0 and
                    table.concat(state.abilityFaults, ",") or "-") ..
            " abilities=" .. table.concat(ability_parts, ";"))
    end

    local function log_cast(options, state, selected, reason, result,
            presence_stacks, presence_source, selected_target_handle)
        if type(options) ~= "table" or options.castLog ~= true then
            return
        end
        if type(result) == "table" and result.accepted == true and
            result.new_command == true then
            last_cast_failure_key = nil
            emit(options, "info",
                "route=balance phase=cast queued=true" ..
                " command=" .. tostring(result.command_handle or "-") ..
                " command_state=" .. tostring(result.core and result.core.command_state or "-") ..
                " executor=" .. tostring(result.disposition or "-") ..
                " ability=" .. tostring(selected) ..
                " reason=" .. tostring(reason) ..
                " target=" ..
                    tostring(selected_target_handle or state.targetHandle) ..
                " force=" .. number_text(state.force, 0) ..
                " pom=" ..
                    number_text(state.effects.presenceOfMind.stacks, 0) ..
                " pom_projected=" .. number_text(presence_stacks, 0) ..
                " pom_source=" .. tostring(presence_source))
            return
        end

        local failure_reason = type(result) == "table" and
            (result.reason or result.code) or "invalid_cast_result"
        local key = tostring(selected) .. "|" ..
            tostring(selected_target_handle or state.targetHandle) .. "|" ..
            tostring(failure_reason)
        if key == last_cast_failure_key then
            return
        end
        last_cast_failure_key = key
        emit(options, "warn",
            "route=balance phase=cast queued=false" ..
            " ability=" .. tostring(selected) ..
            " decision=" .. tostring(reason) ..
            " target=" ..
                tostring(selected_target_handle or state.targetHandle) ..
            " reason=" .. tostring(failure_reason))
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

    local function stop(reason)
        last_decision_key = nil
        last_cast_failure_key = nil
        last_gate_key = nil
        last_gate_name = nil
        last_gate_subject = nil
        last_gate_reason = nil
        native_admission = nil
        route_player_handle, route_actor_epoch = nil, nil
        mobility_bar_next_at = 0.0
        clear_mobility_bar_plan()
        reset_presence_lifecycle(true)
        if owns_pending() then
            executor:cancel(reason or "balance_route_inactive")
        end
        return owns_pending()
    end

    local function tick(loadout, active, options)
        loadout = Mirror.adapt_loadout(loadout)
        CurrentLoadout = loadout
        local selection, loadout_gate, loadout_subject, loadout_reason =
            validated_loadout(loadout)
        if selection ~= nil then
            request_selected_ability_metadata(loadout, selection, options)
        end
        local max_spread = type(options) == "table" and
            options.maxSpread == true
        local direct_spread_radius = type(options) == "table" and
            type(options.spreadRadius) == "number" and
            math.max(1.0, math.min(30.0, options.spreadRadius)) or
            FORCE_IN_BALANCE_RADIUS_METERS
        local forcequake_radius = type(options) == "table" and
            type(options.forcequakeRadius) == "number" and
            math.max(1.0, math.min(12.0, options.forcequakeRadius)) or
            FORCEQUAKE_RADIUS_METERS
        local forcequake_min_targets = type(options) == "table" and
            type(options.forcequakeMinTargets) == "number" and
            math.max(2, math.min(8,
                math.floor(options.forcequakeMinTargets + 0.5))) or
            FORCEQUAKE_FILLER_MIN_TARGETS
        local world = nil
        if selection ~= nil and max_spread then
            world = gos.world()
            draw_max_spread_range(options,
                world and world.current_target or nil,
                direct_spread_radius)
        end
        if active ~= true or selection == nil then
            if active ~= true then
                log_gate(options, "activation", "rotation", "inactive")
            else
                log_gate(options, loadout_gate, loadout_subject, loadout_reason)
            end
            last_decision_key = nil
            last_cast_failure_key = nil
            native_admission = nil
            route_player_handle, route_actor_epoch = nil, nil
            mobility_bar_next_at = 0.0
            clear_mobility_bar_plan()
            reset_presence_lifecycle(true)
            if owns_pending() then
                executor:cancel(active == true and "balance_loadout_incomplete" or
                    "balance_rotation_inactive")
            end
            return true
        end
        world = world or gos.world()
        local target = world and world.current_target or nil
        local player_handle = safe_method(world and world.player or nil, "handle")
        local actor_epoch = world and world.actor_epoch or nil
        if type(player_handle) == "string" then
            if route_player_handle ~= nil and
                (route_player_handle ~= player_handle or
                    route_actor_epoch ~= nil and actor_epoch ~= nil and
                    route_actor_epoch ~= actor_epoch) then
                native_admission = nil
                reset_presence_lifecycle(true)
            end
            route_player_handle, route_actor_epoch = player_handle, actor_epoch
        end
        local presence_backlog, presence_cursor, presence_event_count,
            presence_dropped =
            observe_presence_lifecycle(options, world)
        if executor:owns_command() then
            local status = executor:status()
            local executor_state = type(status) == "table" and
                tostring(status.disposition or status.core.state or "pending") or
                "invalid_status"
            local executor_reason = type(status) == "table" and
                tostring(status.reason or "pending") or "invalid_status"
            log_gate(options, "executor",
                type(status) == "table" and status.ability or "command",
                executor_state .. ":" .. executor_reason,
                " command=" .. tostring(
                    type(status) == "table" and
                        status.command_handle or "-") ..
                " idempotency=" .. tostring(
                    type(status) == "table" and
                        status.idempotency_key or "-") ..
                " known=" .. tostring(
                    type(status) == "table" and status.core.known == true) ..
                " terminal=" .. tostring(
                    type(status) == "table" and status.core.terminal == true) ..
                " awaiting_terminal=" .. tostring(
                    type(status) == "table" and
                        status.awaiting_terminal == true))
            return true
        end
        if presence_backlog then
            log_gate(options, "combat_events", "presence_lifecycle", "backlog",
                " cursor=" .. tostring(presence_cursor or "-") ..
                " events=" .. tostring(presence_event_count or 0) ..
                " dropped=" .. tostring(presence_dropped or 0))
            return true
        end
        local spread_enabled = selection.suppression == "Force in Balance" and
            loadout.known["Abundant Justice"] == true
        local cluster, cluster_error
        if target then
            cluster, cluster_error = read_target_clusters(
                world, target, spread_enabled, max_spread,
                direct_spread_radius, forcequake_radius,
                forcequake_min_targets)
        else
            cluster_error = "target_unavailable"
        end
        draw_max_spread_candidate(options, cluster)
        local state, state_gate, state_subject, state_reason, state_detail = read_state(
            loadout, selection, options, world, cluster, cluster_error,
            presence_throw_active)
        if not state then
            log_gate(options, state_gate, state_subject, state_reason,
                state_detail)
            return true
        end
        clear_gate(options)
        local observed_presence = observed_presence_stacks(state)
        presence_last_observed_stacks = observed_presence
        if presence_throw_active and state.busy then
            if type(presence_throw_start_stacks) ~= "number" then
                presence_throw_start_stacks = math.max(0,
                    math.min(PRESENCE_MAX_STACKS,
                        observed_presence - presence_throw_tick_count))
            elseif presence_throw_tick_count == 0 then
                presence_throw_start_stacks = observed_presence
            else
                local expected_stacks = math.min(PRESENCE_MAX_STACKS,
                    presence_throw_start_stacks + presence_throw_tick_count)
                if observed_presence > expected_stacks then
                    presence_throw_start_stacks = math.max(0,
                        observed_presence - presence_throw_tick_count)
                end
            end
            if not presence_stack_tick_ready and
                not presence_stack_tick_disproved and
                type(presence_throw_start_stacks) == "number" and
                presence_throw_start_stacks + presence_throw_tick_count >=
                    PRESENCE_MAX_STACKS and
                type(presence_throw_last_tick_ms) == "number" then
                presence_stack_tick_ready = true
                presence_stack_tick_ready_ms = presence_throw_last_tick_ms
            end
        elseif presence_throw_active and not state.busy then
            local stack_tick_ready = presence_stack_tick_ready
            local stack_tick_ready_ms = presence_stack_tick_ready_ms
            reset_presence_lifecycle(false)
            presence_stack_tick_ready = stack_tick_ready
            presence_stack_tick_ready_ms = stack_tick_ready_ms
        end
        if presence_stack_tick_ready and
            observed_presence < PRESENCE_MAX_STACKS and
            type(presence_stack_tick_ready_ms) == "number" then
            local presence_effect = state.effects.presenceOfMind
            local age_ms = presence_effect and presence_effect.ageMs or nil
            if type(age_ms) == "number" then
                local effect_sample_ms =
                    state.now * 1000.0 - math.max(0.0, age_ms)
                -- Both public timestamps are integer milliseconds derived from
                -- QPC. Require a 2ms lead so truncation can never make an
                -- older/same-frame effect sample look newer than the TT tick.
                if effect_sample_ms >= presence_stack_tick_ready_ms + 2.0 then
                    emit_diagnostic(options, "info",
                        "route=balance phase=presence_handoff" ..
                        " state=stack_tick_disproved" ..
                        " observed=" .. tostring(observed_presence) ..
                        " sample_after_tick_ms=" ..
                            number_text(effect_sample_ms -
                                presence_stack_tick_ready_ms, 0))
                    presence_stack_tick_ready = false
                    presence_stack_tick_ready_ms = nil
                    presence_stack_tick_disproved = true
                end
            end
        end
        state.presenceThrowActive = presence_throw_active
        state.presenceThrowTickCount = presence_throw_tick_count
        state.presenceStackTickReady = presence_stack_tick_ready
        state.presenceThrowStartStacks = presence_throw_start_stacks
        state.presencePredictedNextTickMs =
            presence_throw_predicted_next_tick_ms
        state.presenceFirstTickMeanMs = presence_first_tick_mean_ms
        state.presenceTickIntervalMeanMs = presence_tick_interval_mean_ms
        if presence_completion_observed then
            presence_completion_observed = false
        end
        update_mobility_bar(options, state)
        local selected, selected_reason, presence_stacks, presence_source,
            selected_target = select_with_native_admission(state)
        local selected_target_handle = selected_target and
            safe_method(selected_target, "handle") or state.targetHandle
        log_decision(options, state, selected, selected_reason,
            presence_stacks, presence_source, selected_target_handle)
        if selected then
            local presence_spender = selected == state.primaryDotAbility or
                selected == state.presenceFillerAbility
            local target = selected_target or state.target
            if Ability[selected].groundTarget then
                -- Match Telekinetics Forcequake exactly: do not prequeue the
                -- first ground-target leg inside the GCD window. Core owns both
                -- legs under one command handle once the lock is fully clear.
                if state.busy or type(state.gcd) ~= "number" or
                    state.gcd > 0.0 then
                    log_gate(options, "ground_target", selected,
                        state.busy and "busy" or "gcd",
                        " gcd=" .. number_text(state.gcd, 3))
                    return true
                end
                target = nil
            end
            local result = executor:submit(selected, target, {
                idempotencyKey = "balance:" .. selected_target_handle .. ":" ..
                    selected,
            })
            log_cast(options, state, selected, selected_reason, result,
                presence_stacks, presence_source, selected_target_handle)
            native_admission = nil
            if type(result) == "table" and result.admission_pending == true and
                result.owns_command ~= true then
                local ability = state.abilities[selected]
                native_admission = {
                    ability = selected,
                    abilityHandle = type(ability) == "table" and ability.handle or nil,
                    targetHandle = selected_target_handle,
                    worldTargetHandle = state.targetHandle,
                }
            end
            if presence_spender and
                type(result) == "table" and result.accepted == true then
                presence_stack_tick_ready = false
                presence_stack_tick_suppressed = true
            end
        end
        return true
    end

    return {
        is_selected = is_selected,
        owns_pending = owns_pending,
        clear_native_admission = function() native_admission = nil end,
        stop = stop,
        tick = tick,
    }
end

return M
