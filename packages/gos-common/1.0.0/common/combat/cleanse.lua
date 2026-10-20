-- Shared cleanse decisions. The caller owns the ONLY AbilityExecutor.
-- No tick callbacks, casts, command polling/cancellation, cooldown estimates,
-- selected-target substitution, or lifetime extension live in this module.
local DB = require("combat.cleanse_db")
local M = { build_id = "2026-10-19-shared-cleanse-r6-fresh-admission",
    db_revision = DB.revision, supports_tier_filter = true }
-- Exact ability/passive names from the extracted class ability catalogs.
local counterparts = {
    sorcerer = { base = "sage", ability = "Expunge", talent = "Sith Purity", alias = "Purity", adds = "physical" },
    scoundrel = { base = "operative", ability = "Triage", talent = "Psych Meds", adds = "mental" },
    mercenary = { base = "commando", ability = "Cure", talent = "Cure Mind", adds = "mental" },
}
local cleansers = {}
for style, definition in pairs(DB.cleansers) do cleansers[style] = definition end
for style, counterpart in pairs(counterparts) do
    local base = assert(DB.cleansers[counterpart.base])
    cleansers[style] = {
        ability = counterpart.ability, range_meters = base.range_meters,
        max_effects = base.max_effects, removes = base.removes,
        upgrades = { { talent = counterpart.talent, alias = counterpart.alias, adds = counterpart.adds } },
    }
end
local MAX_UNITS, MAX_EFFECTS, MAX_DIAGNOSTICS = 512, 512, 64
local METERS_PER_WORLD_UNIT = 10
local by_definition, diagnostic_seen = {}, {}
local missing_identity_warned = false
local diagnostic_count, diagnostic_next_ms = 0, 0
local DIAGNOSTIC_INTERVAL_MS = 2000
local tier_order = { must = 1, movement = 2, pressure = 3 }
local categories = { "force", "mental", "physical", "tech" }

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
local function number(n, default, lo, hi)
    if not finite(n) then return default end
    return math.max(lo, math.min(hi, n))
end
local function method(object, name, ...)
    if not object or type(object[name]) ~= "function" then return nil end
    local ok, result = pcall(object[name], object, ...)
    if ok then return result end
end
local function definition_key(value)
    return type(value) == "string" and #value == 26 and
        value:match("^effectdef:%x+$") ~= nil
end
assert(DB.identity == "effect_definition_v1", "Unsupported cleanse catalog identity schema")
for _, rule in ipairs(DB.effects) do
    assert(definition_key(rule.definition_key) and rule.key == rule.definition_key and
        tier_order[rule.tier] and rule.dispel and DB.sources[rule.source],
        "Invalid cleanse rule: " .. tostring(rule.key))
    assert(not by_definition[rule.definition_key] and not DB.excluded[rule.definition_key],
        "Duplicate/conflicting cleanse definition: " .. rule.definition_key)
    by_definition[rule.definition_key] = rule
end
for key, reason in pairs(DB.excluded) do
    assert(definition_key(key) and type(reason) == "string", "Invalid cleanse exclusion")
end

function M.capabilities(loadout)
    if type(loadout) ~= "table" or loadout.status ~= "ready" or
        type(loadout.known) ~= "table" then
        return { status = "unavailable", reason = "loadout_unavailable" }
    end
    local definition = cleansers[loadout.combat_style]
    if not definition then
        return { status = "unavailable", reason = "unsupported_combat_style" }
    end
    if loadout.known[definition.ability] ~= true then
        return { status = "unavailable", reason = "cleanse_not_learned",
            ability = definition.ability }
    end
    local result = { status = "ready", ability = definition.ability,
        style = loadout.combat_style, discipline = loadout.discipline,
        range_meters = definition.range_meters, max_effects = definition.max_effects,
        removes = {}, unknown = {}, proof = {}, upgrades = {} }
    for _, category in ipairs(categories) do
        if definition.removes[category] then
            result.removes[category] = true
            result.proof[category] = "base_ability"
        end
    end
    for _, upgrade in ipairs(definition.upgrades) do
        if loadout.known[upgrade.talent] == true or
            upgrade.alias ~= nil and loadout.known[upgrade.alias] == true then
            result.removes[upgrade.adds] = true
            result.proof[upgrade.adds] = upgrade.talent
            result.upgrades[upgrade.talent] = "present"
        elseif loadout.talents_available == true then
            result.upgrades[upgrade.talent] = "absent"
        else
            result.unknown[upgrade.adds] = true
            result.upgrades[upgrade.talent] = "unknown"
        end
    end
    return result
