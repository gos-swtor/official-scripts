-- Seer healing action planner.
--
-- Pure policy only: no gos calls, no casts, no guessed heal amounts.
-- IDF determines patient urgency; this module determines which authored
-- Seer mechanic should own the next healing GCD.
local M = {}

M.Severity = {
    LIFE = "life_saving",
    EMERGENCY = "emergency",
    ACTIVE = "active",
    ROUTINE = "routine",
    IDLE = "idle",
}

local function add(plan, seen, id, reason, target, hold)
    if seen[id] then return end
    seen[id] = true
    plan[#plan + 1] = {
        id = id,
        reason = reason,
        target = target or "patient",
        hold = hold ~= false,
    }
end

local function available(ctx, key)
    return ctx.abilities and ctx.abilities[key] == true
end
local function rejuvenate_useful(ctx)
    if not available(ctx, "rejuvenate") or
        ctx.force_potency_active == true then
        return false
    end
    return ctx.target_rejuvenate ~= true or
        ctx.renewal_refresh == true
end

local function needs_resplendence(ctx)
    if ctx.resplendence_known ~= true then return false end
    if type(ctx.resplendence_stacks) ~= "number" then return true end
    if ctx.resplendence_stacks >= 3 then return false end
    if ctx.resplendence_stacks < 2 then return true end
    return ctx.force_soft_low == true
end

local function urgent(ctx)
    return ctx.severity == M.Severity.LIFE or
        ctx.severity == M.Severity.EMERGENCY
end

local function group_pressure(ctx)
    return (ctx.wandering_count or 0) >= 2 or
        (ctx.salvation_count or 0) >= 3
