-- Seer Force-state optimizer.
--
-- Resource decisions are based only on current observations. The caller must
-- not credit future crits, Resplendence charges, regeneration or cooldowns.
-- Runtime heal costs are supplied by Core; this module does not duplicate
-- Inner Strength / Immutable Force / Preservation / Force Shelter arithmetic.

local M = {}

M.Mechanics = {
    vindicate_restore = 40,
    resplendence_bonus = 5,
    resplendence_restore = 45,
    resplendence_max_stacks = 3,
    resplendence_duration = 30,
    amnesty_regen_bonus = 2,
    amnesty_duration = 10,
    resplendence_amnesty_full_value = 65,
    weary_regen_penalty = 2,
    weary_max_stacks = 4,
    weary_duration = 10,
    telekinetic_regeneration_fraction_per_hit = 0.02,
}

local IDLE = "idle"
local LIGHT = "light"
local ACTIVE = "active"
local EMERGENCY = "emergency"

M.Pressure = {
    IDLE = IDLE,
    LIGHT = LIGHT,
    ACTIVE = ACTIVE,
    EMERGENCY = EMERGENCY,
}

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function valid_pressure(value)
    return value == IDLE or value == LIGHT or
        value == ACTIVE or value == EMERGENCY
end

local function valid_state(state)
    if type(state) ~= "table" or state.enabled ~= true or
        state.vindicate_known ~= true or state.resplendence_known ~= true or
        not finite(state.current) or
        not finite(state.maximum) or state.maximum <= 0 or state.current < 0 or
        state.current > state.maximum or not finite(state.reserve) or
        state.reserve < 0 or state.reserve > state.maximum or
        not finite(state.soft_fraction) or state.soft_fraction <= 0 or
        state.soft_fraction >= 1 then
        return false
    end
    -- Effect observations are tri-state. Unknown fails closed so a stale
    -- scanner sample cannot authorize an unsafe Vindicate.
    return type(state.resplendence_present) == "boolean" and
        type(state.amnesty_present) == "boolean" and
        type(state.weary_present) == "boolean"
end

local function due(remaining, window)
    return finite(remaining) and finite(window) and window >= 0 and
        remaining <= window
end

local function safe_restore(state)
    if state.resplendence_present then
        return M.Mechanics.resplendence_restore, "resplendence"
    end
    if state.amnesty_present and not state.weary_present then
        return M.Mechanics.vindicate_restore, "amnesty"
    end
    return nil, nil
end

local function recovery_flags(state, pressure)
    local hard = state.current <= state.reserve
    local soft = state.current / state.maximum <= state.soft_fraction
    local low_pressure = pressure == IDLE or pressure == LIGHT
    return hard, soft, low_pressure,
        hard or state.weary_present or (low_pressure and soft)
end