end

-- Append settings at registration, once. Per-class existing settings survive.
function M.settings(schema, defaults)
    assert(type(schema) == "table" and type(schema.fields) == "table")
    assert(defaults == nil or type(defaults) == "table", "Invalid cleanse defaults")
    local fields = {
        { key = "cleanse_enabled", type = "bool", label = "Shared PvP Cleanse", default = true,
          tooltip = "Use the current-client exact-definition cleanse catalog while the rotation is active. Requires the matching Core effect identity contract; no name guessing." },
        { key = "cleanse_self", type = "bool", label = "Shared Cleanse: Self", default = true },
        { key = "cleanse_allies", type = "bool", label = "Shared Cleanse: Allies", default = true },
        { key = "cleanse_movement", type = "bool", label = "Shared Cleanse: Roots", default = true },
        { key = "cleanse_slows", type = "bool", label = "Shared Cleanse: Slows", default = false },
        { key = "cleanse_pressure", type = "bool", label = "Shared Cleanse: Pressure Debuffs", default = false,
          tooltip = "Lower priority than controls. Seer retains its existing Seer-specific pressure setting." },
        { key = "cleanse_min_remaining", type = "number", label = "Shared Cleanse: Minimum Seconds", default = 0.8,
          min = 0, max = 3, step = 0.1 },
        { key = "cleanse_pressure_hp_percent", type = "int", label = "Shared Cleanse: Pressure HP %", default = 90,
          min = 1, max = 100 },
        { key = "cleanse_diagnostics", type = "bool", label = "Shared Cleanse: Diagnostics", default = false,
          tooltip = "Log a bounded sample of skipped/unknown effect names; never enables speculative cleansing." },
    }
    for key, value in pairs(defaults or {}) do
        local found = false
        for _, entry in ipairs(fields) do
            if entry.key == key then
                assert(type(value) == type(entry.default), "Invalid cleanse default: " .. key)
                entry.default, found = value, true
                break
            end
        end
        assert(found, "Unknown cleanse default: " .. tostring(key))
    end
    for _, entry in ipairs(fields) do
        for _, existing in ipairs(schema.fields) do
            assert(existing.key ~= entry.key, "Duplicate cleanse setting: " .. entry.key)
        end
        schema.fields[#schema.fields + 1] = entry
    end
    return schema
end

function M.policy(settings)
    local source = type(settings) == "table" and settings or {}
    settings = setmetatable({}, { __index = function(_, key)
        local value = source[key]
        if value == nil and type(source.fields) == "table" then value = source.fields[key] end
        return value
    end })
    return {
        enabled = settings.cleanse_enabled ~= false,
        self = settings.cleanse_self ~= false, allies = settings.cleanse_allies ~= false,
        movement = settings.cleanse_movement ~= false, slows = settings.cleanse_slows == true,
        pressure = settings.cleanse_pressure == true, physical = true,
        min_remaining = number(settings.cleanse_min_remaining, 0.8, 0, 3),
        pressure_hp = number(settings.cleanse_pressure_hp_percent, 90, 1, 100) / 100,
        diagnostics = settings.cleanse_diagnostics == true,
    }
end

function M.seer_policy(legacy, shared)
    local policy = M.policy()
    if type(shared) == "table" then
        for k, v in pairs(shared) do policy[k] = v end
    end
    legacy = type(legacy) == "table" and legacy or {}
    policy.enabled = policy.enabled and legacy.autoCleanse ~= false
    policy.self = policy.self and legacy.cleanseSelf ~= false
    policy.allies = policy.allies and legacy.cleanseAllies ~= false
    policy.physical = legacy.cleansePhysical ~= false
    policy.pressure = legacy.cleansePressure ~= false
    policy.min_remaining = number(legacy.cleanseMinRemaining, 0.8, 0, 3)
    policy.pressure_hp = number(legacy.cleansePressureHp, 0.9, 0.01, 1)
    return policy
end

function M.match(effect)
    if type(effect) ~= "table" then return nil, "invalid_effect" end
    if effect.definition_key == nil then return nil, "effect_definition_unavailable" end
    if not definition_key(effect.definition_key) then return nil, "invalid_effect_definition" end
    local rule = by_definition[effect.definition_key]
    if not rule then
        return nil, DB.excluded[effect.definition_key] or "unknown_effect_definition"
    end
    -- Display text and its locale are irrelevant to definition identity. An
    -- unknown/missing key never falls back to a name, icon or enemy class.
    return rule, "catalog_definition_match"
end

local function diagnostic(context, name, reason, identity)
    local policy = context.policy
    if not policy or not policy.diagnostics or type(context.log) ~= "function" or
        diagnostic_count >= MAX_DIAGNOSTICS then return end
    local signature = tostring(identity or name) .. ":" .. tostring(reason)
    if diagnostic_seen[signature] then return end
    local now = gos and type(gos.time_ms) == "function" and gos.time_ms() or nil
    if not finite(now) or now < diagnostic_next_ms then return end
    diagnostic_next_ms = now + DIAGNOSTIC_INTERVAL_MS
    diagnostic_seen[signature] = true
    diagnostic_count = diagnostic_count + 1
    context.log("debug", "cleanse skipped: effect=" .. tostring(name) ..
        " definition=" .. tostring(identity or "-") .. " reason=" .. tostring(reason))
end

local function alive_hp(unit)
    local hp = method(unit, "hp")
    if type(hp) ~= "table" or not finite(hp.current) or not finite(hp.max) or
        hp.max <= 0 or hp.current <= 0 or hp.current > hp.max then return nil end
    return hp.current / hp.max
end
local function in_range(unit, handle, player_handle, range)
    if handle == player_handle then return true end
    local distance = method(unit, "distance")
    return finite(distance) and distance >= 0 and distance * METERS_PER_WORLD_UNIT <= range
end
-- Default remains friendly players for existing Sage/Operative callers.
-- A caller may explicitly opt companions/NPCs into the same exact-definition
-- rules. This does not turn an unknown PvE effect into a cleanse candidate.
local function target_allowed(unit, context)
    local kind = method(unit, "type")
    if method(unit, "reaction") ~= "friendly" then return false end
    if kind ~= "player" and kind ~= "companion" and kind ~= "npc" then return false end
    if type(context.target_types) ~= "table" then return kind == "player" end
    return context.target_types[kind] == true
end
local function admissible(rule, effect, capabilities, policy, hp)
    if capabilities.removes[rule.dispel] ~= true then
        return false, capabilities.unknown[rule.dispel] and "talent_unknown" or "category_not_supported"
    end
    if rule.dispel == "physical" and policy.physical == false then return false, "physical_disabled" end
    if effect.freshness ~= "current" or effect.kind ~= "debuff" or
        effect.has_timer ~= true or not finite(effect.remaining) or
        effect.remaining <= 0 or effect.remaining < policy.min_remaining then
        return false, "effect_not_current_or_expiring"
    end
    if rule.tier == "movement" and (not policy.movement or
        (rule.mechanic == "slow" or rule.mechanic == "movement_control") and
            not policy.slows) then return false, "movement_disabled" end
    if rule.tier == "pressure" and (not policy.pressure or hp > policy.pressure_hp) then
        return false, "pressure_policy"
    end
    return true
end
local function better(a, b)
    if not b then return true end
    if tier_order[a.tier] ~= tier_order[b.tier] then
        return tier_order[a.tier] < tier_order[b.tier]
    end
    if a.priority ~= b.priority then return a.priority < b.priority end
    if a.hpRatio ~= b.hpRatio then return a.hpRatio < b.hpRatio end
    if a.isSelf ~= b.isSelf then return a.isSelf end
    if a.remaining ~= b.remaining then return a.remaining > b.remaining end
    if a.handle ~= b.handle then return a.handle < b.handle end
    return a.key < b.key
end

-- Only handles and scalar observations leave this call. No GosUnit is retained.
function M.evaluate(context)
    assert(type(context) == "table", "Cleanse.evaluate requires context")
    local policy = context.policy or M.policy()
    local cap = context.capabilities or M.capabilities(context.loadout)
    local requested_tier = context.tier
    local plan = { status = "ready", reason = "no_candidate", candidates = {},
        capabilities = cap, incomplete = false, missing_identity = 0, unknown_definitions = 0 }
    if requested_tier ~= nil and tier_order[requested_tier] == nil then
        plan.status, plan.reason = "unavailable", "invalid_tier"
        return plan
    end
    if not policy.enabled or cap.status ~= "ready" then
        plan.status, plan.reason = "unavailable", not policy.enabled and "disabled" or cap.reason
        return plan
    end
    local world = context.world
    local player = world and world.player or nil
    local player_handle = method(player, "handle")
    if not world or type(world.generation) ~= "number" or type(player_handle) ~= "string" or
        not alive_hp(player) then
        plan.status, plan.reason = "unavailable", "player_unavailable"
        return plan
    end
    plan.generation, plan.player_handle = world.generation, player_handle
    local units = context.friendlies
    if units == nil then units = method(world, "units", { reaction = "friendly" }) end
    if type(units) ~= "table" or #units > MAX_UNITS then
        plan.status, plan.reason = "unavailable", "friendly_roster_unavailable"
        return plan
    end
    local seen = {}
    local function consider(unit)
        local handle = method(unit, "handle")
        if type(handle) ~= "string" or seen[handle] then return end
        seen[handle] = true
        local is_self = handle == player_handle
        if (is_self and not policy.self) or (not is_self and not policy.allies) or
            not target_allowed(unit, context) or
            not in_range(unit, handle, player_handle, cap.range_meters) then return end
        local hp = alive_hp(unit)
        if not hp then return end
        local observed = method(unit, "effects", { kind = "debuff", timed = true })
        if type(observed) ~= "table" or observed.status ~= "ready" or
            observed.truncated ~= false or type(observed.items) ~= "table" or #observed.items > MAX_EFFECTS then
            plan.incomplete = true
            return
        end
        local best
        for i = 1, #observed.items do
            local effect = observed.items[i]
            local rule, reason = M.match(effect)
            local allowed = false
            if rule and (requested_tier == nil or rule.tier == requested_tier) then
                allowed, reason = admissible(rule, effect, cap, policy, hp)
            elseif rule then
                reason = "tier_filtered"
            end
            if reason == "effect_definition_unavailable" then
                plan.missing_identity = plan.missing_identity + 1
                plan.incomplete = true
            elseif reason == "invalid_effect_definition" or reason == "unknown_effect_definition" then
                plan.unknown_definitions = plan.unknown_definitions + 1
                plan.incomplete = true
            end
            if allowed then
                local candidate = { ability = cap.ability, handle = handle,
                    generation = world.generation, player_handle = player_handle,
                    key = rule.key, definition_key = effect.definition_key,
                    effect = rule.label, observed_name = effect.name, name_source = effect.name_source,
                    dispel = rule.dispel, mechanic = rule.mechanic, tier = rule.tier,
                    priority = rule.priority, hpRatio = hp, isSelf = is_self,
                    remaining = effect.remaining, proof = cap.proof[rule.dispel] }
                if better(candidate, best) then best = candidate end
            elseif type(effect) == "table" and reason ~= "tier_filtered" then
                diagnostic(context, effect.name, reason, effect.definition_key)
            end
        end
        if best then plan.candidates[#plan.candidates + 1] = best end
    end
    consider(player)
    for i = 1, #units do consider(units[i]) end
    -- Unknown roster effects do not justify spending a low-value pressure
    -- cleanse before a possibly unseen control. Known controls still qualify.
    if plan.incomplete then
        for i = #plan.candidates, 1, -1 do
            if plan.candidates[i].tier == "pressure" then table.remove(plan.candidates, i) end
        end
    end
    table.sort(plan.candidates, better)
    if #plan.candidates > 0 then plan.reason = "candidates"
    elseif plan.missing_identity > 0 then plan.reason = "effect_definition_unavailable"
    elseif plan.unknown_definitions > 0 then plan.reason = "unknown_effect_definition" end
    return plan
end

local target_reasons = {
    target_not_visible = true, not_visible = true, target_out_of_range = true,
    out_of_range = true, target_invalid = true, invalid_target = true,
    target_unavailable = true, target_not_resolved = true, target_not_in_world = true,
    line_of_sight = true, not_in_line_of_sight = true, target_not_in_line_of_sight = true,
    target_view_blocked = true, too_far = true, too_close = true, not_facing = true,
    target_dead = true, target_untargetable = true, missing_target = true,
}
function M.target_failure(result)
    if type(result) ~= "table" then return false end
    local codes = gos.abilities.result_codes or {}
    for _, label in ipairs({
        "missing_target", "stale_unit", "target_unavailable", "unsupported_target",
        "fallback_target_unavailable", "target_dead", "too_far", "too_close",
        "not_facing", "target_view_blocked", "target_untargetable",
    }) do
        if codes[label] ~= nil and result.code == codes[label] then return true end
    end
    return target_reasons[result.reason] == true
end
function M.explicit_target(result, handle)
    return type(result) == "table" and
        result.target_mode == "explicit" and result.target_valid == true and
        result.requested_target_handle == handle and result.target_handle == handle and
        result.target_fallback == "none" and result.fallback_used ~= true
end

function M.explicit_result(result, handle)
    return type(result) == "table" and result.ok == true and
        M.explicit_target(result, handle)
end

local function revalidate(candidate, context, capabilities)
    local world, policy = context.world, context.policy
    if type(candidate) ~= "table" or not world or not world.player then return nil end
    local is_self = candidate.handle == method(world.player, "handle")
    if (is_self and not policy.self) or (not is_self and not policy.allies) then return nil end
    if world.generation ~= candidate.generation or
        method(world.player, "handle") ~= candidate.player_handle then return nil end
    local unit = candidate.isSelf and world.player or method(world, "resolve", candidate.handle)
    if method(unit, "handle") ~= candidate.handle or not target_allowed(unit, context) or
        not in_range(unit, candidate.handle, candidate.player_handle, capabilities.range_meters) then return nil end
    local hp = alive_hp(unit)
    if not hp then return nil end
    local observed = method(unit, "effects", { kind = "debuff", timed = true })
    if type(observed) ~= "table" or observed.status ~= "ready" or observed.truncated ~= false or
        type(observed.items) ~= "table" or #observed.items > MAX_EFFECTS then return nil end
    for i = 1, #observed.items do
        local effect = observed.items[i]
        local rule = M.match(effect)
        if rule and effect.definition_key == candidate.definition_key and
            rule.key == candidate.key and admissible(rule, effect, capabilities, policy, hp) then
            return unit
        end
    end
end

-- Public same-snapshot revalidation for a caller-owned admission transaction.
-- The caller must re-evaluate a fresh plan after every world generation change.
M.revalidate = revalidate

-- Retained admissions keep identity, while their target/effect comes from the
-- current snapshot. Never stamp a stale candidate with a new generation.
function M.refresh_candidate(candidate, context, capabilities)
    if type(candidate) ~= "table" or type(context) ~= "table" or
        type(context.policy) ~= "table" or type(capabilities) ~= "table" or
        capabilities.status ~= "ready" or capabilities.ability ~= candidate.ability then return nil end
    local world = context.world
    local player = world and world.player
    if method(player, "handle") ~= candidate.player_handle then return nil end
    local unit = candidate.handle == candidate.player_handle and player or
        method(world, "resolve", candidate.handle)
    if method(unit, "handle") ~= candidate.handle then return nil end
    local fresh_context = { world = world, policy = context.policy,
        capabilities = capabilities, friendlies = { unit },
        target_types = context.target_types, tier = context.tier, log = context.log }
    local plan = M.evaluate(fresh_context)
    if plan.status ~= "ready" then return nil end
    for _, fresh in ipairs(plan.candidates) do
        if fresh.handle == candidate.handle and fresh.key == candidate.key and
            fresh.definition_key == candidate.definition_key then
            local resolved = revalidate(fresh, fresh_context, capabilities)
            if resolved then return resolved, fresh end
        end
    end
end

-- submit(candidate, current_unit) is owned by the calling rotation and returns
-- {accepted=bool, owned=bool, admission_pending=bool, reason=string, code=number}.
-- admission_via_submit opts into the caller performing authoritative Core admission.
-- Pending admission consumes the tick but is not a command or a queued cleanse.
-- This helper never creates or polls an AbilityExecutor.
function M.attempt(context)
    assert(type(context) == "table" and type(context.submit) == "function")
    context.policy = context.policy or M.policy()
    if context.active ~= true or not context.policy.enabled or context.pending == true then return false end
    local cap = M.capabilities(context.loadout)
    if cap.status ~= "ready" then
        diagnostic(context, cap.ability, cap.reason)
        return false
    end
    local world = context.world
    local player = world and world.player or nil
    if not player then return false end
    if context.preserve_stealth == true then
        if context.auto_stealth_pending == true then return false end
        local stealth = method(player, "effect", "Stealth", { kind = "buff" })
        if type(stealth) ~= "table" or stealth.status ~= "ready" or
            stealth.present ~= false or stealth.truncated ~= false then return false end
    end
    if gos.abilities.is_casting_or_channeling() ~= false then return false end
    -- Native Core admission owns the GCD/readiness window, just as in the calling
    -- rotations. A second Lua GCD threshold could let prequeued DPS repeatedly
    -- jump ahead of an urgent cleanse. Do not implement another queue here.
    -- Resource cost and cooldown stay authoritative Core observations. A
    -- known running cooldown is a cheap early rejection, not a Lua countdown.
    local ability = cap.ability
    if type(context.ability_name) == "function" then
        ability = context.ability_name(cap.ability)
    end
    if type(ability) ~= "string" or ability == "" then return false end
    local info = gos.abilities.info(ability)
    if type(info) ~= "table" or type(info.ability_handle) ~= "string" or
        info.has_resource_cost ~= true or not finite(info.resource_cost) or info.resource_cost < 0 then return false end
    if info.has_cooldown_remaining == true and finite(info.cooldown_remaining) and
        info.cooldown_remaining > 0 then return false end
    local resource = method(player, "resource")
    if type(resource) ~= "table" or not finite(resource.current) then return false end
    local available = resource.current
    if cap.style == "mercenary" then
        if resource.kind ~= "heat" or not finite(resource.max) or resource.max <= 0 or
            resource.current < 0 or resource.current > resource.max then return false end
        available = resource.max - resource.current
    end
    if available < info.resource_cost then return false end
    context.capabilities = cap
    local plan = M.evaluate(context)
    if plan.missing_identity > 0 and not missing_identity_warned and type(context.log) == "function" then
        missing_identity_warned = true
        context.log("warn", "cleanse: effect definition_key unavailable; missing rows are skipped. " ..
            "Use the Core build with the effect-definition contract; name guessing is disabled.")
    end
    if plan.status ~= "ready" then return false end
    for i = 1, #plan.candidates do
        local candidate = plan.candidates[i]
        local unit = revalidate(candidate, context, cap)
        if unit then
            -- A caller using authoritative submit admission must not gate its
            -- next-tick retry behind a separate advisory request identity.
            local advisory
            if context.admission_via_submit ~= true then
                advisory = gos.abilities.can_cast(info.ability_handle, unit)
            end
            if context.admission_via_submit == true or M.explicit_result(advisory, candidate.handle) then
                local result = context.submit(candidate, unit)
                if type(result) == "table" and (result.accepted == true or result.owned == true or
                    result.admission_pending == true) then
                    if result.accepted == true and type(context.log) == "function" then
                        context.log("info", "cleanse queued=true ability=" .. cap.ability ..
                            " effect=" .. candidate.effect .. " target=" .. candidate.handle ..
                            " definition=" .. candidate.definition_key .. " tier=" .. candidate.tier .. " dispel=" .. candidate.dispel ..
                            " capability=" .. tostring(candidate.proof) .. " outcome=unconfirmed")
                    end
                    return true
                end
                if not M.target_failure(result) then return false end
            elseif not M.target_failure(advisory) then
                return false
            end
        end
    end
    return false
end

return M