end
function M.plan(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local plan, seen = {}, {}
    if ctx.severity == nil or ctx.severity == M.Severity.IDLE then
        return plan
    end

    local is_life = ctx.severity == M.Severity.LIFE
    local is_urgent = urgent(ctx)
    local has_conveyance = ctx.conveyance == true
    local has_altruism = ctx.altruism == true
    local potency = ctx.force_potency_active == true
    local rejuv = rejuvenate_useful(ctx)
    local need_resplendence = needs_resplendence(ctx)
    local resplendence_capped = type(ctx.resplendence_stacks) == "number" and
        ctx.resplendence_stacks >= 3
    local recovery_claimed = ctx.force_action == "vindicate" and
        (ctx.force_hard_low == true or resplendence_capped)
    local wandering_group = (ctx.wandering_count or 0) >= 2
    local salvation_group = (ctx.salvation_count or 0) >=
        (ctx.salvation_min or 3)
    local salvation_high = (ctx.salvation_count or 0) >=
        math.max(4, ctx.salvation_min or 3)

    local function spendable(key)
        if not available(ctx, key) then return false end
        if is_urgent then return true end
        local allowed = ctx.spend_allowed
        return type(allowed) ~= "table" or allowed[key] ~= false
    end

    -- Throughput cooldowns are setup actions, not replacements for healing.
    if ctx.heavy_pressure == true and
        available(ctx, "mental_alacrity") and
        ctx.mental_alacrity_active == false then
        add(plan, seen, "mental_alacrity",
            "heavy_pressure_alacrity", "self", false)
    end

    -- True life-saving self-heal gets first refusal because it is immediate
    -- HP and cannot be redirected to another patient.
    if is_life and ctx.patient_is_self and ctx.force_mend_candidate and
        spendable("force_mend") then
        add(plan, seen, "force_mend", "self_life_saving", "self")
    end

    -- An already-earned instant Altruism Benevolence is immediate rescue HP
    -- and beats prevention. Do not throw away an instant proc just to shield.
    if is_urgent and has_altruism and spendable("benevolence") then
        add(plan, seen, "benevolence",
            has_conveyance and "altruism_conveyance_benevolence" or
                "altruism_urgent_benevolence")
    end

    -- Prevention-first under proven/high incoming pressure after immediate
    -- rescue procs. Force Armor buys the next GCD for the larger/slower heal
    -- instead of trying to race raw incoming damage with throughput alone.
    local pressure_armor = ctx.armor_allowed and spendable("armor") and
        (ctx.incoming_exact or is_urgent or ctx.idf_urgent or
            ctx.pressure_shield or ctx.pressure_active)
    if pressure_armor then
        add(plan, seen, "armor",
            ctx.incoming_exact and "incoming_exact_armor" or
                "pressure_armor")
    end

    -- Under sustained Emergency pressure, an observed safe +40/+45 restore at
    -- the configured reserve prevents the zero-Force spiral. Free Altruism and
    -- prevention above keep first refusal; Life-saving treatment still does.
    if is_urgent and not is_life and ctx.force_action == "vindicate" and
        ctx.force_hard_low == true then
        add(plan, seen, "vindicate",
            "force_optimizer_" .. tostring(ctx.force_reason or "recovery"),
            "self")
    end

    -- Remaining life-saving throughput follows prevention.
    if is_life then
        if has_altruism and spendable("benevolence") then
            add(plan, seen, "benevolence", "altruism_life_saving")
        end
        if ctx.armor_allowed and spendable("armor") then
            add(plan, seen, "armor", "armor_life_saving")
        end
    end

    -- Spend Altruism instead of allowing it to be overwritten. When the
    -- patient is stable enough and Conveyance is absent, Rejuvenate may set up
    -- the premium Altruism + Conveyance Benevolence combination first.
    if has_altruism and spendable("benevolence") then
        if has_conveyance or ctx.altruism_expiring or is_urgent then
            add(plan, seen, "benevolence",
                has_conveyance and "altruism_conveyance_benevolence" or
                    "altruism_urgent_benevolence")
        elseif rejuv and not potency and not salvation_high and
            not recovery_claimed then
            add(plan, seen, "rejuvenate", "altruism_combo_rejuvenate")
            add(plan, seen, "benevolence", "altruism_combo_fallback")
        else
            add(plan, seen, "benevolence", "altruism_available")
        end
    end

    -- Spend capped stacks before another non-urgent Trance, including when
    -- Potency is already active. Vindicate does not spend the Potency charge.
    -- Immediate rescue/prevention above and urgent healing still come first.
    if not is_urgent and ctx.force_action == "vindicate" and resplendence_capped then
        add(plan, seen, "vindicate",
            "force_optimizer_" .. tostring(ctx.force_reason or "recovery"),
            "self")
    end

    -- Active Force Potency is a reservation. Never throw it away on
    -- Rejuvenate or Wandering Mend. Trance is the preferred spender; Armor can
    -- safely occupy a GCD without consuming the charge, and direct filler is a
    -- valid healing spender if Trance is unavailable.
    if potency then
        if spendable("trance") then
            add(plan, seen, "trance", "force_potency_trance")
        end
        if ctx.armor_allowed and spendable("armor") then
            add(plan, seen, "armor", "force_potency_preserve_armor")
        end
        if spendable("filler") and
            ctx.target_ratio <= (ctx.filler_threshold or 0) then
            add(plan, seen, "filler", "force_potency_direct_heal")
        end
    elseif ctx.heavy_pressure == true and
        ctx.force_potency_enabled == true and
        available(ctx, "force_potency") and
        spendable("trance") and not has_conveyance then
        add(plan, seen, "force_potency",
            "heavy_pressure_force_potency", "self", false)
    end

    -- Preserve the existing hard-reserve order when stacks are not capped.
    if not is_urgent and ctx.force_action == "vindicate" and ctx.force_hard_low == true then
        add(plan, seen, "vindicate",
            "force_optimizer_" .. tostring(ctx.force_reason or "recovery"), "self")
    end

    -- Existing Conveyance is valuable and should be spent before creating a
    -- new one. Trance owns it when Resplendence/Aura value is high; otherwise
    -- group throughput can consume it.
    if has_conveyance and not potency then
        if spendable("trance") and
            (need_resplendence or ctx.aura_cluster or is_life) then
            add(plan, seen, "trance",
                ctx.aura_cluster and "conveyance_rejuvenating_aura" or
                    "conveyance_resplendence")
        end
        if spendable("wandering") and
            ctx.wandering_active ~= true and wandering_group then
            add(plan, seen, "wandering",
                "conveyance_wandering_group", "wandering")
        end
        if spendable("salvation") and salvation_group and
            (not is_urgent or ctx.salvation_covers_patient) then
            add(plan, seen, "salvation",
                "conveyance_salvation_group", "salvation")
        end
    end

    -- High-value group healing may preempt fresh single-target setup. Four
    -- stacked patients justify Salvation; two connected injured patients make
    -- Wandering Mend worth using immediately.
    if not potency and not is_life then
        if not is_urgent and spendable("salvation") and salvation_high then
            add(plan, seen, "salvation", "salvation_high_value", "salvation")
        end
        if spendable("wandering") and
            ctx.wandering_active ~= true and wandering_group then
            add(plan, seen, "wandering",
                is_urgent and "wandering_emergency_group" or
                    "wandering_group", "wandering")
        end
    end

    -- Rejuvenate is the engine opener. In ordinary single-target healing it
    -- comes before routine shielding, and Renewal/Force Shelter explicitly
    -- permit useful clipping. It is withheld only while Potency is active or
    -- while an existing Conveyance proc still needs to be spent.
    if rejuv and not potency and not has_conveyance and
        spendable("rejuvenate") then
        add(plan, seen, "rejuvenate",
            ctx.target_rejuvenate == true and
                "rejuvenate_refresh_engine" or "rejuvenate_engine")
    end

    -- Routine Force Armor is the next single-target fallback after Rejuvenate.
    -- The route already removed ineligible/locked-out targets and applies the
    -- Force-reserve gate through spend_allowed.
    if ctx.armor_allowed and spendable("armor") then
        add(plan, seen, "armor", "armor_maintenance")
    end

    -- Wandering Mend remains a strong mobile heal even without group pressure
    -- when the selected patient is sufficiently low. Never consume Potency on
    -- it.
    if not potency and spendable("wandering") and
        ctx.wandering_active ~= true and
        (wandering_group or
            ctx.target_ratio <= (ctx.wandering_threshold or 0)) then
        add(plan, seen, "wandering",
            wandering_group and "wandering_group" or
                "wandering_single", "wandering")
    end

    -- Three-target Salvation is efficient, but unlike the 4+ case it does not
    -- steal the initial engine/mitigation GCD from a single patient.
    if spendable("salvation") and salvation_group and not is_urgent then
        add(plan, seen, "salvation", "salvation_group", "salvation")
    end

    -- Healing Trance is core throughput and the Resplendence engine. It is not
    -- held behind the old low-HP threshold when we need stacks or are actively
    -- treating a patient.
    if spendable("trance") and
        (is_urgent or need_resplendence or ctx.aura_cluster or
            ctx.target_ratio <= (ctx.trance_threshold or 0)) then
        add(plan, seen, "trance",
            need_resplendence and "trance_resplendence_engine" or
                "healing_trance")
    end

    -- If Conveyance was present but no stronger spender could be used,
    -- Deliverance/Keeper is a valid final spender and naturally creates
    -- Altruism for the next tick.
    if spendable("filler") and
        ctx.target_ratio <= (ctx.filler_threshold or 0) then
        add(plan, seen, "filler",
            has_conveyance and "conveyance_direct_fallback" or
                "direct_filler")
    end

    -- Refresh Rejuvenate only after an existing Conveyance proc had a chance to
    -- be consumed. This catches Renewal clipping after stronger actions fail.
    if rejuv and not potency and has_conveyance and
        spendable("rejuvenate") then
        add(plan, seen, "rejuvenate",
            ctx.target_rejuvenate == true and
                "rejuvenate_refresh" or "rejuvenate")
    end

    -- A covered emergency may use Salvation only after direct rescue actions.
    if is_urgent and spendable("salvation") and
        ctx.salvation_covers_patient and salvation_group then
        add(plan, seen, "salvation",
            "emergency_salvation_fallback", "salvation")
    end

    -- Soft Force recovery is a downtime/light-pressure action. It never
    -- preempts a useful normal heal, but it is preferable to idling once those
    -- options are exhausted.
    local light_active = ctx.severity == M.Severity.ACTIVE and
        ctx.target_ratio > (ctx.trance_threshold or 0.90)
    if ctx.force_action == "vindicate" and
        not is_urgent and
        (ctx.severity == M.Severity.ROUTINE or light_active) then
        add(plan, seen, "vindicate",
            "force_optimizer_" .. tostring(ctx.force_reason or "recovery"),
            "self")
    elseif ctx.force_action == "build_resplendence" and
        not is_urgent and not resplendence_capped and available(ctx, "trance") then
        add(plan, seen, "trance", "force_build_resplendence")
    end

    -- Append the existing safe alternatives after the ideal chain. add()
    -- preserves priority and deduplicates them; the route can then continue in
    -- the same tick when a nonempty ideal plan exhausts on cooldown, missing
    -- metadata, movement, range or rejection. Timing/ownership gates still hold.
    do
        if is_life or is_urgent then
            -- Prevention-first under burst pressure. A legal Force Armor buys
            -- the next GCD for the larger heal instead of trying to race raw
            -- incoming damage with throughput alone.
            if ctx.armor_allowed and spendable("armor") and
                (ctx.incoming_exact or ctx.idf_urgent or
                    ctx.pressure_shield or ctx.pressure_active or is_urgent) then
                add(plan, seen, "armor", "no_idle_armor_rescue")
            end
            if has_altruism and spendable("benevolence") then
                add(plan, seen, "benevolence", "no_idle_altruism_rescue")
            end
            if spendable("wandering") and ctx.wandering_active ~= true then
                add(plan, seen, "wandering", "no_idle_wandering_rescue", "wandering")
            end
            if spendable("filler") then
                add(plan, seen, "filler", "no_idle_direct_rescue")
            end
            if spendable("trance") then
                add(plan, seen, "trance", "no_idle_trance_rescue")
            end
            if not potency and spendable("rejuvenate") then
                add(plan, seen, "rejuvenate", "no_idle_rejuvenate_rescue")
            end
        elseif ctx.severity == M.Severity.ACTIVE or
            ctx.severity == M.Severity.ROUTINE then
            local mild = ctx.target_ratio >=
                math.max(0.80, ctx.trance_threshold or 0.80)
            local preventive_armor = ctx.armor_allowed and spendable("armor") and
                (ctx.incoming_exact or ctx.idf_urgent or
                    ctx.pressure_shield or ctx.pressure_active)
            if preventive_armor then
                add(plan, seen, "armor", "no_idle_pressure_armor_active")
            end
            if mild and not potency and spendable("rejuvenate") then
                add(plan, seen, "rejuvenate", "no_idle_rejuvenate_maintenance")
            end
            if mild and ctx.armor_allowed and spendable("armor") then
                add(plan, seen, "armor", "no_idle_armor_maintenance")
            end
            if not potency and spendable("wandering") and
                ctx.wandering_active ~= true and not mild then
                add(plan, seen, "wandering", "no_idle_wandering_active", "wandering")
            end
            if spendable("trance") then
                add(plan, seen, "trance", "no_idle_trance_active")
            end
            if spendable("filler") then
                add(plan, seen, "filler", "no_idle_direct_active")
            end
            if not potency and spendable("rejuvenate") then
                add(plan, seen, "rejuvenate", "no_idle_rejuvenate_active")
            end
            if ctx.armor_allowed and spendable("armor") then
                add(plan, seen, "armor", "no_idle_armor_active")
            end
        end
    end

    return plan
end

function M.severity(target_ratio, triage_band, heal_start)
    if triage_band == 0 or target_ratio <= 0.20 then
        return M.Severity.LIFE
    end
    if triage_band == 1 or target_ratio <= 0.60 then
        return M.Severity.EMERGENCY
    end
    if target_ratio <= (heal_start or 0.95) then
        return M.Severity.ACTIVE
    end
    return M.Severity.ROUTINE
end

function M.describe(plan)
    local result = {}
    for index = 1, #(plan or {}) do
        local row = plan[index]
        result[#result + 1] = tostring(row.id) .. ":" ..
            tostring(row.reason)
    end
    return table.concat(result, ",")
end

return M