-- Returns action, reason, recovery_needed, safe_available.
-- action is one of: vindicate, build_resplendence,
-- telekinetic_regeneration, hold.
function M.plan(state, context)
    context = type(context) == "table" and context or {}
    local pressure = context.pressure or ACTIVE
    if not valid_state(state) or not valid_pressure(pressure) then
        return "hold", "force_state_unknown", false, false
    end

    local restore, safe_kind = safe_restore(state)
    local safe_available = restore ~= nil
    local hard, soft, low_pressure, recovery_needed =
        recovery_flags(state, pressure)
    local room = state.maximum - state.current
    local cash_window = finite(context.amnesty_cash_window) and
        math.max(0, context.amnesty_cash_window) or 0
    local amnesty_due = state.amnesty_present and
        due(state.amnesty_remaining, cash_window)

    if pressure == EMERGENCY then
        if context.allow_safe_emergency_recovery == true and hard and
            restore ~= nil and room >= restore then
            return "vindicate",
                safe_kind == "resplendence" and
                    "resplendence_emergency_hard_reserve" or
                    "amnesty_emergency_hard_reserve",
                true, true
        end
        return "hold", "emergency_healing_first",
            recovery_needed, safe_available
    end

    if state.weary_present then
        if state.resplendence_present then
            if (low_pressure or hard) and
                room >= M.Mechanics.resplendence_restore then
                return "vindicate", "resplendence_repair_weary", true, true
            end
            return "hold", "weary_repair_wait_for_window", true, true
        end
        if low_pressure or hard then
            if context.can_build_resplendence == true then
                return "build_resplendence", "build_to_repair_weary",
                    true, false
            end
            if context.force_barrier_purge_available == true then
                return "hold", "weary_barrier_purge_manual", true, false
            end
        end
        return "hold", "weary_healing_first", true, false
    end

    if state.resplendence_present then
        local capped_resplendence =
            type(state.resplendence_stacks) == "number" and
            state.resplendence_stacks >= M.Mechanics.resplendence_max_stacks
        if state.amnesty_present then
            if hard and room >= M.Mechanics.resplendence_restore then
                return "vindicate", "resplendence_hard_reserve_refresh",
                    true, true
            end
            if pressure ~= EMERGENCY and capped_resplendence and
                room >= M.Mechanics.resplendence_restore then
                return "vindicate", "resplendence_avoid_overflow",
                    true, true
            end
            if low_pressure and amnesty_due and
                room >= M.Mechanics.resplendence_restore then
                return "vindicate",
                    "resplendence_refresh_expiring_amnesty", true, true
            end
            -- The configured soft recovery threshold is an instruction, not a
            -- hint. During idle/light pressure, an observed Resplendence token
            -- should recover Force even while Amnesty is already running.
            -- Waiting for passive +2/s regeneration made the live route appear
            -- frozen at ~40-60% Force despite having a safe +45 Vindicate.
            if low_pressure and soft and
                room >= M.Mechanics.resplendence_restore then
                return "vindicate", "resplendence_soft_recovery", true, true
            end
            return "hold", "force_comfortable", recovery_needed, true
        end

        local overflow_bank = pressure ~= EMERGENCY and
            capped_resplendence and
            room >= M.Mechanics.resplendence_restore
        if overflow_bank then
            return "vindicate", "resplendence_avoid_overflow", true, true
        end
        -- Starting Amnesty is worth more than the immediate +45 Force. In
        -- pure downtime reserve enough headroom for its full +20 regeneration
        -- value as well; otherwise a near-full bar just converts the buff into
        -- overcap. Light healing may spend sooner because incoming heal costs
        -- will create that headroom naturally.
        local downtime_bank = pressure == IDLE and
            room >= M.Mechanics.resplendence_amnesty_full_value
        local pressure_recovery = (low_pressure and soft) or hard
        if (downtime_bank or pressure_recovery) and
            room >= M.Mechanics.resplendence_restore then
            return "vindicate", "resplendence_start_amnesty", true, true
        end
        return "hold", "healing_or_force_comfortable",
            recovery_needed, true
    end

    if state.amnesty_present then
        if hard and room >= M.Mechanics.vindicate_restore then
            return "vindicate", "amnesty_cash_hard_reserve", true, true
        end
        if low_pressure and amnesty_due and
            room >= M.Mechanics.vindicate_restore then
            return "vindicate", "amnesty_cash_expiring", true, true
        end
        if low_pressure and soft then
            if pressure == IDLE and
                context.can_telekinetic_regenerate == true then
                return "telekinetic_regeneration",
                    "bank_amnesty_with_telekinetic_regeneration",
                    true, true
            end
            if context.can_build_resplendence == true then
                return "build_resplendence",
                    "build_while_amnesty_ticks", true, true
            end
            return "hold", "bank_amnesty_regeneration", true, true
        end
        return "hold", "healing_or_force_comfortable",
            recovery_needed, true
    end

    if recovery_needed then
        if pressure == IDLE and
            context.can_telekinetic_regenerate == true then
            return "telekinetic_regeneration",
                "telekinetic_regeneration_before_weary", true, false
        end
        if context.can_build_resplendence == true then
            return "build_resplendence",
                hard and "build_at_hard_reserve" or
                    "build_for_soft_recovery",
                true, false
        end
        return "hold", "passive_regeneration_before_weary", true, false
    end

    return "hold", "force_comfortable", false, false
end

-- Called only after the route has already attempted every useful heal allowed
-- by current triage. A debt-producing Vindicate is admitted only when one
-- +40 activation actually unlocks the cheapest currently useful paid heal.
function M.last_resort(state, context)
    context = type(context) == "table" and context or {}
    local pressure = context.pressure or ACTIVE
    if not valid_state(state) or not valid_pressure(pressure) then
        return "hold", "force_state_unknown", false
    end

    local restore, safe_kind = safe_restore(state)
    local hard = state.current <= state.reserve
    local minimum = context.minimum_useful_paid_cost
    local unlocks_paid_heal = finite(minimum) and minimum > 0 and
        state.current < minimum and state.current + (restore or 0) >= minimum
    if restore ~= nil and state.current < state.maximum and
        (hard or unlocks_paid_heal) and
        (hard or pressure == EMERGENCY or context.urgent == true) then
        return "vindicate",
            safe_kind == "resplendence" and
                "safe_last_resort_resplendence" or
                "safe_last_resort_amnesty",
            true
    end

    if context.allow_debt ~= true or hard ~= true or
        not finite(minimum) or minimum <= 0 then
        return "hold", "debt_vindicate_not_justified", false
    end

    if state.current < minimum and
        state.current + M.Mechanics.vindicate_restore >= minimum then
        return "vindicate", "emergency_force_loan_weary", false
    end
    return "hold", "debt_vindicate_does_not_unlock_heal", false
end

function M.potency_worth_spending_for_build(reason)
    return reason == "build_at_hard_reserve" or
        reason == "build_to_repair_weary"
end

return M
